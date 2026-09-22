import Testing
import Foundation
@testable import AirStatKit

@Suite("Accessory batteries")
struct AccessoryBatteryTests {

    private func source(_ name: String, _ capacity: Int, max: Int = 100, id: String? = nil,
                        part: String? = nil, group: String? = nil, category: String? = nil,
                        charging: Bool? = nil, state: String? = nil) -> [String: Any] {
        var dict: [String: Any] = ["Name": name, "Current Capacity": capacity, "Max Capacity": max]
        dict["Accessory Identifier"] = id
        dict["Part Identifier"] = part
        dict["Group Identifier"] = group
        dict["Accessory Category"] = category
        dict["Is Charging"] = charging
        dict["Power Source State"] = state
        return dict
    }

    @Test("earbuds fold into one accessory named by the combined part, with the parts kept")
    func earbuds() {
        let sources = [
            source("AirPods Pro", 64, id: "a", part: "Left", group: "g1", category: "Headphones"),
            source("AirPods Pro", 71, id: "a", part: "Right", group: "g1", category: "Headphones"),
            source("AirPods Pro Case", 90, id: "a", part: "Case", group: "g1", category: "Audio Battery Case", charging: true),
            source("AirPods Pro", 64, id: "a", part: "Combined", group: "g1", category: "Headphones"),
        ]
        let list = PowerCollector.accessories(from: sources)
        #expect(list.count == 1)
        let pods = list[0]
        #expect(pods.name == "AirPods Pro")
        #expect(pods.percent == 64)
        #expect(pods.parts.map(\.name) == ["Left", "Right", "Case"])
        #expect(pods.parts.map(\.percent) == [64, 71, 90])
        #expect(pods.parts[2].isCharging)
        #expect(pods.isCharging == false)
    }

    @Test("a group with no combined part takes the lowest bud as its headline, not the case")
    func lowestBud() {
        let sources = [
            source("Buds", 40, id: "b", part: "Left", group: "g2"),
            source("Buds", 55, id: "b", part: "Right", group: "g2"),
            source("Buds Case", 12, id: "b", part: "Case", group: "g2", category: "Audio Battery Case"),
        ]
        let list = PowerCollector.accessories(from: sources)
        #expect(list.count == 1)
        #expect(list[0].percent == 40)
        #expect(list[0].name == "Buds")
    }

    @Test("a device by itself is one row, scaled to its own maximum and charging by state")
    func standalone() {
        let sources = [
            source("Magic Mouse", 23, id: "m", category: "Mouse"),
            source("Magic Keyboard", 5, max: 10, id: "k", category: "Keyboard", state: "AC Power"),
        ]
        let list = PowerCollector.accessories(from: sources)
        #expect(list.map(\.name) == ["Magic Mouse", "Magic Keyboard"])
        #expect(list.map(\.percent) == [23, 50])
        #expect(list[1].isCharging)
        #expect(list[0].parts.isEmpty)
    }

    @Test("sources without a name or a charge are skipped, and the internal battery is not an accessory")
    func skipsUnusable() {
        let sources: [[String: Any]] = [
            ["Name": "", "Current Capacity": 50],
            ["Current Capacity": 50],
            ["Name": "Nameless charge"],
            ["Name": "InternalBattery-0", "Current Capacity": 91, "Max Capacity": 100,
             "Type": "InternalBattery"],
            ["Name": "InternalBattery-0", "Current Capacity": 91, "Max Capacity": 100],
            ["Name": "Back-UPS", "Current Capacity": 80, "Max Capacity": 100, "Type": "UPS"],
        ]

        #expect(PowerCollector.accessories(from: sources).isEmpty)
        #expect(PowerCollector.accessories(from: []).isEmpty)
    }

    @Test("reading the live list does not fail on a Mac with nothing attached")
    func liveRead() {
        // No assertion on the contents: what is paired is the machine's business.
        _ = PowerCollector.readAccessories()
    }
}
