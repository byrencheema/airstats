import SwiftUI
import AirStatKit

/// The second-look content of every module.
///
/// Split from `PanelModuleView` so the module shell — header, disclosure, hover,
/// accessibility — stays readable next to nine bodies of metric-specific layout.
extension PanelModuleView {

    @ViewBuilder
    var detail: some View {
        switch module {
        case .cpu:       cpuDetail
        case .memory:    memoryDetail
        case .gpu:       gpuDetail
        case .network:   networkDetail
        case .disk:      diskDetail
        case .battery:   batteryDetail
        case .thermal:   thermalDetail
        case .processes: processesDetail
        case .system:    systemDetail
        }
    }

    /// Detail when the module is open, and the reason when the metric is unavailable.
    ///
    /// A failure is shown whether or not the module is collapsed: for a module that
    /// has no value, the explanation *is* the summary, and hiding it would leave a
    /// header with a blank space where the number belongs.
    @ViewBuilder
    private func section<V: Sendable & Equatable, C: View>(
        _ state: MetricState<V>,
        @ViewBuilder content: @escaping (V) -> C
    ) -> some View {
        if isExpanded {
            MetricContent(state) { content($0) }
        } else if let failure = state.failure {
            UnavailableNote(failure)
        }
    }

    // MARK: CPU

    private var cpuDetail: some View {
        section(engine.cpu) { cpu in
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                coreClusters(cpu)
                PanelDetailGrid(entries: [
                    PanelDetailEntry("Load", loadAverage(cpu.loadAverage)),
                    PanelDetailEntry("Threads", formatter.count(cpu.threadCount)),
                ])
            }
        }
    }

    @ViewBuilder
    private func coreClusters(_ cpu: CPUSnapshot) -> some View {
        let efficiency = cores(cpu, of: .efficiency)
        let performance = cores(cpu, of: .performance)
        if efficiency.isEmpty || performance.isEmpty {
            if !cpu.perCore.isEmpty {
                PanelCoreRow(label: "\(cpu.perCore.count) cores", loads: cpu.perCore,
                             busy: cpu.total.busy, tint: tint,
                             slotWidth: PanelCoreRow.slotWidth(sharedAcross: cpu.perCore.count))
            }
        } else {
            let slot = PanelCoreRow.slotWidth(sharedAcross: max(efficiency.count, performance.count))
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                PanelCoreRow(label: "\(efficiency.count) E-cores", loads: efficiency,
                             busy: cpu.efficiencyBusy, tint: tint, slotWidth: slot)
                PanelCoreRow(label: "\(performance.count) P-cores", loads: performance,
                             busy: cpu.performanceBusy, tint: tint, slotWidth: slot)
            }
        }
    }

    private func cores(_ cpu: CPUSnapshot, of kind: CoreKind) -> [CPULoad] {
        guard cpu.coreKinds.count == cpu.perCore.count else { return [] }
        return zip(cpu.perCore, cpu.coreKinds).compactMap { $0.1 == kind ? $0.0 : nil }
    }

    /// One decimal, not two: three two-decimal figures do not fit a half-width
    /// column, and the second decimal of a load average carries nothing.
    private func loadAverage(_ load: LoadAverage) -> String {
        [load.one, load.five, load.fifteen]
            .map { formatter.fixed($0, decimals: 1) }
            .joined(separator: " · ")
    }

    // MARK: Memory

    private var memoryDetail: some View {
        section(engine.memory) { memory in
            let segments = Self.readableSegments(ChartGallery.memorySegments(memory))
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                StackedCompositionBar(segments, format: .memoryBytes,
                                      title: "Memory composition",
                                      barHeight: Design.Space.s, showsLegend: false)
                PanelSegmentLegend(segments: segments, format: .memoryBytes)
                PanelBarRow(label: "Pressure",
                            value: "\(memory.memoryPressure.label) · \(formatter.percent(memory.pressureFraction))",
                            fraction: memory.pressureFraction,
                            tint: PanelModuleView.barTint)
                PanelDetailGrid(entries: [
                    PanelDetailEntry("Swap", formatter.memory(memory.swapUsedBytes)),
                    PanelDetailEntry("Total", formatter.memory(memory.totalBytes)),
                ])
            }
        }
    }

    /// Composition shades, re-tinted so every segment can actually be read.
    ///
    /// Measured against a light panel: `systemGreen` itself is 1.97:1, so the metric
    /// hue cannot carry a segment no matter how the segments are ordered, and
    /// `ChartPalette.composition` ramps down to 28% opacity, which is fainter still.
    /// Apple's system hues are all in that range in light mode, so "use distinct hues"
    /// cannot meet a 3:1 bar either. Four compressed steps of the label colour can:
    /// they land at 13.7, 8.9, 5.8 and 3.9:1, roughly 30 RGB apart from each other, and
    /// the palest still reads against the track.
    private static let compositionShades: [Double] = [1.0, 0.85, 0.70, 0.55]

    private static func readableSegments(_ segments: [CompositionSegment]) -> [CompositionSegment] {
        var index = 0
        return segments.map { segment in
            guard !segment.isRemainder else { return segment }
            defer { index += 1 }
            let shade = compositionShades[min(index, compositionShades.count - 1)]
            return CompositionSegment(id: segment.id, label: segment.label,
                                      shortLabel: segment.shortLabel,
                                      value: segment.value,
                                      tint: Design.Palette.primaryText.opacity(shade),
                                      isRemainder: false)
        }
    }

    // MARK: GPU

    private var gpuDetail: some View {
        section(engine.gpu) { gpu in
            if let device = gpu.primary {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    if let used = device.vramUsedBytes, let total = device.vramTotalBytes, total > 0 {
                        PanelBarRow(label: device.memoryLabel,
                                    value: "\(formatter.memory(used)) of \(formatter.memory(total))",
                                    fraction: Double(used) / Double(total),
                                    tint: tint)
                    }
                    let entries = gpuEntries(device)
                    if !entries.isEmpty { PanelDetailGrid(entries: entries) }
                }
            } else {
                UnavailableNote(.failed("No graphics device reported"))
            }
        }
    }

    /// The device is named in the header, so the detail carries only what the header
    /// cannot: the split between renderer and tiler, where the driver reports it.
    private func gpuEntries(_ device: GPUDevice) -> [PanelDetailEntry] {
        var entries: [PanelDetailEntry] = []
        if let renderer = device.rendererUtilization {
            entries.append(PanelDetailEntry("Renderer", formatter.percent(renderer)))
        }
        if let tiler = device.tilerUtilization {
            entries.append(PanelDetailEntry("Tiler", formatter.percent(tiler)))
        }
        return entries
    }

    // MARK: Network

    private var networkDetail: some View {
        section(engine.network) { network in
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                PanelDetailGrid(entries: networkEntries(network))
                if let publicIP = publicIPValue(network.publicIP) {
                    // Full width rather than a grid cell, the way the battery's adapter
                    // row is: a grid cell is half of 340pt and truncated "203.0.113…"
                    // after the label, and an IPv6 answer is three times longer again.
                    ReadoutRow("Public IP", publicIP)
                }
                if let wifi = network.wifi, let quality = wifi.signalQuality {
                    // The network's name labels its own signal bar; a row that said
                    // "Signal" and a row that said "Network" would be two lines
                    // saying one thing.
                    PanelBarRow(label: wifi.ssid ?? "Signal", value: signalValue(wifi),
                                fraction: quality, tint: tint)
                }
            }
        }
    }

    private func networkEntries(_ network: NetworkSnapshot) -> [PanelDetailEntry] {
        var entries = [
            PanelDetailEntry("Upload", formatter.networkRate(network.uploadBytesPerSecond)),
        ]
        if let ip = network.localIPv4 {
            entries.append(PanelDetailEntry("Local IP", ip))
        } else if let name = network.primaryInterfaceName {
            entries.append(PanelDetailEntry("Interface", name))
        }
        return entries
    }

    /// What the public IP row says, or nil when there should be no row at all.
    ///
    /// The fetcher reports `.unsupported` while the toggle is off, and that is the one
    /// state with no row: a permanently empty field would read as a lookup that keeps
    /// failing rather than a feature nobody asked for. The fetcher's failure text is a
    /// sentence and this line holds a value, so the row says only which of the three
    /// things is true: an address, a lookup in flight, or one that did not answer.
    private func publicIPValue(_ state: MetricState<String>) -> String? {
        switch state {
        case .value(let address): return address
        case .failure(.unsupported): return nil
        case .failure(.pending): return "Looking up…"
        case .failure: return MetricFormatter.unavailable
        }
    }

    /// Signal strength with the negotiated rate beside it: the two together are what
    /// answer "is my Wi-Fi the problem", and neither is worth a row of its own.
    private func signalValue(_ wifi: WiFiInfo) -> String {
        var text = wifi.rssi.map { "\($0) dBm" } ?? MetricFormatter.unavailable
        if let rate = wifi.transmitRateMbps {
            text += " · \(formatter.fixed(rate, decimals: 0)) Mbps"
        }
        return text
    }

    // MARK: Disk

    private var diskDetail: some View {
        section(engine.disk) { disk in
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                ForEach(disk.volumes) { volume in
                    volumeRow(volume)
                }
                PanelDetailGrid(entries: [
                    PanelDetailEntry("Read", formatter.diskRate(disk.readBytesPerSecond)),
                    PanelDetailEntry("Write", formatter.diskRate(disk.writeBytesPerSecond)),
                ])
            }
        }
    }

    /// Every figure in this module is derived from `availableBytes`, including the
    /// headline.
    ///
    /// Mixing bases is what made the old row unreconcilable: the headline said
    /// "185 GB free" from `availableBytes` while the row said "71% of 494 GB" from
    /// `freeBytes`, and 29% of 494 is 143, not 185. The two differ by purgeable space,
    /// which macOS counts as available and the filesystem counts as used. Following
    /// Finder and reporting one of them everywhere means free + used = total, on screen,
    /// with no footnote.
    private func volumeRow(_ volume: VolumeInfo) -> some View {
        let total = Double(volume.totalBytes)
        let remaining = total > 0 ? Double(volume.availableBytes) / total : 0
        let occupied = volume.totalBytes > volume.availableBytes
            ? volume.totalBytes - volume.availableBytes : 0
        return VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                Text(volume.name)
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if volume.isEjectable {
                    Image(systemName: "eject.fill")
                        .font(Design.Text.micro)
                        .foregroundStyle(Design.Palette.tertiaryText)
                }
                Spacer(minLength: Design.Space.m)
                Text("\(formatter.storage(occupied)) of \(formatter.storage(volume.totalBytes))")
                    .font(Design.Text.caption.monospacedDigit())
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
            }
            CapacityBar(fraction: 1 - remaining, tint: PanelModuleView.barTint)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Battery

    private var batteryDetail: some View {
        section(engine.power) { power in
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                if power.hasBattery, let percentage = power.percentage {
                    CapacityBar(fraction: percentage / 100, tint: PanelModuleView.barTint)
                }
                if let adapter = adapterSummary(power) {
                    ReadoutRow("Adapter", adapter)
                }
                let entries = powerEntries(power)
                if !entries.isEmpty { PanelDetailGrid(entries: entries) }
            }
        }
    }

    private func adapterSummary(_ power: PowerSnapshot) -> String? {
        if let name = power.adapterName { return name }
        if let watts = power.adapterWatts { return formatter.count(watts) + " W" }
        return nil
    }

    /// Only what the platform actually reported. A battery that does not publish a
    /// cycle count gets no cycle row, rather than a zero. A machine with no battery
    /// has nothing to say here that the header and the adapter row have not said.
    private func powerEntries(_ power: PowerSnapshot) -> [PanelDetailEntry] {
        guard power.hasBattery else { return [] }
        var entries: [PanelDetailEntry] = []
        if power.isCharging, let toFull = power.timeToFull {
            entries.append(PanelDetailEntry("Full in", formatter.duration(toFull)))
        } else if let toEmpty = power.timeToEmpty {
            entries.append(PanelDetailEntry("Time left", formatter.duration(toEmpty)))
        } else if power.isFullyCharged {
            entries.append(PanelDetailEntry("State", "Charged"))
        }
        if let health = power.healthPercent {
            entries.append(PanelDetailEntry("Health", formatter.percentValue(health)))
        }
        if let cycles = power.cycleCount {
            entries.append(PanelDetailEntry("Cycles", formatter.count(cycles)))
        }
        if let condition = power.condition {
            entries.append(PanelDetailEntry("Condition", condition))
        }
        if power.isLowPowerMode {
            entries.append(PanelDetailEntry("Low Power", "On"))
        }
        return entries
    }

    // MARK: Thermal

    private var thermalDetail: some View {
        section(engine.thermal) { thermal in
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                PanelDetailGrid(entries: thermalEntries(thermal))
                if let reason = thermal.sensorsUnavailableReason {
                    UnavailableNote(.unsupported(reason))
                }
            }
        }
    }

    private func thermalEntries(_ thermal: ThermalSnapshot) -> [PanelDetailEntry] {
        var entries = [PanelDetailEntry("Pressure", thermal.pressure.label)]
        if let gpu = thermal.gpuCelsius {
            entries.append(PanelDetailEntry("GPU", formatter.temperature(gpu)))
        }
        // Fans are read out rather than gauged: a stopped fan is a normal state on a
        // Mac that is not working hard, and an empty dial next to a healthy machine
        // reads as a broken sensor. "0 RPM" cannot be misread.
        for fan in thermal.fans {
            entries.append(PanelDetailEntry(fan.name, formatter.rpm(fan.currentRPM)))
        }
        return entries
    }

    // MARK: Processes

    private var processesDetail: some View {
        section(engine.processes) { processes in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(topProcesses(processes)) { process in
                    processRow(process)
                }
            }
        }
    }

    private var sortKey: ProcessSortKey { PanelSettings.processSortKey }

    private func topProcesses(_ processes: ProcessSnapshot) -> [ProcessRow] {
        let count = PanelSettings.processRowCount
        let sorted = processes.processes.sorted { a, b in
            switch sortKey {
            case .cpu: return a.cpuPercent > b.cpuPercent
            case .memory: return a.memoryBytes > b.memoryBytes
            case .energy: return (a.energyImpact ?? 0) > (b.energyImpact ?? 0)
            case .diskIO: return diskTotal(a) > diskTotal(b)
            case .networkIO, .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .pid: return a.pid < b.pid
            }
        }
        return Array(sorted.prefix(count))
    }

    private func diskTotal(_ process: ProcessRow) -> Double {
        (process.diskReadBytesPerSecond ?? 0) + (process.diskWriteBytesPerSecond ?? 0)
    }

    private func processRow(_ process: ProcessRow) -> some View {
        HStack(spacing: Design.Space.s) {
            processIcon(process)
            Text(process.name)
                .font(Design.Text.body)
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Design.Space.m)
            Text(processValue(process))
                .font(Design.Text.value)
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
                .frame(width: PanelModuleView.processValueWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(process.name)
        .accessibilityValue(processValue(process))
    }

    /// A real icon for anything with a bundle, a symbol for everything else.
    ///
    /// Not `NSWorkspace.icon(for: .unixExecutable)`, which is what Activity Monitor
    /// uses: that icon is a black tile with "exec" written on it in small green type,
    /// and at the 12pt this row can afford the type disappears and it renders as a
    /// solid block. A symbol stays a symbol at any size.
    @ViewBuilder
    private func processIcon(_ process: ProcessRow) -> some View {
        switch PanelAppIcon.icon(for: process) {
        case .bundle(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: Design.Space.l, height: Design.Space.l)
        case .executable:
            Image(systemName: "gearshape.fill")
                .font(Design.Text.caption)
                .foregroundStyle(Design.Palette.secondaryText)
                .frame(width: Design.Space.l, height: Design.Space.l)
        }
    }

    private func processValue(_ process: ProcessRow) -> String {
        switch sortKey {
        case .cpu, .name, .pid: return formatter.unclampedPercent(process.cpuPercent)
        case .memory: return formatter.memory(process.memoryBytes)
        case .energy: return process.energyImpact.map { formatter.fixed($0, decimals: 1) }
                             ?? MetricFormatter.unavailable
        case .diskIO: return formatter.diskRate(diskTotal(process))
        case .networkIO: return MetricFormatter.unavailable
        }
    }

    // MARK: System

    private var systemDetail: some View {
        section(engine.system) { system in
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                ReadoutRow("Model", system.modelName)
                PanelDetailGrid(entries: [
                    PanelDetailEntry("Chip", system.chipName),
                    PanelDetailEntry(system.osName, system.osVersion),
                ])
            }
        }
    }

}
