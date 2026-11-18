import Testing
import Foundation
import AppKit
@testable import AirStatKit
@testable import AirStatUI

@MainActor
@Suite("Network throughput stacks Upload over Download in one fixed-width column")
struct MenuBarNetworkStackTests {

    private func renderWidth(down: Double, up: Double,
                             style: MenuBarDisplayStyle = .text) -> CGFloat {
        var snapshot = SnapshotFixtures.nominal
        snapshot.network = .value(SnapshotFixtures.network(down: down, up: up))
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .networkThroughput, style: style)]
        let model = MenuBarRenderModel(snapshot: snapshot,
                                       history: SnapshotFixtures.history(),
                                       settings: settings,
                                       isStale: false)
        let view = MenuBarContentView(frame: .zero)
        view.update(with: model)
        return view.intrinsicContentSize.width
    }

    @Test("upload sits over download and keeps one width across idle and saturated links")
    func stackedOrderAndFixedWidth() {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .networkThroughput, style: .text)]
        let model = MenuBarRenderModel(snapshot: SnapshotFixtures.nominal,
                                       history: SnapshotFixtures.history(),
                                       settings: settings,
                                       isStale: false)
        let item = model.items[0]
        #expect(item.pairOrder == .secondaryOverPrimary)
        #expect(item.secondary?.glyph == "↑")
        #expect(item.primary.glyph == "↓")

        let idle = renderWidth(down: 0, up: 0)
        let moderate = renderWidth(down: 2_400_000, up: 340_000)
        let saturated = renderWidth(down: 940_000_000, up: 512_000_000)
        #expect(idle == moderate)
        #expect(moderate == saturated)
        // Stacked in one column, the whole item stays well under 75pt instead of the
        // ~105pt side-by-side layout that crowded notched displays.
        #expect(saturated <= 75, "stacked network readout measured \(saturated)pt wide")
    }

    @Test("renders offscreen cleanly across text, icon, and graph styles")
    func rendersEveryThroughputStyle() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatNetStackTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        for style in [MenuBarDisplayStyle.text, .iconAndText, .textAndGraph] {
            var settings = Settings()
            settings.menuBar.items = [
                MenuBarItemConfig(metric: .cpuUsage, style: .text, showsCaption: true),
                MenuBarItemConfig(metric: .networkThroughput, style: style, showsCaption: false),
                MenuBarItemConfig(metric: .bluetoothBattery, style: .iconAndText, showsCaption: false),
                MenuBarItemConfig(metric: .battery, style: .battery, showsCaption: false),
            ]
            for isDark in [false, true] {
                let sub = out.appendingPathComponent(style.rawValue, isDirectory: true)
                let req = OffscreenRenderer.Request(surface: .menuBar, scenario: .nominal,
                                                    isDark: isDark, scale: 2, settings: settings)
                let url = try OffscreenRenderer.render(req, to: sub)
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }
}
