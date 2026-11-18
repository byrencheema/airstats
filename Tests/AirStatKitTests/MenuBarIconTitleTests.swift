import Testing
import Foundation
import AppKit
@testable import AirStatKit
@testable import AirStatUI

@MainActor
@Suite("Menu bar icon titles and Vietnamese localisation")
struct MenuBarIconTitleTests {

    @Test("usesIconTitles replaces text captions with metric and device icons")
    func iconTitlesRenderAndUseDeviceSymbol() throws {
        var settings = Settings()
        settings.menuBar.usesIconTitles = true
        settings.menuBar.items = [
            MenuBarItemConfig(metric: .cpuUsage, style: .text, showsCaption: true),
            MenuBarItemConfig(metric: .memoryUsage, style: .text, showsCaption: true),
            MenuBarItemConfig(metric: .gpuUsage, style: .text, showsCaption: true),
            MenuBarItemConfig(metric: .diskFree, style: .text, showsCaption: true),
            MenuBarItemConfig(metric: .bluetoothBattery, style: .text, showsCaption: true),
        ]

        let model = MenuBarRenderModel(snapshot: SnapshotFixtures.nominal,
                                       history: SnapshotFixtures.history(),
                                       settings: settings,
                                       isStale: false)
        #expect(model.items.allSatisfy { $0.usesIconTitle })
        // Lowest Bluetooth device in nominal fixture is Magic Mouse (23%), so it picks
        // the mouse glyph rather than a generic Bluetooth symbol.
        #expect(model.items[4].symbolName == BluetoothDeviceCategory.mouse.symbolName)

        let view = MenuBarContentView(frame: .zero)
        view.update(with: model)
        #expect(view.intrinsicContentSize.width > 0)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatIconTitleTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let req = OffscreenRenderer.Request(surface: .menuBar, scenario: .nominal,
                                            isDark: true, scale: 2, settings: settings)
        let url = try OffscreenRenderer.render(req, to: out)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Vietnamese language setting localises metrics, panels, alerts and round-trips")
    func vietnameseLocalisation() throws {
        var settings = Settings()
        settings.general.language = .vietnamese
        settings.menuBar.usesIconTitles = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded.general.language == .vietnamese)
        #expect(decoded.menuBar.usesIconTitles)

        #expect(L10n.tr("Battery", "Pin", language: AppLanguage.vietnamese) == "Pin")
        #expect(MenuBarRenderModel.captionText(for: .diskFree, language: .vietnamese) == "TRỐNG")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatViTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        store.update { $0.general.language = .vietnamese }
        defer { store.update { $0.general.language = .system } }

        #expect(PanelModule.memory.label == "Bộ nhớ")
        #expect(PanelModule.disk.label == "Ổ đĩa")
        #expect(PanelModule.battery.label == "Pin")

        var evaluator = ThresholdEvaluator()
        let rule = ThresholdRule(metric: .bluetoothBatteryLow, threshold: 20,
                                 isEnabled: true, sustainedFor: 0)
        var snapshot = SnapshotFixtures.nominal
        snapshot.bluetooth = .value(SnapshotFixtures.bluetooth(mousePercent: 12, charging: false))
        let alerts = evaluator.alerts(for: [rule],
                                      readings: ThresholdEvaluator.readings(from: snapshot),
                                      now: Date())
        #expect(alerts.count == 1)
        #expect(alerts[0].title == "Pin thiết bị Bluetooth yếu")
        #expect(alerts[0].body(in: snapshot) == "Magic Mouse còn 12%, dưới ngưỡng 20%.")
    }

    @Test("every Bluetooth device category has valid outline and filled SF Symbols")
    func bluetoothCategorySymbolsExist() {
        let categories: [BluetoothDeviceCategory] = [
            .headphones, .speaker, .keyboard, .mouse, .trackpad,
            .gamepad, .phone, .computer, .watch, .microphone, .other,
        ]
        for category in categories {
            #expect(NSImage(systemSymbolName: category.symbolName,
                            accessibilityDescription: nil) != nil,
                    "Missing symbol \(category.symbolName)")
            #expect(NSImage(systemSymbolName: category.filledSymbolName,
                            accessibilityDescription: nil) != nil,
                    "Missing filled symbol \(category.filledSymbolName)")
        }
    }
}
