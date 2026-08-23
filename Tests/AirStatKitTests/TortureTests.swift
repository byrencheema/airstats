import Testing
import Foundation
import SwiftUI
import AppKit
@testable import AirStatKit
@testable import AirStatUI

@MainActor
@Suite("Torture")
struct TortureTests {

    private func dir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatTorture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func decode(_ json: String) throws -> AirStatKit.Settings {
        try JSONDecoder().decode(AirStatKit.Settings.self, from: Data(json.utf8))
    }

    // MARK: Settings fuzz

    @Test("a garbage depth value does not throw or wipe the file")
    func garbageDepth() throws {
        #expect(try decode(#"{"overlay":{"depth":"upside-down"}}"#).desktopWidget.depth == .aboveEverything)
        #expect(try decode(#"{"overlay":{"depth":17}}"#).desktopWidget.depth == .aboveEverything)
        #expect(try decode(#"{"overlay":{"depth":null}}"#).desktopWidget.depth == .aboveEverything)
        #expect(try decode(#"{"overlay":{"depth":{"a":1}}}"#).desktopWidget.depth == .aboveEverything)
        // A garbage new key falls through to the retired one rather than to the
        // default, so an upgrade that goes wrong still lands on what the user chose.
        #expect(try decode(#"{"overlay":{"depth":"upside-down","floatsAboveEverything":false}}"#)
                .desktopWidget.depth == .withWindows)
    }

    @Test("hostile numbers never make the desktop widget invisible or zero-sized")
    func hostileNumbers() throws {
        let s = try decode(#"{"overlay":{"width":-9999,"opacity":-5,"inactiveOpacity":900}}"#)
        #expect(s.desktopWidget.width >= 160)
        #expect(s.desktopWidget.opacity >= 0.2)
        #expect(s.desktopWidget.inactiveOpacity <= 1)

        let big = try decode(#"{"overlay":{"width":1e308,"opacity":1e308}}"#)
        #expect(big.desktopWidget.width.isFinite && big.desktopWidget.width <= 480)
        #expect(big.desktopWidget.opacity.isFinite && big.desktopWidget.opacity <= 1)
    }

    @Test("a NaN origin does not survive into the layout")
    func nanOrigin() throws {
        let s = try decode(#"{"overlay":{"originX":"nan","originY":"nan"}}"#)
        #expect(s.desktopWidget.originX == nil || s.desktopWidget.originX!.isFinite)
        #expect(s.desktopWidget.originY == nil || s.desktopWidget.originY!.isFinite)
    }

    @Test("an empty or nonsense module list falls back to something drawable")
    func moduleList() throws {
        #expect(!(try decode(#"{"overlay":{"modules":[]}}"#).desktopWidget.modules.isEmpty))
        #expect(!(try decode(#"{"overlay":{"modules":["nope","nada"]}}"#).desktopWidget.modules.isEmpty))
        #expect(!(try decode(#"{"overlay":{"modules":"cpu"}}"#).desktopWidget.modules.isEmpty))
    }

    @Test("a duplicated module cannot reach the desktop widget's ForEach identity")
    func duplicateModules() throws {
        let s = try decode(#"{"overlay":{"modules":["cpu","cpu","memory","cpu"]}}"#)
        #expect(s.desktopWidget.modules == [.cpu, .memory], "duplicates survived decoding")
    }

    @Test("a settings file that is a directory, empty, or binary garbage still opens")
    func hostileSettingsFile() {
        for payload in [Data(), Data([0xff, 0xfe, 0x00]), Data("{".utf8), Data("null".utf8)] {
            let d = dir()
            try? payload.write(to: d.appendingPathComponent("settings.json"))
            let store = SettingsStore(directory: d)
            #expect(store.settings.desktopWidget.width >= 160, "a bad file cost the defaults")
        }
    }

    @Test("importing hostile JSON never throws past the caller or wipes the store")
    func hostileImport() {
        let store = SettingsStore(directory: dir())
        let before = store.settings.desktopWidget.depth
        for payload in ["[]", "null", "{\"overlay\":[]}", String(repeating: "{", count: 5_000)] {
            _ = try? store.importJSON(Data(payload.utf8))
        }
        #expect(store.settings.desktopWidget.width >= 160)
        #expect(store.settings.desktopWidget.depth == before || DesktopWidgetDepth.allCases.contains(store.settings.desktopWidget.depth))
    }

    @Test("an exported file round-trips through import unchanged")
    func exportImportRoundTrip() throws {
        let store = SettingsStore(directory: dir())
        store.update {
            $0.desktopWidget.depth = .wallpaper
            $0.desktopWidget.modules = [.system, .cpu]
            $0.desktopWidget.isCompact = false
        }
        let data = try store.exportJSON()
        let other = SettingsStore(directory: dir())
        try other.importJSON(data)
        #expect(other.settings.desktopWidget.depth == .wallpaper)
        #expect(other.settings.desktopWidget.modules == [.system, .cpu])
        #expect(other.settings.desktopWidget.isCompact == false)
    }

    @Test("truncated and non-object JSON is survivable")
    func brokenJSON() {
        #expect(throws: (any Error).self) { try decode(#"{"overlay":"#) }
        #expect(throws: (any Error).self) { try decode("[]") }
        #expect((try? decode("{}")) != nil)
    }

    // MARK: Depth → window level

    @Test("every depth produces a finite, in-range window level")
    func depthLevels() {
        for d in DesktopWidgetDepth.allCases {
            let raw = d.windowLevel.rawValue
            #expect(raw > Int(CGWindowLevelForKey(.minimumWindow)))
            #expect(raw < Int(CGWindowLevelForKey(.maximumWindow)))
        }
    }

    // MARK: Desktop widget reservation table

    @Test("every module has a distinct raw value and survives a round trip")
    func moduleRawValues() throws {
        for m in PanelModule.allCases {
            #expect(PanelModule(rawValue: m.rawValue) == m)
        }
        #expect(Set(PanelModule.allCases.map(\.rawValue)).count == PanelModule.allCases.count)
    }
}

/// Serialized, and yielding between cycles.
///
/// Building and tearing down an AppKit window is synchronous main-actor work, and the
/// rest of the package's tests run concurrently with this suite. Held without a break,
/// the main actor starves every other main-actor test — including the ones that assert
/// a settings change is delivered within half a second, which then fail for reasons
/// that have nothing to do with settings.
@MainActor
@Suite("Torture: windows", .serialized)
struct WindowTortureTests {

    private func store() -> SettingsStore {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatTorture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return SettingsStore(directory: d)
    }

    @Test("hiding a panel that was never shown, twice, is harmless")
    func redundantHide() {
        let s = store()
        let controller = PanelController(engine: MetricsEngine(settingsStore: s), settings: s)
        controller.hide()
        controller.hide()
        #expect(controller.isVisible == false)
        #expect(controller.activeEventMonitorCount == 0)
    }

    /// Anchors off the bottom, off the side, and on no screen at all. The placement
    /// clamps rather than producing a window nobody can reach.
    ///
    /// This also carries the panel's monitor-leak check, rather than a second test
    /// doing its own show/hide loop. Presenting the panel runs a fade through
    /// `NSAnimationContext`, which pumps CoreAnimation on the main run loop, and a
    /// dedicated loop of those starved the main-actor tests running beside this suite
    /// until they timed out. Five cycles happen here anyway; a monitor that leaks
    /// leaks on the first of them.
    @Test("an impossible anchor still lands the panel on screen")
    func hostileAnchors() async throws {
        let s = store()
        let controller = PanelController(engine: MetricsEngine(settingsStore: s), settings: s)
        let screen = try #require(NSScreen.main)
        let anchors: [NSRect?] = [
            nil,
            NSRect(x: -50_000, y: -50_000, width: 30, height: 22),
            NSRect(x: 50_000, y: 50_000, width: 30, height: 22),
            NSRect(x: screen.frame.midX, y: screen.visibleFrame.minY, width: 30, height: 22),
            NSRect(x: 0, y: 0, width: 0, height: 0),
        ]
        for anchor in anchors {
            controller.show(anchoredTo: anchor, on: nil)
            let frame = try #require(NSApp.windows.first { $0.isVisible }?.frame)
            #expect(frame.width > 0 && frame.height > 0, "degenerate frame for \(String(describing: anchor))")
            #expect(NSScreen.screens.contains { $0.frame.intersects(frame) },
                    "panel landed on no screen for \(String(describing: anchor))")
            controller.hide()
            await Task.yield()
        }
        #expect(controller.activeEventMonitorCount == 0,
                "\(controller.activeEventMonitorCount) monitors survived")
    }

    /// Every depth, twice each, with the desktop widget showing. A level written in the wrong
    /// order silently collapses to `.floating`, which is the bug this guards.
    @Test("cycling every depth keeps the window at the level it asked for")
    func depthCycling() async throws {
        let s = store()
        s.update { $0.desktopWidget.isEnabled = true }
        let controller = DesktopWidgetController(engine: MetricsEngine(settingsStore: s), settings: s)
        controller.show()
        do {
            for depth in DesktopWidgetDepth.allCases {
                s.update { $0.desktopWidget.depth = depth }
                // The controller watches the store over an async sequence, so the
                // change lands some turns later, exactly as it does in the app. Polled
                // rather than slept on, so a busy main actor cannot make this flaky.
                for _ in 0..<100 where controller.windowLevel != depth.windowLevel {
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(controller.windowLevel == depth.windowLevel,
                        "\(depth) settled at \(String(describing: controller.windowLevel))")
            }
        }
        controller.hide()
        #expect(controller.activeEventMonitorCount == 0)
    }

    @Test("a desktop widget shown and hidden repeatedly leaks no monitors")
    func desktopWidgetMonitorsDoNotLeak() async {
        let s = store()
        s.update { $0.desktopWidget.isEnabled = true }
        let controller = DesktopWidgetController(engine: MetricsEngine(settingsStore: s), settings: s)
        for _ in 0..<3 {
            controller.show()
            controller.hide()
            await Task.yield()
        }
        #expect(controller.activeEventMonitorCount == 0,
                "\(controller.activeEventMonitorCount) monitors survived")
    }
}

@Suite("Torture: formatting")
struct FormattingTortureTests {

    private static let hostile: [Double] = [
        .nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
        .leastNonzeroMagnitude, 0, -0, -1, 1e300, -1e300, 9_007_199_254_740_992,
    ]

    /// Every one of these ends up inside a `String(format:)` or an `Int(_:)`, and
    /// `Int(_:)` traps on values a sensor can genuinely report after a bad read.
    @Test("no hostile double crashes a formatter or produces an empty string")
    func hostileDoubles() {
        let f = MetricFormatter(settings: GeneralSettings())
        for v in Self.hostile {
            let probes: [(String, () -> String)] = [
                ("percent", { f.percent(v) }), ("percentValue", { f.percentValue(v) }),
                ("unclampedPercent", { f.unclampedPercent(v) }),
                ("memory", { f.memory(v) }), ("storage", { f.storage(v) }), ("bytes", { f.bytes(v) }),
                ("networkRate", { f.networkRate(v) }), ("networkRateCompact", { f.networkRate(v, compact: true) }),
                ("diskRate", { f.diskRate(v) }), ("diskRateCompact", { f.diskRate(v, compact: true) }),
                ("temperature", { f.temperature(v) }), ("temperatureValue", { f.temperatureValue(v) }),
                ("duration", { f.duration(v) }), ("uptime", { f.uptime(v) }),
                ("compactUptime", { f.compactUptime(v) }),
                ("rpm", { f.rpm(v) }), ("watts", { f.watts(v) }), ("frequency", { f.frequency(v) }),
                ("fixed", { f.fixed(v, decimals: 2) }), ("byteValue", { f.byteValue(v, unitIndex: 0) }),
            ]
            for (name, probe) in probes {
                let out = probe()
                #expect(!out.isEmpty, "\(name) returned empty for \(v)")
                #expect(out.count < 200, "\(name) returned \(out.count) chars for \(v)")
            }
        }
    }

    @Test("a hostile unit index or decimal count does not trap")
    func hostileIndices() {
        let f = MetricFormatter(settings: GeneralSettings())
        for index in [-1_000, -1, 0, 5, 99, Int.max] {
            #expect(!f.byteValue(1024, unitIndex: index).isEmpty)
            #expect(!f.bytes(Double(1024), forceUnit: index).isEmpty)
        }
        for decimals in [-5, 0, 3, 40] {
            #expect(!f.fixed(1.5, decimals: decimals).isEmpty)
            #expect(!f.percent(0.5, decimals: decimals).isEmpty)
        }
    }

    @Test("UInt64.max bytes formats without overflowing")
    func hugeByteCounts() {
        let f = MetricFormatter(settings: GeneralSettings())
        for v in [UInt64.max, UInt64.max / 2, 0, 1] {
            #expect(!f.memory(v).isEmpty)
            #expect(!f.storage(v).isEmpty)
            #expect(!f.bytes(v).isEmpty)
        }
    }

    @Test("a negative or absurd count still renders")
    func hostileCounts() {
        let f = MetricFormatter(settings: GeneralSettings())
        for v in [Int.min, -1, 0, Int.max] {
            #expect(!f.count(v).isEmpty)
        }
    }

    @Test("nil sensor readings never render as a bare zero")
    func nilReadings() {
        let f = MetricFormatter(settings: GeneralSettings())
        #expect(f.temperature(Double?.none) == MetricFormatter.unavailable)
        #expect(f.rpm(Double?.none) == MetricFormatter.unavailable)
        #expect(f.watts(Double?.none) == MetricFormatter.unavailable)
        #expect(f.frequency(Double?.none) == MetricFormatter.unavailable)
        #expect(f.duration(TimeInterval?.none) == MetricFormatter.unavailable)
    }
}

@MainActor
@Suite("Torture: hostile strings")
struct HostileStringTests {

    private func store() -> SettingsStore {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatTorture-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return SettingsStore(directory: d)
    }

    /// A process name, a computer name and a Wi-Fi SSID are all attacker- or
    /// user-supplied. None of them is length-limited by the system in any way this app
    /// controls, and both windows are laid out from their content's fitting size.
    private func hostileSnapshot() -> SystemSnapshot {
        // Long enough to be absurd, short enough that laying it out does not hold the
        // main actor away from every test running beside this one.
        let long = String(repeating: "W", count: 600)
        let emoji = String(repeating: "👨‍👩‍👧‍👦🇦🇶", count: 60)
        let rtl = String(repeating: "مرحبا", count: 60)
        var s = SystemSnapshot.empty
        s.processes = .value(ProcessSnapshot(
            processes: [
                ProcessRow(pid: 1, name: long, cpuPercent: 99),
                ProcessRow(pid: 2, name: emoji, cpuPercent: 50),
                ProcessRow(pid: 3, name: rtl, cpuPercent: 25),
                ProcessRow(pid: 4, name: "\u{202E}reversed", cpuPercent: 10),
            ],
            totalProcessCount: 4, totalThreadCount: 8))
        s.system = .value(SystemInfoSnapshot(hostName: long, computerName: emoji,
                                             chipName: rtl, osVersion: long, uptime: 1_000))
        return s
    }

    private func fittingSize(of view: some View) -> NSSize {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @Test("a five-thousand-character process name cannot widen the panel")
    func panelWidthHolds() {
        let s = store()
        let engine = MetricsEngine(settingsStore: s)
        engine.loadFixture(snapshot: hostileSnapshot(), history: MetricHistory(capacity: 60, sampleInterval: 1))
        let size = fittingSize(of: PanelRootView(engine: engine, settings: s))
        #expect(abs(size.width - PanelSettings.width) < 0.5, "panel grew to \(size.width)")
        #expect(size.height.isFinite && size.height < 20_000, "panel grew to \(size.height) tall")
    }

    @Test("the same strings cannot widen the desktop widget")
    func desktopWidgetWidthHolds() {
        let s = store()
        s.update {
            $0.desktopWidget.isCompact = false
            $0.desktopWidget.modules = PanelModule.allCases
        }
        let engine = MetricsEngine(settingsStore: s)
        engine.loadFixture(snapshot: hostileSnapshot(), history: MetricHistory(capacity: 60, sampleInterval: 1))
        let size = fittingSize(of: DesktopWidgetRootView(engine: engine, settings: s, layout: nil))
        #expect(abs(size.width - s.settings.desktopWidget.width) < 0.5, "desktop widget grew to \(size.width)")
        #expect(size.height.isFinite && size.height < 20_000, "desktop widget grew to \(size.height) tall")
    }
}
