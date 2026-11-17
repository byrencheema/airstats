import Foundation
import AirStatKit

/// A rule that has earned a notification.
struct ThresholdAlert: Equatable {
    let ruleID: UUID
    let metric: ThresholdMetric
    let value: Double
    let threshold: Double
}

/// The decision half of threshold monitoring: given the rules, the current readings
/// and the time, which rules should notify.
///
/// Held apart from delivery so the sustained-duration and cooldown bookkeeping can be
/// tested without a notification centre, and so the monitor is left holding only the
/// parts that need one.
struct ThresholdEvaluator {

    private struct RuleState {
        var breachBegan: Date?
        var notifiedAt: Date?
        /// True once this unbroken run of the condition has produced an alert.
        var alertedThisEpisode = false
    }

    private var states: [UUID: RuleState] = [:]

    /// Rules currently carrying breach or cooldown state. Exposed so a test can show
    /// that state for a rule the user switched off is dropped rather than accumulated.
    var trackedRuleCount: Int { states.count }

    mutating func reset() { states.removeAll() }

    /// Advances every rule's clock by one sample and returns the rules that fire.
    ///
    /// `rules` is the set already cleared for delivery: master switch on, rule on,
    /// metric measurable here. State for anything absent from it is discarded, so a
    /// rule the user turns off does not come back mid-cooldown.
    mutating func alerts(for rules: [ThresholdRule],
                         readings: [ThresholdMetric: Double],
                         now: Date) -> [ThresholdAlert] {
        var alerts: [ThresholdAlert] = []
        var surviving: [UUID: RuleState] = [:]

        for rule in rules {
            var state = states[rule.id] ?? RuleState()
            defer { surviving[rule.id] = state }

            // A missing reading is not evidence the condition ended, but it is not
            // evidence it held either, so the sustained clock restarts rather than
            // crediting time nobody measured.
            guard let value = readings[rule.metric],
                  rule.metric.isBreached(by: value, threshold: rule.threshold) else {
                state.breachBegan = nil
                state.alertedThisEpisode = false
                continue
            }

            let began = state.breachBegan ?? now
            state.breachBegan = began
            guard now.timeIntervalSince(began) >= rule.sustainedFor else { continue }
            if rule.metric.notifiesOncePerEpisode && state.alertedThisEpisode { continue }
            if let notifiedAt = state.notifiedAt, now.timeIntervalSince(notifiedAt) < rule.cooldown { continue }

            state.notifiedAt = now
            state.alertedThisEpisode = true
            alerts.append(ThresholdAlert(ruleID: rule.id, metric: rule.metric,
                                         value: value, threshold: rule.threshold))
        }

        states = surviving
        return alerts
    }

    /// Every watchable metric read out of a snapshot in the units the Notifications
    /// pane presents, so a rule compares against the number the user typed.
    ///
    /// A metric this Mac cannot measure is simply absent rather than zero.
    static func readings(from snapshot: SystemSnapshot) -> [ThresholdMetric: Double] {
        var readings: [ThresholdMetric: Double] = [:]

        if let cpu = snapshot.cpu.value {
            readings[.cpuUsage] = cpu.total.busy * 100
        }
        if let memory = snapshot.memory.value {
            readings[.memoryPressure] = memory.pressureFraction * 100
        }
        if let root = snapshot.disk.value?.rootVolume {
            // `availableBytes` is what the disk module calls free, and decimal GB is
            // the unit macOS states disk capacity in, which is what the rule's "GB"
            // suffix will mean to whoever typed the number.
            readings[.diskFree] = Double(root.availableBytes) / 1_000_000_000
        }
        if let power = snapshot.power.value, let percentage = power.percentage {
            // Split by charge state: a low-battery warning is noise once the machine
            // is on the charger, and a full-battery alert has nothing to say to a
            // battery that is discharging through 100%.
            if power.isPluggedIn {
                readings[.batteryFull] = percentage
            } else {
                readings[.batteryLow] = percentage
            }
        }
        if let bluetooth = snapshot.bluetooth.value,
           let lowest = bluetooth.lowestBatteryPercent(dischargingOnly: true) {
            readings[.bluetoothBatteryLow] = lowest
        }
        if let thermal = snapshot.thermal.value {
            if let cpuCelsius = thermal.cpuCelsius { readings[.cpuTemperature] = cpuCelsius }
            readings[.thermalPressure] = Double(thermal.pressure.rawValue)
        }

        return readings
    }
}

extension ThresholdMetric {

    /// Direction is per metric, not uniform: free disk space and a draining battery
    /// are alarming as they fall, everything else as it climbs.
    var firesWhenBelow: Bool {
        switch self {
        case .diskFree, .batteryLow, .bluetoothBatteryLow: return true
        case .cpuUsage, .memoryPressure, .batteryFull, .cpuTemperature, .thermalPressure: return false
        }
    }

    func isBreached(by value: Double, threshold: Double) -> Bool {
        firesWhenBelow ? value <= threshold : value >= threshold
    }

    /// Reaching a full charge is an event, not a condition. A Mac left on the charger
    /// sits at 100% for hours, and repeating on every cooldown would make the rule
    /// unusable, so it waits for the battery to leave the threshold first.
    var notifiesOncePerEpisode: Bool { self == .batteryFull }
}

extension ThresholdAlert {

    var title: String {
        switch metric {
        case .cpuUsage: return L10n.tr("CPU usage is high", "CPU đang sử dụng cao")
        case .memoryPressure: return L10n.tr("Memory pressure is high", "Áp lực bộ nhớ cao")
        case .diskFree: return L10n.tr("Startup disk is running out of space", "Ổ đĩa khởi động sắp hết dung lượng")
        case .batteryLow: return L10n.tr("Battery is low", "Pin yếu")
        case .batteryFull: return L10n.tr("Battery is charged", "Pin đã sạc đầy")
        case .bluetoothBatteryLow: return L10n.tr("Bluetooth battery is low", "Pin thiết bị Bluetooth yếu")
        case .cpuTemperature: return L10n.tr("CPU is running hot", "Nhiệt độ CPU đang cao")
        case .thermalPressure: return L10n.tr("This Mac is under thermal pressure", "Máy Mac đang nóng")
        }
    }

    var body: String { body(in: nil) }

    func body(in snapshot: SystemSnapshot?) -> String {
        switch metric {
        case .cpuUsage:
            return L10n.tr("CPU is at \(percent(value)), above your \(percent(threshold)) threshold.",
                           "CPU đang ở mức \(percent(value)), vượt ngưỡng \(percent(threshold)).")
        case .memoryPressure:
            return L10n.tr("Memory pressure is at \(percent(value)), above your \(percent(threshold)) threshold.",
                           "Áp lực bộ nhớ ở mức \(percent(value)), vượt ngưỡng \(percent(threshold)).")
        case .diskFree:
            return L10n.tr("\(gigabytes(value)) free on the startup disk, below your \(gigabytes(threshold)) threshold.",
                           "Còn trống \(gigabytes(value)) trên ổ đĩa khởi động, dưới ngưỡng \(gigabytes(threshold)).")
        case .batteryLow:
            return L10n.tr("Battery is at \(percent(value)), below your \(percent(threshold)) threshold.",
                           "Pin còn \(percent(value)), dưới ngưỡng \(percent(threshold)).")
        case .batteryFull:
            return L10n.tr("Battery is at \(percent(value)). You can unplug.",
                           "Pin đã đạt \(percent(value)). Bạn có thể rút sạc.")
        case .bluetoothBatteryLow:
            let deviceName = snapshot?.bluetooth.value?
                .lowestBatteryDevice(dischargingOnly: true)?.device.name
                ?? L10n.tr("Bluetooth device", "Thiết bị Bluetooth")
            return L10n.tr("\(deviceName) is at \(percent(value)), below your \(percent(threshold)) threshold.",
                           "\(deviceName) còn \(percent(value)), dưới ngưỡng \(percent(threshold)).")
        case .cpuTemperature:
            return L10n.tr("CPU is at \(degrees(value)), above your \(degrees(threshold)) threshold.",
                           "Nhiệt độ CPU là \(degrees(value)), vượt ngưỡng \(degrees(threshold)).")
        case .thermalPressure:
            return L10n.tr("Thermal pressure is \(level(value)), at or past your \(level(threshold)) threshold.",
                           "Áp lực nhiệt đang ở mức \(level(value)), đạt ngưỡng \(level(threshold)).")
        }
    }

    private func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    private func gigabytes(_ value: Double) -> String { "\(Int(value.rounded())) GB" }

    private func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }

    private func level(_ value: Double) -> String {
        ThermalPressure(rawValue: Int(value))?.label.lowercased() ?? "\(Int(value))"
    }
}
