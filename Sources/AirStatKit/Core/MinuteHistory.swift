import Foundation

/// A day of every series, one minute at a time.
///
/// The raw ring keeps every sample for the "Keep history for" span and is cleared on
/// wake, because a rate that spans a sleep is meaningless. This tier keeps the last
/// 24 hours as one bucket per minute, each holding the minimum, the sum and the
/// maximum of the samples that fell in it, and it is never cleared: a minute with no
/// samples is a gap, and a gap is a fact about the day worth drawing.
///
/// Storage is flat and index-addressed rather than a dictionary keyed by `SeriesKey`.
/// The fold runs 21 times per sample for the life of the process, and hashing a
/// string-backed key each time measured at about forty times the cost of an array
/// index. Buckets are anchored to absolute minutes, so a chart drawn from this slides
/// one column per minute instead of shimmering as samples land, and a gap falls out
/// of the arithmetic: minutes that pass with no sample are emptied as the newest
/// bucket moves over them.
///
/// About 420 KB at the default capacity, allocated once.
public struct MinuteHistory: Sendable, Equatable {
    public static let bucketDuration: TimeInterval = 60
    /// 24 hours.
    public static let defaultCapacity = 1440

    public let capacity: Int
    private var minima: [Float]
    private var maxima: [Float]
    private var sums: [Float]
    private var counts: [UInt16]
    /// Whole minutes since 1970 of the newest bucket, nil until the first sample.
    public private(set) var newestMinute: Int?

    private static let seriesCount = SeriesKey.allCases.count

    public init(capacity: Int = MinuteHistory.defaultCapacity) {
        let cap = max(2, capacity)
        self.capacity = cap
        let cells = Self.seriesCount * cap
        minima = [Float](repeating: .greatestFiniteMagnitude, count: cells)
        maxima = [Float](repeating: -.greatestFiniteMagnitude, count: cells)
        sums = [Float](repeating: 0, count: cells)
        counts = [UInt16](repeating: 0, count: cells)
    }

    public static func minute(of date: Date) -> Int {
        Int((date.timeIntervalSince1970 / bucketDuration).rounded(.down))
    }

    public static func date(ofMinute minute: Int) -> Date {
        Date(timeIntervalSince1970: Double(minute) * bucketDuration)
    }

    /// Moves the newest bucket to the minute containing `date`, emptying every bucket
    /// between there and the previous newest.
    ///
    /// Called once per snapshot, before any series is recorded: 21 series cross a
    /// minute boundary at the same instant, and asking each of them would pay the
    /// comparison 21 times. A jump of a day or more empties the whole tier. A clock
    /// that goes backwards keeps writing into the newest bucket rather than into the
    /// past, so an NTP correction cannot resurrect a minute the chart has already
    /// drawn.
    public mutating func advance(to date: Date) {
        let minute = Self.minute(of: date)
        guard let newest = newestMinute else {
            newestMinute = minute
            return
        }
        guard minute > newest else { return }
        if minute - newest >= capacity {
            clearAll()
        } else {
            for passed in (newest + 1)...minute { clear(slot: slot(of: passed)) }
        }
        newestMinute = minute
    }

    /// Folds one sample into the newest bucket. Non-finite values are dropped rather
    /// than coerced, so they cannot pull a minimum to zero.
    public mutating func record(_ key: SeriesKey, _ value: Double) {
        guard let newest = newestMinute else { return }
        let sample = Float(value)
        guard sample.isFinite else { return }
        let cell = index(of: key, slot: slot(of: newest))
        minima[cell] = Swift.min(minima[cell], sample)
        maxima[cell] = Swift.max(maxima[cell], sample)
        sums[cell] += sample
        if counts[cell] < .max { counts[cell] += 1 }
    }

    /// The last `capacity` minutes of one series, oldest first, ending at the newest
    /// bucket. Allocates four arrays; call once per render, not per point.
    public func series(_ key: SeriesKey) -> MinuteSeries {
        guard let newest = newestMinute else {
            return MinuteSeries(key: key, capacity: capacity, end: Date())
        }
        var lows = [Float](repeating: 0, count: capacity)
        var means = [Float](repeating: 0, count: capacity)
        var highs = [Float](repeating: 0, count: capacity)
        var samples = [UInt16](repeating: 0, count: capacity)
        let oldest = newest - capacity + 1
        for (position, minute) in (oldest...newest).enumerated() {
            let cell = index(of: key, slot: slot(of: minute))
            let count = counts[cell]
            guard count > 0 else { continue }
            samples[position] = count
            lows[position] = minima[cell]
            highs[position] = maxima[cell]
            means[position] = sums[cell] / Float(count)
        }
        return MinuteSeries(key: key, minima: lows, averages: means, maxima: highs,
                            counts: samples,
                            end: Self.date(ofMinute: newest + 1))
    }

    /// True when any series has a sample in any bucket.
    public var isEmpty: Bool { !counts.contains { $0 > 0 } }

    private func slot(of minute: Int) -> Int {
        let wrapped = minute % capacity
        return wrapped < 0 ? wrapped + capacity : wrapped
    }

    private func index(of key: SeriesKey, slot: Int) -> Int {
        key.index * capacity + slot
    }

    private mutating func clear(slot: Int) {
        for series in 0..<Self.seriesCount {
            let cell = series * capacity + slot
            minima[cell] = .greatestFiniteMagnitude
            maxima[cell] = -.greatestFiniteMagnitude
            sums[cell] = 0
            counts[cell] = 0
        }
    }

    private mutating func clearAll() {
        for cell in minima.indices {
            minima[cell] = .greatestFiniteMagnitude
            maxima[cell] = -.greatestFiniteMagnitude
            sums[cell] = 0
            counts[cell] = 0
        }
    }
}

extension SeriesKey {
    /// Position in `allCases`, the index the minute tier is addressed by.
    var index: Int {
        switch self {
        case .cpuTotal: return 0
        case .cpuUser: return 1
        case .cpuSystem: return 2
        case .cpuPerformance: return 3
        case .cpuEfficiency: return 4
        case .memoryUsed: return 5
        case .memoryPressure: return 6
        case .memorySwap: return 7
        case .gpuUtilization: return 8
        case .gpuVRAM: return 9
        case .networkUpload: return 10
        case .networkDownload: return 11
        case .diskRead: return 12
        case .diskWrite: return 13
        case .diskUsed: return 14
        case .batteryPercent: return 15
        case .batteryWatts: return 16
        case .systemWatts: return 17
        case .cpuTemperature: return 18
        case .gpuTemperature: return 19
        case .fanRPM: return 20
        }
    }
}

/// One series' day, as a chart draws it: parallel arrays, oldest bucket first.
///
/// A value handed out by `MinuteHistory.series(_:)` rather than a view into it, so a
/// chart holding one cannot force the tier to copy 420 KB on the next fold. Buckets
/// with a zero count were never sampled and carry no value; every reader has to treat
/// them as a gap, not as zero.
public struct MinuteSeries: Sendable, Equatable {
    public let key: SeriesKey
    public let minima: [Float]
    public let averages: [Float]
    public let maxima: [Float]
    public let counts: [UInt16]
    /// End of the newest bucket.
    public let end: Date
    public let bucketDuration: TimeInterval = MinuteHistory.bucketDuration

    /// Extremes and the count-weighted mean over every sampled bucket.
    public let minimum: Double
    public let maximum: Double
    public let average: Double
    /// Buckets that hold at least one sample.
    public let sampledCount: Int
    /// The bucket holding the newest sample, or nil when nothing was sampled.
    public let newestSampled: Int?
    /// Value of the newest sampled bucket's mean.
    public let last: Double?

    public init(key: SeriesKey, minima: [Float], averages: [Float], maxima: [Float],
                counts: [UInt16], end: Date) {
        precondition(minima.count == counts.count && averages.count == counts.count
                     && maxima.count == counts.count, "MinuteSeries arrays disagree")
        self.key = key
        self.minima = minima
        self.averages = averages
        self.maxima = maxima
        self.counts = counts
        self.end = end
        var lo = Float.greatestFiniteMagnitude
        var hi = -Float.greatestFiniteMagnitude
        var sum = 0.0
        var weight = 0
        var sampled = 0
        var newest: Int?
        for index in counts.indices where counts[index] > 0 {
            let count = Int(counts[index])
            lo = Swift.min(lo, minima[index])
            hi = Swift.max(hi, maxima[index])
            sum += Double(averages[index]) * Double(count)
            weight += count
            sampled += 1
            newest = index
        }
        sampledCount = sampled
        newestSampled = newest
        minimum = sampled > 0 ? Double(lo) : 0
        maximum = sampled > 0 ? Double(hi) : 0
        average = weight > 0 ? sum / Double(weight) : 0
        last = newest.map { Double(averages[$0]) }
    }

    /// An unsampled day of `capacity` buckets.
    public init(key: SeriesKey, capacity: Int, end: Date) {
        self.init(key: key,
                  minima: [Float](repeating: 0, count: capacity),
                  averages: [Float](repeating: 0, count: capacity),
                  maxima: [Float](repeating: 0, count: capacity),
                  counts: [UInt16](repeating: 0, count: capacity),
                  end: end)
    }

    public var count: Int { counts.count }
    public var isEmpty: Bool { sampledCount == 0 }
    /// Wall clock the whole window covers, sampled or not.
    public var span: TimeInterval { Double(count) * bucketDuration }
    public var start: Date { end.addingTimeInterval(-span) }

    /// Start of the bucket at `index`.
    public func date(at index: Int) -> Date {
        start.addingTimeInterval(Double(index) * bucketDuration)
    }

    /// Wall clock between the oldest sampled bucket and the end of the window: how
    /// much of the day has actually been collected.
    public var collectedSpan: TimeInterval {
        guard let first = counts.firstIndex(where: { $0 > 0 }) else { return 0 }
        return Double(count - first) * bucketDuration
    }
}
