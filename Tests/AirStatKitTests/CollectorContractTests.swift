import Testing
import Foundation
@testable import AirStatKit

/// Contract tests that every collector must satisfy, run against the REAL collectors
/// on the real machine. These are the guards that stop a future change from
/// reintroducing the failure mode this app exists to avoid: showing a number the app
/// is not actually sure about.
@Suite("Collector contract", .serialized)
struct CollectorContractTests {

    /// Runs a collector the way `SamplingCore` does.
    private func sample<S: MetricSource>(_ source: S, times: Int = 3,
                                         interval: TimeInterval = 0.15) -> [MetricState<S.Output>] {
        source.start()
        defer { source.stop() }
        var results: [MetricState<S.Output>] = []
        var previous: ContinuousClock.Instant?
        for index in 0..<times {
            if index > 0 { Thread.sleep(forTimeInterval: interval) }
            let now = Monotonic.now
            let elapsed = previous.map { Monotonic.seconds(since: $0) } ?? 0
            previous = now
            results.append(source.collect(context: SampleContext(
                elapsed: elapsed, isFirstSample: index == 0, activity: .panel)))
        }
        return results
    }

    @Test("no collector reports a rate on its very first sample")
    func firstSampleHasNoFabricatedRate() {
        // A rate needs two counter readings. Anything a collector emits on the first
        // call is either honestly absent or a "since boot" average masquerading as a
        // current rate — the latter is the bug this guards against.
        let network = NetworkCollector()
        network.start()
        defer { network.stop() }
        let first = network.collect(context: SampleContext(elapsed: 0, isFirstSample: true, activity: .panel))
        if let value = first.value {
            #expect(value.uploadBytesPerSecond == 0)
            #expect(value.downloadBytesPerSecond == 0)
        }

        let disk = DiskCollector()
        disk.start()
        defer { disk.stop() }
        let firstDisk = disk.collect(context: SampleContext(elapsed: 0, isFirstSample: true, activity: .panel))
        if let value = firstDisk.value {
            #expect(value.readBytesPerSecond == 0)
            #expect(value.writeBytesPerSecond == 0)
        }
    }

    /// A collector that needs two samples to difference against has nothing wrong with
    /// it on the first one. The distinction is load-bearing in the UI: a pending module
    /// holds its full height open because a reading is coming, and a failed one
    /// collapses to a line. Reporting the baseline as a failure made the desktop widget open a
    /// row short and jump a tick later.
    @Test("a collector still taking its baseline is pending, not failed")
    func baselineSamplesArePending() {
        let first = SampleContext(elapsed: 0, isFirstSample: true, activity: .panel)

        if case .failure(let failure) = CPUCollector().collect(context: first) {
            #expect(failure == .pending, "CPU reported \(failure) while taking its baseline")
        }
        if case .failure(let failure) = ProcessCollector().collect(context: first) {
            #expect(failure == .pending, "processes reported \(failure) while taking its baseline")
        }
    }

    @Test("a zero elapsed time never produces an infinite or NaN rate")
    func zeroElapsedIsSafe() {
        // Timer coalescing and a manual refresh can genuinely deliver two samples in
        // the same instant. Dividing by that elapsed time must not escape into the UI.
        for _ in 0..<3 {
            let network = NetworkCollector()
            network.start()
            defer { network.stop() }
            _ = network.collect(context: SampleContext(elapsed: 0, isFirstSample: true, activity: .panel))
            let second = network.collect(context: SampleContext(elapsed: 0, isFirstSample: false, activity: .panel))
            if let value = second.value {
                #expect(value.uploadBytesPerSecond.isFinite)
                #expect(value.downloadBytesPerSecond.isFinite)
                #expect(value.uploadBytesPerSecond >= 0)
                #expect(value.downloadBytesPerSecond >= 0)
            }
        }
    }

    @Test("CPU load fractions stay within 0...1 and sum coherently")
    func cpuFractionsAreBounded() {
        let states = sample(CPUCollector())
        guard let cpu = states.last?.value else { return }
        #expect(cpu.total.busy >= 0 && cpu.total.busy <= 1)
        #expect(cpu.total.user >= 0 && cpu.total.system >= 0 && cpu.total.idle >= 0)
        let sum = cpu.total.user + cpu.total.system + cpu.total.idle + cpu.total.nice
        #expect(abs(sum - 1) < 0.02, "load fractions should sum to ~1, got \(sum)")
        for (index, core) in cpu.perCore.enumerated() {
            #expect(core.busy >= 0 && core.busy <= 1, "core \(index) busy=\(core.busy)")
        }
        #expect(cpu.perCore.count == ProcessInfo.processInfo.activeProcessorCount)
    }

    @Test("memory breakdown equals its own headline")
    func memoryPartsSumToUsed() {
        let states = sample(MemoryCollector())
        guard let memory = states.last?.value else { return }
        let parts = memory.appBytes + memory.wiredBytes + memory.compressedBytes
        // Exact equality: usedBytes is defined as this sum, computed from one sample.
        #expect(parts == memory.usedBytes,
                "app+wired+compressed=\(parts) must equal usedBytes=\(memory.usedBytes)")
        #expect(memory.usedBytes <= memory.totalBytes)
        #expect(memory.usedFraction >= 0 && memory.usedFraction <= 1)
        #expect(memory.pressureFraction >= 0 && memory.pressureFraction <= 1)
    }

    @Test("every volume's capacity figures are internally consistent")
    func volumeInvariants() {
        let states = sample(DiskCollector(), times: 2)
        guard let disk = states.last?.value else { return }
        for volume in disk.volumes {
            #expect(volume.freeBytes <= volume.totalBytes,
                    "\(volume.name): free exceeds total")
            #expect(volume.availableBytes <= volume.totalBytes,
                    "\(volume.name): available exceeds total")
            // Available includes purgeable space the OS would reclaim, so it is never
            // smaller than the strict free figure.
            #expect(volume.freeBytes <= volume.availableBytes,
                    "\(volume.name): available(\(volume.availableBytes)) < free(\(volume.freeBytes))")
            #expect(volume.usedBytes + volume.freeBytes == volume.totalBytes,
                    "\(volume.name): used + free must equal total")
            #expect(volume.usedFraction >= 0 && volume.usedFraction <= 1)
        }
    }

    @Test("battery health agrees with the capacities reported beside it")
    func batteryHealthIsConsistent() {
        let states = sample(PowerCollector(), times: 2)
        guard let power = states.last?.value else { return }
        guard power.hasBattery else { return }

        if let percentage = power.percentage {
            #expect(percentage >= 0 && percentage <= 100)
        }
        // If the collector reports both a health figure and the capacities it is
        // derived from, they must tell the same story.
        if let health = power.healthPercent,
           let maxCapacity = power.maxCapacitymAh,
           let design = power.designCapacitymAh, design > 0 {
            let derived = Double(maxCapacity) / Double(design) * 100
            #expect(abs(derived - health) < 1.5,
                    "healthPercent=\(health) but maxCapacity/design=\(derived)")
        }
        // Discharging must not report a positive current draw, and vice versa.
        if let amperage = power.amperage, !power.isCharging, power.isPluggedIn == false {
            #expect(amperage <= 0, "discharging but amperage is positive: \(amperage)")
        }
    }

    @Test("a fan never reports a speed below its own stated minimum without being stopped")
    func fanReadingsAreCoherent() {
        let states = sample(ThermalCollector(), times: 2)
        guard let thermal = states.last?.value else { return }
        for fan in thermal.fans {
            #expect(fan.currentRPM >= 0)
            if let minimum = fan.minRPM, fan.currentRPM > 0 {
                #expect(fan.currentRPM >= minimum - 1,
                        "fan \(fan.id) spinning at \(fan.currentRPM) below stated min \(minimum)")
            }
            // The dial must never be driven outside 0...1, including when stopped.
            if let load = fan.loadFraction {
                #expect(load >= 0 && load <= 1, "fan \(fan.id) loadFraction=\(load)")
            }
        }
        for sensor in thermal.sensors {
            #expect(sensor.celsius > -20 && sensor.celsius < 130,
                    "\(sensor.id) implausible: \(sensor.celsius)C")
        }
    }

    @Test("process CPU is per-core-relative and memory is real")
    func processRowsArePlausible() {
        let states = sample(ProcessCollector(), times: 2, interval: 0.3)
        guard let processes = states.last?.value else { return }
        #expect(processes.totalProcessCount > 0)
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        for row in processes.processes {
            #expect(row.pid > 0)
            #expect(!row.name.isEmpty)
            #expect(row.cpuPercent >= 0)
            // Percent of one core, so the ceiling is cores*100 with headroom for
            // sampling jitter — but it must not be wildly beyond physical possibility.
            #expect(row.cpuPercent <= cores * 100 * 1.5,
                    "\(row.name) cpu=\(row.cpuPercent)% exceeds \(cores) cores")
        }
        // Sorted descending by CPU, so the panel can take a prefix.
        let cpuValues = processes.processes.map(\.cpuPercent)
        #expect(cpuValues == cpuValues.sorted(by: >), "processes must be sorted by CPU descending")
    }

    @Test("system info is static across samples and uptime advances")
    func systemInfoIsStable() {
        let collector = SystemInfoCollector()
        collector.start()
        defer { collector.stop() }
        let first = collector.collect(context: SampleContext(elapsed: 0, isFirstSample: true, activity: .panel))
        Thread.sleep(forTimeInterval: 1.1)
        let second = collector.collect(context: SampleContext(elapsed: 1.1, isFirstSample: false, activity: .panel))

        guard let a = first.value, let b = second.value else { return }
        #expect(a.modelIdentifier == b.modelIdentifier)
        #expect(a.chipName == b.chipName)
        #expect(a.totalMemoryBytes == b.totalMemoryBytes)
        #expect(a.logicalCores == b.logicalCores)
        #expect(b.uptime > a.uptime, "uptime must advance between samples")
        #expect(a.logicalCores == ProcessInfo.processInfo.activeProcessorCount)
        #expect(a.totalMemoryBytes == ProcessInfo.processInfo.physicalMemory)
    }

    @Test("an unsupported source retires and is never sampled again")
    func unsupportedSourcesRetire() {
        // The scheduler must stop calling a collector that reports permanent
        // unsupport, or a Mac without a sensor pays for the failed lookup forever.
        final class AlwaysUnsupported: MetricSource {
            typealias Output = CPUSnapshot
            let identifier = CollectorID.cpu
            let preferredInterval: TimeInterval = 0
            private(set) var callCount = 0
            func collect(context: SampleContext) -> MetricState<CPUSnapshot> {
                callCount += 1
                return .failure(.unsupported("not on this hardware"))
            }
        }
        let source = AlwaysUnsupported()
        let slot = SourceSlot(source)
        for _ in 0..<5 {
            slot.tick(now: Monotonic.now, activity: .panel, isEnabled: true,
                      baseInterval: 0, didWakeFromSleep: false)
        }
        #expect(source.callCount == 1, "retired source was sampled \(source.callCount) times")
        #expect(slot.isRetired)
    }

    @Test("a disabled source is never sampled")
    func disabledSourcesAreSkipped() {
        final class Counting: MetricSource {
            typealias Output = CPUSnapshot
            let identifier = CollectorID.cpu
            let preferredInterval: TimeInterval = 0
            private(set) var callCount = 0
            func collect(context: SampleContext) -> MetricState<CPUSnapshot> {
                callCount += 1
                return .value(CPUSnapshot())
            }
        }
        let source = Counting()
        let slot = SourceSlot(source)
        for _ in 0..<5 {
            slot.tick(now: Monotonic.now, activity: .panel, isEnabled: false,
                      baseInterval: 0, didWakeFromSleep: false)
        }
        #expect(source.callCount == 0)
    }

    @Test("a suspended activity level stops all sampling")
    func suspendedActivityStopsSampling() {
        final class Counting: MetricSource {
            typealias Output = CPUSnapshot
            let identifier = CollectorID.cpu
            let preferredInterval: TimeInterval = 0
            private(set) var callCount = 0
            func collect(context: SampleContext) -> MetricState<CPUSnapshot> {
                callCount += 1
                return .value(CPUSnapshot())
            }
        }
        let source = Counting()
        let slot = SourceSlot(source)
        for _ in 0..<5 {
            slot.tick(now: Monotonic.now, activity: .suspended, isEnabled: true,
                      baseInterval: 0, didWakeFromSleep: false)
        }
        #expect(source.callCount == 0, "sampled while the machine was asleep")
    }
}
