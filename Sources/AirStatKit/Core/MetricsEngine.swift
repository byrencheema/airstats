import Foundation
import Observation

/// The app's single source of truth for live system data.
///
/// Owns the background `SamplingCore`, folds every snapshot into bounded history,
/// and translates UI state (panel open, desktop widget shown, screen locked) into the
/// sampling activity level that decides how hard the machine works.
@MainActor
@Observable
public final class MetricsEngine {

    /// The most recent complete snapshot. Starts as all-`.pending`.
    public private(set) var snapshot: SystemSnapshot = .empty

    /// Bounded ring buffers behind every chart.
    public private(set) var history: MetricHistory

    /// The last 24 hours, one bucket per minute. Survives sleep and lock: see
    /// `setSuspensionReason`.
    public private(set) var dayHistory = MinuteHistory()

    public private(set) var activity: SamplingActivity = .menuBar

    /// Wall-clock time of the last snapshot, for the "updated Xs ago" affordance.
    public private(set) var lastUpdate: Date?

    /// True when the newest snapshot is older than it should be — the panel greys
    /// out values rather than presenting stale numbers as current.
    public var isStale: Bool {
        if let staleOverride { return staleOverride }
        guard let lastUpdate else { return true }
        let allowance = max(settingsStore.settings.general.updateInterval * 3, 6)
        return Date().timeIntervalSince(lastUpdate) > allowance
    }

    /// Forces the staleness answer. Fixtures carry a fixed reference date, which would
    /// otherwise read as hours stale and grey out every rendered surface.
    public var staleOverride: Bool?

    private let settingsStore: SettingsStore
    private let dayHistoryFile: MinuteHistoryFile
    /// The newest minute the day was last written at, so the hourly save is a
    /// subtraction per sample and not a timer.
    private var dayHistorySavedMinute: Int?
    private var core: SamplingCore?
    private var isPanelVisible = false
    private var isDesktopWidgetVisible = false
    private var isMenuBarOccluded = false
    private struct SuspensionReasons: OptionSet {
        let rawValue: Int

        static let systemSleeping = Self(rawValue: 1 << 0)
        static let screensSleeping = Self(rawValue: 1 << 1)
        static let sessionInactive = Self(rawValue: 1 << 2)
        static let locked = Self(rawValue: 1 << 3)
    }

    private var suspensionReasons: SuspensionReasons = []
    /// Established by `beginObservingPowerState()` rather than at init, so the engine's
    /// low-power state has exactly one entry point.
    private var isLowPowerMode = false
    /// Snapshots ingested, counted only as far as `isLowPowerPaused` needs.
    private var ingestCount = 0
    private var observationTask: Task<Void, Never>?
    private var powerStateObserver: NSObjectProtocol?
    private var thermalStateObserver: NSObjectProtocol?
    private var settingsApplyTask: Task<Void, Never>?
    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        let s = settingsStore.settings
        self.history = MetricHistory(capacity: s.historyCapacity,
                                     sampleInterval: s.general.updateInterval)
        self.dayHistoryFile = MinuteHistoryFile(
            directory: settingsStore.settingsFileURL.deletingLastPathComponent())
    }

    // MARK: Lifecycle

    public func start() {
        guard core == nil else { return }
        if dayHistory.isEmpty, let saved = dayHistoryFile.load(capacity: dayHistory.capacity) {
            dayHistory = saved
            dayHistorySavedMinute = saved.newestMinute
        }
        let core = SamplingCore { [weak self] snapshot in
            self?.ingest(snapshot)
        }
        self.core = core
        applySettings()
        core.start()
        beginObservingSettings()
        beginObservingPowerState()
        beginObservingThermalState()
    }

    /// True while the power-state observer is installed. The notification centre keeps
    /// block observers alive until they are removed and nothing looks wrong when one
    /// outlives its owner, so the state is exposed for verification rather than left
    /// to be reasoned about.
    public var isObservingPowerState: Bool { powerStateObserver != nil }

    public func stop() {
        // Synchronous: this runs from the app's termination path, where a detached
        // write would not get to finish.
        dayHistoryFile.save(dayHistory)
        dayHistorySavedMinute = dayHistory.newestMinute
        observationTask?.cancel()
        observationTask = nil
        settingsApplyTask?.cancel()
        settingsApplyTask = nil
        endObservingPowerState()
        endObservingThermalState()
        core?.stop()
        core = nil
    }

    // MARK: UI state

    public func setPanelVisible(_ visible: Bool) {
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        updateActivity()
    }

    public func setDesktopWidgetVisible(_ visible: Bool) {
        guard visible != isDesktopWidgetVisible else { return }
        isDesktopWidgetVisible = visible
        updateActivity()
    }

    /// Called when the status item is hidden behind a full-screen app, tucked under
    /// the notch, or otherwise not on screen.
    public func setMenuBarOccluded(_ occluded: Bool) {
        guard occluded != isMenuBarOccluded else { return }
        isMenuBarOccluded = occluded
        updateActivity()
    }

    public func setSystemAsleep(_ asleep: Bool) {
        setSuspensionReason(.systemSleeping, active: asleep)
    }

    public func setScreensAsleep(_ asleep: Bool) {
        setSuspensionReason(.screensSleeping, active: asleep)
    }

    public func setSessionActive(_ active: Bool) {
        setSuspensionReason(.sessionInactive, active: !active)
    }

    public func setLocked(_ locked: Bool) {
        setSuspensionReason(.locked, active: locked)
    }

    /// Sets the Low Power Mode state. `start()` wires this to the process's own
    /// notification; it is public so the state can be driven directly, which is the
    /// only way to exercise the pause without changing the machine's power settings.
    public func setLowPowerMode(_ enabled: Bool) {
        guard enabled != isLowPowerMode else { return }
        isLowPowerMode = enabled
        updateActivity()
    }

    public func refreshNow() { core?.sampleNow() }

    /// True when the user asked for a pause, the machine is in Low Power Mode, and
    /// there is something to freeze on.
    ///
    /// Rate-based collectors report nothing until their second sample, so an app
    /// launched into an already-on Low Power Mode would pause on a menu bar reading
    /// "unavailable". A paused app should show the last real numbers, not no numbers.
    private var isLowPowerPaused: Bool {
        ingestCount >= 2 && isLowPowerMode && settingsStore.settings.general.pausesOnLowPower
    }

    private func updateActivity() {
        let newActivity: SamplingActivity
        if !suspensionReasons.isEmpty {
            newActivity = .suspended
        } else if isPanelVisible {
            newActivity = .panel
        } else if isDesktopWidgetVisible {
            newActivity = .desktopWidget
        } else if isLowPowerPaused {
            // Ranked below the surfaces the user opened deliberately and above the
            // occlusion throttle: a pause is the stronger of the two power measures,
            // but freezing a panel the user is looking at would show them stale numbers
            // with no way to refresh, since a suspended core ignores `sampleNow`.
            newActivity = .suspended
        } else if isMenuBarOccluded && settingsStore.settings.general.throttlesWhenOccluded {
            newActivity = .occluded
        } else {
            newActivity = .menuBar
        }
        guard newActivity != activity else { return }
        activity = newActivity
        core?.setActivity(newActivity)
        core?.setEnabledSources(currentRequiredSources)
    }

    private func setSuspensionReason(_ reason: SuspensionReasons, active: Bool) {
        let oldReasons = suspensionReasons
        if active {
            suspensionReasons.insert(reason)
        } else {
            suspensionReasons.remove(reason)
        }
        guard oldReasons != suspensionReasons else { return }

        if !suspensionReasons.isEmpty {
            if oldReasons.isEmpty { saveDayHistory() }
            updateActivity()
            return
        }
        if !oldReasons.isEmpty {
            core?.noteWakeFromSleep()
            // Rates spanning any sleep/lock interval are meaningless; drop the
            // discontinuity only when every suspension reason has cleared. The raw
            // tier only: the minute tier is anchored to wall-clock minutes, so the
            // sleep shows up there as the gap it was, and a day of buckets is not
            // thrown away because the lid closed.
            history.clear()
        }
        updateActivity()
    }

    private var currentRequiredSources: Set<CollectorID> {
        settingsStore.settings.requiredSources(panelVisible: isPanelVisible,
                                               desktopWidgetVisible: isDesktopWidgetVisible)
    }

    // MARK: Settings

    /// Re-reads settings and re-registers, so any change to the settings tree
    /// re-applies interval, history capacity and the enabled-source set.
    private func beginObservingSettings() {
        observationTask?.cancel()
        let changes = settingsStore.changes
        observationTask = Task { @MainActor [weak self] in
            for await _ in changes {
                guard let self else { return }
                self.scheduleSettingsApply()
            }
        }
    }

    /// Collapse a burst of settings revisions into one configuration transaction. The
    /// settings store is main-actor isolated, so yielding once lets a slider or reset
    /// finish its current run-loop turn before reading the final settings tree.
    private func scheduleSettingsApply() {
        settingsApplyTask?.cancel()
        settingsApplyTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.applySettings()
            self.settingsApplyTask = nil
        }
    }

    /// Low Power Mode is a state the user flips mid-session, so the pause has to
    /// follow it live rather than being decided once at launch.
    func beginObservingPowerState() {
        guard powerStateObserver == nil else { return }
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled)
                }
        }
        // The notification only reports changes, so the state as it stands right now
        // has to be read out. It comes from the process rather than from
        // `snapshot.power.isLowPowerMode`, which the power collector samples: a snapshot
        // is a product of sampling, so a state that pauses sampling would latch on at
        // the last sample taken and could never see itself clear.
        setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    func endObservingPowerState() {
        guard let powerStateObserver else { return }
        NotificationCenter.default.removeObserver(powerStateObserver)
        self.powerStateObserver = nil
    }

    private func beginObservingThermalState() {
        guard thermalStateObserver == nil else { return }
        thermalStateObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setThermalPressure(ProcessInfo.processInfo.thermalState)
                }
            }
        setThermalPressure(ProcessInfo.processInfo.thermalState)
    }

    private func setThermalPressure(_ state: ProcessInfo.ThermalState) {
        let pressure: ThermalPressure
        switch state {
        case .nominal: pressure = .nominal
        case .fair: pressure = .fair
        case .serious: pressure = .serious
        case .critical: pressure = .critical
        @unknown default: pressure = .nominal
        }
        core?.setThermalPressure(pressure)
    }

    private func endObservingThermalState() {
        guard let thermalStateObserver else { return }
        NotificationCenter.default.removeObserver(thermalStateObserver)
        self.thermalStateObserver = nil
    }

    /// Re-pushes the whole configuration, and is called for *any* accepted settings
    /// change: the engine wakes on `settingsStore.revision`, which bumps on every
    /// mutation. Changing a desktop widget colour re-pushes the interval, the enabled-source
    /// set and the public IP flag.
    ///
    /// That is harmless only because every setter it calls early-returns on an
    /// unchanged value, so the redundant pushes cost a few queue hops. Anything added
    /// here that is *not* idempotent becomes a bug the moment a user drags a colour
    /// picker, because a drag runs this at display rate.
    func applySettings() {
        let s = settingsStore.settings
        core?.apply(.init(baseInterval: s.general.updateInterval,
                          enabledSources: currentRequiredSources,
                          publicIPLookupEnabled: s.general.fetchesPublicIP))
        // Turning the pause off has to resume sampling now, not at whatever UI
        // transition happens to call `updateActivity` next.
        updateActivity()

        let capacity = s.historyCapacity
        if history.capacity != capacity { history.resize(to: capacity) }
        if history.sampleInterval != s.general.updateInterval {
            history.sampleInterval = s.general.updateInterval
        }
    }

    // MARK: Ingest

    func ingest(_ new: SystemSnapshot) {
        snapshot = new
        lastUpdate = new.capturedAt
        record(new)
        guard ingestCount < 2 else { return }
        ingestCount += 1
        // The pause that was waiting for rates to exist can take effect now.
        updateActivity()
    }

    /// Fold a snapshot into history. Only series whose metric is actually available
    /// are appended — a missing sensor leaves a gap rather than a fabricated zero.
    /// Writes the day off the main actor. The tier is a value, so the copy handed
    /// to the task is the snapshot being saved and later samples cannot race it.
    private func saveDayHistory() {
        let snapshot = dayHistory
        let file = dayHistoryFile
        dayHistorySavedMinute = snapshot.newestMinute
        Task.detached(priority: .utility) { file.save(snapshot) }
    }

    private func record(_ s: SystemSnapshot) {
        history.markSampleDate(s.capturedAt)
        dayHistory.advance(to: s.capturedAt)
        if let newest = dayHistory.newestMinute, newest - (dayHistorySavedMinute ?? newest) >= 60 {
            saveDayHistory()
        }

        if let cpu = s.cpu.value {
            fold(.cpuTotal, cpu.total.busy)
            fold(.cpuUser, cpu.total.user)
            fold(.cpuSystem, cpu.total.system)
            if let p = cpu.performanceBusy { fold(.cpuPerformance, p) }
            if let e = cpu.efficiencyBusy { fold(.cpuEfficiency, e) }
        }
        if let mem = s.memory.value {
            fold(.memoryUsed, mem.usedFraction)
            fold(.memoryPressure, mem.pressureFraction)
            fold(.memorySwap, Double(mem.swapUsedBytes))
        }
        if let gpu = s.gpu.value, let primary = gpu.primary {
            if let util = primary.utilization { fold(.gpuUtilization, util) }
            if let used = primary.vramUsedBytes, let total = primary.vramTotalBytes, total > 0 {
                fold(.gpuVRAM, Double(used) / Double(total))
            }
        }
        if let net = s.network.value {
            fold(.networkUpload, net.uploadBytesPerSecond)
            fold(.networkDownload, net.downloadBytesPerSecond)
        }
        if let disk = s.disk.value {
            fold(.diskRead, disk.readBytesPerSecond)
            fold(.diskWrite, disk.writeBytesPerSecond)
            if let root = disk.rootVolume { fold(.diskUsed, root.usedFraction) }
        }
        if let power = s.power.value {
            if let pct = power.percentage { fold(.batteryPercent, pct) }
            if let w = power.batteryWatts { fold(.batteryWatts, w) }
            if let w = power.systemWatts { fold(.systemWatts, w) }
        }
        if let thermal = s.thermal.value {
            if let c = thermal.cpuCelsius { fold(.cpuTemperature, c) }
            if let g = thermal.gpuCelsius { fold(.gpuTemperature, g) }
            if let fan = thermal.fans.first { fold(.fanRPM, fan.currentRPM) }
        }
    }

    /// One sample into both tiers.
    private func fold(_ key: SeriesKey, _ value: Double) {
        history.record(key, value)
        dayHistory.record(key, value)
    }

    /// Injects fixture data for offscreen rendering and previews.
    ///
    /// Deliberately not gated behind `#if DEBUG`: the render CLI ships in the same
    /// binary and is how the UI gets reviewed, and a fixture path that only exists in
    /// debug builds cannot verify what release builds actually draw.
    public func loadFixture(snapshot: SystemSnapshot, history: MetricHistory,
                            dayHistory: MinuteHistory = MinuteHistory()) {
        self.snapshot = snapshot
        self.history = history
        self.dayHistory = dayHistory
        self.lastUpdate = snapshot.capturedAt
    }

    // MARK: Convenience accessors for the UI

    public var cpu: MetricState<CPUSnapshot> { snapshot.cpu }
    public var memory: MetricState<MemorySnapshot> { snapshot.memory }
    public var gpu: MetricState<GPUSnapshot> { snapshot.gpu }
    public var network: MetricState<NetworkSnapshot> { snapshot.network }
    public var disk: MetricState<DiskSnapshot> { snapshot.disk }
    public var power: MetricState<PowerSnapshot> { snapshot.power }
    public var thermal: MetricState<ThermalSnapshot> { snapshot.thermal }
    public var processes: MetricState<ProcessSnapshot> { snapshot.processes }
    public var system: MetricState<SystemInfoSnapshot> { snapshot.system }
}
