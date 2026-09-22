import Foundation

/// Fixed-capacity ring buffer of `Float` samples.
///
/// `Float` rather than `Double` halves the memory and is far more precision than a
/// 200-pixel sparkline can resolve. Storage is allocated once at init and never
/// grows, so a session running for weeks has exactly the same footprint as one
/// running for a minute.
public struct SampleRing: Sendable, Equatable {
    private var storage: [Float]
    private var head: Int = 0
    public private(set) var count: Int = 0
    public let capacity: Int

    public init(capacity: Int) {
        let cap = max(1, capacity)
        self.capacity = cap
        self.storage = [Float](repeating: 0, count: cap)
    }

    public mutating func append(_ value: Float) {
        storage[head] = value.isFinite ? value : 0
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    public mutating func append(_ value: Double) { append(Float(value)) }

    /// Oldest-to-newest ordered samples. Allocates; call once per render, not per point.
    public var values: [Float] {
        guard count > 0 else { return [] }
        return withUnsafeRuns { older, newer in
            // One allocation and two memcpys. Appending the runs into a reserved array
            // instead costs about twice this, because each append re-checks capacity.
            Array(unsafeUninitializedCapacity: older.count + newer.count) { out, initialized in
                guard let destination = out.baseAddress else { return }
                if let source = older.baseAddress {
                    destination.initialize(from: source, count: older.count)
                }
                if let source = newer.baseAddress {
                    (destination + older.count).initialize(from: source, count: newer.count)
                }
                initialized = older.count + newer.count
            }
        }
    }

    /// The samples oldest-to-newest, as the one or two contiguous runs they occupy.
    ///
    /// This replaces a `withValues` that handed out a single buffer and guarded on
    /// `count < capacity`, which is false exactly when the ring is full: the steady
    /// state after the first hour of uptime, and the only state where avoiding the
    /// allocation is worth anything. The guard was not a bug, it was the honest
    /// consequence of promising one contiguous buffer for samples that wrap. Two runs
    /// is the shape a full ring can actually be walked in, so it is the shape the API
    /// takes: `older` runs from `head` to the end of storage, `newer` from the start
    /// of storage up to `head`, and concatenating them gives oldest-to-newest. Either
    /// may be empty; both are when the ring is.
    ///
    /// Walking these instead of `subscript` is what makes aggregates cheap: no bounds
    /// precondition, no wrap branch and no integer modulo per element.
    public func withUnsafeRuns<R>(
        _ body: (UnsafeBufferPointer<Float>, UnsafeBufferPointer<Float>) -> R
    ) -> R {
        storage.withUnsafeBufferPointer { buffer in
            let empty = UnsafeBufferPointer(rebasing: buffer[0..<0])
            guard count > 0 else { return body(empty, empty) }
            guard count == capacity else {
                // Never wrapped: the samples sit in order at the front of storage.
                return body(UnsafeBufferPointer(rebasing: buffer[0..<count]), empty)
            }
            return body(UnsafeBufferPointer(rebasing: buffer[head..<capacity]),
                        UnsafeBufferPointer(rebasing: buffer[0..<head]))
        }
    }

    public subscript(index: Int) -> Float {
        precondition(index >= 0 && index < count, "SampleRing index out of range")
        // A compare and a subtract rather than a modulo: `start + index` is under
        // `2 * capacity`, so at most one wrap can ever be needed.
        var slot = (count < capacity ? 0 : head) + index
        if slot >= capacity { slot -= capacity }
        return storage[slot]
    }

    public var last: Float? { count > 0 ? self[count - 1] : nil }

    public var maximum: Float {
        guard count > 0 else { return 0 }
        return withUnsafeRuns { older, newer in
            var m: Float = -.greatestFiniteMagnitude
            for v in older { m = Swift.max(m, v) }
            for v in newer { m = Swift.max(m, v) }
            return m
        }
    }

    public var minimum: Float {
        guard count > 0 else { return 0 }
        return withUnsafeRuns { older, newer in
            var m: Float = .greatestFiniteMagnitude
            for v in older { m = Swift.min(m, v) }
            for v in newer { m = Swift.min(m, v) }
            return m
        }
    }

    public var average: Float {
        guard count > 0 else { return 0 }
        return withUnsafeRuns { older, newer in
            var sum: Float = 0
            for v in older { sum += v }
            for v in newer { sum += v }
            return sum / Float(count)
        }
    }

    public mutating func removeAll() {
        head = 0
        count = 0
    }

    /// Resize preserving the most recent samples.
    public mutating func resized(to newCapacity: Int) -> SampleRing {
        var ring = SampleRing(capacity: newCapacity)
        let keep = Swift.min(count, ring.capacity)
        guard keep > 0 else { return ring }
        // The oldest `count - keep` samples are dropped, which may fall entirely in
        // the first run, or consume it and reach into the second.
        var drop = count - keep
        withUnsafeRuns { older, newer in
            let olderStart = Swift.min(drop, older.count)
            drop -= olderStart
            for i in olderStart..<older.count { ring.append(older[i]) }
            let newerStart = Swift.min(drop, newer.count)
            for i in newerStart..<newer.count { ring.append(newer[i]) }
        }
        return ring
    }
}

/// The named time series AirStat retains for charting.
public enum SeriesKey: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case cpuTotal, cpuUser, cpuSystem, cpuPerformance, cpuEfficiency
    case memoryUsed, memoryPressure, memorySwap
    case gpuUtilization, gpuVRAM
    case networkUpload, networkDownload
    case diskRead, diskWrite, diskUsed
    case batteryPercent, batteryWatts, systemWatts
    case cpuTemperature, gpuTemperature, fanRPM
    /// 1 while the Mac is on external power, 0 on battery. Recorded so a day of
    /// charge can say where the charger went in and came out.
    case batteryPlugged

    public var label: String {
        switch self {
        case .cpuTotal: return "CPU"
        case .cpuUser: return "User"
        case .cpuSystem: return "System"
        case .cpuPerformance: return "P-Cores"
        case .cpuEfficiency: return "E-Cores"
        case .memoryUsed: return "Memory Used"
        case .memoryPressure: return "Memory Pressure"
        case .memorySwap: return "Swap"
        case .gpuUtilization: return "GPU"
        case .gpuVRAM: return "VRAM"
        case .networkUpload: return "Upload"
        case .networkDownload: return "Download"
        case .diskRead: return "Read"
        case .diskWrite: return "Write"
        case .diskUsed: return "Disk Used"
        case .batteryPercent: return "Battery"
        case .batteryWatts: return "Battery Power"
        case .systemWatts: return "System Power"
        case .cpuTemperature: return "CPU Temp"
        case .gpuTemperature: return "GPU Temp"
        case .fanRPM: return "Fan"
        case .batteryPlugged: return "On Power"
        }
    }

    /// Series whose natural range is 0...1 and can share a normalised axis.
    public var isNormalized: Bool {
        switch self {
        case .cpuTotal, .cpuUser, .cpuSystem, .cpuPerformance, .cpuEfficiency,
             .memoryUsed, .memoryPressure, .gpuUtilization, .gpuVRAM, .diskUsed, .batteryPlugged:
            return true

        default:
            return false
        }
    }
}

/// All retained history, keyed by series.
///
/// A value type so the UI can diff cheaply, backed by fixed-size rings so the
/// total allocation is bounded at `capacity * seriesCount * 4` bytes — about
/// 170 KB at the maximum 1-hour-at-1s retention.
public struct MetricHistory: Sendable, Equatable {
    public private(set) var series: [SeriesKey: SampleRing]
    public private(set) var capacity: Int
    /// Wall-clock time of the newest sample, so charts can label their axis.
    public private(set) var lastSampleDate: Date?
    /// Seconds between samples, needed to convert an index into a time offset.
    public var sampleInterval: TimeInterval

    public init(capacity: Int = 300, sampleInterval: TimeInterval = 2) {
        self.capacity = max(2, capacity)
        self.sampleInterval = sampleInterval
        var s = [SeriesKey: SampleRing](minimumCapacity: SeriesKey.allCases.count)
        for key in SeriesKey.allCases { s[key] = SampleRing(capacity: max(2, capacity)) }
        self.series = s
    }

    public mutating func record(_ key: SeriesKey, _ value: Double) {
        series[key]?.append(value)
    }

    public mutating func markSampleDate(_ date: Date) { lastSampleDate = date }

    public subscript(key: SeriesKey) -> SampleRing {
        series[key] ?? SampleRing(capacity: capacity)
    }

    public func values(_ key: SeriesKey) -> [Float] { self[key].values }

    /// Grow or shrink every series, preserving the newest samples.
    public mutating func resize(to newCapacity: Int) {
        let cap = max(2, newCapacity)
        guard cap != capacity else { return }
        // `SeriesKey.allCases` rather than `series.keys`: it is what `init` populates
        // the dictionary from, so the two agree by construction, and nothing here
        // mutates a collection it is in the middle of iterating.
        //
        // Not a speed change, and it was expected to be one. The theory was that the
        // keys view keeps the dictionary's storage referenced for the life of the
        // loop, so every assignment inside it copies all 21 entries. Measured, the two
        // forms are within noise of each other, and pre-uniquing the dictionary before
        // the loop does not move either, so those copies are not happening. What the
        // 21 iterations actually cost is 21 keyed lookups, and `SeriesKey`'s `String`
        // raw value makes each hash about 230 ns. Anyone chasing this further should
        // start there, not here.
        for key in SeriesKey.allCases {
            if var ring = series[key] { series[key] = ring.resized(to: cap) }
        }
        capacity = cap
    }

    public mutating func clear() {
        for key in SeriesKey.allCases { series[key]?.removeAll() }
        lastSampleDate = nil
    }

    /// Total seconds of history currently retained for a series.
    public func span(of key: SeriesKey) -> TimeInterval {
        Double(self[key].count) * sampleInterval
    }
}
