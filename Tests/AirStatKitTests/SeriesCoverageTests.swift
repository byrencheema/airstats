import Testing
import Foundation
@testable import AirStatKit
@testable import AirStatUI

/// Adding a metric touches eight files. Swift's exhaustive switching names most of the
/// places you missed, but two steps are hand-written mappings that are exhaustive over
/// nothing: `MetricsEngine.record(_:)` and `ThresholdEvaluator.readings(from:)`. Forget
/// a line in either and it compiles clean, then the chart is permanently empty or the
/// notification rule can never fire, with nothing to say so.
///
/// These two suites are what turn that silence into a failing test.
@MainActor
@Suite("Every series the app can chart is actually recorded")
struct SeriesCoverageTests {

    /// Series a fully-populated snapshot legitimately cannot fill.
    ///
    /// Empty, and it should stay that way. Anything added here needs a reason that is
    /// about the snapshot, not about `record(_:)`, because the whole point of the suite
    /// is that a forgotten `record` line is indistinguishable from an absent field.
    private static let unrecordableSeries: Set<SeriesKey> = []

    /// An engine over a throwaway settings directory. `SettingsStore(directory:)` is the
    /// only thing that isolates a test from the real settings file — `HOME` does not
    /// redirect `applicationSupportDirectory`.
    private func makeEngine() -> MetricsEngine {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return MetricsEngine(settingsStore: SettingsStore(directory: dir))
    }

    @Test("recording one fully-populated snapshot leaves no series empty")
    func everySeriesReceivesASample() {
        let engine = makeEngine()
        engine.ingest(SnapshotFixtures.fullyPopulated)

        let recorded = Set(SeriesKey.allCases.filter { engine.history[$0].count > 0 })
        let expected = Set(SeriesKey.allCases).subtracting(Self.unrecordableSeries)

        // Equality rather than a superset check, so an exclusion that has quietly become
        // recordable shows up as a failure too and the list above stays honest.
        #expect(recorded == expected, """
            series missing from MetricsEngine.record(_:): \
            \(expected.subtracting(recorded).map(\.rawValue).sorted()); \
            unexpectedly recorded: \(recorded.subtracting(expected).map(\.rawValue).sorted())
            """)
    }

    @Test("each series carries the snapshot's value, not a fabricated zero")
    func recordedValuesComeFromTheSnapshot() {
        let engine = makeEngine()
        let snapshot = SnapshotFixtures.fullyPopulated
        engine.ingest(snapshot)

        // A spot check per source, chosen so a mapping crossed between two series of the
        // same shape (upload for download, read for write) does not pass presence alone.
        let expected: [SeriesKey: Double] = [
            .cpuTotal: snapshot.cpu.value!.total.busy,
            .memoryPressure: snapshot.memory.value!.pressureFraction,
            .gpuUtilization: snapshot.gpu.value!.primary!.utilization!,
            .networkDownload: snapshot.network.value!.downloadBytesPerSecond,
            .networkUpload: snapshot.network.value!.uploadBytesPerSecond,
            .diskRead: snapshot.disk.value!.readBytesPerSecond,
            .diskWrite: snapshot.disk.value!.writeBytesPerSecond,
            .batteryPercent: snapshot.power.value!.percentage!,
            .systemWatts: snapshot.power.value!.systemWatts!,
            .cpuTemperature: snapshot.thermal.value!.cpuCelsius!,
            .gpuTemperature: snapshot.thermal.value!.gpuCelsius!,
            .fanRPM: snapshot.thermal.value!.fans[0].currentRPM,
        ]
        for (key, value) in expected {
            let recorded = engine.history[key].last
            #expect(recorded != nil, "\(key.rawValue) recorded nothing")
            // Rings hold Float, so the comparison is at Float precision by necessity.
            #expect(recorded == Float(value), "\(key.rawValue) recorded \(recorded as Any)")
        }
    }

    @Test("a source that failed leaves its series empty rather than recording zero")
    func failedSourcesLeaveGaps() {
        let engine = makeEngine()
        engine.ingest(SnapshotFixtures.degraded)

        // The degraded fixture's gpu, network, thermal and processes are all failures.
        for key: SeriesKey in [.gpuUtilization, .gpuVRAM, .networkUpload, .networkDownload,
                               .cpuTemperature, .gpuTemperature, .fanRPM] {
            #expect(engine.history[key].count == 0,
                    "\(key.rawValue) invented a sample for a source that failed")
        }
        #expect(engine.history[.cpuTotal].count == 1, "a working source stopped recording")
    }
}

@Suite("Every threshold metric can be read out of a snapshot")
struct ThresholdReadingCoverageTests {

    /// The one metric a single snapshot cannot supply alongside the others.
    ///
    /// `readings(from:)` splits the battery by charge state on purpose: a low-battery
    /// warning is noise on the charger, and a full-battery alert has nothing to say to a
    /// pack discharging through 100%. So no one snapshot can produce both, and the union
    /// of the two charge states is the strongest assertion available. Both halves are
    /// covered below.
    private static let unavailableWhileDischarging: Set<ThresholdMetric> = [.batteryFull]

    private var discharging: SystemSnapshot { SnapshotFixtures.fullyPopulated }

    private var charging: SystemSnapshot {
        var snapshot = SnapshotFixtures.fullyPopulated
        snapshot.power = .value(SnapshotFixtures.power(percent: 100, charging: true))
        return snapshot
    }

    @Test("no threshold metric is missing from readings(from:)")
    func everyMetricIsReadable() {
        let onBattery = Set(ThresholdEvaluator.readings(from: discharging).keys)
        let onCharger = Set(ThresholdEvaluator.readings(from: charging).keys)
        let covered = onBattery.union(onCharger)

        #expect(covered == Set(ThresholdMetric.allCases), """
            metrics missing from ThresholdEvaluator.readings(from:): \
            \(Set(ThresholdMetric.allCases).subtracting(covered).map(\.rawValue).sorted())
            """)

        // The exclusion above is a property of the charge-state split, not a gap: on
        // battery everything except `batteryFull` must still be present.
        #expect(onBattery == Set(ThresholdMetric.allCases)
            .subtracting(Self.unavailableWhileDischarging))
        #expect(onCharger.contains(.batteryFull))
        #expect(onCharger.contains(.batteryLow) == false,
                "a low-battery rule would fire on the charger")
    }

    @Test("readings arrive in the units the Notifications pane asks the user for")
    func readingsUseTheUserFacingUnits() {
        let snapshot = discharging
        let readings = ThresholdEvaluator.readings(from: snapshot)
        let root = snapshot.disk.value!.rootVolume!

        #expect(readings[.cpuUsage] == snapshot.cpu.value!.total.busy * 100)
        #expect(readings[.memoryPressure] == snapshot.memory.value!.pressureFraction * 100)
        #expect(readings[.diskFree] == Double(root.availableBytes) / 1_000_000_000)
        #expect(readings[.batteryLow] == snapshot.power.value!.percentage)
        #expect(readings[.bluetoothBatteryLow] == snapshot.bluetooth.value!.lowestBatteryPercent(dischargingOnly: true))
        #expect(readings[.cpuTemperature] == snapshot.thermal.value!.cpuCelsius)
        #expect(readings[.thermalPressure] == Double(snapshot.thermal.value!.pressure.rawValue))
    }

    @Test("a machine with no readable sensors offers no readings at all")
    func unmeasurableMetricsAreAbsent() {
        // A missing reading has to stay missing: `alerts(for:readings:now:)` restarts the
        // sustained clock on absence, where a zero would look like a genuine breach for
        // every metric that fires on the way down.
        let readings = ThresholdEvaluator.readings(from: SnapshotFixtures.pending)
        #expect(readings.isEmpty)
    }
}
