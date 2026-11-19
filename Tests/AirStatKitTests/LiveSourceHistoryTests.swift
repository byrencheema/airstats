import Testing
import Foundation
@testable import AirStatKit

@MainActor
@Suite("History records only sources that were running")
struct LiveSourceHistoryTests {

    private func makeEngine() -> MetricsEngine {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return MetricsEngine(settingsStore: SettingsStore(directory: dir))
    }

    @Test("a source suspended with the panel stops adding its last reading to history")
    func suspendedSourceIsNotRecorded() {
        let engine = makeEngine()
        engine.ingest(SnapshotFixtures.nominal)
        #expect(engine.history[.networkDownload].count == 1)

        var closed = SnapshotFixtures.nominal
        closed.liveSources = [.cpu, .thermal, .gpu, .power, .system]
        engine.ingest(closed)
        engine.ingest(closed)
        #expect(engine.history[.networkDownload].count == 1, "network was suspended but kept recording")
        #expect(engine.history[.memoryUsed].count == 1)
        #expect(engine.history[.cpuTotal].count == 3)
        #expect(engine.dayHistory.series(.networkDownload).counts.last == 1)
    }
}
