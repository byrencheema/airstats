import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

@Suite("A text readout whose text has not changed does not redraw")
struct MenuBarRedrawTests {

    /// Built once per style: each config carries a fresh identity, and two models
    /// from different configs are rightly unequal.
    private static let settings: [MenuBarDisplayStyle: Settings] = [MenuBarDisplayStyle.text, .graph].reduce(into: [:]) { all, style in
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage, style: style),
                                  MenuBarItemConfig(metric: .networkThroughput, style: style)]
        all[style] = settings
    }

    private func model(_ style: MenuBarDisplayStyle, history: MetricHistory) -> MenuBarRenderModel {
        MenuBarRenderModel(snapshot: SnapshotFixtures.nominal, history: history,
                           settings: Self.settings[style]!, isStale: false)
    }

    private func history(samples: Int) -> MetricHistory {
        var history = MetricHistory(capacity: 60)
        for index in 0..<samples {
            history.record(.cpuTotal, 0.2 + Double(index % 7) / 100)
            history.record(.networkDownload, Double(index * 1000))
            history.record(.networkUpload, Double(index * 300))
        }
        return history
    }

    @Test("a new sample in history leaves a text model equal, so the status item is not redrawn")
    func textIgnoresHistory() {
        #expect(model(.text, history: history(samples: 10)) == model(.text, history: history(samples: 11)))
    }

    @Test("a graph still redraws when history moves")
    func graphFollowsHistory() {
        #expect(model(.graph, history: history(samples: 10)) != model(.graph, history: history(samples: 11)))
    }
}
