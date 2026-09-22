import Testing
import Foundation
import SwiftUI
@testable import AirStatKit
@testable import AirStatUI

@Suite("History band plot")
struct BandPlotTests {

    private let rect = CGRect(x: 0, y: 0, width: 10, height: 100)
    private let unit = ChartScale(upperBound: 1, isDerived: false, peak: 1)

    private func minutes(_ values: [Double?], notes: [Int: String] = [:]) -> MinuteSeries {
        MinuteSeries(key: .cpuTotal,
                     minima: values.map { Float(($0 ?? 0) * 0.5) },
                     averages: values.map { Float($0 ?? 0) },
                     maxima: values.map { Float(($0 ?? 0) * 1.5) },
                     counts: values.map { $0 == nil ? 0 : 2 },
                     notes: notes,
                     end: Date(timeIntervalSince1970: 86_400))
    }

    /// Subpaths, which is rectangles for a span path and runs plus dots for a stroke.
    private func subpaths(_ path: Path) -> Int {
        var moves = 0
        path.forEach { if case .move = $0 { moves += 1 } }
        return moves
    }

    @Test("a column's note is the one from the minute that set its high")
    func columnNotes() {
        // Two buckets per column. Column 0 gets its high from bucket 1, which is
        // the noted one; column 1 gets its high from bucket 2, which is not.
        let values: [Double?] = [0.1, 0.4, 0.5, 0.2] + Array(repeating: 0.1, count: 16)
        let plot = BandPlot(rect: rect, scale: unit,
                            minutes: minutes(values, notes: [1: "Xcode", 3: "Music"]))
        #expect(plot.columns[0]?.note == "Xcode")
        #expect(plot.columns[1]?.note == nil)
        #expect(plot.columns[2]?.note == nil)
    }

    @Test("the stroke carries the line, a dot per lone column and the marker")
    func strokeMarks() {
        var values: [Double?] = Array(repeating: 0.5, count: 10)
        values[3] = nil; values[5] = nil
        let plot = BandPlot(rect: rect, scale: unit, minutes: minutes(values))
        // Runs 0..<3, 4..<5 (a lone column) and 6..<10: two lines and one dot, then
        // the marker on the newest column.
        #expect(subpaths(plot.strokeMarksPath(lineWidth: 1.5)) == 3)
        #expect(subpaths(plot.strokeMarksPath(lineWidth: 1.5, newest: plot.newestSampled)) == 4)
        #expect(plot.newestSampled == 9)
        #expect(subpaths(plot.strokeMarksPath(lineWidth: 1.5, newest: 3)) == 3)
    }

    @Test("shaded spans cover the runs of columns at one, edge to edge")
    func spans() {
        let values: [Double?] = [0, 0, 1, 1, 1, 0, nil, 1, 1, 1]
        let plot = BandPlot(rect: rect, scale: unit, minutes: minutes(values))
        let path = plot.spanPath { $0.mean >= 0.5 }
        #expect(subpaths(path) == 2)
        #expect(abs(path.boundingRect.maxX - rect.maxX) < 0.001)
        #expect(abs(path.boundingRect.height - rect.height) < 0.001)
        #expect(plot.spanPath { _ in false }.isEmpty)
        #expect(subpaths(plot.spanPath { _ in true }) == 2)
    }

    @Test("the grid is one path of rules and marks")
    func grid() {
        let plot = BandPlot(rect: rect, scale: unit, minutes: minutes(Array(repeating: 0.5, count: 10)))
        #expect(subpaths(plot.gridPath(marks: HistoryAxis.marks)) == 5 + 2)
    }

    @Test("buckets reduce to per-column extremes and a weighted mean, and gaps stay gaps")
    func reduction() {
        // Twenty buckets into ten columns: two per column. Buckets 4 and 5 are empty,
        // so column 2 is a gap; bucket 6 is empty and 7 is not, so column 3 is sampled.
        var values: [Double?] = (0..<20).map { Double($0) / 40 }
        values[4] = nil; values[5] = nil; values[6] = nil
        let plot = BandPlot(rect: rect, scale: unit, minutes: minutes(values))
        #expect(plot.count == 10)
        #expect(plot.columns[2] == nil)
        #expect(plot.columns[3] != nil)
        #expect(abs(plot.columns[3]!.mean - 7.0 / 40) < 0.0001)
        let first = plot.columns[0]!
        #expect(first.low == 0)
        #expect(abs(first.high - 1.5 / 40) < 0.0001)
        #expect(abs(first.mean - 0.5 / 40) < 0.0001)
        #expect(plot.sampledCount == 9)
        #expect(plot.runs == [0..<2, 3..<10])
    }

    @Test("paths break across a gap instead of bridging it")
    func pathsBreak() {
        var values: [Double?] = Array(repeating: 0.5, count: 10)
        values[5] = nil
        let plot = BandPlot(rect: rect, scale: unit, minutes: minutes(values))
        // Two runs: two band subpaths, and the line lifts its pen once.
        #expect(plot.runs.count == 2)
        let band = plot.bandPath()
        var moves = 0
        band.forEach { element in if case .move = element { moves += 1 } }
        #expect(moves == 2)
        #expect(plot.isEmpty == false)
    }

    @Test("a raw ring with fewer samples than columns is one column per sample")
    func rawUnreduced() {
        var ring = SampleRing(capacity: 8)
        for v in [0.1, 0.4, 0.2] { ring.append(v) }
        let plot = BandPlot(rect: rect, scale: unit, samples: ring)
        #expect(plot.count == 3)
        #expect(plot.columns.map { $0!.low } == plot.columns.map { $0!.high })
        #expect(abs(plot.columns[1]!.mean - 0.4) < 0.0001)
        #expect(plot.supportsTrend)
    }

    @Test("a raw ring wider than the plot keeps both ends of every column")
    func rawReduced() {
        var ring = SampleRing(capacity: 40)
        for i in 0..<40 { ring.append(Float(i % 2 == 0 ? 0.1 : 0.9)) }
        let plot = BandPlot(rect: rect, scale: unit, samples: ring)
        #expect(plot.count == 10)
        for column in plot.columns {
            #expect(abs(column!.low - 0.1) < 0.0001)
            #expect(abs(column!.high - 0.9) < 0.0001)
            #expect(abs(column!.mean - 0.5) < 0.0001)
        }
    }

    @Test("a pointer position maps to the nearest column and back to its fraction")
    func scrubMapping() {
        let plot = BandPlot(rect: rect, scale: unit, minutes: minutes(Array(repeating: 0.5, count: 10)))
        #expect(plot.column(at: -5) == 0)
        #expect(plot.column(at: 50) == 9)
        #expect(plot.column(at: 5) == 4 || plot.column(at: 5) == 5)
        #expect(plot.fraction(of: 0) == 0)
        #expect(plot.fraction(of: 9) == 1)
        #expect(plot.x(9) == rect.maxX)
    }

    @Test("an unsampled window draws nothing and says so")
    func empty() {
        let plot = BandPlot(rect: rect, scale: unit, minutes: minutes(Array(repeating: nil, count: 10)))
        #expect(plot.isEmpty)
        #expect(plot.bandPath().isEmpty)
        #expect(plot.linePath().isEmpty)
        #expect(plot.runs.isEmpty)
    }
}

@Suite("History axis")
struct HistoryAxisTests {

    @Test("time before now reads in the unit that fits it")
    func relative() {
        #expect(HistoryAxis.relative(0) == "now")
        #expect(HistoryAxis.relative(-40) == "-40s")
        #expect(HistoryAxis.relative(-300) == "-5m")
        #expect(HistoryAxis.relative(-200) == "-3:20")
        #expect(HistoryAxis.relative(-100) == "-1:40")
        #expect(HistoryAxis.relative(-3_600) == "-1h")
        #expect(HistoryAxis.relative(-2_400) == "-40m")
    }

    @Test("a day is labelled in clock time and a short window as time before now")
    func labels() {
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        let day = HistoryAxis.labels(span: 86_400, end: end)
        #expect(day.count == 4)
        #expect(day.last == "now")
        #expect(day[0] == HistoryAxis.clock(end.addingTimeInterval(-86_400)))
        let short = HistoryAxis.labels(span: 300, end: end)
        #expect(short == ["-5m", "-3:20", "-1:40", "now"])
    }

    @Test("range segments are labelled in the shortest honest unit")
    func rangeLabels() {
        #expect(HistoryRange.label(forSpan: 60) == "1m")
        #expect(HistoryRange.label(forSpan: 300) == "5m")
        #expect(HistoryRange.label(forSpan: 1_800) == "30m")
        #expect(HistoryRange.label(forSpan: 3_600) == "1h")
        #expect(HistoryRange.label(forSpan: 86_400) == "24h")
    }

    @Test("every module with a chart has a series the tier records")
    func moduleSeries() {
        let charted = PanelModule.allCases.compactMap(\.historySeries)
        #expect(charted.count == 7)
        #expect(PanelModule.processes.historySeries == nil)
        #expect(PanelModule.system.historySeries == nil)
        #expect(PanelModule.thermal.historySeries?.domain == 30...100)
    }
}

@Suite("Charger shading")
struct ShadingTests {
    private let rect = CGRect(x: 0, y: 0, width: 10, height: 100)
    private let unit = ChartScale(upperBound: 1, isDerived: false, peak: 1)

    private func plugged(_ values: [Double?]) -> BandPlot {
        BandPlot(rect: rect, scale: unit,
                 minutes: MinuteSeries(key: .batteryPlugged,
                                       minima: values.map { Float($0 ?? 0) },
                                       averages: values.map { Float($0 ?? 0) },
                                       maxima: values.map { Float($0 ?? 0) },
                                       counts: values.map { $0 == nil ? 0 : 1 },
                                       end: Date(timeIntervalSince1970: 600)))
    }

    @Test("a window spent entirely on one side of the threshold is not shaded")
    func oneState() {
        #expect(!plugged([1, 1, 1, nil, 1, 1]).straddles(0.5))
        #expect(!plugged([0, 0, 0, 0, 0, 0]).straddles(0.5))
        #expect(!plugged([nil, nil]).straddles(0.5))
        #expect(plugged([1, 1, 0, 0, 1, 1]).straddles(0.5))
        #expect(plugged([0.2, 0.7]).straddles(0.5))
    }
}

@Suite("Filled band")
struct FilledBandTests {
    @Test("the filled style reaches the floor from every column's high")
    func reachesFloor() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 100)
        let unit = ChartScale(upperBound: 1, isDerived: false, peak: 1)
        var values: [Double?] = Array(repeating: 0.6, count: 10)
        values[4] = nil
        let series = MinuteSeries(key: .batteryPercent,
                                  minima: values.map { Float($0 ?? 0) },
                                  averages: values.map { Float($0 ?? 0) },
                                  maxima: values.map { Float($0 ?? 0) },
                                  counts: values.map { $0 == nil ? 0 : 1 },
                                  end: Date(timeIntervalSince1970: 600))
        let plot = BandPlot(rect: rect, scale: unit, minutes: series)
        let filled = plot.filledBandPath().boundingRect
        #expect(abs(filled.maxY - rect.maxY) < 0.001)
        #expect(abs(filled.minY - 40) < 0.001)
        #expect(abs(plot.bandPath().boundingRect.height) < 0.001)
    }
}
