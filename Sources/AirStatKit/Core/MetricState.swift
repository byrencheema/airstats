import Foundation

/// Why a metric could not be produced. Kept distinct from a plain `nil` so the UI can
/// explain *why* something is missing instead of silently rendering a dash.
public enum MetricFailure: Sendable, Equatable, Hashable {
    /// The hardware or OS version genuinely cannot provide this metric.
    /// Permanent for this machine — the UI should hide or grey out the module.
    case unsupported(String)
    /// The metric exists but the sample failed this cycle (transient syscall error,
    /// device disconnected, sensor asleep). The UI should show the last known value
    /// marked stale, or a dash.
    case failed(String)
    /// The user denied a permission the metric requires.
    case denied(String)
    /// Never sampled yet.
    case pending

    public var message: String {
        switch self {
        case .unsupported(let s): return s
        case .failed(let s): return s
        case .denied(let s): return s
        case .pending: return "Collecting…"
        }
    }

    /// A two-word stand-in for `message`, for surfaces too narrow to wrap prose.
    ///
    /// The desktop widget shows this in the slot a reading would have occupied, so a metric
    /// this Mac cannot provide costs one line instead of three. The full message is
    /// still what the tooltip and VoiceOver read out.
    public var shortLabel: String {
        switch self {
        case .unsupported: return "Unavailable"
        case .failed: return "No reading"
        case .denied: return "No access"
        case .pending: return "Collecting…"
        }
    }

    public var isPermanent: Bool {
        if case .unsupported = self { return true }
        return false
    }
}

/// A metric value that knows whether it is real, and how old it is.
///
/// The correctness rule for this app: never render a number the app is not certain
/// about. Everything flows through `MetricState`, and the UI is required to handle
/// the failure cases explicitly rather than substituting zero.
public enum MetricState<Value: Sendable & Equatable>: Sendable, Equatable {
    case value(Value)
    case failure(MetricFailure)

    public static var pending: Self { .failure(.pending) }

    public var value: Value? {
        if case .value(let v) = self { return v }
        return nil
    }

    public var failure: MetricFailure? {
        if case .failure(let f) = self { return f }
        return nil
    }

    public var isAvailable: Bool { value != nil }

    /// True when this metric will never work on this machine, so UI can hide it for good.
    public var isPermanentlyUnavailable: Bool { failure?.isPermanent ?? false }

    public func map<T>(_ transform: (Value) -> T) -> MetricState<T> {
        switch self {
        case .value(let v): return .value(transform(v))
        case .failure(let f): return .failure(f)
        }
    }

    /// Value if present, otherwise the supplied default. Use only for
    /// non-displayed math (e.g. sorting); never to fabricate a displayed number.
    public func valueOr(_ fallback: Value) -> Value { value ?? fallback }
}

extension MetricState: Hashable where Value: Hashable {}

/// A sample plus the monotonic instant it was captured at.
///
/// `ContinuousClock` is used deliberately: it keeps advancing across system sleep,
/// so a snapshot taken before a 3-hour sleep is correctly reported as 3 hours stale
/// on wake rather than appearing fresh.
public struct Timestamped<Value: Sendable & Equatable>: Sendable, Equatable {
    public var value: Value
    public var capturedAt: ContinuousClock.Instant
    public var wallClock: Date

    public init(_ value: Value,
                capturedAt: ContinuousClock.Instant = Monotonic.now,
                wallClock: Date = Date()) {
        self.value = value
        self.capturedAt = capturedAt
        self.wallClock = wallClock
    }

    public var age: Duration { Monotonic.now - capturedAt }

    public func isStale(threshold: Duration) -> Bool { age > threshold }
}

/// Monotonic time source for the whole app.
///
/// Deliberately `ContinuousClock` rather than `SuspendingClock`: it keeps counting
/// while the Mac is asleep, which is exactly what staleness detection needs on wake.
public enum Monotonic {
    private static let clock = ContinuousClock()
    public static var now: ContinuousClock.Instant { clock.now }

    public static func seconds(since instant: ContinuousClock.Instant) -> Double {
        let d = now - instant
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}

extension Duration {
    /// Seconds as a `Double`, for arithmetic against sampling intervals.
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
