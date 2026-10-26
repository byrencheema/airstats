import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

@Suite("The stacked pair style is offered to the two-direction readouts and to nothing else")
struct StackedPairAvailabilityTests {

    private static let pairedMetrics: Set<MenuBarMetric> = [.networkThroughput, .diskActivity]

    @Test("only the paired readouts offer it")
    func onlyPairsOfferIt() {
        for metric in MenuBarMetric.allCases {
            let offered = metric.supportedStyles.contains(.stackedPair)
            #expect(offered == Self.pairedMetrics.contains(metric), "\(metric) offered \(offered)")
        }
    }

    @Test("it is on offer, not the default: a new readout still lands on text")
    func pairsStillDefaultToText() {
        for metric in Self.pairedMetrics {
            #expect(metric.supportedStyles.first == .text, "\(metric)")
        }
    }

    @Test("a metric that cannot draw it is clamped off it")
    func unsupportedStyleIsClamped() {
        let cpu = MenuBarItemConfig(metric: .cpuUsage, style: .stackedPair).sanitized()
        #expect(cpu.style != .stackedPair)
    }

    @Test("a readout already on it keeps it, on decode too")
    func supportedStyleSurvives() throws {
        let json = #"{"menuBar":{"items":[{"metric":"networkThroughput","style":"stackedPair"}]}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.menuBar.items[0].style == .stackedPair)
    }

    @Test("two rows are all a 22-point bar fits, so a caption is refused")
    func pairRefusesCaption() {
        #expect(!MenuBarDisplayStyle.stackedPair.supportsCaption)
    }
}

@Suite("The stacked pair angles its arrows; the one-line styles keep theirs")
struct StackedPairGlyphTests {

    private func glyphs(for metric: MenuBarMetric,
                        style: MenuBarDisplayStyle) -> (primary: String?, secondary: String?) {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: metric, style: style)]
        let model = MenuBarRenderModel(snapshot: SnapshotFixtures.nominal,
                                       history: MetricHistory(),
                                       settings: settings, isStale: false)
        let item = model.items[0]
        return (item.primary.glyph, item.secondary?.glyph)
    }

    @Test("the stacked style draws diagonal arrows")
    func stackedDrawsDiagonal() {
        let glyphs = glyphs(for: .networkThroughput, style: .stackedPair)
        #expect(glyphs.primary == "↙")
        #expect(glyphs.secondary == "↗")
    }

    @Test("the one-line styles keep the vertical arrows")
    func inlineKeepsVertical() {
        for style in [MenuBarDisplayStyle.text, .textAndGraph, .iconAndText] {
            let glyphs = glyphs(for: .networkThroughput, style: style)
            #expect(glyphs.primary == "↓", "\(style)")
            #expect(glyphs.secondary == "↑", "\(style)")
        }
    }

    @Test("the disk pair letters work stacked too, so they stay letters")
    func diskKeepsLetters() {
        let glyphs = glyphs(for: .diskActivity, style: .stackedPair)
        #expect(glyphs.primary == "R")
        #expect(glyphs.secondary == "W")
    }
}
