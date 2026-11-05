import Foundation

/// The one thing worth saying about the Mac right now, if anything is.
///
/// Shown above the modules once a reading has crossed into territory the user would
/// want to hear about, naming the process behind it where there is one: "Memory
/// pressure 88%, Xcode 4.0 GB" says what is wrong and what to quit in a single line.
/// A healthy Mac gets nothing, which is most of the time, so the line means something
/// when it appears.
public struct PanelInsight: Sendable, Equatable {
    public enum Kind: Sendable, Equatable, CaseIterable {
        case thermal, memory, battery, cpu, disk
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    /// Judged on the recent average rather than the latest sample. One busy tick would
    /// bring the line in and the next idle one take it away, and the panel's height
    /// would jump with it every time.
    public static let cpuThreshold = 0.85
    /// Samples averaged for CPU: 20 seconds at the panel's 2 second cadence.
    public static let cpuWindow = 10
    public static let batteryThreshold = 10.0
    public static let diskFreeThreshold = 0.10

    /// The most urgent condition that holds, or nil.
    ///
    /// Heat first, because it slows everything else down. Memory pressure next, since
    /// it is the usual answer to "why is my Mac slow". Then a battery about to run out,
    /// a CPU that has been pinned for a while, and a disk with almost nothing left.
    public static func make(snapshot: SystemSnapshot, recentCPU: [Float],
                            formatter: MetricFormatter) -> PanelInsight? {
        let processes = snapshot.processes.value?.processes ?? []
        let busiest = processes
            .filter { $0.pid > 0 && $0.name != "kernel_task" }
            .max { $0.cpuPercent < $1.cpuPercent }
        let biggest = processes
            .filter { $0.pid > 0 && $0.name != "kernel_task" }
            .max { $0.memoryBytes < $1.memoryBytes }

        func busiestSuffix() -> String {
            guard let busiest, busiest.cpuPercent >= 1 else { return "" }
            return ", \(busiest.name) \(formatter.unclampedPercent(busiest.cpuPercent, decimals: 0))"
        }

        if let thermal = snapshot.thermal.value, thermal.pressure >= .serious {
            let heat = thermal.cpuCelsius.map { " at \(formatter.temperature($0))" } ?? ""
            return PanelInsight(kind: .thermal, text: "Running hot\(heat)" + busiestSuffix())
        }

        if let memory = snapshot.memory.value, memory.memoryPressure >= .warning {
            var text = "Memory pressure \(formatter.percent(memory.pressureFraction))"
            if let biggest { text += ", \(biggest.name) \(formatter.memory(biggest.memoryBytes))" }
            return PanelInsight(kind: .memory, text: text)
        }

        if let power = snapshot.power.value, power.hasBattery, !power.isPluggedIn,
           let percentage = power.percentage, percentage <= batteryThreshold {
            var text = "Battery \(formatter.percentValue(percentage))"
            if let left = power.timeToEmpty, left > 0 { text += ", \(formatter.duration(left)) left" }
            return PanelInsight(kind: .battery, text: text)
        }

        let window = recentCPU.suffix(cpuWindow)
        if window.count == cpuWindow {
            let average = Double(window.reduce(0, +)) / Double(window.count)
            if average >= cpuThreshold {
                return PanelInsight(kind: .cpu, text: "CPU \(formatter.percent(average))" + busiestSuffix())
            }
        }

        if let root = snapshot.disk.value?.rootVolume, root.totalBytes > 0,
           Double(root.availableBytes) / Double(root.totalBytes) < diskFreeThreshold {
            return PanelInsight(kind: .disk,
                                text: "Disk almost full, \(formatter.storage(root.availableBytes)) free")
        }

        return nil
    }
}
