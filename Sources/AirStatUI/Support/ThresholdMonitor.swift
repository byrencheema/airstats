import Foundation
import UserNotifications
import AirStatKit

/// Watches metrics against the user's threshold rules and posts notifications.
///
/// Sustained-duration and cooldown handling live here so a transient spike while
/// launching an app never produces an alert.
@MainActor
public final class ThresholdMonitor {

    private let engine: MetricsEngine
    private let settings: SettingsStore
    private let authority: NotificationAuthority

    private var observationTask: Task<Void, Never>?
    private var evaluator = ThresholdEvaluator()

    /// True while the observation loop and any pending authorisation request are
    /// installed.
    ///
    /// Exposed for the same reason `PanelController.activeEventMonitorCount` is: a
    /// task or a delegate that outlives `stop()` is silent, and nothing looks wrong
    /// until the app is posting notifications on behalf of a shut-down monitor.
    public var isRunning: Bool {
        observationTask != nil || authority.isRunning
    }

    /// The authority is injected rather than defaulted so that anything else which
    /// starts posting shares this one: a default would quietly give each poster its
    /// own, which is a second permission prompt and a fight over the delegate slot.
    public init(engine: MetricsEngine, settings: SettingsStore,
                authority: NotificationAuthority) {
        self.engine = engine
        self.settings = settings
        self.authority = authority
    }

    // MARK: Lifecycle

    public func start() {
        guard observationTask == nil else { return }
        // Observation-driven like the status item rather than a timer of its own: the
        // rules can only ever change answer when a new snapshot or a new setting lands.
        // The tracking closure below is rebuilt when the feature toggles so a disabled
        // monitor keeps only the settings wakeup and never follows the sample stream.
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let notificationsEnabled = self.settings.settings.notifications.isEnabled
                let changes = ObservedChanges { [engine = self.engine, settings = self.settings] in
                    _ = settings.revision
                    if settings.settings.notifications.isEnabled {
                        _ = engine.snapshot
                    }
                }
                self.evaluate()

                for await _ in changes {
                    guard !Task.isCancelled else { return }
                    self.evaluate()
                    guard self.settings.settings.notifications.isEnabled == notificationsEnabled else {
                        break
                    }
                }
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        evaluator.reset()
        authority.reset()
    }

    // MARK: Evaluation

    private func evaluate() {
        let notifications = settings.settings.notifications
        guard notifications.isEnabled else {
            evaluator.reset()
            return
        }
        // Nothing is measured until there is somewhere to send the answer. Denial is
        // terminal, so a refused prompt costs one check per sample and no more.
        //
        // Asked here, the first time the user actually switches notifications on, and
        // never at launch. A menu bar utility that demands permission on first run is
        // asking for something the user has not opted into yet.
        guard authority.request("threshold alerts") else { return }

        // A rule for a metric this Mac cannot measure could never fire honestly, and
        // the pane already tells the user so.
        let availability = MetricAvailability(snapshot: engine.snapshot)
        let rules = notifications.enabledRules.filter { availability.note(for: $0.metric) == nil }

        let alerts = evaluator.alerts(for: rules,
                                      readings: ThresholdEvaluator.readings(from: engine.snapshot),
                                      now: Date())
        for alert in alerts { deliver(alert) }
    }

    // MARK: Delivery

    private func deliver(_ alert: ThresholdAlert) {
        // One identifier per rule, so a rule that fires again after its cooldown
        // replaces its own stale banner instead of stacking a column of the same
        // warning in Notification Centre.
        authority.post(identifier: "threshold.\(alert.ruleID.uuidString)",
                       title: alert.title,
                       body: alert.body)
        WindowLog.log("notification posted metric=\(alert.metric.rawValue) value=\(alert.value) threshold=\(alert.threshold)")
    }
}
