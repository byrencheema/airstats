import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

@Suite("Bluetooth collector assembly and readouts")
struct BluetoothTests {

    @Test("connected devices claim matching accessory batteries and sort ahead of disconnected pairings")
    func connectedAndDisconnectedOrdering() {
        let paired = [
            BluetoothCollector.RawPairedDevice(name: "Magic Keyboard", address: "AA:BB:CC:DD:EE:03",
                                               isConnected: false, majorClass: 5, minorClass: 0x10),
            BluetoothCollector.RawPairedDevice(name: "Studio Speaker", address: "AA:BB:CC:DD:EE:04",
                                               isConnected: true, majorClass: 4, minorClass: 5, rssi: -54),
            BluetoothCollector.RawPairedDevice(name: "Magic Mouse", address: "AA:BB:CC:DD:EE:02",
                                               isConnected: true, majorClass: 5, minorClass: 0x20),
        ]
        let accessories = [
            AccessoryBattery(id: "aa-bb-cc-dd-ee-02", name: "Magic Mouse", category: "Mouse",
                             transport: "Bluetooth", percent: 41, isCharging: false),
        ]

        let snapshot = BluetoothCollector.assemble(isPoweredOn: true, paired: paired,
                                                   accessories: accessories)
        #expect(snapshot.connectedCount == 2)
        #expect(snapshot.connectedDevices.map(\.name) == ["Magic Mouse", "Studio Speaker"])
        #expect(snapshot.disconnectedDevices.map(\.name) == ["Magic Keyboard"])

        let mouse = snapshot.connectedDevices[0]
        #expect(mouse.batteryPercent == 41)
        #expect(mouse.category == .mouse)

        // A connected speaker that publishes no battery stays connected with nil charge,
        // never a fabricated zero.
        let speaker = snapshot.connectedDevices[1]
        #expect(speaker.batteryPercent == nil)
        #expect(speaker.rssi == -54)
        #expect(speaker.category == .speaker)
    }

    @Test("multi-slot BLE ghost pairings collapse when disconnected and never steal a connected slot's battery")
    func deduplicatesStaleBLESlots() {
        let paired = [
            BluetoothCollector.RawPairedDevice(name: "Lucky65V2-3", address: "08:01:28:09:81:26", isConnected: false),
            BluetoothCollector.RawPairedDevice(name: "Lucky65V2-3", address: "08:01:03:70:24:75", isConnected: true),
            BluetoothCollector.RawPairedDevice(name: "Lucky65V2-3", address: "08:01:0A:33:13:C0", isConnected: false),
            BluetoothCollector.RawPairedDevice(name: "M650 Mouse", address: "13:05:AA:11:2B:53", isConnected: false),
            BluetoothCollector.RawPairedDevice(name: "M650 Mouse", address: "13:05:AA:11:26:F8", isConnected: false),
        ]
        let accessories = [
            AccessoryBattery(id: "76FCAA07-1630-F89B-2C19-ABC8291C5716", name: "Lucky65V2-3",
                             category: "Keyboard", transport: "Bluetooth LE", percent: 53),
        ]

        let snapshot = BluetoothCollector.assemble(isPoweredOn: true, paired: paired,
                                                   accessories: accessories)
        #expect(snapshot.connectedDevices.count == 1)
        #expect(snapshot.connectedDevices[0].address == "08:01:03:70:24:75")
        #expect(snapshot.connectedDevices[0].batteryPercent == 53)
        // The two disconnected Lucky65V2-3 slots vanish because that keyboard is already
        // connected, and the two disconnected M650 Mouse slots fold into one row.
        #expect(snapshot.disconnectedDevices.map(\.name) == ["M650 Mouse"])
    }

    @Test("unmatched Bluetooth power sources are kept, while wired USB power sources are excluded")
    func unmatchedPowerSourcesFilterByTransport() {
        let accessories = [
            AccessoryBattery(id: "airpods-uuid", name: "AirPods Pro", category: "Headphones",
                             transport: "Bluetooth LE", percent: 68, parts: [
                                .init(name: "Left", percent: 68, isCharging: false),
                                .init(name: "Right", percent: 74, isCharging: false),
                                .init(name: "Case", percent: 90, isCharging: true),
                             ]),
            AccessoryBattery(id: "usb-ups", name: "Desk UPS", category: nil,
                             transport: "USB", percent: 100),
        ]

        let snapshot = BluetoothCollector.assemble(isPoweredOn: true, paired: [],
                                                   accessories: accessories)
        #expect(snapshot.devices.map(\.name) == ["AirPods Pro"])
        #expect(snapshot.devices[0].isConnected)
        #expect(snapshot.devices[0].parts.count == 3)
    }

    @Test("turning the Bluetooth radio off marks every pairing disconnected and drops live charges")
    func poweredOffState() {
        let paired = [
            BluetoothCollector.RawPairedDevice(name: "Magic Mouse", address: "AA:BB:CC:DD:EE:02",
                                               isConnected: true, fallbackPercent: 80),
        ]
        let accessories = [
            AccessoryBattery(id: "AA:BB:CC:DD:EE:02", name: "Magic Mouse", percent: 80),
        ]

        let snapshot = BluetoothCollector.assemble(isPoweredOn: false, paired: paired,
                                                   accessories: accessories)
        #expect(!snapshot.isPoweredOn)
        #expect(snapshot.connectedCount == 0)
        #expect(snapshot.disconnectedDevices.count == 1)
        #expect(snapshot.disconnectedDevices[0].batteryPercent == nil)
        #expect(snapshot.lowestBatteryPercent() == nil)
    }

    @Test("product name beats a combo BLE HID chip's mislabelled first usage page")
    func categoryInferenceHandlesBLEComboChips() {
        // Observed on RivieraWaves BLE mice that advertise Keyboard Usage Page first
        // for macro keys, causing IOPowerSources to tag them "Keyboard".
        let mouse = BluetoothCollector.inferCategory(majorClass: 0, minorClass: 0,
                                                     name: "X11mouse1",
                                                     accessoryCategory: "Keyboard")
        #expect(mouse == .mouse)

        let keyboard = BluetoothCollector.inferCategory(majorClass: 0, minorClass: 0,
                                                        name: "BT5.0 KB",
                                                        accessoryCategory: nil)
        #expect(keyboard == .keyboard)
    }

    @Test("lowest discharging battery ignores charging accessories and charging earbud cases")
    func lowestDischargingBattery() {
        let snapshot = SnapshotFixtures.bluetooth(mousePercent: 12, charging: true)
        // Overall lowest includes the charging Magic Mouse at 12%.
        #expect(snapshot.lowestBatteryPercent(dischargingOnly: false) == 12)
        // Discharging-only skips the charging Magic Mouse and the charging AirPods case,
        // picking the Left AirPod at 64%.
        let discharging = snapshot.lowestBatteryDevice(dischargingOnly: true)
        #expect(discharging?.device.name == "AirPods Pro")
        #expect(discharging?.percent == 64)
    }

    @Test("menu bar readouts report connected count, radio off, and lowest battery")
    func menuBarRendering() {
        var settings = Settings()
        settings.menuBar.items = [
            MenuBarItemConfig(metric: .bluetoothDevices, style: .text, showsCaption: true),
            MenuBarItemConfig(metric: .bluetoothBattery, style: .iconAndText, showsCaption: false),
        ]

        let nominal = MenuBarRenderModel(snapshot: SnapshotFixtures.nominal,
                                         history: MetricHistory(),
                                         settings: settings, isStale: false)
        #expect(nominal.items[0].primary.valueText == "2")
        #expect(!nominal.items[0].isUnavailable)
        #expect(nominal.items[1].primary.valueText == "23%")
        #expect(!nominal.items[1].isUnavailable)

        var offSnapshot = SnapshotFixtures.nominal
        offSnapshot.bluetooth = .value(BluetoothSnapshot(isPoweredOn: false, devices: []))
        let offModel = MenuBarRenderModel(snapshot: offSnapshot,
                                          history: MetricHistory(),
                                          settings: settings, isStale: false)
        #expect(offModel.items[0].primary.valueText == "Off")
        #expect(!offModel.items[0].isUnavailable)
        #expect(offModel.items[1].isUnavailable)
    }

    @Test("low Bluetooth battery alert names the discharging peripheral")
    func notificationNamesTheDevice() {
        var evaluator = ThresholdEvaluator()
        let rule = ThresholdRule(metric: .bluetoothBatteryLow, threshold: 20,
                                 isEnabled: true, sustainedFor: 0)
        var snapshot = SnapshotFixtures.nominal
        snapshot.bluetooth = .value(SnapshotFixtures.bluetooth(mousePercent: 14, charging: false))

        let readings = ThresholdEvaluator.readings(from: snapshot)
        #expect(readings[.bluetoothBatteryLow] == 14)

        let alerts = evaluator.alerts(for: [rule], readings: readings, now: Date())
        #expect(alerts.count == 1)
        #expect(alerts[0].body(in: snapshot) == "Magic Mouse is at 14%, below your 20% threshold.")
    }

    @Test("live Bluetooth collection satisfies bounded battery invariants")
    func liveCollectorContract() {
        let collector = BluetoothCollector()
        collector.start()
        defer { collector.stop() }
        let state = collector.collect(context: SampleContext(elapsed: 0, isFirstSample: true,
                                                             activity: .panel))
        if let bt = state.value {
            for device in bt.devices {
                #expect(!device.name.isEmpty)
                if let pct = device.batteryPercent {
                    #expect(pct >= 0 && pct <= 100)
                    #expect(device.isConnected, "disconnected device must not carry a battery reading")
                }
            }
        }
    }
}
