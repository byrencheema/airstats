import Testing
import Foundation
@testable import AirStatKit

@Suite("Top Processes remembers its sort and only offers the ones it can rank by")
struct ProcessSortSettingTests {

    @Test("defaults to CPU")
    func defaultsToCPU() {
        #expect(PanelSettings().processSort == .cpu)
    }

    @Test("a chosen sort survives a round trip")
    func roundTrips() throws {
        var settings = Settings()
        settings.panel.processSort = .energy
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.panel.processSort == .energy)
    }

    @Test("the old panel pane's sort key is not read, and an unoffered sort falls back")
    func oldAndUnofferedKeysFallBack() throws {
        let old = #"{"panel":{"processSortKey":"pid"}}"#
        #expect(try JSONDecoder().decode(Settings.self, from: Data(old.utf8)).panel.processSort == .cpu)
        let unoffered = #"{"panel":{"processSort":"name"}}"#
        #expect(try JSONDecoder().decode(Settings.self, from: Data(unoffered.utf8)).panel.processSort == .cpu)
    }

    @Test("power reads in milliwatts below a watt")
    func powerFormatting() {
        let formatter = MetricFormatter()
        #expect(formatter.processPower(0.085) == "85 mW")
        #expect(formatter.processPower(0.9996) == "1.0 W")
        #expect(formatter.processPower(5.02) == "5.0 W")
        #expect(formatter.processPower(nil) == MetricFormatter.unavailable)
        #expect(formatter.processPower(-1) == MetricFormatter.unavailable)
    }
}

@Suite("Process power comes from the kernel's energy counter")
struct ProcessPowerTests {

    @Test("a process spinning a core draws measurable power, and nothing reads negative")
    func spinningProcessDrawsPower() throws {
        let spinner = Process()
        spinner.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        spinner.standardOutput = FileHandle.nullDevice
        try spinner.run()
        defer { spinner.terminate() }

        let collector = ProcessCollector()
        collector.start()
        defer { collector.stop() }
        var last: ProcessSnapshot?
        var previous: ContinuousClock.Instant?
        // Three samples: a baseline, one that ships the row and records its counters,
        // and one that has a delta to divide.
        for index in 0..<3 {
            if index > 0 { Thread.sleep(forTimeInterval: 0.5) }
            let now = Monotonic.now
            let elapsed = previous.map { Monotonic.seconds(since: $0) } ?? 0
            previous = now
            last = collector.collect(context: SampleContext(
                elapsed: elapsed, isFirstSample: index == 0, activity: .panel)).value
        }
        let processes = try #require(last)
        let row = try #require(processes.processes.first { $0.pid == spinner.processIdentifier })
        let watts = try #require(row.powerWatts)
        #expect(watts > 0.1, "a pinned core drew \(watts) W")
        for row in processes.processes {
            if let watts = row.powerWatts {
                #expect(watts.isFinite && watts >= 0, "\(row.name) drew \(watts) W")
            }
        }
    }
}
