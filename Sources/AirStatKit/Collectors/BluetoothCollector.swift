import Foundation
import IOBluetooth
import IOKit

/// Paired and connected Bluetooth peripherals and their battery levels.
///
/// Concurrency: every method runs on `SamplingCore`'s serial queue.
///
/// Two system layers are combined because neither has the whole picture on macOS:
/// `IOBluetooth` knows the radio's power state and every paired Classic and BLE
/// peripheral with its live connection state, without triggering a CoreBluetooth TCC
/// prompt; `IOPowerSources` (`PowerCollector.readAccessories()`) knows the battery
/// percentages of connected HID and audio accessories, including Left/Right/Case
/// splits for earbuds. Joining them lets connected devices without a battery service
/// still appear as connected, and keeps disconnected pairings from showing stale or
/// fabricated charges.
public final class BluetoothCollector: MetricSource {
    public typealias Output = BluetoothSnapshot

    public let identifier: CollectorID = .bluetooth
    public let preferredInterval: TimeInterval = 5.0

    struct RawPairedDevice: Sendable, Equatable {
        var name: String
        var address: String?
        var isConnected: Bool
        var majorClass: UInt32
        var minorClass: UInt32
        var rssi: Int?
        var fallbackPercent: Double?
        var fallbackParts: [AccessoryBattery.Part]

        init(name: String, address: String? = nil, isConnected: Bool,
             majorClass: UInt32 = 0, minorClass: UInt32 = 0, rssi: Int? = nil,
             fallbackPercent: Double? = nil, fallbackParts: [AccessoryBattery.Part] = []) {
            self.name = name
            self.address = address
            self.isConnected = isConnected
            self.majorClass = majorClass
            self.minorClass = minorClass
            self.rssi = rssi
            self.fallbackPercent = fallbackPercent
            self.fallbackParts = fallbackParts
        }
    }

    public init() {}

    public func collect(context: SampleContext) -> MetricState<BluetoothSnapshot> {
        guard let controller = IOBluetoothHostController.default() else {
            return .failure(.unsupported("No Bluetooth controller on this Mac"))
        }
        let isPoweredOn = controller.powerState == kBluetoothHCIPowerStateON
        let rawPaired = Self.readPairedDevices(isPoweredOn: isPoweredOn)
        let accessories = isPoweredOn ? PowerCollector.readAccessories() : []
        let hidCategories = isPoweredOn ? Self.readHIDCategories() : [:]
        return .value(Self.assemble(isPoweredOn: isPoweredOn,
                                    paired: rawPaired,
                                    accessories: accessories,
                                    hidCategories: hidCategories))
    }

    // MARK: Live reading

    /// Primary HID usage of connected Bluetooth HID services, keyed by lowercased
    /// product name. QMK/VIA keyboards append MouseKeys to `DeviceUsagePairs`, which
    /// makes `IOPowerSources` tag them `"Mouse"`; `IOHIDDevice`'s `PrimaryUsage` still
    /// names the device's real primary descriptor (6 = keyboard, 2 = mouse).
    private static func readHIDCategories() -> [String: BluetoothDeviceCategory] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOHIDDevice"),
                                           &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var result: [String: BluetoothDeviceCategory] = [:]
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            func prop(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(entry, key as CFString,
                                                kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let transport = prop("Transport") as? String,
                  transport.localizedCaseInsensitiveContains("bluetooth"),
                  let product = prop("Product") as? String,
                  let page = (prop("PrimaryUsagePage") as? NSNumber)?.intValue,
                  let usage = (prop("PrimaryUsage") as? NSNumber)?.intValue,
                  page == 1
            else { continue }
            let key = canonicalName(product)
            switch usage {
            case 2: result[key] = .mouse
            case 4, 5: result[key] = .gamepad
            case 6: result[key] = .keyboard
            default: break
            }
        }
        return result
    }

    private static func readPairedDevices(isPoweredOn: Bool) -> [RawPairedDevice] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return []
        }
        return devices.compactMap { device in
            let rawName = device.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !rawName.isEmpty else { return nil }

            let connected = isPoweredOn && device.isConnected()
            let address = normalizeAddress(device.addressString)

            // `rawRSSI()` returns 0 or 127 (the HCI "unavailable" sentinel) on BLE
            // and idle links; real dBm readings sit strictly below zero.
            var rssi: Int?
            if connected {
                let raw = Int(device.rawRSSI())
                if raw < 0, raw >= -120 { rssi = raw }
            }

            let fallback = connected ? readFallbackBattery(from: device) : (nil, [])
            return RawPairedDevice(
                name: rawName,
                address: address,
                isConnected: connected,
                majorClass: UInt32(device.deviceClassMajor),
                minorClass: UInt32(device.deviceClassMinor),
                rssi: rssi,
                fallbackPercent: fallback.0,
                fallbackParts: fallback.1
            )
        }
    }

    /// Private `IOBluetoothDevice` battery properties populated for some Classic
    /// Bluetooth headsets that never register an `IOPowerSources` entry.
    ///
    /// Unpopulated ivars read back as 0 on BLE and non-Apple peripherals (verified
    /// against devices at 53% and 93% in `IOPowerSources`), so 0 is treated as
    /// absent rather than as a flat battery.
    private static func readFallbackBattery(
        from device: IOBluetoothDevice
    ) -> (Double?, [AccessoryBattery.Part]) {
        func kvcPercent(_ key: String) -> Double? {
            let selector = NSSelectorFromString(key)
            guard device.responds(to: selector),
                  let value = (device.value(forKey: key) as? NSNumber)?.doubleValue,
                  value > 0, value <= 100
            else { return nil }
            return value
        }

        var parts: [AccessoryBattery.Part] = []
        if let left = kvcPercent("batteryPercentLeft") {
            parts.append(.init(name: "Left", percent: left, isCharging: false))
        }
        if let right = kvcPercent("batteryPercentRight") {
            parts.append(.init(name: "Right", percent: right, isCharging: false))
        }
        if let box = kvcPercent("batteryPercentCase") {
            parts.append(.init(name: "Case", percent: box, isCharging: false))
        }
        if !parts.isEmpty {
            let buds = parts.filter { $0.name != "Case" }
            let headline = kvcPercent("batteryPercentCombined")
                ?? (buds.isEmpty ? parts : buds).map(\.percent).min()
            return (headline, parts)
        }
        let single = kvcPercent("batteryPercentSingle") ?? kvcPercent("batteryPercentCombined")
        return (single, [])
    }

    // MARK: Assembly

    static func assemble(isPoweredOn: Bool,
                         paired: [RawPairedDevice],
                         accessories: [AccessoryBattery],
                         hidCategories: [String: BluetoothDeviceCategory] = [:]) -> BluetoothSnapshot {
        var remainingAccessories = isPoweredOn ? accessories : []

        func claimAccessory(for device: RawPairedDevice) -> AccessoryBattery? {
            guard device.isConnected else { return nil }
            if let address = device.address,
               let index = remainingAccessories.firstIndex(where: {
                   normalizeAddress($0.id) == address
               }) {
                return remainingAccessories.remove(at: index)
            }
            let target = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = remainingAccessories.firstIndex(where: {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(target) == .orderedSame
            }) {
                return remainingAccessories.remove(at: index)
            }
            return nil
        }

        var connected: [BluetoothDevice] = []
        var disconnectedCandidates: [RawPairedDevice] = []

        for raw in paired {
            if raw.isConnected && isPoweredOn {
                let accessory = claimAccessory(for: raw)
                let category = inferCategory(majorClass: raw.majorClass,
                                             minorClass: raw.minorClass,
                                             name: raw.name,
                                             hidCategory: hidCategories[canonicalName(raw.name)],
                                             accessoryCategory: accessory?.category)
                let id = raw.address ?? accessory?.id ?? raw.name
                connected.append(BluetoothDevice(
                    id: id,
                    name: raw.name,
                    address: raw.address,
                    category: category,
                    isConnected: true,
                    batteryPercent: accessory?.percent ?? raw.fallbackPercent,
                    isCharging: accessory?.isCharging ?? false,
                    parts: accessory?.parts ?? raw.fallbackParts,
                    rssi: raw.rssi
                ))
            } else {
                disconnectedCandidates.append(raw)
            }
        }

        // Apple H1/H2 and certain BLE accessories can publish a Bluetooth power
        // source without appearing in `IOBluetoothDevice.pairedDevices()`. Wired-only
        // USB power sources are left out so a USB UPS or controller is not called
        // Bluetooth.
        for unmatched in remainingAccessories where isBluetoothTransport(unmatched.transport) {
            let category = inferCategory(majorClass: 0, minorClass: 0,
                                         name: unmatched.name,
                                         hidCategory: hidCategories[canonicalName(unmatched.name)],
                                         accessoryCategory: unmatched.category)
            connected.append(BluetoothDevice(
                id: normalizeAddress(unmatched.id) ?? unmatched.id,
                name: unmatched.name,
                address: normalizeAddress(unmatched.id),
                category: category,
                isConnected: true,
                batteryPercent: unmatched.percent,
                isCharging: unmatched.isCharging,
                parts: unmatched.parts
            ))
        }

        // Multi-slot BLE keyboards and mice rotate one address byte per host slot or
        // re-pairing and leave every old record in `bluetoothd` under the same name
        // (observed: four "Lucky65V2-3" and two "M650 Mouse" records on one Mac).
        // Connected links are never collapsed — two active speakers with one name are
        // two devices — but stale disconnected duplicates are folded to one row, and
        // suppressed altogether when a device of that name is already connected.
        var seenNames = Set(connected.map { canonicalName($0.name) })
        var disconnected: [BluetoothDevice] = []
        for raw in disconnectedCandidates {
            let key = canonicalName(raw.name)
            guard seenNames.insert(key).inserted else { continue }
            let category = inferCategory(majorClass: raw.majorClass,
                                         minorClass: raw.minorClass,
                                         name: raw.name,
                                         accessoryCategory: nil)
            disconnected.append(BluetoothDevice(
                id: raw.address ?? raw.name,
                name: raw.name,
                address: raw.address,
                category: category,
                isConnected: false
            ))
        }

        let byName: (BluetoothDevice, BluetoothDevice) -> Bool = { a, b in
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            if order != .orderedSame { return order == .orderedAscending }
            return a.id < b.id
        }
        connected.sort(by: byName)
        disconnected.sort(by: byName)

        return BluetoothSnapshot(isPoweredOn: isPoweredOn,
                                 devices: connected + disconnected)
    }

    // MARK: Classification & normalisation

    static func normalizeAddress(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: ":")
            .uppercased()
        let parts = cleaned.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6,
              parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) })
        else { return nil }
        return cleaned
    }

    private static func canonicalName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isBluetoothTransport(_ transport: String?) -> Bool {
        guard let transport, !transport.isEmpty else { return true }
        return transport.localizedCaseInsensitiveContains("bluetooth")
    }

    static func inferCategory(majorClass: UInt32,
                              minorClass: UInt32,
                              name: String,
                              hidCategory: BluetoothDeviceCategory? = nil,
                              accessoryCategory: String?) -> BluetoothDeviceCategory {
        // Classic Bluetooth carries a Bluetooth SIG Class of Device, which is
        // authoritative whenever the peripheral populated it.
        switch majorClass {
        case 1: return .computer
        case 2: return .phone
        case 4: // Audio / Video
            switch minorClass {
            case 4: return .microphone
            case 5, 8, 10: return .speaker
            case 1, 2, 6:
                return nameSuggestsSpeaker(name) ? .speaker : .headphones
            default:
                return nameSuggestsSpeaker(name) ? .speaker : .headphones
            }
        case 5: // Peripheral (HID)
            let sub = minorClass & 0x0F
            let role = minorClass & 0x30
            if sub == 1 || sub == 2 { return .gamepad }
            if sub == 5 { return .trackpad }
            if role == 0x10 || role == 0x30 { return .keyboard }
            if role == 0x20 {
                return name.localizedCaseInsensitiveContains("trackpad") ? .trackpad : .mouse
            }
        case 7: return .watch
        default: break
        }

        // BLE peripherals report majorClass == 0, and combo BLE HID chips routinely
        // put Keyboard Usage first on mice and MouseKeys last on QMK keyboards, which
        // makes `IOPowerSources` flip their categories. Unambiguous words in the
        // product name win first, then `IOHIDDevice`'s primary usage, then powerd's tag.
        if let fromName = categoryFromName(name) { return fromName }
        if let hidCategory { return hidCategory }
        if let accessoryCategory, let fromAccessory = categoryFromAccessory(accessoryCategory) {
            return fromAccessory
        }
        return .other
    }

    private static func nameSuggestsSpeaker(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("speaker") || lower.contains("soundbar")
    }

    private static func categoryFromName(_ name: String) -> BluetoothDeviceCategory? {
        let lower = name.lowercased()
        if lower.contains("trackpad") { return .trackpad }
        if lower.contains("mouse") { return .mouse }
        if lower.contains("keyboard") || lower.hasSuffix(" kb") || lower.contains(" kb ") {
            return .keyboard
        }
        if lower.contains("airpods") || lower.contains("earbuds") || lower.contains("freebuds")
            || lower.contains("buds") || lower.contains("headphones") || lower.contains("headset") {
            return .headphones
        }
        if lower.contains("speaker") || lower.contains("soundbar") { return .speaker }
        if lower.contains("controller") || lower.contains("gamepad") || lower.contains("dualsense")
            || lower.contains("dualshock") || lower.contains("joy-con") {
            return .gamepad
        }
        if lower.contains("watch") { return .watch }
        if lower.contains("microphone") { return .microphone }
        return nil
    }

    private static func categoryFromAccessory(_ category: String) -> BluetoothDeviceCategory? {
        let lower = category.lowercased()
        if lower.contains("headphone") || lower.contains("earpod") || lower.contains("beats")
            || lower.contains("audio battery case") || lower.contains("headset") {
            return .headphones
        }
        if lower.contains("speaker") { return .speaker }
        if lower.contains("trackpad") { return .trackpad }
        if lower.contains("mouse") { return .mouse }
        if lower.contains("keyboard") { return .keyboard }
        if lower.contains("controller") || lower.contains("gamepad") { return .gamepad }
        if lower.contains("watch") { return .watch }
        return nil
    }
}
