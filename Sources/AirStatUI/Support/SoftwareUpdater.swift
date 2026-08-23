import AppKit
import Foundation
import Observation
import Sparkle

/// AirStats' whole update mechanism: Sparkle, plus the small amount of state SwiftUI
/// needs to draw a button and a toggle against it.
///
/// Sparkle owns the schedule, the download, the signature checks, the install and the
/// relaunch. Nothing here decides any of that. What it does is bridge two Objective-C
/// properties into something a view can observe: `SPUUpdater` publishes
/// `canCheckForUpdates` through KVO and nothing else, so a pane reading
/// `lastUpdateCheckDate` directly would keep showing whatever was true when it was
/// first drawn.
///
/// The automatic-check preference lives in Sparkle's own UserDefaults rather than in
/// `Settings`. Two stores for one switch is how an app ends up honouring only one of
/// them: Sparkle reads its copy whatever AirStats thinks.
@MainActor
@Observable
public final class SoftwareUpdater {

    /// False while a check is in flight, which is also what tells us one has finished:
    /// Sparkle raises no notification when it writes `lastUpdateCheckDate`, so the
    /// footnote follows the only property it does publish.
    public private(set) var canCheck: Bool = false
    public private(set) var lastCheck: Date?
    public private(set) var checksAutomatically: Bool
    /// Whether Sparkle downloads and installs on its own. Off until the user says
    /// otherwise, either here or in Sparkle's own window, which offers the same choice
    /// the first time it installs something.
    public private(set) var installsAutomatically: Bool

    /// The release a scheduled check found and Sparkle has been told not to announce
    /// itself, or nil. Set for as long as that update is outstanding, which is what the
    /// panel row and the one-time notice are drawn from.
    public private(set) var pendingVersion: String?

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    /// Retained here because `SPUStandardUpdaterController` holds its delegates weakly.
    @ObservationIgnored private let feed: FeedOverride
    @ObservationIgnored private let reminders: GentleReminders
    @ObservationIgnored private var observation: NSKeyValueObservation?

    public init() {
        let feed = FeedOverride()
        let reminders = GentleReminders()
        // Started from `start()` instead, so the first appcast request happens when the
        // rest of the app comes up rather than while it is still being assembled.
        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                     updaterDelegate: feed,
                                                     userDriverDelegate: reminders)
        self.feed = feed
        self.reminders = reminders
        self.controller = controller
        self.checksAutomatically = controller.updater.automaticallyChecksForUpdates
        self.installsAutomatically = controller.updater.automaticallyDownloadsUpdates
        reminders.onPending = { [weak self] version in self?.pendingVersion = version }
        reminders.onResolved = { [weak self] in self?.pendingVersion = nil }
    }

    public func start() {
        controller.startUpdater()
        sync()
        observation = controller.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    /// The user asked. Sparkle answers in its own window, with an update, an error or
    /// "you are up to date", which is the reason this app links it at all.
    ///
    /// The activation is ours rather than Sparkle's. Sparkle activates the app too, but
    /// only from inside the same call, and by then this app has nothing to activate
    /// from: the panel this is usually called from never makes AirStats active, and it
    /// closes on the way out. Its window then opens behind whatever the user was
    /// looking at, which reads exactly like the button having done nothing.
    public func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }

    public func setChecksAutomatically(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
    }

    public func setInstallsAutomatically(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
        installsAutomatically = controller.updater.automaticallyDownloadsUpdates
    }

    private func sync() {
        canCheck = controller.updater.canCheckForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        installsAutomatically = controller.updater.automaticallyDownloadsUpdates
    }
}

/// Keeps a scheduled update out of the user's way until they ask for it.
///
/// Sparkle's own alert is a window that arrives unasked and takes focus. That is right
/// for an app someone is looking at and wrong for this one, whose whole claim is that it
/// stays out of the way: the check runs on a timer, so the window would land in
/// the middle of whatever the user was doing, to say something that can wait.
///
/// So a scheduled find is answered by a row in the panel and one notification, and
/// Sparkle's window is shown only when the user acts on either. A check the user asked
/// for is untouched, because then the window is the answer to their question.
@MainActor
private final class GentleReminders: NSObject, SPUStandardUserDriverDelegate {

    var onPending: ((String) -> Void)?
    var onResolved: (() -> Void)?

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Always ours, whatever `immediateFocus` says.
    ///
    /// Sparkle sets that flag at launch, on the reasoning that an app the user just
    /// opened is an app they are looking at. It does not hold here: this app is opened
    /// by the login item, minutes before anyone touches the machine, and taking that as
    /// permission to put a window up is how a background app ends up greeting someone
    /// with a dialog they did not ask for.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        WindowLog.log("update offered quietly version=\(version)")
        MainActor.assumeIsolated { onPending?(version) }
    }

    /// The user has the update in front of them, so the standing notice has done its job.
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        WindowLog.log("update taken up by the user")
        MainActor.assumeIsolated { onResolved?() }
    }

    /// Installed, skipped, or put off. Sparkle raises the next one when it is due.
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        WindowLog.log("update session finished")
        MainActor.assumeIsolated { onResolved?() }
    }
}

/// Sends Sparkle to a staging appcast when `defaults write com.airstat.AirStats
/// AirStatsFeedURL <https url>` is set, so a release can be tested end to end against a
/// preview host without editing Info.plist and rebuilding. Unset, Sparkle uses the
/// `SUFeedURL` the app ships with.
private final class FeedOverride: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "AirStatsFeedURL")
    }
}
