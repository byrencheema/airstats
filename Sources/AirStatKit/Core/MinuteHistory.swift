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
    /// The process at the top of the list in minutes that earned a look, one per
    /// kind per bucket. Only the sample that was highest in the minute keeps its
    /// name, so a bucket's note is the process behind its high, not its last.
    private var notes: [MinuteNote?]
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
        notes = [MinuteNote?](repeating: nil, count: NoteKind.allCases.count * cap)
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

    /// Names the process behind the newest bucket's high for `kind`, where `value`
    /// is the machine-wide reading the process list was taken at. A later, higher
    /// sample in the same minute replaces the name; a lower one leaves it.
    public mutating func note(_ kind: NoteKind, name: String, value: Double) {
        guard let newest = newestMinute, !name.isEmpty else { return }
        let sample = Float(value)
        guard sample.isFinite else { return }
        let cell = kind.rawValue * capacity + slot(of: newest)
        if let existing = notes[cell], existing.value >= sample { return }
        notes[cell] = MinuteNote(name: name, value: sample)
    }

    /// The note for `kind` in the bucket holding `date`, if that minute earned one.
    public func note(_ kind: NoteKind, at date: Date) -> MinuteNote? {
        guard let newest = newestMinute else { return nil }
        let minute = Self.minute(of: date)
        guard minute <= newest, minute > newest - capacity else { return nil }
        return notes[kind.rawValue * capacity + slot(of: minute)]
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
        var named: [Int: String] = [:]
        let kind = NoteKind(explaining: key)
        let oldest = newest - capacity + 1
        for (position, minute) in (oldest...newest).enumerated() {
            let slot = slot(of: minute)
            let cell = index(of: key, slot: slot)
            let count = counts[cell]
            guard count > 0 else { continue }
            samples[position] = count
            lows[position] = minima[cell]
            highs[position] = maxima[cell]
            means[position] = sums[cell] / Float(count)
            if let kind, let note = notes[kind.rawValue * capacity + slot] {
                named[position] = note.name
            }
        }
        return MinuteSeries(key: key, minima: lows, averages: means, maxima: highs,
                            counts: samples, notes: named,
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
        for kind in NoteKind.allCases { notes[kind.rawValue * capacity + slot] = nil }
    }

    private mutating func clearAll() {
        for cell in minima.indices {
            minima[cell] = .greatestFiniteMagnitude
            maxima[cell] = -.greatestFiniteMagnitude
            sums[cell] = 0
            counts[cell] = 0
        }
        for cell in notes.indices { notes[cell] = nil }
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
        case .batteryPlugged: return 21
        }
    }
}

/// Which process list a minute's note came from.
public enum NoteKind: Int, CaseIterable, Sendable {
    case cpu, memory

    /// The kind that explains a series' peaks, for the two series that have one.
    public init?(explaining key: SeriesKey) {
        switch key {
        case .cpuTotal: self = .cpu
        case .memoryUsed: self = .memory
        default: return nil
        }
    }
}

/// The process behind one minute's high, and the machine-wide reading it was seen at.
public struct MinuteNote: Sendable, Equatable {
    public let name: String
    public let value: Float

    public init(name: String, value: Float) {
        self.name = name
        self.value = value
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
    /// The process behind the high of the buckets that were looked at, by position.
    public let notes: [Int: String]
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
                counts: [UInt16], notes: [Int: String] = [:], end: Date) {
        precondition(minima.count == counts.count && averages.count == counts.count
                     && maxima.count == counts.count, "MinuteSeries arrays disagree")
        self.key = key
        self.minima = minima
        self.averages = averages
        self.maxima = maxima
        self.counts = counts
        self.notes = notes
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

extension MinuteHistory {
    /// The file format: a fixed header, the four arrays in declaration order, then
    /// the notes as a count and a run of (cell, value, length, UTF-8) entries, all
    /// little-endian. About 350 KB at the default capacity plus a few bytes per
    /// note. Read back only when every field of the header matches what this build
    /// would write, so a file from a different capacity or series set is treated as
    /// absent, never as data.
    private static let magic: UInt32 = 0x4149_5248
    private static let formatVersion: UInt32 = 2
    /// Bytes of name a note keeps on disk. Longer names are cut, not refused: a
    /// process name is a label, and 48 bytes of it identifies the process.
    private static let noteNameLimit = 48

    public func encoded() -> Data {
        var data = Data()
        data.reserveCapacity(32 + minima.count * 14)
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        append(Self.magic.littleEndian)
        append(Self.formatVersion.littleEndian)
        append(UInt32(capacity).littleEndian)
        append(UInt32(Self.seriesCount).littleEndian)
        append(Int64(newestMinute ?? -1).littleEndian)
        minima.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        maxima.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        sums.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        counts.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        let kept = notes.indices.filter { notes[$0] != nil }
        append(UInt32(kept.count).littleEndian)
        for cell in kept {
            let note = notes[cell]!
            let name = Data(note.name.utf8.prefix(Self.noteNameLimit))
            append(UInt32(cell).littleEndian)
            append(note.value.bitPattern.littleEndian)
            append(UInt8(name.count))
            data.append(name)
        }
        return data
    }

    /// Nil for anything that is not exactly a file this build wrote.
    public init?(encoded data: Data, capacity expected: Int = MinuteHistory.defaultCapacity) {
        var offset = 0
        func read<T: FixedWidthInteger>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            var value: T = 0
            _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset..<(offset + size)) }
            offset += size
            return T(littleEndian: value)
        }
        guard read(UInt32.self) == Self.magic,
              read(UInt32.self) == Self.formatVersion,
              let capacity = read(UInt32.self).map(Int.init), capacity == expected,
              let series = read(UInt32.self).map(Int.init), series == Self.seriesCount,
              let newest = read(Int64.self) else { return nil }
        let cells = series * capacity
        let floats = cells * MemoryLayout<Float>.size
        let shorts = cells * MemoryLayout<UInt16>.size
        guard data.count >= offset + floats * 3 + shorts + 4 else { return nil }
        func floatArray() -> [Float] {
            defer { offset += floats }
            return data[offset..<(offset + floats)].withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        self.capacity = capacity
        minima = floatArray()
        maxima = floatArray()
        sums = floatArray()
        counts = data[offset..<(offset + shorts)].withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        offset += shorts
        let noteCells = NoteKind.allCases.count * capacity
        var restored = [MinuteNote?](repeating: nil, count: noteCells)
        guard let noteCount = read(UInt32.self) else { return nil }
        for _ in 0..<Int(noteCount) {
            guard let cell = read(UInt32.self).map(Int.init), cell < noteCells,
                  let bits = read(UInt32.self), let length = read(UInt8.self),
                  offset + Int(length) <= data.count,
                  let name = String(data: data[offset..<(offset + Int(length))], encoding: .utf8)
            else { return nil }
            offset += Int(length)
            restored[cell] = MinuteNote(name: name, value: Float(bitPattern: bits))
        }
        guard offset == data.count else { return nil }
        notes = restored
        newestMinute = newest >= 0 ? Int(newest) : nil
    }


    /// Seconds between the oldest sampled bucket of one series and the end of the
    /// window, without allocating the series.
    public func collectedSpan(of key: SeriesKey) -> TimeInterval {
        guard let newest = newestMinute else { return 0 }
        let oldest = newest - capacity + 1
        for (position, minute) in (oldest...newest).enumerated()
        where counts[index(of: key, slot: slot(of: minute))] > 0 {
            return Double(capacity - position) * Self.bucketDuration
        }
        return 0
    }
}

/// Where the day lives between launches.
///
/// Written at quit, on the way into sleep, and once an hour, so a relaunch or an
/// update opens on the day it had rather than on an empty axis. Restoring is safe
/// because buckets are anchored to wall-clock minutes: the first sample after
/// launch advances the tier and the time the app was not running becomes the gap
/// it was.
public struct MinuteHistoryFile: Sendable {
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("history.bin")
    }

    public func save(_ history: MinuteHistory) {
        try? history.encoded().write(to: url, options: .atomic)
    }

    public func load(capacity: Int = MinuteHistory.defaultCapacity) -> MinuteHistory? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return MinuteHistory(encoded: data, capacity: capacity)
    }
}
