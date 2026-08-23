import Testing
import Foundation
@testable import AirStatKit

@Suite("Settings decoding is fault tolerant")
struct SettingsDecodingTests {

    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    @Test("an empty object yields full defaults")
    func emptyObject() throws {
        let settings = try decode("{}")
        #expect(settings.general.updateInterval == 2)
        #expect(settings.menuBar.items.count == MenuBarSettings.defaultItems.count)
        #expect(settings.panel.collapsedModules == PanelSettings.defaultCollapsed)
    }

    /// A settings file written by 1.2.1 or earlier has `floatsAboveEverything` and no
    /// `depth`, and the upgrade must not silently move anyone's desktop widget.
    @Test("a pre-1.3 desktop widget layer converts from the old boolean")
    func desktopWidgetDepthMigratesFromLegacyBool() throws {
        #expect(try decode(#"{"overlay":{"floatsAboveEverything":true}}"#).desktopWidget.depth
                == .aboveEverything)
        #expect(try decode(#"{"overlay":{"floatsAboveEverything":false}}"#).desktopWidget.depth
                == .withWindows)
        #expect(try decode(#"{"overlay":{}}"#).desktopWidget.depth == .aboveEverything)
    }

    /// The new key wins, so a file that somehow carries both is not dragged backwards
    /// by the one nothing writes any more.
    @Test("a stored layer beats the boolean it replaced")
    func desktopWidgetDepthPrefersTheNewKey() throws {
        let settings = try decode(#"{"overlay":{"depth":"wallpaper","floatsAboveEverything":true}}"#)
        #expect(settings.desktopWidget.depth == .wallpaper)
    }

    /// Round-tripping must not resurrect the retired key, or every save would write a
    /// field the next version has to keep reading.
    @Test("saving a desktop widget writes the layer and not the old boolean")
    func desktopWidgetDepthRoundTrips() throws {
        var settings = Settings()
        settings.desktopWidget.depth = .wallpaper
        let data = try JSONEncoder().encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("floatsAboveEverything"))
        #expect(try JSONDecoder().decode(Settings.self, from: data).desktopWidget.depth == .wallpaper)
    }

    /// Asserted by content, not against the constant the app reads. The defaults check
    /// above compares `collapsedModules` to `PanelSettings.defaultCollapsed`, which
    /// stays true no matter what that constant is changed to and so cannot notice a
    /// module quietly starting open.
    @Test("the panel opens with every module closed")
    func panelStartsFullyCollapsed() {
        let collapsed = PanelSettings().collapsedModules
        for module in PanelModule.allCases {
            #expect(collapsed.contains(module), "\(module.label) starts open")
        }
    }

    @Test("a fresh install opens at login, an existing one keeps its answer")
    func launchAtLoginDefault() throws {
        // The shipped default, which is what a Mac with no settings file gets.
        #expect(GeneralSettings().launchAtLogin)
        // A file that already says no must stay no. The default changed after release,
        // and re-enabling a login item someone deliberately turned off would be the
        // worst possible reading of "default it to on".
        #expect(try decode(#"{"general":{"launchAtLogin":false}}"#).general.launchAtLogin == false)
        // A file predating the key is an existing install too, so it does not opt in.
        #expect(try decode(#"{"general":{}}"#).general.launchAtLogin == false)
    }

    @Test("a malformed key falls back without losing its siblings")
    func malformedKeyIsIsolated() throws {
        let settings = try decode("""
        {"general":{"updateInterval":"not a number","launchAtLogin":true,"temperatureUnit":"kelvin"}}
        """)
        #expect(settings.general.updateInterval == 2)          // fell back
        #expect(settings.general.launchAtLogin == true)        // survived
        #expect(settings.general.temperatureUnit == .celsius)  // unknown enum fell back
    }

    @Test("out-of-range values are clamped, not accepted")
    func clamping() throws {
        let settings = try decode("""
        {"general":{"updateInterval":9999},
         "overlay":{"opacity":0.0,"width":10000},
         "charts":{"historyDuration":999999}}
        """)
        #expect(settings.general.updateInterval == 60)
        #expect(settings.desktopWidget.opacity == 0.2)   // never invisible
        #expect(settings.desktopWidget.width == 480)
        #expect(settings.charts.historyDuration == 3600)
    }

    @Test("an empty menu bar is repaired so the app stays reachable")
    func emptyMenuBarIsRepaired() throws {
        let settings = try decode(#"{"menuBar":{"items":[]}}"#)
        #expect(!settings.menuBar.items.isEmpty)
        #expect(!settings.menuBar.enabledItems.isEmpty)
    }

    @Test("every item disabled still leaves one enabled after sanitising")
    func allDisabledIsRepaired() {
        var settings = Settings()
        for index in settings.menuBar.items.indices { settings.menuBar.items[index].isEnabled = false }
        let sanitized = SettingsStore.sanitize(settings)
        #expect(sanitized.menuBar.enabledItems.count == 1)
    }

    @Test("a style the metric no longer supports is corrected")
    func incompatibleStyleIsCorrected() {
        // Uptime keeps no series, so there is nothing for a graph to plot.
        let item = MenuBarItemConfig(metric: .uptime, style: .graph)
        #expect(!MenuBarMetric.uptime.supportedStyles.contains(.graph))
        #expect(item.sanitized().style != .graph)
    }

    @Test("a retired style in a stored file lands on one the metric supports")
    func retiredStyleIsMigrated() throws {
        let settings = try decode(#"{"menuBar":{"items":[{"metric":"cpuUsage","style":"ring"}]}}"#)
        #expect(MenuBarMetric.cpuUsage.supportedStyles.contains(settings.menuBar.items[0].style))
    }

    @Test("round-trips without loss")
    func roundTrip() throws {
        var original = Settings()
        original.general.temperatureUnit = .fahrenheit
        original.desktopWidget.isEnabled = true
        original.menuBar.items.append(MenuBarItemConfig(metric: .gpuUsage, style: .graph))
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Settings.self, from: data)
        #expect(restored == original)
    }

    /// Every settings file written before Sparkle still holds the home-made checker's
    /// keys. They are read by nothing now, and a decoder that choked on them would
    /// throw away the user's whole configuration to say so.
    @Test("a file from the retired update checker still loads")
    func retiredUpdateKeysAreIgnored() throws {
        let settings = try decode("""
        {"updates":{"lastCheckedAt":776000000,"latestVersion":"1.1",
                    "latestURL":"https://airstats.app/download","notifiedVersion":"1.1"},
         "general":{"checksForUpdates":false,"notifiesAboutUpdates":false,"launchAtLogin":true}}
        """)
        #expect(settings.general.launchAtLogin)
        #expect(settings.general.updateInterval == 2)
    }

    @Test("truncated JSON throws so the caller can fall back to the backup")
    func truncatedThrows() {
        #expect(throws: (any Error).self) {
            try decode("{\"general\":{\"updateInterval\":")
        }
    }
}

@Suite("Required sources track what is actually on screen")
struct RequiredSourceTests {

    @Test("only menu bar sources are needed when the panel is closed")
    func menuBarOnly() {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage)]
        let sources = settings.requiredSources(panelVisible: false, desktopWidgetVisible: false)
        #expect(sources.contains(.cpu))
        #expect(!sources.contains(.power))     // nothing on screen needs the battery
        #expect(!sources.contains(.processes)) // the expensive one stays off
    }

    @Test("opening the panel pulls in its modules")
    func panelOpen() {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage)]
        let sources = settings.requiredSources(panelVisible: true, desktopWidgetVisible: false)
        #expect(sources.contains(.processes))
        #expect(sources.contains(.power))
    }

    @Test("enabled notification rules keep their source alive")
    func notificationRulesRequireSources() {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage)]
        settings.notifications.isEnabled = true
        settings.notifications.rules = [ThresholdRule(metric: .batteryLow, isEnabled: true)]
        let sources = settings.requiredSources(panelVisible: false, desktopWidgetVisible: false)
        #expect(sources.contains(.power))
    }
}

@Suite("History capacity follows interval and retention")
struct HistoryCapacityTests {

    @Test("capacity covers the requested duration at the chosen interval")
    func capacity() {
        var settings = Settings()
        settings.general.updateInterval = 2
        settings.charts.historyDuration = 300
        #expect(settings.historyCapacity >= 150)
        #expect(settings.historyCapacity <= 160)
    }

    @Test("capacity stays bounded at the fastest interval and longest retention")
    func bounded() {
        var settings = Settings()
        settings.general.updateInterval = 0.5
        settings.charts.historyDuration = 3600
        // 7200 samples would be honest but wasteful; the cap keeps memory predictable.
        #expect(settings.historyCapacity == 4096)
    }
}
