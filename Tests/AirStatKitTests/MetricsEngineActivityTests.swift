import Testing
import Foundation
@testable import AirStatKit

@MainActor
@Suite("Low Power Mode pausing")
struct LowPowerPauseTests {

    /// An engine over a throwaway settings directory, so a test never reads or writes
    /// the real `~/Library/Application Support/AirStat/settings.json`.
    private func makeEngine(pausesOnLowPower: Bool,
                            throttlesWhenOccluded: Bool = true) -> (MetricsEngine, SettingsStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SettingsStore(directory: dir)
        store.update {
            $0.general.pausesOnLowPower = pausesOnLowPower
            $0.general.throttlesWhenOccluded = throttlesWhenOccluded
        }
        let engine = MetricsEngine(settingsStore: store)
        // The pause waits for rate collectors to have something to freeze on, so an
        // engine that has never ingested anything can never be paused.
        engine.ingest(.empty)
        engine.ingest(.empty)
        return (engine, store)
    }

    @Test("low power mode suspends sampling when the setting is on")
    func lowPowerSuspends() {
        let (engine, _) = makeEngine(pausesOnLowPower: true)
        engine.setLowPowerMode(false)
        #expect(engine.activity == .menuBar)
        engine.setLowPowerMode(true)
        #expect(engine.activity == .suspended)
    }

    @Test("the pause waits for the first samples rather than freezing on nothing")
    func pauseWaitsForWarmUp() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SettingsStore(directory: dir)
        store.update { $0.general.pausesOnLowPower = true }
        let engine = MetricsEngine(settingsStore: store)

        engine.setLowPowerMode(true)
        #expect(engine.activity == .menuBar, "paused before any sample had been taken")
        engine.ingest(.empty)
        #expect(engine.activity == .menuBar, "paused while rates were still baselining")
        engine.ingest(.empty)
        #expect(engine.activity == .suspended)
    }

    @Test("low power mode is ignored when the setting is off")
    func lowPowerIgnoredWhenSettingOff() {
        let (engine, _) = makeEngine(pausesOnLowPower: false)
        engine.setLowPowerMode(true)
        #expect(engine.activity == .menuBar)
    }

    @Test("leaving low power mode resumes sampling")
    func leavingLowPowerResumes() {
        let (engine, _) = makeEngine(pausesOnLowPower: true)
        engine.setLowPowerMode(true)
        #expect(engine.activity == .suspended)
        engine.setLowPowerMode(false)
        #expect(engine.activity == .menuBar)
    }

    @Test("turning the setting off resumes sampling without leaving low power mode")
    func turningSettingOffResumes() {
        let (engine, store) = makeEngine(pausesOnLowPower: true)
        engine.setLowPowerMode(true)
        #expect(engine.activity == .suspended)
        store.update { $0.general.pausesOnLowPower = false }
        engine.applySettings()
        #expect(engine.activity == .menuBar)
    }

    @Test("a surface the user opened keeps sampling through the pause")
    func openSurfacesOutrankThePause() {
        let (engine, _) = makeEngine(pausesOnLowPower: true)
        engine.setLowPowerMode(true)
        engine.setPanelVisible(true)
        #expect(engine.activity == .panel)
        engine.setPanelVisible(false)
        #expect(engine.activity == .suspended)
        engine.setDesktopWidgetVisible(true)
        #expect(engine.activity == .desktopWidget)
    }

    @Test("the pause outranks the occlusion throttle")
    func pauseOutranksThrottle() {
        let (engine, _) = makeEngine(pausesOnLowPower: true, throttlesWhenOccluded: true)
        engine.setMenuBarOccluded(true)
        #expect(engine.activity == .occluded)
        engine.setLowPowerMode(true)
        #expect(engine.activity == .suspended)
    }

    @Test("sleep still wins over everything")
    func sleepWins() {
        let (engine, _) = makeEngine(pausesOnLowPower: true)
        engine.setPanelVisible(true)
        engine.setLowPowerMode(true)
        engine.setSystemAsleep(true)
        #expect(engine.activity == .suspended)
    }

    @Test("the power state observer is removed, not left behind")
    func observerIsTornDown() {
        // The pause stays off so the assertions do not depend on whether the machine
        // running the suite happens to be in Low Power Mode.
        let (engine, _) = makeEngine(pausesOnLowPower: false)
        #expect(engine.isObservingPowerState == false)
        engine.beginObservingPowerState()
        #expect(engine.isObservingPowerState)
        engine.beginObservingPowerState()
        engine.endObservingPowerState()
        #expect(engine.isObservingPowerState == false, "a second install left an observer behind")
    }
}
