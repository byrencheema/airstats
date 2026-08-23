import Foundation
import Observation

/// Owns the user's configuration and its persistence.
///
/// Writes are atomic and debounced: dragging the opacity slider produces one file
/// write when the drag ends, not sixty during it. A last-known-good copy is kept
/// alongside so a truncated write can never brick the app's configuration.
@MainActor
@Observable
public final class SettingsStore {

    public private(set) var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            SettingsStore.currentTheme = settings.theme
            revision &+= 1
            scheduleSave()
        }
    }

    /// The colour overrides the UI layer draws with, mirrored out of the store.
    ///
    /// The palette is consulted from places that have no store to read from — chart
    /// tints supplied as default argument values, and `Design.Palette.metric` itself,
    /// which is a static function called from twenty sites. Threading a store through
    /// all of them to deliver a value that is process-wide anyway would be ceremony;
    /// mirroring it here is not.
    ///
    /// Written only from `didSet` above and from `load`, both of which are main-actor
    /// confined, and always before the `revision` bump that makes SwiftUI re-read it.
    public nonisolated(unsafe) private(set) static var currentTheme = ThemeSettings()

    /// Increments on every accepted change. Views observe this to recompute
    /// derived layout without diffing the whole settings tree.
    public private(set) var revision: UInt64 = 0

    /// Set when the on-disk file could not be read and defaults were substituted,
    /// so the UI can tell the user rather than silently resetting their setup.
    public private(set) var loadDiagnostic: String?

    private let fileURL: URL
    private let backupURL: URL
    private var saveTask: Task<Void, Never>?
    private let saveDebounce: Duration

    public init(directory: URL? = nil, saveDebounce: Duration = .milliseconds(400)) {
        let dir = directory ?? SettingsStore.defaultDirectory
        self.fileURL = dir.appendingPathComponent("settings.json")
        self.backupURL = dir.appendingPathComponent("settings.backup.json")
        self.saveDebounce = saveDebounce
        let (loaded, diagnostic) = SettingsStore.load(from: fileURL, backup: backupURL)
        self.settings = loaded
        self.loadDiagnostic = diagnostic
        // `didSet` does not fire during initialisation, so the first paint would use
        // the shipped palette and only pick up the user's colours on their next edit.
        SettingsStore.currentTheme = loaded.theme
    }

    /// Note that `HOME` does not redirect `applicationSupportDirectory`, so a test
    /// instance cannot be isolated by launching it with a fake home. Pass `directory:`
    /// instead; it is the only thing that keeps a test off the user's real settings.
    public nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("AirStats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Mutation

    /// The single mutation entry point. Everything funnels through here so that
    /// persistence, clamping, and revision bumping cannot be bypassed.
    public func update(_ mutate: (inout Settings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = SettingsStore.sanitize(copy)
    }

    public func resetToDefaults() {
        settings = Settings()
        flush()
    }

    public func resetSection(_ section: SettingsSection) {
        update { s in
            switch section {
            case .general: s.general = GeneralSettings()
            case .menuBar: s.menuBar = MenuBarSettings()
            case .charts: s.charts = ChartSettings()
            case .desktopWidget: s.desktopWidget = DesktopWidgetSettings()
            case .notifications: s.notifications = NotificationSettings()
            case .shortcuts: s.shortcuts = ShortcutSettings()
            case .theme: s.theme = ThemeSettings()
            }
        }
    }

    public enum SettingsSection: String, Sendable, CaseIterable {
        case general, menuBar, charts, desktopWidget, notifications, shortcuts, theme

        /// What this subtree is called in the window. Here rather than in the UI layer
        /// because the reset menu lists sections, not panes — one pane now edits more
        /// than one of these.
        public var label: String {
            switch self {
            case .general: return "General"
            case .menuBar: return "Menu Bar"
            case .charts: return "Charts"
            case .desktopWidget: return "Desktop Widget"
            case .notifications: return "Notifications"
            case .shortcuts: return "Shortcuts"
            case .theme: return "Colors"
            }
        }
    }

    // MARK: Import / export

    public func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }

    /// Replace the entire configuration from a user-supplied file. Throws only when
    /// the data is not decodable at all; individual bad keys fall back to defaults.
    public func importJSON(_ data: Data) throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        settings = SettingsStore.sanitize(decoded)
        flush()
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = settings
        let url = fileURL
        let backup = backupURL
        let delay = saveDebounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await SettingsStore.write(snapshot, to: url, backup: backup)
            _ = self
        }
    }

    /// Write immediately. Called on quit so nothing is lost to the debounce window.
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = settings
        let url = fileURL
        let backup = backupURL
        // Synchronous on purpose: at termination there is no later to defer to.
        SettingsStore.writeSynchronously(snapshot, to: url, backup: backup)
    }

    private nonisolated static func write(_ settings: Settings, to url: URL, backup: URL) async {
        await Task.detached(priority: .utility) {
            writeSynchronously(settings, to: url, backup: backup)
        }.value
    }

    private nonisolated static func writeSynchronously(_ settings: Settings, to url: URL, backup: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }

        // Promote the current file to backup before overwriting, but only if it
        // parses — otherwise we would be preserving the corruption.
        if let existing = try? Data(contentsOf: url),
           (try? JSONDecoder().decode(Settings.self, from: existing)) != nil {
            try? existing.write(to: backup, options: .atomic)
        }
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated static func load(from url: URL, backup: URL) -> (Settings, String?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (Settings(), nil)
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(Settings.self, from: data)
            return (sanitize(decoded), nil)
        } catch {
            if let backupData = try? Data(contentsOf: backup),
               let decoded = try? JSONDecoder().decode(Settings.self, from: backupData) {
                return (sanitize(decoded), "Settings file was unreadable; restored the previous version.")
            }
            // Preserve the unreadable file for the user rather than deleting it.
            let quarantine = url.deletingLastPathComponent()
                .appendingPathComponent("settings.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: quarantine)
            return (Settings(), "Settings file was unreadable and has been reset. The old file was kept at \(quarantine.lastPathComponent).")
        }
    }

    /// Enforce invariants that decoding alone cannot: cross-field consistency and
    /// states that would leave the app unusable.
    nonisolated static func sanitize(_ input: Settings) -> Settings {
        var s = input
        s.menuBar.items = s.menuBar.items.map { $0.sanitized() }
        if s.menuBar.items.isEmpty { s.menuBar.items = MenuBarSettings.defaultItems }
        // A user who disables every menu bar item still needs a way to open the app.
        if s.menuBar.enabledItems.isEmpty { s.menuBar.items[0].isEnabled = true }
        if s.desktopWidget.modules.isEmpty { s.desktopWidget.modules = [.cpu, .memory, .network] }
        s.general.updateInterval = min(max(s.general.updateInterval, 0.5), 60)
        s.charts.historyDuration = min(max(s.charts.historyDuration, 30), 3600)
        s.desktopWidget.opacity = min(max(s.desktopWidget.opacity, 0.2), 1)
        s.desktopWidget.inactiveOpacity = min(max(s.desktopWidget.inactiveOpacity, 0.15), s.desktopWidget.opacity)
        s.desktopWidget.width = min(max(s.desktopWidget.width, 160), 480)
        return s
    }

    public var settingsFileURL: URL { fileURL }
}
