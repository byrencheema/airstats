import Foundation
import IOKit
import IOKit.ps

/// Battery charge, health, adapter and system power draw.
///
/// Concurrency: every method runs on `SamplingCore`'s serial queue. See
/// `MetricSource` for the full contract, including the rule that a failed syscall
/// must surface as `.failure`, never as a zeroed value.
///
/// Two sources are combined. `IOPowerSources` is authoritative for everything the
/// rest of the system already agrees on — charge percentage, charging state, time
/// remaining — because it is the layer `pmset` and the menu bar battery glyph read,
/// so using it keeps AirStat from disagreeing with the OS by a percent. The
/// `AppleSmartBattery` IORegistry node then supplies what IOPowerSources does not
/// publish: raw mAh capacities, cycle count, voltage, signed amperage, pack
/// temperature and the power-telemetry block.
///
/// Nothing here is a cumulative counter — every field is an instantaneous level — so
/// `context.elapsed`, `isFirstSample` and `didWakeFromSleep` need no handling: there
/// is no baseline that a wake could invalidate.
public final class PowerCollector: MetricSource {
    public typealias Output = PowerSnapshot

    public let identifier: CollectorID = .power
    public let preferredInterval: TimeInterval = 5.0

    /// The `AppleSmartBattery` node, held for the life of the collector so a sample is
    /// a handful of property reads rather than a registry match. `IO_OBJECT_NULL` on
    /// desktops, which is a supported configuration rather than an error.
    private var battery: io_service_t = IO_OBJECT_NULL
    /// A Mac does not grow a battery mid-session, so a miss is remembered rather than
    /// re-matched every five seconds for the life of the process.
    private var didLookUpBattery = false
    /// Fixed for the life of the pack, so it is read once instead of every sample.
    private var designCapacity: Int?
    /// Accessory batteries and when they were last read. Earbuds report their charge
    /// to macOS on their own schedule, minutes apart, so reading the list every
    /// five seconds would return the same figures and cost a copy of the list.
    private var accessories: [AccessoryBattery] = []
    private var accessoriesReadAt: ContinuousClock.Instant?
    static let accessoryInterval: Duration = .seconds(60)

    public init() {}

    public func start() {
        openBattery()
    }

    public func stop() {
        if battery != IO_OBJECT_NULL {
            IOObjectRelease(battery)
            battery = IO_OBJECT_NULL
        }
        didLookUpBattery = false
        designCapacity = nil
        accessories = []
        accessoriesReadAt = nil
    }

    public func collect(context: SampleContext) -> MetricState<PowerSnapshot> {
        // Tolerates start() having been skipped; on the normal path this is a no-op.
        if !didLookUpBattery { openBattery() }

        // IOPSCopyPowerSourcesInfo is the only call here that can fail outright. It
        // returning NULL means powerd is not answering, which is transient.
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .failure(.failed("IOPSCopyPowerSourcesInfo returned no snapshot"))
        }
        guard let handles = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
            as? [CFTypeRef] else {
            return .failure(.failed("IOPSCopyPowerSourcesList returned no list"))
        }

        // Deliberately matches only the internal battery: an attached UPS also appears
        // in this list, and reporting its charge as the Mac's would be wrong.
        let source = handles.lazy
            .compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }

        var snapshot = PowerSnapshot()
        snapshot.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        snapshot.hasBattery = source != nil || boolean("BatteryInstalled") == true

        applyAdapter(to: &snapshot)
        snapshot.accessories = currentAccessories()

        guard snapshot.hasBattery else {
            // A Mac with no battery is running off the wall by definition; there is no
            // other way for it to be powered on. Every battery-specific field stays nil
            // so the UI shows them as unavailable rather than as zero.
            snapshot.isPluggedIn = true
            return .value(snapshot)
        }

        applyCharge(to: &snapshot, source: source)
        applyElectrical(to: &snapshot)
        applyHealth(to: &snapshot, source: source)
        return .value(snapshot)
    }

    // MARK: Accessories

    /// The accessory list, re-read once a minute.
    ///
    /// The same power source machinery the internal battery comes from, asked for
    /// its accessory sources: this is what `pmset -g accps` and the Bluetooth menu
    /// read. The call is exported by IOKit but not declared in its public headers,
    /// so it is declared here; if a macOS release stops answering, the list is
    /// empty and the panel shows no accessory rows, which is the state it starts in.
    private func currentAccessories() -> [AccessoryBattery] {
        let now = ContinuousClock.now
        if let readAt = accessoriesReadAt, now - readAt < Self.accessoryInterval {
            return accessories
        }
        accessoriesReadAt = now
        accessories = Self.readAccessories()
        return accessories
    }

    static func readAccessories() -> [AccessoryBattery] {
        guard let blob = IOPSCopyPowerSourcesByType(Self.accessorySourceType)?.takeRetainedValue(),
              let handles = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        let sources = handles.compactMap {
            IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return accessories(from: sources)
    }

    /// `kIOPSSourceForAccessories` in IOKit's private key header.
    private static let accessorySourceType: Int32 = 3

    /// Folds the accessory sources into one accessory per device.
    ///
    /// A source with a group identifier is one part of a device that reports
    /// several: the parts are gathered under the group, the combined part names the
    /// device and gives its headline charge, and the rest are listed by their part
    /// name. A source without a group is a device by itself. Anything without a
    /// name and a charge is skipped rather than shown as a nameless row.
    static func accessories(from sources: [[String: Any]]) -> [AccessoryBattery] {
        struct Entry {
            let name: String
            let percent: Double
            let isCharging: Bool
            let identifier: String
            let part: String?
            let group: String?
            let category: String?
        }
        let entries: [Entry] = sources.compactMap { source in
            guard let name = source["Name"] as? String, !name.isEmpty,
                  let capacity = (source["Current Capacity"] as? NSNumber)?.doubleValue else { return nil }
            let maximum = (source["Max Capacity"] as? NSNumber)?.doubleValue ?? 100
            let percent = maximum > 0 ? min(100, max(0, capacity / maximum * 100)) : capacity
            let charging = source["Is Charging"] as? Bool
                ?? ((source["Power Source State"] as? String) == "AC Power")
            let identifier = source["Accessory Identifier"] as? String
                ?? source["Hardware Serial Number"] as? String ?? name
            return Entry(name: name, percent: percent, isCharging: charging,
                         identifier: identifier, part: source["Part Identifier"] as? String,
                         group: source["Group Identifier"] as? String,
                         category: source["Accessory Category"] as? String)
        }

        var order: [String] = []
        var grouped: [String: [Entry]] = [:]
        for entry in entries {
            let key = entry.group ?? "\(entry.identifier)|\(entry.name)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(entry)
        }

        return order.compactMap { key in
            guard let members = grouped[key] else { return nil }
            if members.count == 1, members[0].group == nil {
                let one = members[0]
                return AccessoryBattery(id: one.identifier, name: one.name, category: one.category,
                                        percent: one.percent, isCharging: one.isCharging)
            }
            let combined = members.first { $0.part == "Combined" }
            let parts = members.filter { $0.part != "Combined" }.map {
                AccessoryBattery.Part(name: $0.part ?? $0.name, percent: $0.percent,
                                      isCharging: $0.isCharging)
            }
            let named = combined ?? members.first { !($0.category ?? "").localizedCaseInsensitiveContains("case") }
                ?? members[0]
            let buds = parts.filter { $0.name.caseInsensitiveCompare("Case") != .orderedSame }
            let headline = combined?.percent ?? (buds.isEmpty ? parts : buds).map(\.percent).min() ?? named.percent
            return AccessoryBattery(id: named.identifier, name: named.name, category: named.category,
                                    percent: headline,
                                    isCharging: combined?.isCharging ?? parts.contains { $0.isCharging },
                                    parts: parts)
        }
    }

    // MARK: Assembly

    private func applyCharge(to snapshot: inout PowerSnapshot, source: [String: Any]?) {

        // Taken as a ratio on purpose. IOPowerSources documents no unit for these two
        // keys and is free to report either mAh or a percentage — on Apple Silicon it
        // reports a percentage, so both are 100 at full charge — and dividing one by
        // the other is correct under either convention.
        if let current = (source?[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
           let full = (source?[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue, full > 0 {
            snapshot.percentage = min(100, max(0, current / full * 100))
        } else if let current = number("AppleRawCurrentCapacity")?.doubleValue,
                  let full = number("AppleRawMaxCapacity")?.doubleValue, full > 0 {
            snapshot.percentage = min(100, max(0, current / full * 100))
        }

        snapshot.isCharging = source?[kIOPSIsChargingKey] as? Bool
            ?? boolean("IsCharging") ?? false
        snapshot.isPluggedIn = (source?[kIOPSPowerSourceStateKey] as? String).map { $0 == kIOPSACPowerValue }
            ?? boolean("ExternalConnected") ?? false
        // "Is Charged" is documented as published by Apple batteries but is absent from
        // the dictionary on this machine, so AppleSmartBattery is the working source.
        snapshot.isFullyCharged = source?[kIOPSIsChargedKey] as? Bool
            ?? boolean("FullyCharged") ?? false

        // Both IOPowerSources keys are in minutes; the snapshot is in seconds. A
        // negative value is powerd's "still estimating" sentinel and zero means the
        // direction does not apply, so neither becomes a displayed duration.
        if let minutes = (source?[kIOPSTimeToEmptyKey] as? NSNumber)?.doubleValue, minutes > 0 {
            snapshot.timeToEmpty = minutes * 60
        }
        if let minutes = (source?[kIOPSTimeToFullChargeKey] as? NSNumber)?.doubleValue,
           minutes > 0, snapshot.isCharging {
            snapshot.timeToFull = minutes * 60
        }

        // Charging held while connected and short of full: macOS's optimized-charging
        // hold looks exactly like this. So does a thermal or low-adapter-power hold,
        // which is why this is derived from observable state rather than claimed from a
        // specific hardware bit — AppleSmartBattery's NotChargingReason bitfield is
        // undocumented and its meanings are not verifiable from a single power state.
        snapshot.isOptimizedChargingPaused =
            snapshot.isPluggedIn && !snapshot.isCharging && !snapshot.isFullyCharged
    }

    private func applyElectrical(to snapshot: inout PowerSnapshot) {
        // Millivolts and signed milliamps; the sign convention is already the one the
        // snapshot documents, negative while discharging.
        let millivolts = number("Voltage")?.doubleValue
        let milliamps = number("Amperage").map { Double($0.int64Value) }
        if let millivolts, millivolts > 0 { snapshot.voltage = millivolts / 1000 }
        snapshot.amperage = milliamps
        if let volts = snapshot.voltage, let milliamps {
            snapshot.batteryWatts = volts * milliamps / 1000
        }

        // Centi-Celsius. Anything outside a range a lithium pack can physically be in
        // means the key is not what it is assumed to be on this hardware, so it is
        // dropped rather than displayed.
        if let raw = number("Temperature")?.doubleValue {
            let celsius = raw / 100
            if celsius > -40, celsius < 100 { snapshot.temperatureCelsius = celsius }
        }

        // systemWatts stays nil. AppleSmartBattery's PowerTelemetryData block does carry
        // a SystemLoad key in milliwatts that looks like the answer — it tracks load
        // (3.2 W idle against 21 W under an all-core spin) and its siblings balance,
        // BatteryPower == -SystemLoad while SystemPowerIn is 0 on battery — but it does
        // not survive checking. On battery the pack is the only supply, so true system
        // power must equal battery output power, and SystemLoad was seen disagreeing
        // with |Voltage x Amperage| by up to 45% at the same instant (6.7 W against
        // 11.7 W); over a seven-minute steady-load run it averaged 21.4 W where the
        // energy actually drained out of the pack was 18.2 W. So it is a smoothed
        // estimate that would contradict the batteryWatts sitting beside it in the same
        // snapshot. Publishing it would be inventing a number, and on battery
        // batteryWatts already is the system draw. Revisit only with a machine on AC,
        // where SystemPowerIn and AdapterEfficiencyLoss become non-zero and the
        // adapter-in minus charge-out identity can actually be tested.
    }

    private func applyHealth(to snapshot: inout PowerSnapshot, source: [String: Any]?) {
        if designCapacity == nil { designCapacity = number("DesignCapacity")?.intValue }
        snapshot.designCapacitymAh = designCapacity.flatMap { $0 > 0 ? $0 : nil }
        snapshot.maxCapacitymAh = number("AppleRawMaxCapacity")?.intValue
        snapshot.currentCapacitymAh = number("AppleRawCurrentCapacity")?.intValue
        snapshot.cycleCount = number("CycleCount")?.intValue

        // Derived from the two fields published above rather than from a separately
        // chosen key, so healthPercent cannot drift out of step with the capacities
        // shown next to it. All three come from one scale: AppleRawCurrentCapacity,
        // AppleRawMaxCapacity and DesignCapacity.
        //
        // This reads about 3 points below the "Maximum Capacity" System Information
        // shows, and the gap is understood rather than unexplained. Apple's figure is
        // built on NominalChargeCapacity, which on this pack is exactly
        // AppleRawMaxCapacity + PackReserve — reserve capacity the gauge holds back and
        // never hands to the user — and Apple then smooths the result over days. Raw
        // full-charge capacity is also load-dependent, observed swinging 1.5% between
        // idle and an all-core spin, so no instantaneous reading reproduces Apple's
        // number exactly. Reporting the usable-capacity ratio and keeping the arithmetic
        // checkable beats matching a smoothed figure that cannot be recomputed.
        if let design = snapshot.designCapacitymAh, let full = snapshot.maxCapacitymAh,
           design > 0, full > 0 {
            snapshot.healthPercent = Double(full) / Double(design) * 100
        }

        snapshot.condition = condition(source: source)
    }

    /// Mirrors the wording System Information's "Condition" row uses.
    private func condition(source: [String: Any]?) -> String? {
        // A non-empty health condition is already a user-facing string
        // ("Check Battery", "Permanent Battery Failure") and outranks everything else.
        if let condition = source?[kIOPSBatteryHealthConditionKey] as? String, !condition.isEmpty {
            return condition
        }
        if let failure = number("PermanentFailureStatus")?.intValue, failure != 0 {
            return kIOPSPermanentFailureValue
        }
        switch source?[kIOPSBatteryHealthKey] as? String {
        case kIOPSGoodValue: return "Normal"
        case kIOPSFairValue, kIOPSPoorValue: return "Service Recommended"
        default: return nil
        }
    }

    /// Reasoned through but never exercised: no charger was ever connected while this
    /// was written, so `IOPSCopyExternalPowerAdapterDetails` only ever returned NULL
    /// here and the key names below come from the IOPSKeys.h documentation rather than
    /// from an observed dictionary. Same caveat applies to every charging-side field in
    /// `applyCharge` — the positive-amperage, `timeToFull` and `isCharging` paths have
    /// not been seen to fire. Verify against `pmset -g ac` on a plugged-in Mac.
    private func applyAdapter(to snapshot: inout PowerSnapshot) {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue()
            as? [String: Any] else { return }
        if let watts = (details[kIOPSPowerAdapterWattsKey] as? NSNumber)?.intValue, watts > 0 {
            snapshot.adapterWatts = watts
        }
        // Apple adapters publish a marketing name; third-party USB-C supplies often
        // publish only one of the other two, and some publish none at all.
        for key in ["Name", "Description", "Manufacturer"] {
            if let name = details[key] as? String, !name.isEmpty {
                snapshot.adapterName = name
                break
            }
        }
    }

    // MARK: IORegistry

    private func openBattery() {
        // Releasing first keeps a second start() without an intervening stop() from
        // stranding the previous handle.
        if battery != IO_OBJECT_NULL { IOObjectRelease(battery) }
        didLookUpBattery = true
        battery = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSmartBattery"))
        designCapacity = number("DesignCapacity")?.intValue
    }

    /// Individual property reads rather than `IORegistryEntryCreateCFProperties`: the
    /// full node also carries BatteryData, LifetimeData and a four-element
    /// PortControllerInfo array, and copying all of that measured 0.53 ms against
    /// 0.15 ms for reading the handful of keys this collector actually wants.
    private func property(_ key: String) -> Any? {
        guard battery != IO_OBJECT_NULL else { return nil }
        return IORegistryEntryCreateCFProperty(battery, key as CFString,
                                               kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func number(_ key: String) -> NSNumber? { property(key) as? NSNumber }

    private func boolean(_ key: String) -> Bool? { property(key) as? Bool }

    private func dictionary(_ key: String) -> [String: Any]? { property(key) as? [String: Any] }
}

/// Exported by IOKit and used by `pmset`, but absent from the public headers. The
/// argument selects the source type; see `PowerCollector.accessorySourceType`.
@_silgen_name("IOPSCopyPowerSourcesByType")
private func IOPSCopyPowerSourcesByType(_ type: Int32) -> Unmanaged<CFTypeRef>?
