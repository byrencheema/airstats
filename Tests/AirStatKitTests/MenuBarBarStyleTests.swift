import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

@Suite("The bar style is offered to the fraction readouts and to nothing else")
struct BarStyleAvailabilityTests {

    private static let fractionMetrics: Set<MenuBarMetric> = [
        .cpuUsage, .gpuUsage, .memoryUsage, .memoryPressure,
    ]

    @Test("only the readouts with a known ceiling offer it")
    func onlyFractionsOfferIt() {
        for metric in MenuBarMetric.allCases {
            let offered = metric.supportedStyles.contains(.bar)
            #expect(offered == Self.fractionMetrics.contains(metric), "\(metric) offered \(offered)")
        }
    }

    @Test("it is on offer, not the default: a new readout still lands on text")
    func fractionsStillDefaultToText() {
        for metric in Self.fractionMetrics {
            #expect(metric.supportedStyles.first == .text, "\(metric)")
        }
    }

    @Test("a metric that cannot draw it is clamped off it")
    func unsupportedStyleIsClamped() {
        let uptime = MenuBarItemConfig(metric: .uptime, style: .bar).sanitized()
        #expect(uptime.style != .bar)
        #expect(MenuBarMetric.uptime.supportedStyles.contains(uptime.style))
    }

    @Test("a readout already on it keeps it, on decode too")
    func supportedStyleSurvives() throws {
        let json = #"{"menuBar":{"items":[{"metric":"memoryPressure","style":"bar"}]}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.menuBar.items[0].style == .bar)
    }

    @Test("the shape is anonymous, so a caption is allowed beside it")
    func barAllowsCaption() {
        #expect(MenuBarDisplayStyle.bar.supportsCaption)
    }
}

@Suite("The bar fills to the fraction the readout reports")
struct BarStyleRenderTests {

    private func render(_ metric: MenuBarMetric, _ snapshot: SystemSnapshot,
                        showsCaption: Bool = false) -> MenuBarItemRender {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: metric, style: .bar,
                                                    showsCaption: showsCaption)]
        let model = MenuBarRenderModel(snapshot: snapshot, history: MetricHistory(),
                                       settings: settings, isStale: false)
        return model.items[0]
    }

    @Test("each fraction readout carries its own level")
    func levelsMatchTheSnapshot() {
        let snapshot = SnapshotFixtures.nominal
        // Memory's fraction is rebuilt from byte counts in the fixture, so it is
        // compared to within a rounding, not exactly.
        func level(_ metric: MenuBarMetric) -> Double { render(metric, snapshot).level ?? -1 }
        #expect(abs(level(.cpuUsage) - 0.34) < 0.001)
        #expect(abs(level(.memoryUsage) - 0.57) < 0.001)
        #expect(abs(level(.memoryPressure) - 0.32) < 0.001)
        #expect(abs(level(.gpuUsage) - 0.18) < 0.001)
    }

    @Test("a readout with no sample has no level and is unavailable")
    func missingSampleHasNoLevel() {
        var snapshot = SnapshotFixtures.nominal
        snapshot.gpu = .failure(.unsupported("no GPU"))
        let item = render(.gpuUsage, snapshot)
        #expect(item.level == nil)
        #expect(item.isUnavailable)
    }

    @Test("the caption rides beside the bar when asked for, and not otherwise")
    func captionFollowsTheToggle() {
        let snapshot = SnapshotFixtures.nominal
        #expect(render(.cpuUsage, snapshot, showsCaption: true).caption == "CPU")
        #expect(render(.cpuUsage, snapshot, showsCaption: false).caption == nil)
    }

    @Test("the side label is short enough to run along a bar")
    func sideLabelsAreShort() {
        let snapshot = SnapshotFixtures.nominal
        #expect(render(.memoryPressure, snapshot, showsCaption: true).caption == "PRS")
        for metric in [MenuBarMetric.cpuUsage, .gpuUsage, .memoryUsage, .memoryPressure] {
            #expect((render(metric, snapshot, showsCaption: true).caption?.count ?? 0) <= 3, "\(metric)")
        }
    }
}
