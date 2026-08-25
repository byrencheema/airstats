import AppKit
import Foundation
import Observation
import Sparkle

/// A release Sparkle has found and the user has not yet installed or refused.
///
/// Drawn by the panel row, persisted so a relaunch does not forget it, and announced
/// once by `UpdateAnnouncer`. The stage decides what the row offers: an update that
/// only exists in the appcast needs Sparkle's window to download it, while one the
/// automatic installer has already staged needs nothing but a relaunch.
public struct PendingUpdate: Equatable, Sendable {

    public enum Stage: Int, Comparable, Sendable {
        /// In the appcast. Installing means opening Sparkle's window.
        case available
        /// Downloaded but not staged. Still Sparkle's window to install.
        case downloaded
        /// Staged by the automatic installer. A relaunch finishes it, no window needed.
        case ready

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// What people call it, `1.4`. Drawn, never compared.
    public var version: String
    /// `CFBundleVersion`, which is what Sparkle compares. Kept so a restored record can
    /// be checked against the running bundle without guessing at display strings.
    public var build: String
    public var stage: Stage

    public init(version: String, build: String, stage: Stage) {
        self.version = version
        self.build = build
        self.stage = stage
    }

    public var isReadyToInstall: Bool { stage == .ready }
}

/// AirStats' whole update mechanism: Sparkle, plus the small amount of state SwiftUI
/// needs to draw a row, a button and two toggles against it.
///
/// Sparkle owns the schedule, the download, the signature checks, the install and the
/// relaunch. What this owns is the answer to "is there an update outstanding, and what
/// does the user have to do about it", which Sparkle answers only through delegate
/// calls and only for as long as the process lives.
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
    /// Why the last check failed, or nil. Sparkle writes `lastUpdateCheckDate` on
    /// failure too, so without this a feed that has been unreachable for a month reads
    /// as "checked two minutes ago" and nothing else.
    public private(set) var lastCheckFailure: String?
    public private(set) var checksAutomatically: Bool
    /// Whether Sparkle downloads and installs on its own. Off until the user says
    /// otherwise, either here or in Sparkle's own window, which offers the same choice
    /// the first time it installs something.
    public private(set) var installsAutomatically: Bool

    /// The release that is outstanding, or nil. Set from the moment a check finds one
    /// until it is installed or skipped, across relaunches.
    public private(set) var pending: PendingUpdate? {
        didSet { Self.store(pending, in: defaults) }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    /// Retained here because `SPUStandardUpdaterController` holds its delegates weakly.
    @ObservationIgnored private let hooks: UpdaterHooks
    @ObservationIgnored private let reminders: GentleReminders
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var unattendedObservers: [any NSObjectProtocol] = []
    /// Sparkle's "install this now and relaunch", handed over once the automatic
    /// installer has staged an update. Held until the machine is unattended.
    @ObservationIgnored private var installStaged: (() -> Void)?

    public init(defaults: UserDefaults = .standard) {
        let hooks = UpdaterHooks()
        let reminders = GentleReminders()
        // Started from `start()` instead, so the first appcast request happens when the
        // rest of the app comes up rather than while it is still being assembled.
        let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                     updaterDelegate: hooks,
                                                     userDriverDelegate: reminders)
        self.hooks = hooks
        self.reminders = reminders
        self.controller = controller
        self.defaults = defaults
        self.checksAutomatically = controller.updater.automaticallyChecksForUpdates
        self.installsAutomatically = controller.updater.automaticallyDownloadsUpdates
        // Restored before Sparkle starts so the row is there from the first frame and
        // not from the next weekly check. A record for the version now running is what
        // an install leaves behind, and is dropped rather than shown.
        if let stored = Self.load(from: defaults),
           Self.shouldRestore(pendingBuild: stored.build, runningBuild: Self.runningBuild) {
            self.pending = stored
            WindowLog.log("update restored version=\(stored.version) build=\(stored.build)")
        }

        hooks.onFound = { [weak self] item in self?.note(item, at: .available) }
        hooks.onDownloaded = { [weak self] item in self?.note(item, at: .downloaded) }
        hooks.onStaged = { [weak self] item, install in
            self?.note(item, at: .ready)
            self?.installStaged = install
        }
        hooks.onChoice = { [weak self] choice in self?.resolve(choice) }
        hooks.onNothingFound = { [weak self] in self?.pending = nil }
        hooks.onCycleFinished = { [weak self] failure in
            self?.lastCheckFailure = failure
            self?.sync()
        }
        reminders.onOffered = { [weak self] item, stage in self?.note(item, at: stage) }
    }

    public func start() {
        controller.startUpdater()
        sync()
        observation = controller.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        observeUnattended()
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

    /// What the panel row does. A staged update relaunches into the new version
    /// straight away; anything earlier goes through Sparkle's window, which is where
    /// the download and the release notes live.
    public func installPending() {
        if let installStaged {
            WindowLog.log("update install requested from the row")
            installStaged()
        } else {
            checkForUpdates()
        }
    }

    public func setChecksAutomatically(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
    }

    public func setInstallsAutomatically(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
        installsAutomatically = controller.updater.automaticallyDownloadsUpdates
    }

    // MARK: Bookkeeping

    /// Records a release, never letting it slip back a stage: Sparkle reports the same
    /// item from several places, and "found" arriving after "downloaded" is a repeat,
    /// not a regression.
    private func note(_ item: SUAppcastItem, at stage: PendingUpdate.Stage) {
        let update = PendingUpdate(version: item.displayVersionString,
                                   build: item.versionString, stage: stage)
        pending = Self.merge(current: pending, incoming: update)
        WindowLog.log("update pending version=\(update.version) build=\(update.build) stage=\(stage)")
    }

    /// Only a choice ends the row. "Remind me later" is not one: it is the user
    /// agreeing the row can stand.
    private func resolve(_ choice: SPUUserUpdateChoice) {
        switch choice {
        case .skip:
            WindowLog.log("update skipped by the user")
            pending = nil
        case .install:
            WindowLog.log("update taken up by the user")
        case .dismiss:
            WindowLog.log("update put off by the user")
        @unknown default:
            break
        }
    }

    /// Sparkle's automatic installer leaves a staged update for the app's next quit,
    /// and this app does not quit: it is a login item that runs until the machine
    /// does. So the quit is provided for it, at the first moment nobody is looking.
    private func observeUnattended() {
        let workspace = NSWorkspace.shared.notificationCenter
        unattendedObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.installIfUnattended(reason: "display slept") }
            })
        unattendedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.installIfUnattended(reason: "screen locked") }
            })
    }

    private func installIfUnattended(reason: String) {
        guard let installStaged else { return }
        WindowLog.log("update installing unattended reason=\(reason)")
        installStaged()
    }

    private func sync() {
        canCheck = controller.updater.canCheckForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        installsAutomatically = controller.updater.automaticallyDownloadsUpdates
    }

    // MARK: Pure

    /// The stage only ever climbs, and a different release replaces the record outright.
    public nonisolated static func merge(current: PendingUpdate?, incoming: PendingUpdate) -> PendingUpdate {
        guard let current, current.build == incoming.build else { return incoming }
        var merged = incoming
        merged.stage = max(current.stage, incoming.stage)
        return merged
    }

    /// Whether a record from a previous launch is still news. Compared the way Sparkle
    /// compares, on build numbers, so `10` outranks `9` rather than sorting before it.
    public nonisolated static func shouldRestore(pendingBuild: String, runningBuild: String?) -> Bool {
        guard !pendingBuild.isEmpty, let runningBuild else { return false }
        return SUStandardVersionComparator.default.compareVersion(pendingBuild, toVersion: runningBuild) == .orderedDescending
    }

    private nonisolated static let pendingKey = "AirStatsPendingUpdate"

    private nonisolated static var runningBuild: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// Only the identity is written. The stage is not, because it describes Sparkle's
    /// in-process state, which does not survive the process either: a staged install
    /// runs on quit, and a half-downloaded one is fetched again.
    private nonisolated static func store(_ update: PendingUpdate?, in defaults: UserDefaults) {
        guard let update else {
            defaults.removeObject(forKey: pendingKey)
            return
        }
        defaults.set(["version": update.version, "build": update.build], forKey: pendingKey)
    }

    private nonisolated static func load(from defaults: UserDefaults) -> PendingUpdate? {
        guard let stored = defaults.dictionary(forKey: pendingKey),
              let version = stored["version"] as? String,
              let build = stored["build"] as? String else { return nil }
        return PendingUpdate(version: version, build: build, stage: .available)
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

    var onOffered: ((SUAppcastItem, PendingUpdate.Stage) -> Void)?

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
        let stage: PendingUpdate.Stage = state.stage == .notDownloaded ? .available : .downloaded
        WindowLog.log("update offered quietly version=\(update.displayVersionString) stage=\(stage)")
        MainActor.assumeIsolated { onOffered?(update, stage) }
    }

    /// Opening the window is not deciding. The row stands until the user installs or
    /// skips, which arrive through `UpdaterHooks`; "Remind me later" leaves it alone.
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        WindowLog.log("update shown to the user")
    }
}

/// Everything Sparkle tells its updater delegate that this app acts on.
///
/// The automatic installer never speaks to the user driver at all, so for a user who
/// turned "install automatically" on, these calls are the only account of an update
/// there is: found, downloaded, staged. Closures rather than a protocol because
/// `SoftwareUpdater` is the only listener and the type is private.
private final class UpdaterHooks: NSObject, SPUUpdaterDelegate {

    var onFound: ((SUAppcastItem) -> Void)?
    var onDownloaded: ((SUAppcastItem) -> Void)?
    var onStaged: ((SUAppcastItem, @escaping () -> Void) -> Void)?
    var onChoice: ((SPUUserUpdateChoice) -> Void)?
    var onNothingFound: (() -> Void)?
    var onCycleFinished: ((String?) -> Void)?

    /// Sends Sparkle to a staging appcast when `defaults write com.airstat.AirStats
    /// AirStatsFeedURL <url>` is set, so a release can be tested end to end against a
    /// preview host without editing Info.plist and rebuilding. Unset, Sparkle uses the
    /// `SUFeedURL` the app ships with.
    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "AirStatsFeedURL")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { onFound?(item) }
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { onDownloaded?(item) }
    }

    /// Taking the install over. Left to Sparkle, a staged update waits for a quit that
    /// never comes, and the next scheduled check backs off to the impatient interval
    /// on top of that, so turning automatic installs on would make news arrive later.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { onStaged?(item, immediateInstallHandler) }
        return true
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated { onChoice?(choice) }
    }

    /// The feed no longer offers anything newer, which is what an install leaves
    /// behind and what a pulled release looks like.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        MainActor.assumeIsolated { onNothingFound?() }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        let failure = Self.failure(from: error)
        if let failure { WindowLog.log("update check failed: \(failure)") }
        MainActor.assumeIsolated { onCycleFinished?(failure) }
    }

    /// Which endings are failures. "Nothing newer" and "the user said no" end a cycle
    /// with an error too, and neither is worth a footnote.
    private static func failure(from error: (any Error)?) -> String? {
        guard let error = error as NSError? else { return nil }
        let expected: Set<Int> = [Int(SUError.noUpdateError.rawValue),
                                  Int(SUError.installationCanceledError.rawValue),
                                  Int(SUError.installationAuthorizeLaterError.rawValue)]
        if error.domain == SUSparkleErrorDomain, expected.contains(error.code) { return nil }
        return error.localizedDescription
    }
}
