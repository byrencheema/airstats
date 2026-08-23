import AppKit
import Carbon.HIToolbox
import AirStatKit

/// Claims the user's recorded shortcuts system-wide and reports which action fired.
///
/// Registration goes through Carbon's `RegisterEventHotKey` rather than a `CGEvent`
/// tap. A tap would have to be told about every keystroke on the system, which needs
/// Accessibility trust, and AirStat has no other reason to ask the user for that
/// permission. Carbon hands back only the chords that were asked for and needs no
/// grant at all.
@MainActor
public final class GlobalHotKeyCenter {

    /// Called on the main thread when a registered chord is pressed.
    public var onAction: ((ShortcutAction) -> Void)?

    private let settings: SettingsStore

    private var registrations: [ShortcutAction: EventHotKeyRef] = [:]
    /// What each live registration was made from, so a settings change can be reduced
    /// to the actions that actually changed instead of tearing all three down.
    private var registered: [ShortcutAction: AirStatKit.KeyboardShortcut] = [:]

    private var eventHandler: EventHandlerRef?
    private var observationTask: Task<Void, Never>?
    private var activationObserver: (any NSObjectProtocol)?
    private var pendingReport: String?

    /// Distinguishes our hot key identifiers from any other Carbon client's in the
    /// same process. "ASKY". Nonisolated because the C event handler reads it before
    /// it has established that it is on the main actor.
    nonisolated static let signature = OSType(0x4153_4B59)

    /// The C event handler cannot capture, so it reaches the live centre through this.
    static weak var active: GlobalHotKeyCenter?

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Hot keys held by the system on our behalf right now. A registration left behind
    /// is as silent as the stale event monitors `PanelController` guards against, and
    /// worse: it keeps a chord away from every other app. Exposed to be checked rather
    /// than reasoned about.
    public var activeRegistrationCount: Int { registrations.count }

    // MARK: Lifecycle

    public func start() {
        GlobalHotKeyCenter.active = self
        installEventHandler()
        reconcile()
        beginObservingSettings()
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
        for (_, ref) in registrations { UnregisterEventHotKey(ref) }
        registrations.removeAll()
        registered.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        if GlobalHotKeyCenter.active === self { GlobalHotKeyCenter.active = nil }
        WindowLog.log("hot keys stopped count=\(activeRegistrationCount)")
    }

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                            globalHotKeyEventHandler,
                            1, &spec, nil, &eventHandler)
    }

    // MARK: Registration

    private func reconcile() {
        let desired = desiredBindings()
        for action in ShortcutAction.allCases {
            guard registered[action] != desired[action] else { continue }
            unregister(action)
            if let shortcut = desired[action] { register(shortcut, for: action) }
        }
        presentPendingReport()
    }

    /// The bindings that should hold a registration, after dropping the ones that
    /// cannot have one.
    ///
    /// Two actions assigned the same chord are left to the Shortcut Conflicts warning
    /// in Settings: Carbon would reject the second as already taken, and treating that
    /// as unavailable would silently delete a binding the user has already been told
    /// about and may be about to fix.
    private func desiredBindings() -> [ShortcutAction: AirStatKit.KeyboardShortcut] {
        var result: [ShortcutAction: AirStatKit.KeyboardShortcut] = [:]
        var claimed: Set<Combination> = []
        for action in ShortcutAction.allCases {
            guard let shortcut = settings.settings.shortcuts.bindings[action],
                  shortcut.isGloballyRegisterable,
                  claimed.insert(Combination(shortcut)).inserted else { continue }
            result[action] = shortcut
        }
        return result
    }

    private func register(_ shortcut: AirStatKit.KeyboardShortcut, for action: ShortcutAction) {
        var ref: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: GlobalHotKeyCenter.signature,
                                       id: action.hotKeyIdentifier)
        let status = RegisterEventHotKey(shortcut.carbonKeyCode,
                                         shortcut.carbonModifierFlags,
                                         identifier,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else {
            WindowLog.log("hot key rejected action=\(action.rawValue) "
                + "chord=\(ShortcutDisplay.string(for: shortcut)) status=\(status)")
            reportUnavailable(shortcut, for: action)
            return
        }
        registrations[action] = ref
        registered[action] = shortcut
        WindowLog.log("hot key registered action=\(action.rawValue) "
            + "chord=\(ShortcutDisplay.string(for: shortcut)) "
            + "keyCode=\(shortcut.carbonKeyCode) modifiers=\(shortcut.carbonModifierFlags) "
            + "count=\(activeRegistrationCount)")
    }

    private func unregister(_ action: ShortcutAction) {
        guard let ref = registrations[action] else { return }
        UnregisterEventHotKey(ref)
        registrations[action] = nil
        registered[action] = nil
        WindowLog.log("hot key unregistered action=\(action.rawValue) count=\(activeRegistrationCount)")
    }

    /// Drop a chord the system would not give us and say so. Keeping it would leave
    /// the recorder in Settings displaying a shortcut that can never fire, which is a
    /// worse outcome than losing a binding the user has to record again anyway.
    private func reportUnavailable(_ shortcut: AirStatKit.KeyboardShortcut, for action: ShortcutAction) {
        let display = ShortcutDisplay.string(for: shortcut)
        pendingReport = "\(display) is already claimed by macOS or another app, "
            + "so it was not assigned to \(action.label). Record a different combination."
        settings.update { $0.shortcuts.bindings[action] = nil }
    }

    private func presentPendingReport() {
        guard let message = pendingReport else { return }
        // At launch AirStat is not frontmost, and an alert put up then would sit behind
        // whatever the user is actually doing. Hold it until they come back to the app,
        // which is also where the recorder they need is.
        guard NSApp.isActive else {
            observeActivation()
            return
        }
        pendingReport = nil
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Shortcut Unavailable"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.presentPendingReport() }
        }
    }

    // MARK: Dispatch

    fileprivate func fire(_ identifier: UInt32) {
        guard let action = ShortcutAction.action(forHotKeyIdentifier: identifier) else { return }
        WindowLog.log("hot key fired action=\(action.rawValue) appActive=\(NSApp.isActive)")
        onAction?(action)
    }

    // MARK: Settings observation

    /// Recording a shortcut has to take effect without a relaunch, and the recorder
    /// writes straight to the store, so the registrations are driven from the store
    /// the way the desktop widget drives its window configuration.
    private func beginObservingSettings() {
        observationTask?.cancel()
        let changes = settings.changes
        observationTask = Task { @MainActor [weak self] in
            for await _ in changes {
                guard let self else { return }
                self.reconcile()
            }
        }
    }

    /// A chord identified by what Carbon is asked to claim, so two bindings collide
    /// here exactly when Carbon would refuse the second one.
    private struct Combination: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32

        init(_ shortcut: AirStatKit.KeyboardShortcut) {
            keyCode = shortcut.carbonKeyCode
            modifiers = shortcut.carbonModifierFlags
        }
    }
}

/// Top level and capturing nothing, which is what lets Swift hand it to Carbon as a
/// plain C function pointer.
private func globalHotKeyEventHandler(_ callRef: EventHandlerCallRef?,
                                      _ event: EventRef?,
                                      _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &identifier)
    guard status == noErr, identifier.signature == GlobalHotKeyCenter.signature else {
        return OSStatus(eventNotHandledErr)
    }
    // Carbon dispatches hot keys on the main thread's run loop, so the work the
    // handler triggers is already where it needs to be.
    MainActor.assumeIsolated {
        GlobalHotKeyCenter.active?.fire(identifier.id)
    }
    return noErr
}
