import Foundation
import IOKit

/// Temperature sensors, fan speeds and thermal pressure.
///
/// Concurrency: every method runs on `SamplingCore`'s serial queue. See
/// `MetricSource` for the full contract, including the rule that a failed syscall
/// must surface as `.failure`, never as a zeroed value.
///
/// ## Why this talks to the SMC directly
/// macOS ships no public API for die temperatures or fan speeds. The two routes that
/// exist are `IOHIDEventSystemClient*` (private C symbols, resolvable only via `dlsym`)
/// and the `AppleSMC` user client. This collector uses the latter: `IOServiceOpen` and
/// `IOConnectCallStructMethod` are public IOKit, and only the request struct layout and
/// command codes are undocumented. That is a strictly smaller undocumented surface than
/// dlsym'ing private functions, and it fails closed — an unknown key or a changed struct
/// makes a read return a non-zero result byte, which is skipped, rather than crashing.
///
/// Both routes were measured on the target machine and agree; the SMC one additionally
/// exposes fans, which the HID route does not publish at all on Apple Silicon.
///
/// Nothing here is a cumulative counter, so `context.elapsed`, `isFirstSample` and
/// `didWakeFromSleep` carry no information for this collector — every reading is an
/// instantaneous gauge and there is nothing to re-baseline after a wake.
public final class ThermalCollector: MetricSource {
    public typealias Output = ThermalSnapshot

    public let identifier: CollectorID = .thermal
    public let preferredInterval: TimeInterval = 3.0

    /// One SMC read costs roughly 0.2 ms — it is a round trip to a separate
    /// coprocessor, not a memory load — so the number of sensors sampled per cycle is
    /// capped rather than reading every key the machine exposes. The target machine
    /// publishes 101 plausible thermal keys; reading all of them measured ~19 ms, well
    /// past the point where a menu bar app has any business spending time.
    private enum Budget {
        static let cpuSensors = 7
        static let gpuSensors = 2
        static let ambientSensors = 2
        static let memorySensors = 2
        static let batterySensors = 1
        static let storageSensors = 1
    }

    /// A power-gated sensor does not report "unavailable" — it reports a sentinel. On the
    /// target machine every GPU key reads exactly 0.0, -0.7 or -3.2 while the GPU is
    /// idle, then jumps to a real 50-75 °C when work arrives. A band of -20...130 would
    /// happily surface "-3.2 °C" as a GPU temperature, so the floor sits just above
    /// freezing instead: a powered die is never at or below 0 °C, and readings below
    /// that are the SMC saying "this domain is off", which must render as absent.
    private static let plausibleRange: ClosedRange<Double> = 1.0...130.0

    /// A powered CPU or GPU die idles well above the room it sits in, so for those two
    /// categories the floor is higher. The first two samples after a wake from deep
    /// idle (measured on macOS 27) read the CPU at 2.7 °C and the GPU at 7.6 °C while
    /// the SMC was still coming up, and the 24-hour chart kept "min 3°C" for the rest
    /// of the day. Ambient and battery sensors keep the low floor: a cold room is real.
    private static let dieFloor = 10.0

    static func isPlausible(_ celsius: Double, category: SensorCategory) -> Bool {
        guard plausibleRange.contains(celsius) else { return false }
        switch category {
        case .cpu, .gpu: return celsius >= dieFloor
        default: return true
        }
    }

    /// SMC keys are four-character codes whose prefix encodes what is being measured.
    /// Only prefixes verified on Apple Silicon are matched by prefix, because the
    /// namespace is reused: this machine exposes `TCMz` and `TCHP`, which are *not* the
    /// Intel `TC0P` CPU-proximity sensor, and `TG0B`, which is a battery gas gauge
    /// rather than the Intel `TG0P` GPU sensor. Intel keys are therefore listed
    /// individually below so the two conventions cannot collide.
    private static let verifiedPrefixes: [(prefix: String, category: SensorCategory)] = [
        ("Tp", .cpu),      // CPU performance-core die sensors
        ("Te", .cpu),      // CPU efficiency-core die sensors
        ("Tg", .gpu),      // GPU cluster die sensors
        ("Ts", .ambient),  // enclosure / skin sensors
        ("TB", .battery),
        ("TH", .storage),
    ]

    /// Long-standing Intel Mac keys, matched exactly. Unverified — this collector was
    /// developed on Apple Silicon, where none of these exist. They cost nothing when
    /// absent, and an Intel Mac that lacks them simply reports sensors unavailable.
    private static let legacyKeys: [(key: String, category: SensorCategory)] = [
        ("TC0P", .cpu), ("TC0D", .cpu), ("TC0E", .cpu), ("TC0F", .cpu),
        ("TG0P", .gpu), ("TG0D", .gpu),
        ("TA0P", .ambient), ("TA1P", .ambient),
        ("TM0P", .memory), ("TM0S", .memory),
    ]

    /// A sensor resolved once in `start()`: the key plus everything needed to decode it,
    /// so the sampling path is one IOKit call per sensor instead of three.
    private struct Sensor {
        let key: UInt32
        let id: String
        let name: String
        let category: SensorCategory
        let dataSize: UInt32
        let dataType: UInt32
    }

    private struct Fan {
        let id: Int
        let key: UInt32
        let dataSize: UInt32
        let dataType: UInt32
        let minRPM: Double?
        let maxRPM: Double?
    }

    private var connection: io_connect_t = 0
    private var sensors: [Sensor] = []
    private var fans: [Fan] = []
    /// Set when `start()` could not reach the SMC at all, so `collect()` can explain
    /// itself without retrying a connection that is not coming back.
    private var setupFailure: String?

    /// Request and reply buffers are held for the life of the collector so the sampling
    /// path allocates nothing.
    private var request: UnsafeMutableRawPointer?
    private var reply: UnsafeMutableRawPointer?

    public init() {}

    // MARK: Lifecycle

    public func start() {
        stop()

        request = .allocate(byteCount: Layout.size, alignment: 16)
        reply = .allocate(byteCount: Layout.size, alignment: 16)

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            setupFailure = "no AppleSMC service on this machine"
            return
        }
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        guard opened == kIOReturnSuccess else {
            connection = 0
            setupFailure = String(format: "AppleSMC could not be opened (0x%08x)", opened)
            return
        }

        discoverSensors()
        discoverFans()
    }

    public func stop() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
        request?.deallocate()
        reply?.deallocate()
        request = nil
        reply = nil
        sensors = []
        fans = []
        setupFailure = nil
    }

    deinit { stop() }

    // MARK: Sampling

    public func collect(context: SampleContext) -> MetricState<ThermalSnapshot> {
        // Thermal pressure comes from a public API that works everywhere, including in a
        // VM with no SMC, so it is read first and the snapshot is built around it. That
        // is what keeps this collector useful on a machine with no readable sensors.
        let pressure = Self.pressure(from: ProcessInfo.processInfo.thermalState)

        guard connection != 0 else {
            return .value(ThermalSnapshot(pressure: pressure,
                                          sensorsUnavailableReason: setupFailure ?? "SMC not open"))
        }

        var readings: [TemperatureSensor] = []
        readings.reserveCapacity(sensors.count)
        var cpuSum = 0.0, cpuCount = 0
        var gpuSum = 0.0, gpuCount = 0
        var readFailures = 0

        // With only the menu bar showing, the CPU average is the one temperature
        // anything reads: the readout, the CPU temperature alert and its history.
        // The other sensors are for the panel and widget, and each costs an SMC round
        // trip, so skipping them takes this collector from about 4.4 ms to under half.
        let cpuOnly = context.activity < .desktopWidget
        for sensor in sensors where !cpuOnly || sensor.category == .cpu {
            guard let raw = read(key: sensor.key, dataSize: sensor.dataSize, dataType: sensor.dataType) else {
                readFailures += 1
                continue
            }
            // Out-of-band values are a powered-down domain, not a temperature. Dropping
            // the sensor entirely is the only honest rendering: there is no reading.
            guard Self.isPlausible(raw, category: sensor.category) else { continue }

            readings.append(TemperatureSensor(id: sensor.id, name: sensor.name,
                                              category: sensor.category, celsius: raw))
            switch sensor.category {
            case .cpu: cpuSum += raw; cpuCount += 1
            case .gpu: gpuSum += raw; gpuCount += 1
            default: break
            }
        }

        var fanInfo: [FanInfo] = []
        fanInfo.reserveCapacity(fans.count)
        for fan in fans {
            guard let rpm = read(key: fan.key, dataSize: fan.dataSize, dataType: fan.dataType),
                  rpm >= 0, rpm < 60_000 else { continue }
            // 0 RPM is a stopped fan, not a failed read, and the two are distinguishable:
            // a failed read returns nil above and drops the fan from the array entirely.
            // Apple Silicon laptops park their fans completely and only spin up well past
            // 73 °C sustained, so 0 is the normal idle reading and must be reported as the
            // real measurement it is.
            //
            // `minRPM` is the slowest speed the fan turns at *while spinning*, so a
            // stopped fan legitimately sits below it. `FanInfo.loadFraction` already
            // clamps to 0...1, so the dial reads empty rather than running backwards.
            fanInfo.append(FanInfo(id: fan.id, name: "Fan \(fan.id + 1)", currentRPM: rpm,
                                   minRPM: fan.minRPM, maxRPM: fan.maxRPM))
        }

        // Aggregates are the arithmetic mean of the accepted sensors in each category —
        // an unweighted mean over a spatial sample of the cluster's die sensors, not a
        // hot spot. `nil` rather than 0 when the whole cluster is gated, which is the
        // normal state of the GPU on an idle machine.
        let cpuCelsius = cpuCount > 0 ? cpuSum / Double(cpuCount) : nil
        let gpuCelsius = gpuCount > 0 ? gpuSum / Double(gpuCount) : nil

        var reason: String?
        if sensors.isEmpty {
            reason = setupFailure ?? "this Mac's SMC exposes no recognised temperature keys"
        } else if readings.isEmpty {
            reason = readFailures > 0
                ? "SMC stopped responding to sensor reads"
                : "all sensor domains are powered down"
        }

        return .value(ThermalSnapshot(pressure: pressure,
                                      sensors: readings,
                                      fans: fanInfo,
                                      cpuCelsius: cpuCelsius,
                                      gpuCelsius: gpuCelsius,
                                      sensorsUnavailableReason: reason))
    }

    private static func pressure(from state: ProcessInfo.ThermalState) -> ThermalPressure {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    // MARK: Discovery

    /// Walks the SMC key index once and keeps a bounded, evenly spread sample of each
    /// category. Enumerating all 2294 keys measured ~320 ms on the target machine; it
    /// happens once per session, off the main thread, and is what lets this work on a
    /// Mac whose key names nobody has hardcoded.
    private func discoverSensors() {
        guard let total = keyCount() else {
            setupFailure = "SMC key directory unreadable"
            return
        }

        var byCategory: [SensorCategory: [String]] = [:]
        let legacy = Dictionary(uniqueKeysWithValues: Self.legacyKeys.map { ($0.key, $0.category) })

        for index in 0..<total {
            guard let name = keyName(at: index), name.hasPrefix("T") else { continue }
            let category: SensorCategory
            if let exact = legacy[name] {
                category = exact
            } else if let match = Self.verifiedPrefixes.first(where: { name.hasPrefix($0.prefix) }) {
                category = match.category
            } else {
                continue
            }
            byCategory[category, default: []].append(name)
        }

        let caps: [SensorCategory: Int] = [
            .cpu: Budget.cpuSensors, .gpu: Budget.gpuSensors, .ambient: Budget.ambientSensors,
            .memory: Budget.memorySensors, .battery: Budget.batterySensors, .storage: Budget.storageSensors,
        ]

        var resolved: [Sensor] = []
        for (category, keys) in byCategory {
            guard let cap = caps[category] else { continue }
            // Sorted then strided, so the sample is spread across the die rather than
            // clustered in whichever keys happen to be hottest right now. Picking by
            // current temperature would bias the mean warm and change from run to run.
            let chosen = Self.evenlySampled(keys.sorted(), cap: cap)
            for (offset, name) in chosen.enumerated() {
                guard let key = Self.fourCharCode(name), let info = keyInfo(for: key) else { continue }
                guard Self.decodableSizes.contains(info.size) else { continue }
                resolved.append(Sensor(key: key,
                                       id: name,
                                       name: Self.label(for: category, index: offset, of: chosen.count),
                                       category: category,
                                       dataSize: info.size,
                                       dataType: info.type))
            }
        }
        sensors = resolved.sorted { ($0.category.rawValue, $0.id) < ($1.category.rawValue, $1.id) }
    }

    /// `FNum` reports the fan count; each fan then has `F<n>Ac` for the live speed and
    /// `F<n>Mn`/`F<n>Mx` for the range. Min and max are fixed properties of the chassis,
    /// so they are read once here rather than every cycle. A fanless Mac reports
    /// `FNum` = 0 and correctly produces no fans at all.
    private func discoverFans() {
        guard let key = Self.fourCharCode("FNum"), let info = keyInfo(for: key),
              let count = read(key: key, dataSize: info.size, dataType: info.type) else { return }

        for index in 0..<Int(count) {
            guard index < 16,
                  let currentKey = Self.fourCharCode("F\(index)Ac"),
                  let currentInfo = keyInfo(for: currentKey) else { continue }
            fans.append(Fan(id: index,
                            key: currentKey,
                            dataSize: currentInfo.size,
                            dataType: currentInfo.type,
                            minRPM: staticFanValue("F\(index)Mn"),
                            maxRPM: staticFanValue("F\(index)Mx")))
        }
    }

    private func staticFanValue(_ name: String) -> Double? {
        guard let key = Self.fourCharCode(name), let info = keyInfo(for: key),
              let value = read(key: key, dataSize: info.size, dataType: info.type),
              value > 0, value < 60_000 else { return nil }
        return value
    }

    private static func label(for category: SensorCategory, index: Int, of total: Int) -> String {
        let base: String
        switch category {
        case .cpu: base = "CPU die"
        case .gpu: base = "GPU die"
        case .memory: base = "Memory"
        case .storage: base = "Storage"
        case .battery: base = "Battery"
        case .ambient: base = "Enclosure"
        case .power: base = "Power"
        case .other: base = "Sensor"
        }
        return total > 1 ? "\(base) \(index + 1)" : base
    }

    /// Picks `cap` items spread across `items`, keeping the first and last.
    private static func evenlySampled<T>(_ items: [T], cap: Int) -> [T] {
        guard cap > 0 else { return [] }
        guard items.count > cap else { return items }
        guard cap > 1 else { return [items[items.count / 2]] }
        let stride = Double(items.count - 1) / Double(cap - 1)
        return (0..<cap).map { items[Int((Double($0) * stride).rounded())] }
    }

    // MARK: SMC transport

    /// Byte offsets into the 80-byte `AppleSMC` request/reply struct. Expressed as raw
    /// offsets rather than a Swift struct because Swift makes no guarantee that its
    /// field layout matches the C one the kernel expects, and getting that wrong would
    /// silently read the wrong bytes instead of failing.
    private enum Layout {
        static let size = 80
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let command = 42
        static let index = 44
        static let payload = 48
        static let payloadCapacity = 32
    }

    private enum Command {
        static let read: UInt8 = 5
        static let keyByIndex: UInt8 = 8
        static let keyInfo: UInt8 = 9
    }

    private static let decodableSizes: Set<UInt32> = [1, 2, 4]

    /// Issues one SMC transaction. Returns false when the kernel call fails or the SMC
    /// itself reports a non-zero result — an unknown key lands here, which is exactly
    /// how this degrades on hardware whose key set differs.
    @discardableResult
    private func transact(key: UInt32, command: UInt8,
                          dataSize: UInt32 = 0, dataType: UInt32 = 0, index: UInt32 = 0) -> Bool {
        guard let request, let reply, connection != 0 else { return false }

        memset(request, 0, Layout.size)
        request.storeBytes(of: key, toByteOffset: Layout.key, as: UInt32.self)
        request.storeBytes(of: dataSize, toByteOffset: Layout.dataSize, as: UInt32.self)
        request.storeBytes(of: dataType, toByteOffset: Layout.dataType, as: UInt32.self)
        request.storeBytes(of: command, toByteOffset: Layout.command, as: UInt8.self)
        request.storeBytes(of: index, toByteOffset: Layout.index, as: UInt32.self)

        var replySize = Layout.size
        let kr = IOConnectCallStructMethod(connection, 2, request, Layout.size, reply, &replySize)
        guard kr == kIOReturnSuccess, replySize == Layout.size else { return false }
        return reply.loadUnaligned(fromByteOffset: Layout.result, as: UInt8.self) == 0
    }

    private func keyCount() -> UInt32? {
        guard let key = Self.fourCharCode("#KEY"), let info = keyInfo(for: key),
              transact(key: key, command: Command.read, dataSize: info.size, dataType: info.type),
              let reply, info.size == 4 else { return nil }
        // The directory size is one of the few big-endian payloads the SMC returns.
        return UInt32(bigEndian: reply.loadUnaligned(fromByteOffset: Layout.payload, as: UInt32.self))
    }

    private func keyName(at index: UInt32) -> String? {
        guard transact(key: 0, command: Command.keyByIndex, index: index), let reply else { return nil }
        return Self.string(from: reply.loadUnaligned(fromByteOffset: Layout.key, as: UInt32.self))
    }

    private func keyInfo(for key: UInt32) -> (size: UInt32, type: UInt32)? {
        guard transact(key: key, command: Command.keyInfo), let reply else { return nil }
        let size = reply.loadUnaligned(fromByteOffset: Layout.dataSize, as: UInt32.self)
        let type = reply.loadUnaligned(fromByteOffset: Layout.dataType, as: UInt32.self)
        guard size > 0, size <= UInt32(Layout.payloadCapacity) else { return nil }
        return (size, type)
    }

    private func read(key: UInt32, dataSize: UInt32, dataType: UInt32) -> Double? {
        guard transact(key: key, command: Command.read, dataSize: dataSize, dataType: dataType),
              let reply else { return nil }
        let payload = reply.advanced(by: Layout.payload)

        switch Self.string(from: dataType) {
        case "flt ":
            guard dataSize == 4 else { return nil }
            let value = Double(Float(bitPattern: UInt32(littleEndian:
                payload.loadUnaligned(as: UInt32.self))))
            return value.isFinite ? value : nil
        case "ui8 ", "ui8":
            guard dataSize == 1 else { return nil }
            return Double(payload.loadUnaligned(as: UInt8.self))
        case "ui16":
            guard dataSize == 2 else { return nil }
            return Double(UInt16(bigEndian: payload.loadUnaligned(as: UInt16.self)))
        case "sp78":
            // Intel-era signed 8.8 fixed point, kept so legacy CPU/GPU keys decode.
            guard dataSize == 2 else { return nil }
            return Double(Int16(bigEndian: payload.loadUnaligned(as: Int16.self))) / 256.0
        default:
            return nil
        }
    }

    private static func fourCharCode(_ name: String) -> UInt32? {
        let bytes = Array(name.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func string(from code: UInt32) -> String {
        let bytes = [UInt8(truncatingIfNeeded: code >> 24), UInt8(truncatingIfNeeded: code >> 16),
                     UInt8(truncatingIfNeeded: code >> 8), UInt8(truncatingIfNeeded: code)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }
}
