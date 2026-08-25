import Foundation
import AirStatKit

/// Posts one notification per release, the first time a scheduled check finds it.
///
/// Separate from `SoftwareUpdater` for the same reason `ThresholdMonitor` is separate
/// from `MetricsEngine`: the updater's job is to know what Sparkle knows, and it stays
/// readable without `UserNotifications` by not knowing that anyone acts on the answer.
///
/// Observation-driven rather than called from the delegate, so a release found in a
/// launch where the user had not yet granted permission is still announced in a later
/// one. Announcing is keyed to the version rather than to a flag, so the release after
/// this one is still worth saying out loud.
@MainActor
public final class UpdateAnnouncer {

    /// Which version has been announced. In `UserDefaults` beside Sparkle's own state
    /// rather than in `Settings`: nothing here is a preference the user sets, exports
    /// or restores to a default, and a settings file carrying it would be one more
    /// thing that has to survive a version it no longer understands.
    private static let announcedKey = "AirStatsAnnouncedVersion"

    /// What the notice is posted under, and so what a click on it comes back through.
    private static let identifier = "update.available"

    private let updates: SoftwareUpdater
    private let authority: NotificationAuthority
    private let defaults: UserDefaults

    private var observationTask: Task<Void, Never>?

    public var isRunning: Bool { observationTask != nil }

    public init(updates: SoftwareUpdater,
                authority: NotificationAuthority,
                defaults: UserDefaults = .standard) {
        self.updates = updates
        self.authority = authority
        self.defaults = defaults
    }

    public func start() {
        guard observationTask == nil else { return }
        // The grant is observed alongside the pending version because it is the other
        // thing that can turn "nothing to do" into "post it now". Without it, a user who
        // granted permission at the prompt this feature raised would hear nothing until
        // the next release.
        let changes = ObservedChanges { [updates, authority] in
            _ = updates.pending
            _ = updates.installsAutomatically
            _ = authority.state
        }
        // A notice nobody can act on is worse than none: the system's own answer to a
        // click is to activate the app, and a menu bar app with no window of its own
        // looks broken doing that. Sparkle is holding the update quietly by this point,
        // so asking it to check is what puts the window in front of the user.
        authority.onOpen(Self.identifier) { [updates] in updates.checkForUpdates() }
        observationTask = Task { @MainActor [weak self] in
            for await _ in changes {
                guard let self else { return }
                self.announceIfNeeded()
            }
        }
        announceIfNeeded()
    }

    public func stop() {
        authority.onOpen(Self.identifier, run: nil)
        observationTask?.cancel()
        observationTask = nil
    }

    /// Whether this release still has something to say. Pure, because it is the whole
    /// anti-nag mechanism and its failure mode only shows up a release later in the
    /// wild: a banner every launch forever, or a release nobody is told about.
    ///
    /// Silent when installs are automatic: the update will land on its own the next
    /// time the screen locks, and a banner asking the user to do something the app is
    /// about to do itself is the nag this feature exists to avoid.
    public nonisolated static func shouldAnnounce(pending: String?, announced: String?,
                                                  installsAutomatically: Bool = false) -> Bool {
        guard let pending, !pending.isEmpty, !installsAutomatically else { return false }
        return pending != announced
    }

    private func announceIfNeeded() {
        guard let version = updates.pending?.version,
              Self.shouldAnnounce(pending: version,
                                  announced: defaults.string(forKey: Self.announcedKey),
                                  installsAutomatically: updates.installsAutomatically) else { return }

        // Asked only now, with a release actually in hand. This is the one feature that
        // ships on, so requesting at launch would put a permission dialog in front of
        // every new user on their first run for a banner that may be months away. The
        // row in the panel is what carries the news if this is refused.
        guard authority.request("an available update") else { return }

        // One identifier for the whole feature, not one per version: a user who has been
        // away long enough to miss two releases wants the current notice, not a stack of
        // superseded ones.
        authority.post(identifier: Self.identifier,
                       title: "AirStats \(version) is available",
                       body: "You are running \(currentVersion). Click to install it.")
        // Written after the notification is handed over rather than before, but without
        // waiting to hear it was displayed: the failure this guards against is
        // repetition, and a banner nobody saw is a far smaller loss than a weekly one.
        defaults.set(version, forKey: Self.announcedKey)
        WindowLog.log("update notification posted version=\(version)")
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "an older version"
    }
}
