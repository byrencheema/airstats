import Testing
import Foundation
@testable import AirStatKit

@Suite("Minute history")
struct MinuteHistoryTests {

    private func date(minute: Int, second: Double = 0) -> Date {
        Date(timeIntervalSince1970: Double(minute) * 60 + second)
    }

    @Test("the tier's series index is the position in allCases")
    func seriesIndexMatchesAllCases() {
        for (offset, key) in SeriesKey.allCases.enumerated() {
            #expect(key.index == offset, "\(key) is addressed at \(key.index), listed at \(offset)")
        }
    }

    @Test("samples in one minute fold into one bucket")
    func oneBucket() {
        var day = MinuteHistory(capacity: 10)
        day.advance(to: date(minute: 100, second: 2))
        day.record(.cpuTotal, 0.2)
        day.advance(to: date(minute: 100, second: 32))
        day.record(.cpuTotal, 0.6)
        let series = day.series(.cpuTotal)
        #expect(series.count == 10)
        #expect(series.counts.last == 2)
        #expect(series.minima.last == 0.2)
        #expect(series.maxima.last == 0.6)
        #expect(abs(series.averages.last! - 0.4) < 0.0001)
        #expect(series.sampledCount == 1)
        #expect(series.end == date(minute: 101))
    }

    @Test("minutes that pass with no sample are gaps, not zeros")
    func gaps() {
        var day = MinuteHistory(capacity: 10)
        day.advance(to: date(minute: 100))
        day.record(.cpuTotal, 0.5)
        day.advance(to: date(minute: 104))
        day.record(.cpuTotal, 0.9)
        let series = day.series(.cpuTotal)
        #expect(series.counts.suffix(5).map { Int($0) } == [1, 0, 0, 0, 1])
        #expect(series.sampledCount == 2)
        #expect(series.collectedSpan == 5 * 60)
        #expect(series.minimum == 0.5)
        #expect(abs(series.maximum - 0.9) < 0.0001)
    }

    @Test("a series nothing was recorded for stays empty while its neighbours fill")
    func missingSensorLeavesGap() {
        var day = MinuteHistory(capacity: 4)
        day.advance(to: date(minute: 1))
        day.record(.cpuTotal, 0.5)
        #expect(day.series(.gpuTemperature).isEmpty)
        #expect(!day.series(.cpuTotal).isEmpty)
    }

    @Test("the ring wraps without leaking old minutes into new ones")
    func wraps() {
        var day = MinuteHistory(capacity: 5)
        for minute in 0..<12 {
            day.advance(to: date(minute: minute))
            day.record(.cpuTotal, Double(minute))
        }
        let series = day.series(.cpuTotal)
        #expect(series.averages == [7, 8, 9, 10, 11])
        #expect(series.counts.allSatisfy { $0 == 1 })

        // Skip two minutes and land on a slot that held minute 8: it must be empty
        // on the way past and hold only the new sample after.
        day.advance(to: date(minute: 14))
        day.record(.cpuTotal, 14)
        let after = day.series(.cpuTotal)
        #expect(after.counts.map { Int($0) } == [1, 1, 0, 0, 1])
        #expect(after.averages.last == 14)
    }

    @Test("a jump of a whole window empties everything")
    func longJumpClears() {
        var day = MinuteHistory(capacity: 5)
        day.advance(to: date(minute: 0))
        day.record(.cpuTotal, 1)
        day.advance(to: date(minute: 5))
        #expect(day.isEmpty)
        day.record(.cpuTotal, 2)
        #expect(day.series(.cpuTotal).counts.map { Int($0) } == [0, 0, 0, 0, 1])
    }

    @Test("a clock that goes backwards keeps writing into the newest bucket")
    func clockBackwards() {
        var day = MinuteHistory(capacity: 5)
        day.advance(to: date(minute: 10))
        day.record(.cpuTotal, 1)
        day.advance(to: date(minute: 7))
        day.record(.cpuTotal, 3)
        let series = day.series(.cpuTotal)
        #expect(day.newestMinute == 10)
        #expect(series.counts.last == 2)
        #expect(series.averages.last == 2)
    }

    @Test("non-finite samples are dropped rather than coerced to zero")
    func nonFinite() {
        var day = MinuteHistory(capacity: 3)
        day.advance(to: date(minute: 1))
        day.record(.cpuTotal, .nan)
        day.record(.cpuTotal, .infinity)
        #expect(day.series(.cpuTotal).isEmpty)
        day.record(.cpuTotal, 0.4)
        #expect(day.series(.cpuTotal).minima.last == 0.4)
    }

    @Test("the day average weights buckets by their sample counts")
    func weightedAverage() {
        var day = MinuteHistory(capacity: 3)
        day.advance(to: date(minute: 0))
        day.record(.cpuTotal, 1)
        day.record(.cpuTotal, 1)
        day.record(.cpuTotal, 1)
        day.advance(to: date(minute: 1))
        day.record(.cpuTotal, 5)
        let series = day.series(.cpuTotal)
        #expect(series.average == 2)
        #expect(series.last == 5)
        #expect(series.newestSampled == 2)
    }

    @Test("nothing recorded reads as an empty day ending now")
    func emptyDay() {
        let series = MinuteHistory(capacity: 7).series(.cpuTotal)
        #expect(series.isEmpty)
        #expect(series.count == 7)
        #expect(series.collectedSpan == 0)
        #expect(series.last == nil)
        #expect(abs(series.end.timeIntervalSinceNow) < 5)
    }
}

@MainActor
@Suite("History across sleep")
struct HistorySleepTests {

    private func makeEngine() -> MetricsEngine {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return MetricsEngine(settingsStore: SettingsStore(directory: dir))
    }

    @Test("waking clears the raw ring and keeps the day")
    func wakeKeepsTheDay() {
        let engine = makeEngine()
        engine.ingest(SnapshotFixtures.nominal)
        engine.ingest(SnapshotFixtures.nominal)
        #expect(engine.history[.cpuTotal].count == 2)
        #expect(engine.dayHistory.series(.cpuTotal).counts.last == 2)

        engine.setSystemAsleep(true)
        engine.setSystemAsleep(false)
        #expect(engine.history[.cpuTotal].count == 0, "rates across a sleep are meaningless")
        #expect(engine.dayHistory.series(.cpuTotal).counts.last == 2, "the day survived the lid")
    }

    @Test("the fixture day is a day, with a gap in it")
    func fixtureShape() {
        let series = SnapshotFixtures.dayHistory().series(.cpuTotal)
        #expect(series.count == 1440)
        #expect(series.counts.contains(0))
        #expect(series.counts.first! > 0)
        #expect(series.counts.last! > 0)
        #expect(series.maximum > series.minimum)
        #expect(series.end == SnapshotFixtures.referenceDate)
    }
}

@Suite("History chart settings")
struct HistoryChartSettingsTests {

    @Test("files written before the toggles existed decode with the shipped defaults")
    func decodesDefaults() throws {
        let panel = try JSONDecoder().decode(PanelSettings.self, from: Data("{}".utf8))
        #expect(panel.showsHistoryChart == true)
        let widget = try JSONDecoder().decode(DesktopWidgetSettings.self, from: Data("{}".utf8))
        #expect(widget.showsHistoryChart == false)
    }

    @Test("the toggles round trip")
    func roundTrip() throws {
        var panel = PanelSettings()
        panel.showsHistoryChart = false
        let decodedPanel = try JSONDecoder().decode(PanelSettings.self, from: JSONEncoder().encode(panel))
        #expect(decodedPanel.showsHistoryChart == false)

        var widget = DesktopWidgetSettings()
        widget.showsHistoryChart = true
        let decodedWidget = try JSONDecoder().decode(DesktopWidgetSettings.self,
                                                     from: JSONEncoder().encode(widget))
        #expect(decodedWidget.showsHistoryChart == true)
    }
}

@Suite("Minute history file")
struct MinuteHistoryFileTests {

    private func filled() -> MinuteHistory {
        var day = MinuteHistory(capacity: 8)
        for minute in 0..<6 {
            day.advance(to: Date(timeIntervalSince1970: Double(minute) * 60))
            day.record(.cpuTotal, Double(minute) / 10)
            day.record(.networkDownload, Double(minute) * 1000)
        }
        return day
    }

    @Test("a day round trips through its file byte for byte")
    func roundTrip() {
        let day = filled()
        let decoded = MinuteHistory(encoded: day.encoded(), capacity: 8)
        #expect(decoded == day)
        #expect(decoded?.series(.cpuTotal) == day.series(.cpuTotal))
        #expect(decoded?.newestMinute == 5)
    }

    @Test("a file from another capacity, a truncated one, or garbage is absent, not data")
    func rejectsForeignFiles() {
        let day = filled()
        #expect(MinuteHistory(encoded: day.encoded(), capacity: 1440) == nil)
        #expect(MinuteHistory(encoded: day.encoded().dropLast(), capacity: 8) == nil)
        #expect(MinuteHistory(encoded: Data("not a day".utf8), capacity: 8) == nil)
        #expect(MinuteHistory(encoded: Data(), capacity: 8) == nil)
    }

    @Test("an empty day encodes and decodes as empty")
    func emptyDay() {
        let decoded = MinuteHistory(encoded: MinuteHistory(capacity: 4).encoded(), capacity: 4)
        #expect(decoded?.isEmpty == true)
        #expect(decoded?.newestMinute == nil)
    }

    @Test("the store writes and reads the file, and a restored day resumes with a gap")
    func storeAndResume() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = MinuteHistoryFile(directory: dir)
        #expect(file.load(capacity: 8) == nil)
        file.save(filled())
        var restored = file.load(capacity: 8)!
        #expect(restored.collectedSpan(of: .cpuTotal) == 6 * 60)
        // Relaunched three minutes later: the newest bucket moves on and the two
        // minutes nobody was sampling are gaps.
        restored.advance(to: Date(timeIntervalSince1970: 8 * 60))
        restored.record(.cpuTotal, 0.9)
        #expect(restored.series(.cpuTotal).counts.map { Int($0) } == [1, 1, 1, 1, 1, 0, 0, 1])
    }

    @Test("collected span is measured from the oldest sampled bucket of that series")
    func collectedSpan() {
        var day = MinuteHistory(capacity: 10)
        day.advance(to: Date(timeIntervalSince1970: 0))
        day.record(.cpuTotal, 1)
        day.advance(to: Date(timeIntervalSince1970: 4 * 60))
        day.record(.cpuTotal, 1)
        day.record(.gpuTemperature, 1)
        #expect(day.collectedSpan(of: .cpuTotal) == 5 * 60)
        #expect(day.collectedSpan(of: .gpuTemperature) == 60)
        #expect(day.collectedSpan(of: .fanRPM) == 0)
        #expect(MinuteHistory(capacity: 10).collectedSpan(of: .cpuTotal) == 0)
    }
}
