import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

@Suite("The status dot style is offered to the up-and-down network readout and to nothing else")
struct StatusDotAvailabilityTests {

    @Test("only network up and down offers it")
    func onlyThroughputOffersIt() {
        for metric in MenuBarMetric.allCases {
            let offered = metric.supportedStyles.contains(.statusDot)
            #expect(offered == (metric == .networkThroughput), "\(metric) offered \(offered)")
        }
    }

    @Test("it is on offer, not the default: a new readout still lands on text")
    func throughputStillDefaultsToText() {
        #expect(MenuBarMetric.networkThroughput.supportedStyles.first == .text)
    }

    @Test("a metric that cannot draw it is clamped off it")
    func unsupportedStyleIsClamped() {
        let cpu = MenuBarItemConfig(metric: .cpuUsage, style: .statusDot).sanitized()
        #expect(cpu.style != .statusDot)
    }

    @Test("a readout already on it keeps it, on decode too")
    func supportedStyleSurvives() throws {
        let json = #"{"menuBar":{"items":[{"metric":"networkThroughput","style":"statusDot"}]}}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.menuBar.items[0].style == .statusDot)
    }

    @Test("the lights carry no text, so a caption is refused")
    func dotsRefuseCaption() {
        #expect(!MenuBarDisplayStyle.statusDot.supportsCaption)
    }
}

@Suite("The two lights follow the network")
struct StatusDotRenderTests {

    private func render(_ snapshot: SystemSnapshot,
                        history: MetricHistory = MetricHistory()) -> MenuBarItemRender {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .networkThroughput, style: .statusDot)]
        let model = MenuBarRenderModel(snapshot: snapshot, history: history,
                                       settings: settings, isStale: false)
        return model.items[0]
    }

    @Test("a primary interface with a route out is online, and a transfer lights its light")
    func nominalIsOnline() {
        let item = render(SnapshotFixtures.nominal)
        #expect(item.networkStatus == .init(isOnline: true, isReceiving: true, isSending: true))
        #expect(!item.isUnavailable)
    }

    @Test("background chatter leaves the lights idle")
    func idleIsUnlit() {
        var snapshot = SnapshotFixtures.nominal
        snapshot.network = .value(SnapshotFixtures.network(down: 800, up: 120))
        let item = render(snapshot)
        #expect(item.networkStatus == .init(isOnline: true, isReceiving: false, isSending: false))
    }

    @Test("one direction lights on its own")
    func oneDirectionLights() {
        var snapshot = SnapshotFixtures.nominal
        snapshot.network = .value(SnapshotFixtures.network(down: 0, up: 250_000))
        let item = render(snapshot)
        #expect(item.networkStatus == .init(isOnline: true, isReceiving: false, isSending: true))
    }

    @Test("a light holds on after a burst, and goes out once the burst is old")
    func lightHoldsAfterBurst() {
        var snapshot = SnapshotFixtures.nominal
        snapshot.network = .value(SnapshotFixtures.network(down: 800, up: 120))
        var history = MetricHistory(capacity: 64, sampleInterval: 2)
        let hold = Int(MenuBarItemRender.NetworkStatus.holdSeconds / 2)

        history.record(.networkDownload, 2_000_000)
        for _ in 0..<(hold - 1) { history.record(.networkDownload, 0) }
        let held = render(snapshot, history: history)
        #expect(held.networkStatus?.isReceiving == true)
        #expect(held.networkStatus?.isSending == false)

        history.record(.networkDownload, 0)
        let expired = render(snapshot, history: history)
        #expect(expired.networkStatus?.isReceiving == false)
    }

    @Test("no primary interface is offline, whatever the counters say")
    func noPrimaryIsOffline() {
        var snapshot = SnapshotFixtures.nominal
        snapshot.network = .value(NetworkSnapshot(uploadBytesPerSecond: 1_000_000,
                                                  downloadBytesPerSecond: 1_000_000,
                                                  connectionType: .none))
        let item = render(snapshot)
        #expect(item.networkStatus == .init(isOnline: false))
        #expect(item.accessibilityLabel == "Network offline")
    }

    @Test("no sample at all draws the dash, as the numbers would")
    func missingSampleIsUnavailable() {
        let item = render(SnapshotFixtures.degraded)
        #expect(item.networkStatus == nil)
        #expect(item.isUnavailable)
    }

    @Test("the other styles of the same readout carry the lights too, and no other readout does")
    func onlyThroughputCarriesIt() {
        var settings = Settings()
        settings.menuBar.items = MenuBarMetric.allCases.map { MenuBarItemConfig(metric: $0) }
        let model = MenuBarRenderModel(snapshot: SnapshotFixtures.nominal,
                                       history: MetricHistory(),
                                       settings: settings, isStale: false)
        for (config, item) in zip(settings.menuBar.items, model.items) {
            #expect((item.networkStatus != nil) == (config.metric == .networkThroughput),
                    "\(config.metric)")
        }
    }
}
