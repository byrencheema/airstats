import Foundation

/// Stable identity for each metric source. Used for scheduling, for the
/// "which modules are enabled" set, and for diagnostics.
public enum CollectorID: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case cpu, memory, gpu, network, disk, power, thermal, processes, system

    public var label: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .gpu: return "GPU"
        case .network: return "Network"
        case .disk: return "Disk"
        case .power: return "Battery"
        case .thermal: return "Temperature"
        case .processes: return "Processes"
        case .system: return "System"
        }
    }

    public var symbolName: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "cube.transparent"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .power: return "battery.100"
        case .thermal: return "thermometer.medium"
        case .processes: return "list.bullet.rectangle"
        case .system: return "desktopcomputer"
        }
    }
}

/// How hard the app should be working right now.
///
/// This is the single biggest energy lever in AirStat: collectors that nothing is
/// currently displaying are not sampled at all, and when the menu bar item itself is
/// hidden (full-screen app, occluded behind the notch) the whole cadence slows down.
public enum SamplingActivity: Int, Sendable, Equatable, Hashable, Comparable {
    /// Display asleep, screen locked, or system going to sleep. Timer fully suspended.
    case suspended = 0
    /// Menu bar item is not visible to the user. Slow cadence, menu bar sources only.
    case occluded = 1
    /// Normal state: menu bar visible, panel closed.
    case menuBar = 2
    /// Desktop widget window on screen. Same cadence as menu bar, wider source set.
    case desktopWidget = 3
    /// Panel is open. Full cadence, all enabled sources including processes.
    case panel = 4

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Multiplier applied to each collector's cadence.
    public var cadenceMultiplier: Double {
        switch self {
        case .suspended: return .infinity
        case .occluded: return 4
        case .menuBar: return 1
        case .desktopWidget: return 1
        case .panel: return 1
        }
    }

    public var isSampling: Bool { self != .suspended }
}

/// Everything a collector needs to know about the cycle it is being asked to run in.
public struct SampleContext: Sendable {
    /// Seconds since this specific collector last produced a sample. Rate-based
    /// collectors (network, disk) must divide by this rather than assuming the
    /// nominal interval — the timer coalesces and the machine sleeps.
    public let elapsed: TimeInterval
    /// True on the very first collection, and again after a wake, when cumulative
    /// counters must be re-baselined instead of differenced.
    public let isFirstSample: Bool
    public let activity: SamplingActivity
    /// True when the machine just woke; cumulative counters may have reset.
    public let didWakeFromSleep: Bool

    public init(elapsed: TimeInterval, isFirstSample: Bool,
                activity: SamplingActivity, didWakeFromSleep: Bool = false) {
        self.elapsed = elapsed
        self.isFirstSample = isFirstSample
        self.activity = activity
        self.didWakeFromSleep = didWakeFromSleep
    }
}

/// A source of one kind of system metric.
///
/// ## Concurrency contract
/// Every method is called on `SamplingCore`'s private serial queue, never on the
/// main thread and never concurrently. Implementations may hold mutable state
/// (previous counter values, cached IOKit handles) without synchronisation, but
/// must not touch AppKit or publish to the UI directly.
///
/// ## Correctness contract
/// - Return `.failure(.unsupported)` when the hardware genuinely lacks the metric;
///   the engine will then stop calling this collector for the rest of the session.
/// - Return `.failure(.failed)` for a transient error; the engine keeps retrying.
/// - Never return a fabricated or zeroed value to paper over a failed syscall.
/// - Never return a rate computed from a `context.elapsed` of 0.
public protocol MetricSource: AnyObject {
    associatedtype Output: Sendable & Equatable

    var identifier: CollectorID { get }

    /// Preferred seconds between samples at `.menuBar` activity or above. The engine
    /// takes the max of this and the user's configured base interval, so a collector
    /// that is expensive (processes, volume enumeration) can ask to run rarely.
    var preferredInterval: TimeInterval { get }

    /// Acquire long-lived resources (Mach ports, IOKit connections). Called once
    /// before the first `collect`, and again after `stop()` if sampling resumes.
    func start()

    /// Release resources. Called when the collector is disabled or the app quits.
    /// Must be safe to call without a preceding `start()`.
    func stop()

    func collect(context: SampleContext) -> MetricState<Output>
}

extension MetricSource {
    public func start() {}
    public func stop() {}
}

/// Utility for rate collectors: safely difference a monotonically-increasing counter.
///
/// Handles the three ways cumulative system counters lie to you: the first sample
/// (no baseline), counter reset on wake or interface reconfiguration (value went
/// backwards), and a zero/negative elapsed time.
public struct CounterDelta: Sendable {
    private var previous: UInt64?

    public init() {}

    /// Returns the per-second rate, or `nil` when a rate cannot honestly be computed.
    public mutating func rate(current: UInt64, elapsed: TimeInterval) -> Double? {
        defer { previous = current }
        guard let previous else { return nil }
        guard elapsed > 0.001 else { return nil }
        guard current >= previous else { return nil }  // counter reset
        return Double(current - previous) / elapsed
    }

    /// Absolute increase since the last call, or 0 when undefined.
    public mutating func delta(current: UInt64) -> UInt64 {
        defer { previous = current }
        guard let previous, current >= previous else { return 0 }
        return current - previous
    }

    public mutating func reset() { previous = nil }
}
