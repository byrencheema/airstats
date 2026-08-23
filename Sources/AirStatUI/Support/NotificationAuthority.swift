import Foundation
import Observation
import UserNotifications

/// The app's one relationship with `UNUserNotificationCenter`.
///
/// Two features post notifications now — threshold alerts and the update notice — and
/// both of them need the same grant and the same foreground-presentation delegate.
/// Neither is a thing there can be two of: `requestAuthorization` shows the user one
/// prompt whoever asks, and `center.delegate` is a single process-wide slot, so a
/// second owner silently unhooks the first. Sharing one object is what keeps the
/// prompt to one and the delegate honest.
///
/// Nothing here asks at launch. `request(_:)` is called at the moment a feature has
/// something to say, which is the only moment the user can judge the request.
/// `@Observable` so a caller that only had something to say once can be woken when the
/// answer to "may I say it?" finally arrives. The prompt is a dialog a user can leave
/// on screen for a minute, and `request(_:)` returns false for all of it.
@MainActor
@Observable
public final class NotificationAuthority {

    public enum State: Sendable, Equatable {
        case undetermined
        case requesting
        case granted
        /// Refused by the user, or impossible because the process is not running from
        /// an app bundle. Both are final for this launch, so nothing asks again.
        case unavailable
    }

    public private(set) var state: State = .undetermined

    private var task: Task<Void, Never>?
    private var relay: NotificationRelay?
    /// What to run when the user clicks a notification, by the identifier it was
    /// posted under. A dictionary rather than one closure for the same reason the
    /// delegate is shared: two features post from here, and a single slot would let
    /// whichever registered second silently swallow the other one's clicks.
    private var openHandlers: [String: () -> Void] = [:]

    public init() {}

    /// Registers what a click on `identifier` should do.
    ///
    /// Without this a notification is a dead end: the system's own answer to a click is
    /// to activate the app, which for a menu bar app with no window of its own is
    /// indistinguishable from nothing happening.
    /// Passing nil clears the registration, so a feature that stops can stop
    /// answering for clicks it will no longer act on.
    public func onOpen(_ identifier: String, run handler: (() -> Void)?) {
        openHandlers[identifier] = handler
    }

    /// True while a prompt is out or a delegate is installed, so a caller can assert
    /// that `reset()` really let go. Same reason `PanelController` publishes its
    /// monitor count: a delegate that outlives teardown is silent, and nothing looks
    /// wrong until the app is presenting banners on behalf of a shut-down feature.
    public var isRunning: Bool { task != nil || relay != nil }

    /// Asks if nobody has yet, and reports whether posting is worth attempting.
    ///
    /// Returns false while the prompt is out. The caller is expected to be driven by
    /// something that will come back around — an observation, a later check — rather
    /// than to await an answer here, because the answer can be a user staring at a
    /// dialog for a minute.
    @discardableResult
    public func request(_ reason: @autoclosure () -> String) -> Bool {
        switch state {
        case .granted: return true
        case .requesting, .unavailable: return false
        case .undetermined: break
        }

        guard Bundle.main.bundleIdentifier != nil else {
            // `UNUserNotificationCenter.current()` traps outside an app bundle, which
            // is how the render and probe CLIs run out of `.build`.
            state = .unavailable
            return false
        }

        state = .requesting
        let why = reason()
        let center = UNUserNotificationCenter.current()
        task = Task { @MainActor [weak self] in
            var granted = false
            do {
                granted = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                // The failure mode of this whole feature is silence, so the one thing
                // that must never be swallowed is why nothing is arriving.
                WindowLog.log("notification authorisation failed: \(error)")
            }
            guard let self, !Task.isCancelled, self.state == .requesting else { return }
            self.task = nil
            self.state = granted ? .granted : .unavailable
            if granted {
                let relay = NotificationRelay()
                relay.onOpen = { [weak self] identifier in
                    MainActor.assumeIsolated { self?.openHandlers[identifier]?() }
                }
                center.delegate = relay
                self.relay = relay
            }
            WindowLog.log("notification authorisation \(granted ? "granted" : "refused") for \(why)")
        }
        return false
    }

    /// Hands a notification to the system. No-op unless the grant is in hand, so a
    /// caller never has to check twice.
    public func post(identifier: String, title: String, body: String) {
        guard state == .granted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                WindowLog.log("notification delivery failed: \(error.localizedDescription)")
            }
        }
    }

    public func reset() {
        task?.cancel()
        task = nil
        if let relay {
            // The delegate is a process-wide slot on a shared singleton, so this clears
            // it only while it still holds *our* relay. Nothing else in the app wants
            // that slot today, and a teardown that silently unhooks whoever does want
            // it next is the kind of thing nobody finds for months.
            let center = UNUserNotificationCenter.current()
            if center.delegate === relay { center.delegate = nil }
            self.relay = nil
        }
        state = .undetermined
    }
}

/// The two halves of the delegate slot: showing a banner, and hearing a click on one.
///
/// macOS suppresses banners for the app that is currently frontmost. AirStats is
/// frontmost whenever its settings window has focus, which is exactly where a user
/// goes to set these rules up, so present them anyway.
private final class NotificationRelay: NSObject, UNUserNotificationCenterDelegate {

    var onOpen: ((String) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Only the plain click. A notification with buttons of its own would arrive here
    /// too, and answering those the same way would run the default action for a button
    /// the user pressed to do something else.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            onOpen?(response.notification.request.identifier)
        }
        completionHandler()
    }
}
