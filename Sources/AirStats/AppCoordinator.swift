import AppKit
import AirStatKit
import AirStatUI

/// Wires the engine, the settings store and every piece of UI together, and owns
/// the system-level observers (sleep, wake, screen lock, display changes) that
/// decide how hard AirStats is allowed to work.
@MainActor
final class AppCoordinator {

    private let settingsStore: SettingsStore
    private let engine: MetricsEngine

    private let statusItem: StatusItemController
    private let panel: PanelController
    private let desktopWidget: DesktopWidgetController
    private let settingsWindow: SettingsWindowController
    private let thresholdMonitor: ThresholdMonitor
    private let hotKeys: GlobalHotKeyCenter
    private let updater: SoftwareUpdater
    private let updateAnnouncer: UpdateAnnouncer

    private var observers: [any NSObjectProtocol] = []
    /// Where the panel is currently hung. Kept here because with one status item per
    /// readout, "toggle" has a third case: the click came from a different item than
    /// the one the panel is under.
    private var panelAnchor: NSRect?

    init() {
        let store = SettingsStore()
        let engine = MetricsEngine(settingsStore: store)
        let updater = SoftwareUpdater()
        let authority = NotificationAuthority()
        self.settingsStore = store
        self.engine = engine
        self.updater = updater
        self.statusItem = StatusItemController(engine: engine, settings: store)
        self.panel = PanelController(engine: engine, settings: store, updates: updater)
        self.desktopWidget = DesktopWidgetController(engine: engine, settings: store)
        self.settingsWindow = SettingsWindowController(engine: engine, settings: store,
                                                      updater: updater, authority: authority)
        self.thresholdMonitor = ThresholdMonitor(engine: engine, settings: store, authority: authority)
        self.updateAnnouncer = UpdateAnnouncer(updates: updater, authority: authority)
        self.hotKeys = GlobalHotKeyCenter(settings: store)
    }

    // MARK: Lifecycle

    func start() {
        statusItem.onPrimaryAction = { [weak self] in self?.togglePanel() }
        statusItem.onSecondaryAction = { [weak self] in self?.showContextMenu() }
        statusItem.onVisibilityChange = { [weak self] visible in
            self?.engine.setMenuBarOccluded(!visible)
        }

        panel.onVisibilityChange = { [weak self] visible in
            self?.engine.setPanelVisible(visible)
        }
        panel.onRequestSettings = { [weak self] in self?.showSettings() }
        panel.onRequestQuit = { NSApp.terminate(nil) }

        desktopWidget.onVisibilityChange = { [weak self] visible in
            self?.engine.setDesktopWidgetVisible(visible)
        }
        // With the menu bar item hidden, the widget's context menu is the only visible
        // way back into Settings.
        desktopWidget.onRequestSettings = { [weak self] in self?.showSettings() }

        // A hot key must do exactly what the equivalent menu item does, including
        // leaving the frontmost app alone: the panel is worth having precisely because
        // it can be summoned over another app without interrupting it.
        hotKeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .togglePanel: self.togglePanel()
            case .toggleDesktopWidget: self.toggleDesktopWidget()
            case .toggleMenuBarItem: self.toggleMenuBarItem()
            case .openSettings: self.showSettings()
            }
        }

        statusItem.install()
        engine.start()
        thresholdMonitor.start()
        hotKeys.start()
        // Sparkle schedules its own checks from here, once a week, and shows its window
        // only when it finds something.
        updater.start()
        updateAnnouncer.start()
        desktopWidget.syncWithSettings()

        registerSystemObservers()
        // The system follows the stored preference, and then the preference follows the
        // system. Since the shipped default is on, a first launch registers the login
        // item here; a registration macOS refuses would otherwise leave the toggle
        // showing on for a login item that does not exist.
        LoginItem.synchronize(enabled: settingsStore.settings.general.launchAtLogin)
        if LoginItem.isEnabled != settingsStore.settings.general.launchAtLogin {
            settingsStore.update { $0.general.launchAtLogin = LoginItem.isEnabled }
        }
    }

    func shutdown() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        updateAnnouncer.stop()
        hotKeys.stop()
        thresholdMonitor.stop()
        engine.stop()
        statusItem.remove()
        desktopWidget.hide()
        settingsStore.flush()
    }

    // MARK: Actions

    private func togglePanel() {
        let anchor = statusItem.anchorRect
        guard panel.isVisible else {
            panelAnchor = anchor
            panel.show(anchoredTo: anchor, on: statusItem.anchorScreen)
            return
        }
        // Clicking a second readout's item moves the panel under it. Dismissing there
        // would read as the click having missed: the user pointed at a different item
        // and got nothing.
        if let anchor, let panelAnchor, anchor != panelAnchor {
            self.panelAnchor = anchor
            panel.reanchor(to: anchor, on: statusItem.anchorScreen)
            return
        }
        panel.hide()
        panelAnchor = nil
    }

    /// Bring Settings up, from wherever the request came from.
    ///
    /// Also the answer to a second launch: the app has no dock icon and no window of
    /// its own, so opening it from Spotlight or the Finder while it is already running
    /// used to do nothing at all, which is indistinguishable from the app being broken.
    func showSettings() {
        panel.hide()
        settingsWindow.show()
    }

    private func toggleDesktopWidget() {
        settingsStore.update { $0.desktopWidget.isEnabled.toggle() }
        desktopWidget.syncWithSettings()
    }

    /// The panel hangs from the item, so it goes with it.
    private func toggleMenuBarItem() {
        if panel.isVisible {
            panel.hide()
            panelAnchor = nil
        }
        settingsStore.update { $0.menuBar.isVisible.toggle() }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(menuShowSettings), keyEquivalent: ",")
            .target = self
        let desktopWidgetItem = menu.addItem(withTitle: "Show Desktop Widget",
                                       action: #selector(menuToggleDesktopWidget), keyEquivalent: "")
        desktopWidgetItem.target = self
        desktopWidgetItem.state = settingsStore.settings.desktopWidget.isEnabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AirStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.presentMenu(menu)
    }

    @objc private func menuShowSettings() { showSettings() }

    @objc private func menuToggleDesktopWidget() { toggleDesktopWidget() }

    // MARK: System observers

    private func registerSystemObservers() {
        let workspace = NSWorkspace.shared.notificationCenter

        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(false) }
        })
        // Display sleep is far more common than system sleep on a desktop Mac and
        // is just as good a reason to stop sampling.
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(false) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(true) }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(false) }
        })

        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"),
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(true) }
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.setSystemAsleep(false) }
        })

        // Screen reconfiguration moves the status item and can invalidate the
        // panel's anchor; re-anchor rather than leaving the panel stranded.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.desktopWidget.screenConfigurationChanged()
                    if self.panel.isVisible {
                        self.panelAnchor = self.statusItem.anchorRect
                        self.panel.reanchor(to: self.panelAnchor,
                                            on: self.statusItem.anchorScreen)
                    }
                }
        })
    }
}
