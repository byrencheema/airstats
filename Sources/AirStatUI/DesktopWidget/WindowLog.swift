import Foundation

/// Opt-in tracing for window behaviour.
///
/// Window bugs — a panel that drifts off screen, an event monitor that is installed
/// twice and removed once — are invisible in a screenshot and awkward to reproduce by
/// hand. This lets a run of the real app narrate what its windows are doing:
///
///     AIRSTAT_WINDOW_LOG=1 open -a AirStat.app   # or run the binary directly
///
/// Off by default and reduced to a single boolean check when disabled, so it costs
/// nothing in a normal session.
enum WindowLog {
    static let isEnabled = ProcessInfo.processInfo.environment["AIRSTAT_WINDOW_LOG"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        FileHandle.standardError.write(Data("[airstat.window] \(message())\n".utf8))
    }
}
