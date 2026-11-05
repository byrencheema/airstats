import Testing
import Foundation
@testable import AirStatKit

@Suite("The panel's summary line speaks only when something is wrong, and names the cause")
struct PanelInsightTests {

    private let formatter = MetricFormatter()
    private let idleCPU = [Float](repeating: 0.2, count: PanelInsight.cpuWindow)
    private let busyCPU = [Float](repeating: 0.95, count: PanelInsight.cpuWindow)

    private func insight(_ snapshot: SystemSnapshot, cpu: [Float]? = nil) -> PanelInsight? {
        PanelInsight.make(snapshot: snapshot, recentCPU: cpu ?? idleCPU, formatter: formatter)
    }

    @Test("a healthy Mac gets no line")
    func nominalIsSilent() {
        #expect(insight(SnapshotFixtures.nominal) == nil)
        #expect(insight(SnapshotFixtures.charging) == nil)
    }

    @Test("heat outranks everything else, and names the busiest app rather than kernel_task")
    func heatComesFirst() throws {
        let line = try #require(insight(SnapshotFixtures.underLoad, cpu: busyCPU))
        #expect(line.kind == .thermal)
        #expect(line.text.hasPrefix("Running hot at 99"))
        #expect(line.text.contains("Xcode"))
        #expect(!line.text.contains("kernel_task"))
    }

    @Test("memory pressure names the biggest process and its footprint")
    func memoryNamesTheBiggestProcess() throws {
        var snapshot = SnapshotFixtures.nominal
        snapshot.memory = .value(SnapshotFixtures.memory(usedFraction: 0.94, pressure: 0.88))
        let line = try #require(insight(snapshot))
        #expect(line.kind == .memory)
        #expect(line.text == "Memory pressure 88%, Xcode \(formatter.memory(UInt64(4_284_432_384)))")
    }

    @Test("a low battery speaks only while it is unplugged")
    func lowBatteryNeedsToBeUnplugged() throws {
        var snapshot = SnapshotFixtures.nominal
        snapshot.power = .value(SnapshotFixtures.power(percent: 8, charging: false))
        let line = try #require(insight(snapshot))
        #expect(line.kind == .battery)
        #expect(line.text.hasPrefix("Battery 8%, "))
        #expect(line.text.hasSuffix(" left"))

        snapshot.power = .value(SnapshotFixtures.power(percent: 8, charging: true))
        #expect(insight(snapshot) == nil)
    }

    @Test("CPU is judged on the recent average, so one busy sample says nothing")
    func cpuNeedsASustainedAverage() throws {
        let snapshot = SnapshotFixtures.nominal
        #expect(insight(snapshot, cpu: idleCPU + [1.0]) == nil)
        #expect(insight(snapshot, cpu: Array(busyCPU.prefix(PanelInsight.cpuWindow - 1))) == nil,
                "too little history to call it sustained")
        let line = try #require(insight(snapshot, cpu: busyCPU))
        #expect(line.kind == .cpu)
        #expect(line.text.hasPrefix("CPU 95%, Xcode"))
    }

    @Test("a nearly full disk says how much is left")
    func fullDisk() throws {
        var snapshot = SnapshotFixtures.nominal
        // The fixture counts 42 GB of purgeable space as available, as macOS does.
        snapshot.disk = .value(SnapshotFixtures.disk(read: 0, write: 0, usedFraction: 0.995))
        let line = try #require(insight(snapshot))
        #expect(line.kind == .disk)
        #expect(line.text.hasPrefix("Disk almost full, "))
        #expect(line.text.hasSuffix(" free"))
    }

    @Test("an unavailable source is never treated as a reading")
    func failuresAreSilent() {
        #expect(insight(SnapshotFixtures.degraded) == nil)
    }
}
