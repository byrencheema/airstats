import SwiftUI
import AirStatKit

/// Which of the two windows a history chart is showing.
///
/// Two fixed ranges and no picker. The first is whatever "Keep history for" already
/// is, so the chart footer never grows a second retention control next to the one in
/// Settings; the second is the day the minute tier keeps.
public enum HistoryRange: Equatable, Sendable, CaseIterable {
    case recent
    case day

    /// "5m", "1h", "24h": short enough for a two segment control in a chart footer.
    public static func label(forSpan span: TimeInterval) -> String {
        if span < 60 { return "\(Int(span.rounded()))s" }
        if span < 3_600 { return "\(Int((span / 60).rounded()))m" }
        let hours = span / 3_600
        return hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }
}

/// One drawable column of a history plot: the extremes and the mean of whatever fell
/// in it.
struct BandColumn: Equatable {
    var low: Double
    var mean: Double
    var high: Double
    /// The process behind the high, when the minute that set it was looked at.
    var note: String? = nil
}

/// Samples reduced to per-pixel columns that keep both ends of what happened.
///
/// `ChartPlot` keeps each column's maximum, which never hides a spike and is right
/// for a sparkline. Over a day a dip is an event too, a machine that went idle, and a
/// two hour idle stretch drawn as its ceiling is a plateau that never happened. So
/// this keeps the low and the high of every column and draws them as a band, with
/// the mean as the line through it. Columns nothing was sampled in are `nil`, and
/// every path here breaks across them rather than bridging the gap.
struct BandPlot {
    let rect: CGRect
    let scale: ChartScale
    /// Oldest to newest, one per drawable column, nil where nothing was sampled.
    let columns: [BandColumn?]
    /// How many source buckets or samples went into the columns.
    let sourceCount: Int

    /// A day of minute buckets. Columns are cut from the whole window, sampled or
    /// not, so the axis stays "24 hours ago to now" and a day still being collected
    /// draws in the part of it that has happened.
    init(rect: CGRect, scale: ChartScale, minutes: MinuteSeries) {
        self.rect = rect
        self.scale = scale
        self.sourceCount = minutes.count
        let n = minutes.count
        let columns = Self.columnCount(for: rect.width, samples: n)
        var out = [BandColumn?](repeating: nil, count: columns)
        guard n > 0 else { self.columns = out; return }
        minutes.counts.withUnsafeBufferPointer { counts in
            minutes.minima.withUnsafeBufferPointer { lows in
                minutes.maxima.withUnsafeBufferPointer { highs in
                    minutes.averages.withUnsafeBufferPointer { means in
                        for column in 0..<columns {
                            let start = column * n / columns
                            let end = Swift.max(start + 1, (column + 1) * n / columns)
                            var lo = Float.greatestFiniteMagnitude
                            var hi = -Float.greatestFiniteMagnitude
                            var sum = 0.0
                            var weight = 0
                            var peak = -1
                            for i in start..<Swift.min(end, n) where counts[i] > 0 {
                                let count = Int(counts[i])
                                lo = Swift.min(lo, lows[i])
                                if highs[i] > hi { hi = highs[i]; peak = i }
                                sum += Double(means[i]) * Double(count)
                                weight += count
                            }
                            if weight > 0 {
                                out[column] = BandColumn(low: Double(lo),
                                                         mean: sum / Double(weight),
                                                         high: Double(hi),
                                                         note: peak >= 0 ? minutes.notes[peak] : nil)
                            }
                        }
                    }
                }
            }
        }
        self.columns = out
    }

    /// The raw ring, for the short range. Every sample is present, so there are no
    /// gaps; when the ring holds fewer samples than there are columns each sample is
    /// its own column and the band collapses onto the line.
    init(rect: CGRect, scale: ChartScale, samples: SampleRing) {
        self.rect = rect
        self.scale = scale
        self.sourceCount = samples.count
        let n = samples.count
        guard n > 0 else { self.columns = []; return }
        let columns = Self.columnCount(for: rect.width, samples: n)
        var out = [BandColumn?]()
        out.reserveCapacity(columns)
        samples.withUnsafeRuns { older, newer in
            let olderCount = older.count
            for column in 0..<columns {
                let start = column * n / columns
                let end = Swift.max(start + 1, (column + 1) * n / columns)
                var lo = Float.greatestFiniteMagnitude
                var hi = -Float.greatestFiniteMagnitude
                var sum = 0.0
                var count = 0
                for i in start..<Swift.min(end, n) {
                    let v = i < olderCount ? older[i] : newer[i - olderCount]
                    lo = Swift.min(lo, v)
                    hi = Swift.max(hi, v)
                    sum += Double(v)
                    count += 1
                }
                out.append(BandColumn(low: Double(lo), mean: sum / Double(count), high: Double(hi)))
            }
        }
        self.columns = out
    }

    /// One column per point of width at most, and never more columns than samples.
    private static func columnCount(for width: CGFloat, samples: Int) -> Int {
        Swift.max(2, Swift.min(Int(width.rounded(.up)), Swift.max(samples, 2)))
    }

    var count: Int { columns.count }
    var isEmpty: Bool { !columns.contains { $0 != nil } }
    /// Sampled columns, so a day with one minute in it draws a level rather than a
    /// trend it cannot support.
    var sampledCount: Int { columns.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
    var supportsTrend: Bool { sampledCount >= Design.Chart.minimumPoints }

    func x(_ index: Int) -> CGFloat {
        guard count > 1 else { return rect.midX }
        return rect.minX + rect.width * CGFloat(index) / CGFloat(count - 1)
    }

    func y(_ value: Double) -> CGFloat {
        let fraction = Swift.min(Swift.max((value - scale.lowerBound) / scale.span, 0), 1)
        return rect.maxY - rect.height * CGFloat(fraction)
    }

    /// The column under a horizontal position, clamped to the plot.
    func column(at x: CGFloat) -> Int {
        guard count > 1, rect.width > 0 else { return 0 }
        let fraction = Swift.min(Swift.max((x - rect.minX) / rect.width, 0), 1)
        return Int((fraction * CGFloat(count - 1)).rounded())
    }

    /// Where a column sits in the window, 0 at the oldest edge and 1 at the newest.
    func fraction(of column: Int) -> Double {
        guard count > 1 else { return 1 }
        return Double(column) / Double(count - 1)
    }

    /// Maximal runs of adjacent sampled columns.
    var runs: [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        for (index, column) in columns.enumerated() {
            if column != nil {
                if start == nil { start = index }
            } else if let s = start {
                runs.append(s..<index)
                start = nil
            }
        }
        if let s = start { runs.append(s..<columns.count) }
        return runs
    }

    /// The area between each column's low and high, one closed subpath per run.
    func bandPath() -> Path {
        var path = Path()
        for run in runs where run.count > 1 {
            path.move(to: CGPoint(x: x(run.lowerBound), y: y(columns[run.lowerBound]!.high)))
            for i in run.dropFirst() { path.addLine(to: CGPoint(x: x(i), y: y(columns[i]!.high))) }
            for i in run.reversed() { path.addLine(to: CGPoint(x: x(i), y: y(columns[i]!.low))) }
            path.closeSubpath()
        }
        return path
    }

    /// The mean through every run of two or more columns. A run of one column has
    /// no direction to draw and gets a dot from `strokeMarksPath` instead.
    func linePath() -> Path {
        var path = Path()
        for run in runs where run.count > 1 {
            let first = run.lowerBound
            path.move(to: CGPoint(x: x(first), y: y(columns[first]!.mean)))
            for i in run.dropFirst() { path.addLine(to: CGPoint(x: x(i), y: y(columns[i]!.mean))) }
        }
        return path
    }

    /// Everything drawn in the line's own stroke, as one path: the mean through
    /// every run, a dot for every lone column, and the marker on `newest` when it
    /// is given. A dot is a single sampled minute between gaps, or the first minute
    /// of a day: it says "measured here" and nothing about what happened either
    /// side, which is all that is known. One path is one layer, and a chart is
    /// drawn by Core Animation as
    /// one bitmap per layer, so the count of these is the count of 2x backing
    /// stores the panel holds while it is open. A dot as a circle of radius half
    /// the stroke, stroked, is a solid disc of one stroke's diameter, which at the
    /// line's weight reads as the point marker it replaces.
    func strokeMarksPath(lineWidth: CGFloat, newest: Int? = nil) -> Path {
        var path = linePath()
        for run in runs where run.count == 1 {
            let i = run.lowerBound
            path.addPath(ChartLayout.marker(at: CGPoint(x: x(i), y: y(columns[i]!.mean)),
                                            radius: lineWidth / 2))
        }
        if let newest, let column = columns[newest] {
            path.addPath(ChartLayout.marker(at: CGPoint(x: x(newest), y: y(column.mean)),
                                            radius: lineWidth * 0.75))
        }
        return path
    }

    /// The bars with the newest marker in the same fill, for the same reason.
    func barPath(newest: Int?) -> Path {
        var path = barPath()
        if let newest, let column = columns[newest] {
            path.addPath(ChartLayout.marker(at: CGPoint(x: x(newest), y: y(column.high))))
        }
        return path
    }

    /// The newest sampled column, where the "now" marker sits.
    var newestSampled: Int? { columns.lastIndex(where: { $0 != nil }) }

    /// Whether the sampled columns fall on both sides of `threshold`: a window
    /// with a plug or an unplug in it, rather than one spent entirely on power or
    /// entirely off it.
    func straddles(_ threshold: Double) -> Bool {
        var above = false, below = false
        for column in columns {
            guard let column else { continue }
            if column.mean >= threshold { above = true } else { below = true }
            if above && below { return true }
        }
        return false
    }

    /// Full-height rectangles over every run of columns `included` says yes to,

    /// for shading the stretches of a day something was true: on the charger,
    /// say. Each run is one subpath, so the shading is one fill.
    func spanPath(where included: (BandColumn) -> Bool) -> Path {
        var path = Path()
        var start: Int?
        func close(at end: Int) {
            guard let s = start else { return }
            let left = s == 0 ? rect.minX : (x(s - 1) + x(s)) / 2
            let right = end == count ? rect.maxX : (x(end - 1) + x(end)) / 2
            path.addRect(CGRect(x: left, y: rect.minY, width: right - left, height: rect.height))
            start = nil
        }
        for (index, column) in columns.enumerated() {
            if let column, included(column) {
                if start == nil { start = index }
            } else {
                close(at: index)
            }
        }
        close(at: count)
        return path
    }

    /// The mean line closed down to the baseline, one subpath per run.
    func areaPath() -> Path {
        var path = Path()
        for run in runs where run.count > 1 {
            let first = run.lowerBound
            path.move(to: CGPoint(x: x(first), y: rect.maxY))
            for i in run { path.addLine(to: CGPoint(x: x(i), y: y(columns[i]!.mean))) }
            path.addLine(to: CGPoint(x: x(run.upperBound - 1), y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }

    /// Every sampled column as a bar to its high, as subpaths of one path.
    func barPath() -> Path {
        var path = Path()
        guard count > 0 else { return path }
        let slot = rect.width / CGFloat(count)
        let gap = Swift.min(Swift.max(slot * 0.25, 0.4), 1.5)
        let width = Swift.max(slot - gap, 0.6)
        for (i, column) in columns.enumerated() {
            guard let column else { continue }
            let top = y(column.high)
            let height = Swift.max(rect.maxY - top, column.high > 0 ? 1 : 0)
            guard height > 0 else { continue }
            path.addRect(CGRect(x: rect.minX + CGFloat(i) * slot, y: rect.maxY - height,
                                width: width, height: height))
        }
        return path
    }

    /// A flat line at the newest sampled column's mean, for a window with too few
    /// sampled columns to support a trend.
    func levelPath() -> Path {
        var path = Path()
        let level = columns.last(where: { $0 != nil }).map { y($0!.mean) } ?? rect.maxY
        path.move(to: CGPoint(x: rect.minX, y: level))
        path.addLine(to: CGPoint(x: rect.maxX, y: level))
        return path
    }

    /// Vertical hairlines at the interior time marks.
    func timeGridPath(marks: [Double]) -> Path {
        var path = Path()
        for mark in marks where mark > 0 && mark < 1 {
            let x = rect.minX + rect.width * CGFloat(mark)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return path
    }

    /// The horizontal gridlines and the time marks as one path, so the grid is one
    /// stroke and one layer rather than two of each.
    func gridPath(divisions: Int = 4, marks: [Double]) -> Path {
        var path = ChartPlot.gridPath(in: rect, divisions: divisions)
        path.addPath(timeGridPath(marks: marks))
        return path
    }

}

/// Labels for the time axis under a history plot.
enum HistoryAxis {
    /// Where the four labels sit, as fractions of the window.
    static let marks: [Double] = [0, 1.0 / 3.0, 2.0 / 3.0, 1]

    /// Four labels for a window of `span` seconds ending at `end`.
    ///
    /// A day is labelled in clock time, because "what was that at 3am" is the
    /// question a day answers. Anything shorter is labelled as time before now,
    /// because the clock time of a sample four minutes ago is not what anyone is
    /// asking. Thirds rather than quarters: four labels over 300 points is what fits,
    /// and thirds of the shipped spans are all whole seconds.
    static func labels(span: TimeInterval, end: Date) -> [String] {
        marks.map { mark in
            if mark >= 1 { return "now" }
            if span >= 7_200 {
                return clock(end.addingTimeInterval(-span * (1 - mark)))
            }
            return relative(-span * (1 - mark))
        }
    }

    static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened))
    }

    /// "-5m", "-3:20", "-40s": how long before now a point on the axis is.
    static func relative(_ offset: TimeInterval) -> String {
        let seconds = Int((-offset).rounded())
        guard seconds > 0 else { return "now" }
        if seconds < 60 { return "-\(seconds)s" }
        let minutes = seconds / 60
        let rest = seconds % 60
        if rest == 0 {
            return minutes % 60 == 0 ? "-\(minutes / 60)h" : "-\(minutes)m"
        }
        return String(format: "-%d:%02d", minutes, rest)
    }
}
