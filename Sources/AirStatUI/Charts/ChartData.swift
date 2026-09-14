import SwiftUI
import AirStatKit

/// One pass over a `SampleRing`, producing everything a chart needs to know about it.
///
/// `SampleRing` already exposes `maximum`, `minimum` and `average`, but each is a
/// separate O(n) walk and `values` allocates. Charts need all four figures plus the
/// latest sample on every redraw, so they are gathered together here — once per
/// series per update, never per point and never per frame.
public struct ChartStats: Equatable, Sendable {
    public let count: Int
    public let minimum: Double
    public let maximum: Double
    public let average: Double
    public let last: Double?

    public init(_ ring: SampleRing) {
        let n = ring.count
        count = n
        guard n > 0 else {
            minimum = 0; maximum = 0; average = 0; last = nil
            return
        }
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        var sum = 0.0
        var newest: Float = 0
        // Two contiguous runs rather than `ring[i]`: the subscript pays a bounds
        // precondition, a wrap branch and an integer modulo per element, which for a
        // full ring costs more than the whole walk. The runs are visited oldest run
        // first, so the samples arrive in exactly the order the subscript gave them
        // and the sum accumulates identically.
        //
        // `min`/`max` rather than `if v < lo { lo = v }`, and in `Float` rather than
        // widening first: a compare-and-assign branch stops the loop vectorising, and
        // an optimised build then loses to three separate reductions over the same
        // runs. Neither the result nor the accumulation order changes: widening `Float`
        // to `Double` is exact, so comparing before widening picks the same samples, and
        // the sum is still accumulated in `Double`.
        //
        // One reduction per loop, not all three fused into one. Fusing them is the
        // obvious reading of "single pass" and it is slower: `min` and `max` over
        // `Float` vectorise, a `Double` running sum cannot — Swift will not reassociate
        // floating-point addition — and interleaving the two puts a per-element convert
        // and a serial add in the middle of the loop that would otherwise have gone wide.
        // Measured in release, the fused form took 6.0 µs against 3.3 µs for three
        // separate walks, which is the one-pass premise of this type inverting itself;
        // split like this it is 3.21 µs against 3.17 µs. So this is not faster than
        // calling the ring's own three reductions and was never going to be — it is the
        // same three walks. What it is worth having for is the single `withUnsafeRuns`,
        // one wrap decision, and one call site that cannot read a ring three different
        // ways by accident.
        ring.withUnsafeRuns { older, newer in
            for value in older { lo = Swift.min(lo, value) }
            for value in newer { lo = Swift.min(lo, value) }
            for value in older { hi = Swift.max(hi, value) }
            for value in newer { hi = Swift.max(hi, value) }
            for value in older { sum += Double(value) }
            for value in newer { sum += Double(value) }
            newest = newer.last ?? older[older.count - 1]
        }
        minimum = Double(lo)
        maximum = Double(hi)
        average = sum / Double(n)
        last = Double(newest)
    }

    /// Enough samples to justify drawing a trend at all.
    public var supportsTrend: Bool { count >= Design.Chart.minimumPoints }
    public var isEmpty: Bool { count == 0 }
}

// MARK: - Value formatting

/// How a series' numbers become strings.
///
/// Charts never format anything themselves; every case here routes into
/// `MetricFormatter` so a peak label on an axis and the readout row beside it can
/// never disagree about units. Note `memoryBytes` and `storageBytes` are distinct
/// because RAM is base-1024 and storage is base-1000.
public enum ChartValueFormat: Equatable, Sendable {
    /// Samples stored as 0...1.
    case fraction
    /// Samples stored as 0...100.
    case percentValue
    case networkRate
    case diskRate
    case memoryBytes
    case storageBytes
    case temperature
    case watts
    case rpm
    case decimal(places: Int)

    public func string(_ value: Double, using formatter: MetricFormatter) -> String {
        switch self {
        case .fraction: return formatter.percent(value)
        case .percentValue: return formatter.percentValue(value)
        case .networkRate: return formatter.networkRate(value)
        case .diskRate: return formatter.diskRate(value)
        case .memoryBytes: return formatter.memory(value)
        case .storageBytes: return formatter.storage(value)
        case .temperature: return formatter.temperature(value)
        case .watts: return formatter.watts(value)
        case .rpm: return formatter.rpm(value)
        case .decimal(let places): return formatter.fixed(value, decimals: places)
        }
    }

    public static func standard(for key: SeriesKey) -> ChartValueFormat {
        switch key {
        case .cpuTotal, .cpuUser, .cpuSystem, .cpuPerformance, .cpuEfficiency,
             .memoryUsed, .memoryPressure, .gpuUtilization, .gpuVRAM, .diskUsed:
            return .fraction
        case .memorySwap: return .memoryBytes
        case .networkUpload, .networkDownload: return .networkRate
        case .diskRead, .diskWrite: return .diskRate
        case .batteryPercent: return .percentValue
        case .batteryWatts, .systemWatts: return .watts
        case .cpuTemperature, .gpuTemperature: return .temperature
        case .fanRPM: return .rpm
        }
    }
}

// MARK: - Series

/// A drawable time series: the samples, how to colour them, how to label them, and
/// how much wall-clock time they cover.
///
/// Holds the `SampleRing` itself rather than an array. The ring is a struct over
/// copy-on-write storage, so passing one costs a retain, while `ring.values` would
/// allocate a fresh array for every series on every redraw.
public struct ChartSeries: Equatable {
    public let key: SeriesKey
    public let samples: SampleRing
    public let tint: Color
    /// Seconds of wall clock the samples cover, for the time-window caption.
    public let span: TimeInterval
    public let format: ChartValueFormat
    public let stats: ChartStats
    /// Overrides `key.label` when a module wants shorter wording in context.
    public let label: String
    /// A fixed band to plot against, replacing both the natural and the derived scale.
    ///
    /// The escape hatch for series that live in a narrow band well above zero —
    /// temperature being the case that forces it. 44–58 °C against a 0-baseline is a
    /// flat line 85 % up the box that says nothing at sparkline size.
    ///
    /// This is not the truncated-axis lie, because the band is *fixed and stated*: it
    /// is chosen once by the module, does not move with the data, and both ends are
    /// labelled. The dishonest version is a baseline that slides to flatter whatever
    /// the samples happen to be doing, and that remains impossible here.
    public let domain: ClosedRange<Double>?

    public init(key: SeriesKey,
                samples: SampleRing,
                tint: Color,
                span: TimeInterval,
                format: ChartValueFormat? = nil,
                label: String? = nil,
                domain: ClosedRange<Double>? = nil) {
        self.key = key
        self.samples = samples
        self.tint = tint
        self.span = span
        self.format = format ?? .standard(for: key)
        self.label = label ?? key.label
        self.domain = domain
        self.stats = ChartStats(samples)
    }

    /// The common case: pull a series straight out of retained history.
    public init(_ key: SeriesKey,
                from history: MetricHistory,
                tint: Color,
                format: ChartValueFormat? = nil,
                label: String? = nil,
                domain: ClosedRange<Double>? = nil) {
        self.init(key: key,
                  samples: history[key],
                  tint: tint,
                  span: history.span(of: key),
                  format: format,
                  label: label,
                  domain: domain)
    }

    public func string(_ value: Double, using formatter: MetricFormatter) -> String {
        format.string(value, using: formatter)
    }

    /// The series' upper bound when one genuinely exists.
    ///
    /// `SeriesKey.isNormalized` covers the 0...1 metrics; battery is the one series
    /// stored as 0...100 that still has a real ceiling. Everything else — rates,
    /// temperatures, wattage, fan speed — has no maximum this app can know, which is
    /// what forces those charts onto a data-derived scale.
    public var naturalUpperBound: Double? { key.naturalUpperBound }
}

// MARK: - Scale

/// The vertical domain a chart draws against.
///
/// A *derived* baseline is always zero. Letting the bottom of an axis follow the data
/// is the fastest way to turn a 2 °C wobble into a dramatic cliff, so no scale AirStat
/// computes for itself ever does it — a series that looks flat near the bottom of its
/// plot *is* flat. The only way to lift a baseline is `ChartSeries.domain`, which is a
/// band the module states up front and both ends of which get labelled.
public struct ChartScale: Equatable, Sendable {
    public let lowerBound: Double
    public let upperBound: Double
    /// True when the bound came from the data rather than from a real maximum. A
    /// chart drawn against a derived bound is meaningless without its peak label:
    /// 2 KB/s and 100 MB/s produce the identical picture.
    public let isDerived: Bool
    /// True when a caller supplied the band explicitly, so charts know to label the
    /// floor as well as the ceiling.
    public let isExplicit: Bool
    /// The largest sample in the window, whatever the bound was rounded up to.
    public let peak: Double

    public init(lowerBound: Double = 0, upperBound: Double,
                isDerived: Bool, isExplicit: Bool = false, peak: Double) {
        self.lowerBound = lowerBound
        self.upperBound = max(upperBound, lowerBound + .leastNormalMagnitude)
        self.isDerived = isDerived
        self.isExplicit = isExplicit
        self.peak = peak
    }

    public var span: Double { upperBound - lowerBound }

    /// Resolve a domain shared by every series drawn together.
    ///
    /// Normalised series stay pinned to 0...1 even when adaptive scaling is on. Letting
    /// CPU stretch to its window peak would draw an idle machine's 3 % as a full-height
    /// mountain — the single most dishonest thing a system monitor can do, and the
    /// reason adaptive scaling is reserved for series that have no ceiling to scale to.
    public static func resolve(_ series: [ChartSeries], adaptive: Bool) -> ChartScale {
        resolve(peak: series.reduce(0.0) { max($0, $1.stats.maximum) },
                domain: series.compactMap(\.domain).first,
                naturalUpperBound: series.compactMap(\.naturalUpperBound).max(),
                adaptive: adaptive)
    }

    /// The same resolution from the three facts it actually depends on, for a chart
    /// whose peak comes from somewhere other than a `SampleRing`.
    public static func resolve(peak: Double, domain: ClosedRange<Double>?,
                               naturalUpperBound: Double?, adaptive: Bool) -> ChartScale {
        // An explicit band wins outright: the module has already decided what this
        // metric's meaningful range is, and no amount of data should move it.
        if let stated = domain {
            return ChartScale(lowerBound: stated.lowerBound, upperBound: stated.upperBound,
                              isDerived: false, isExplicit: true, peak: peak)
        }
        if let natural = naturalUpperBound {
            return ChartScale(upperBound: natural, isDerived: false, peak: peak)
        }
        // An idle rate chart still needs a non-zero domain to divide by; the peak label
        // reports the honest 0, so the flat line at the baseline is not a lie.
        guard peak > 0 else { return ChartScale(upperBound: 1, isDerived: true, peak: 0) }
        // Adaptive fits the window snugly; fixed quantises to whole decades so the
        // plot's height stays comparable from one glance to the next, at the cost of
        // headroom. Both label the peak, because both bounds came from the data.
        let bound = adaptive ? Self.niceCeiling(peak) : Self.decadeCeiling(peak)
        return ChartScale(upperBound: bound, isDerived: true, peak: peak)
    }

    /// Round up to 1, 2, 2.5 or 5 times a power of ten, so the axis label is a number a
    /// person recognises and stops twitching every time the peak moves by a byte.
    static func niceCeiling(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let exponent = floor(log10(value))
        let decade = pow(10, exponent)
        let normalized = value / decade
        for step in [1.0, 2.0, 2.5, 5.0, 10.0] where normalized <= step {
            return step * decade
        }
        return 10 * decade
    }

    static func decadeCeiling(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        return pow(10, ceil(log10(value)))
    }
}

// MARK: - Palette

public enum ChartPalette {

    /// Shades of one metric's identity colour, for the consumption segments of a
    /// composition bar.
    ///
    /// A ramp rather than five unrelated hues: memory's breakdown is five parts of one
    /// thing, and giving each part its own colour would claim a significance they do
    /// not have. The legend carries the mapping; the bar only has to show proportion.
    public static func composition(_ tint: Color, count: Int) -> [Color] {
        guard count > 1 else { return count == 1 ? [tint] : [] }
        return (0..<count).map { index in
            tint.opacity(1 - 0.72 * Double(index) / Double(count - 1))
        }
    }
}

// MARK: - Captions

public enum ChartCaption {

    /// "last 5 min" — the context without which a chart is decoration rather than data.
    public static func window(_ span: TimeInterval) -> String {
        guard span > 0 else { return "no history" }
        if span < 90 { return "last \(Int(span.rounded()))s" }
        if span < 5_400 { return "last \(Int((span / 60).rounded())) min" }
        let hours = span / 3_600
        return "last \(hours < 9.95 ? String(format: "%.1f", hours) : String(Int(hours.rounded())))h"
    }

    /// The spoken form of a chart: everything the picture conveys, in one sentence.
    public static func accessibilitySummary(_ series: [ChartSeries],
                                            scale: ChartScale,
                                            formatter: MetricFormatter) -> String {
        guard let first = series.first else { return "No data" }
        guard !first.stats.isEmpty else {
            return "No history yet, \(ChartCaption.window(first.span))"
        }
        var parts: [String] = []
        for s in series {
            let stats = s.stats
            let current = stats.last.map { s.string($0, using: formatter) } ?? MetricFormatter.unavailable
            var sentence = "\(s.label): now \(current)"
            if stats.supportsTrend {
                sentence += ", average \(s.string(stats.average, using: formatter))"
                sentence += ", range \(s.string(stats.minimum, using: formatter))"
                sentence += " to \(s.string(stats.maximum, using: formatter))"
            }
            parts.append(sentence)
        }
        var summary = parts.joined(separator: ". ")
        summary += ". Over \(ChartCaption.window(first.span))"
        if scale.isDerived {
            summary += ", scaled to a peak of \(first.string(scale.peak, using: formatter))"
        } else if scale.isExplicit, scale.lowerBound != 0 {
            summary += ", plotted from \(first.string(scale.lowerBound, using: formatter))"
                + " to \(first.string(scale.upperBound, using: formatter))"
        }
        if !first.stats.supportsTrend {
            summary += ". Too few samples to show a trend"
        }
        return summary + "."
    }
}
