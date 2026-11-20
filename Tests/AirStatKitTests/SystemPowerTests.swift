import Testing
import Foundation
@testable import AirStatKit

@Suite("System power")
struct SystemPowerTests {

    private func telemetry(_ input: Int, _ battery: Int) -> [String: Any] {
        ["SystemPowerIn": NSNumber(value: input), "BatteryPower": NSNumber(value: battery), "SystemLoad": NSNumber(value: 99_999)]
    }

    @Test("on battery the draw is the battery's measured output")
    func onBattery() {
        let watts = PowerCollector.systemWatts(pluggedIn: false, batteryWatts: -11.7, telemetry: nil)
        #expect(watts == 11.7)
    }

    @Test("a battery reading that is not discharging gives no draw while unplugged")
    func unpluggedNotDischarging() {
        #expect(PowerCollector.systemWatts(pluggedIn: false, batteryWatts: 0, telemetry: nil) == nil)
        #expect(PowerCollector.systemWatts(pluggedIn: false, batteryWatts: nil, telemetry: nil) == nil)
    }

    @Test("on the charger the draw is adapter input minus what goes into the battery")
    func charging() {
        let watts = PowerCollector.systemWatts(pluggedIn: true, batteryWatts: 37.6, telemetry: telemetry(58_553, 35_319))
        #expect(watts == 23.234)
    }

    @Test("a full battery on the charger leaves the whole input as the draw")
    func fullOnCharger() {
        let watts = PowerCollector.systemWatts(pluggedIn: true, batteryWatts: 0, telemetry: telemetry(14_200, 0))
        #expect(watts == 14.2)
    }

    @Test("the battery topping up a heavy load on the charger adds to the draw")
    func chargerPlusBattery() {
        let watts = PowerCollector.systemWatts(pluggedIn: true, batteryWatts: -8, telemetry: telemetry(60_000, -8_000))
        #expect(watts == 68)
    }

    @Test("no adapter input or missing telemetry gives no draw rather than a guess")
    func missing() {
        #expect(PowerCollector.systemWatts(pluggedIn: true, batteryWatts: 5, telemetry: nil) == nil)
        #expect(PowerCollector.systemWatts(pluggedIn: true, batteryWatts: 5, telemetry: telemetry(0, 0)) == nil)
    }
}
