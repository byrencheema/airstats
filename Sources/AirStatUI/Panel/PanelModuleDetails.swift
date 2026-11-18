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
        case .bluetooth: bluetoothDetail
        case .thermal:   thermalDetail
        case .processes: processesDetail
        case .system:    systemDetail
        }
    }

    /// The history chart under a module's rows, when the module has a series and the
    /// user has not switched the charts off.
    ///
    /// Under the rows rather than over them: the rows are what the module is for, and
    /// the chart is the same headline value the header already shows, spread over
    /// time. `available` lets a module withhold the chart when the series behind it
    /// cannot exist on this machine, a battery chart on a desktop being the case.
    @ViewBuilder
    func history(available: Bool = true) -> some View {
        if available, settings.settings.panel.showsHistoryChart,
           let series = module.historySeries {
            HistoryChart(series,
                         history: engine.history,
                         day: engine.dayHistory,
                         settings: settings.settings.charts,
                         tint: chartTint,
                         band: bandTint,
                         range: $historyRange)

                .padding(.top, Design.Space.s)
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
            // The transition lives here, on the view that is actually inserted and
            // removed. On the container in `PanelModuleView` it applied to nothing.
            MetricContent(state) { content($0) }
                .transition(.disclosure)
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
                    PanelDetailEntry(L10n.tr("Load", "Tải"), loadAverage(cpu.loadAverage)),
                    PanelDetailEntry(L10n.tr("Threads", "Luồng"), formatter.count(cpu.threadCount)),
                ])
                history()
            }
        }
    }

    @ViewBuilder
    private func coreClusters(_ cpu: CPUSnapshot) -> some View {
        let efficiency = cores(cpu, of: .efficiency)
        let performance = cores(cpu, of: .performance)
        if efficiency.isEmpty || performance.isEmpty {
            if !cpu.perCore.isEmpty {
                PanelCoreRow(label: L10n.tr("\(cpu.perCore.count) cores", "\(cpu.perCore.count) nhân"),
                             loads: cpu.perCore,
                             busy: cpu.total.busy, tint: tint,
                             slotWidth: PanelCoreRow.slotWidth(sharedAcross: cpu.perCore.count))
            }
        } else {
            let slot = PanelCoreRow.slotWidth(sharedAcross: max(efficiency.count, performance.count))
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                PanelCoreRow(label: L10n.tr("\(efficiency.count) E-cores", "\(efficiency.count) nhân E"),
                             loads: efficiency,
                             busy: cpu.efficiencyBusy, tint: tint, slotWidth: slot)
                PanelCoreRow(label: L10n.tr("\(performance.count) P-cores", "\(performance.count) nhân P"),
                             loads: performance,
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
            let segments = Self.readableSegments(CompositionSegment.memory(memory))
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                StackedCompositionBar(segments, format: .memoryBytes,
                                      title: L10n.tr("Memory composition", "Thành phần bộ nhớ"),
                                      barHeight: Design.Space.s, showsLegend: false)
                PanelSegmentLegend(segments: segments, format: .memoryBytes)
                PanelBarRow(label: L10n.tr("Pressure", "Áp lực"),
                            value: "\(memory.memoryPressure.label) · \(formatter.percent(memory.pressureFraction))",
                            fraction: memory.pressureFraction,
                            tint: PanelModuleView.barTint)
                PanelDetailGrid(entries: [
                    PanelDetailEntry("Swap", formatter.memory(memory.swapUsedBytes)),
                    PanelDetailEntry(L10n.tr("Total", "Tổng"), formatter.memory(memory.totalBytes)),
                ])
                memoryProcesses
                history()
            }
        }
    }

    /// The biggest memory users, ranked here rather than in the Top Processes module
    /// because that list answers "what is busy" and this one answers "where did the
    /// memory go", and a user with 2 GB free is asking the second question.
    @ViewBuilder
    private var memoryProcesses: some View {
        if let processes = engine.processes.value {
            let ranked = processes.processes
                .sorted { $0.memoryBytes > $1.memoryBytes }
                .prefix(PanelSettings.processRowCount)
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.tr("Top processes", "Tiến trình hàng đầu"))
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .padding(.bottom, Design.Space.xxs)
                ForEach(Array(ranked)) { process in
                    processRow(process, value: formatter.memory(process.memoryBytes))
                }
            }
            .padding(.top, Design.Space.s)
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
                    history(available: device.utilization != nil)
                }
            } else {
                UnavailableNote(.failed(L10n.tr("No graphics device reported", "Không phát hiện thiết bị đồ hoạ")))
            }
        }
    }

    /// The device is named in the header, so the detail carries only what the header
    /// cannot: the split between renderer and tiler, where the driver reports it.
    private func gpuEntries(_ device: GPUDevice) -> [PanelDetailEntry] {
        var entries: [PanelDetailEntry] = []
        if let renderer = device.rendererUtilization {
            entries.append(PanelDetailEntry(L10n.tr("Renderer", "Dựng hình"), formatter.percent(renderer)))
        }
        if let tiler = device.tilerUtilization {
            entries.append(PanelDetailEntry(L10n.tr("Tiler", "Chia ô"), formatter.percent(tiler)))
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
                    ReadoutRow(L10n.tr("Public IP", "IP công khai"), publicIP)
                }
                if let wifi = network.wifi, let quality = wifi.signalQuality {
                    // The network's name labels its own signal bar; a row that said
                    // "Signal" and a row that said "Network" would be two lines
                    // saying one thing.
                    PanelBarRow(label: wifi.ssid ?? L10n.tr("Signal", "Tín hiệu"), value: signalValue(wifi),
                                fraction: quality, tint: tint)
                }
                history()
            }
        }
    }

    private func networkEntries(_ network: NetworkSnapshot) -> [PanelDetailEntry] {
        var entries = [
            PanelDetailEntry(L10n.tr("Upload", "Tải lên"), formatter.networkRate(network.uploadBytesPerSecond)),
        ]
        if let ip = network.localIPv4 {
            entries.append(PanelDetailEntry(L10n.tr("Local IP", "IP nội bộ"), ip))
        } else if let name = network.primaryInterfaceName {
            entries.append(PanelDetailEntry(L10n.tr("Interface", "Giao diện"), name))
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
        case .failure(.pending): return L10n.tr("Looking up…", "Đang tra cứu…")
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
                    PanelDetailEntry(L10n.tr("Read", "Đọc"), formatter.diskRate(disk.readBytesPerSecond)),
                    PanelDetailEntry(L10n.tr("Write", "Ghi"), formatter.diskRate(disk.writeBytesPerSecond)),
                ])
                history()
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
                Text(L10n.tr("\(formatter.storage(occupied)) of \(formatter.storage(volume.totalBytes))",
                             "\(formatter.storage(occupied)) / \(formatter.storage(volume.totalBytes))"))
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
                    ReadoutRow(L10n.tr("Adapter", "Bộ sạc"), adapter)
                }
                let entries = powerEntries(power)
                if !entries.isEmpty { PanelDetailGrid(entries: entries) }
                history(available: power.hasBattery && power.percentage != nil)
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
            entries.append(PanelDetailEntry(L10n.tr("Full in", "Đầy sau"), formatter.duration(toFull)))
        } else if let toEmpty = power.timeToEmpty {
            entries.append(PanelDetailEntry(L10n.tr("Time left", "Còn lại"), formatter.duration(toEmpty)))
        } else if power.isFullyCharged {
            entries.append(PanelDetailEntry(L10n.tr("State", "Trạng thái"), L10n.tr("Charged", "Đã đầy")))
        }
        if let health = power.healthPercent {
            entries.append(PanelDetailEntry(L10n.tr("Health", "Độ chai"), formatter.percentValue(health)))
        }
        if let cycles = power.cycleCount {
            entries.append(PanelDetailEntry(L10n.tr("Cycles", "Chu kỳ sạc"), formatter.count(cycles)))
        }
        if let condition = power.condition {
            entries.append(PanelDetailEntry(L10n.tr("Condition", "Tình trạng"), condition))
        }
        if power.isLowPowerMode {
            entries.append(PanelDetailEntry(L10n.tr("Low Power", "Nguồn điện thấp"), L10n.tr("On", "Bật")))
        }
        return entries
    }

    // MARK: Bluetooth

    private var bluetoothDetail: some View {
        section(engine.bluetooth) { bt in
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                if !bt.isPoweredOn {
                    ReadoutRow(L10n.tr("State", "Trạng thái"), L10n.tr("Turned off", "Đã tắt"), isDimmed: true)
                } else if bt.devices.isEmpty {
                    Text(L10n.tr("No paired devices", "Chưa có thiết bị ghép đôi"))
                        .font(Design.Text.caption)
                        .foregroundStyle(Design.Palette.tertiaryText)
                }
                ForEach(bt.connectedDevices) { device in
                    bluetoothConnectedRow(device)
                }
                if !bt.disconnectedDevices.isEmpty {
                    VStack(alignment: .leading, spacing: Design.Space.xs) {
                        ForEach(bt.disconnectedDevices) { device in
                            bluetoothDisconnectedRow(device)
                        }
                    }
                    .padding(.top, bt.connectedDevices.isEmpty && bt.isPoweredOn ? 0 : Design.Space.xxs)
                }
            }
        }
    }

    private func bluetoothConnectedRow(_ device: BluetoothDevice) -> some View {
        let status = bluetoothConnectedValue(device)
        let isPinned = isDevicePinnedInMenuBar(device)
        return VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.s) {
                BluetoothDeviceBadge(category: device.category, isConnected: true)
                HStack(spacing: Design.Space.xxs) {
                    Text(device.name)
                        .font(Design.Text.label)
                        .foregroundStyle(Design.Palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Design.Palette.tertiaryText)
                            .help(L10n.tr("Pinned to the menu bar", "Đã ghim lên thanh Menu"))
                    }
                }
                Spacer(minLength: Design.Space.m)
                HStack(spacing: Design.Space.xs) {
                    Text(status)
                        .font(Design.Text.caption.monospacedDigit())
                        .foregroundStyle(Design.Palette.secondaryText)
                        .lineLimit(1)
                    if device.parts.isEmpty, let percent = device.batteryPercent {
                        Image(systemName: batterySymbolName(percent: percent, isCharging: device.isCharging))
                            .font(.system(size: 12))
                            .foregroundStyle(percent <= 20 && !device.isCharging
                                             ? Color(nsColor: .systemRed)
                                             : Design.Palette.secondaryText)
                    }
                }
            }
            if let percent = device.batteryPercent {
                CapacityBar(fraction: percent / 100, tint: PanelModuleView.barTint)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { bluetoothPinMenu(for: device, isPinned: isPinned) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(device.name)
        .accessibilityValue(L10n.tr("Connected, \(status)", "Đã kết nối, \(status)"))
    }

    private func bluetoothDisconnectedRow(_ device: BluetoothDevice) -> some View {
        let isPinned = isDevicePinnedInMenuBar(device)
        return HStack(spacing: Design.Space.s) {
            BluetoothDeviceBadge(category: device.category, isConnected: false)
            HStack(spacing: Design.Space.xxs) {
                Text(device.name)
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Design.Palette.tertiaryText)
                        .help(L10n.tr("Pinned to the menu bar", "Đã ghim lên thanh Menu"))
                }
            }
            Spacer(minLength: Design.Space.m)
            Text(L10n.tr("Not connected", "Chưa kết nối"))
                .font(Design.Text.caption)
                .foregroundStyle(Design.Palette.tertiaryText)
                .lineLimit(1)
        }
        .opacity(0.65)
        .contentShape(Rectangle())
        .contextMenu { bluetoothPinMenu(for: device, isPinned: isPinned) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(device.name)
        .accessibilityValue(L10n.tr("Not connected", "Chưa kết nối"))
    }

    @ViewBuilder
    private func bluetoothPinMenu(for device: BluetoothDevice, isPinned: Bool) -> some View {
        if isPinned {
            Button {
                toggleMenuBarPin(for: device)
            } label: {
                Label(L10n.tr("Remove Battery from Menu Bar", "Bỏ ghim pin khỏi thanh Menu"),
                      systemImage: "pin.slash")
            }
        } else {
            Button {
                toggleMenuBarPin(for: device)
            } label: {
                Label(L10n.tr("Show Battery in Menu Bar", "Ghim pin lên thanh Menu"),
                      systemImage: "pin")
            }
        }
    }

    private func isDevicePinnedInMenuBar(_ device: BluetoothDevice) -> Bool {
        settings.settings.menuBar.items.contains { item in
            item.isEnabled
                && item.metric == .bluetoothBattery
                && (item.bluetoothDevice?.matches(device) == true)
        }
    }

    private func toggleMenuBarPin(for device: BluetoothDevice) {
        settings.update { s in
            if let index = s.menuBar.items.firstIndex(where: {
                $0.metric == .bluetoothBattery && ($0.bluetoothDevice?.matches(device) == true)
            }) {
                if s.menuBar.items[index].isEnabled {
                    let hasOtherEnabled = s.menuBar.items.enumerated().contains { idx, item in
                        idx != index && item.isEnabled
                    }
                    if s.menuBar.items.count > 1 && hasOtherEnabled {
                        s.menuBar.items.remove(at: index)
                    } else {
                        s.menuBar.items[index].bluetoothDevice = nil
                    }
                } else {
                    s.menuBar.items[index].isEnabled = true
                    s.menuBar.items[index].bluetoothDevice = BluetoothDeviceTarget(device: device)
                }
            } else {
                let config = MenuBarItemConfig(
                    metric: .bluetoothBattery,
                    style: .text,
                    isEnabled: true,
                    showsCaption: true,
                    bluetoothDevice: BluetoothDeviceTarget(device: device)
                )
                s.menuBar.items.append(config)
            }
        }
    }

    private func batterySymbolName(percent: Double, isCharging: Bool) -> String {
        if isCharging { return "battery.100.bolt" }
        switch percent {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 15...: return "battery.25"
        default: return "battery.0"
        }
    }

    /// Individual bud and case charges for multi-part earbuds, the percentage for a
    /// single-battery accessory, or "Connected" when the peripheral reports no battery.
    private func bluetoothConnectedValue(_ device: BluetoothDevice) -> String {
        if !device.parts.isEmpty {
            return device.parts.map { part in
                let label: String
                switch part.name.lowercased() {
                case "left": label = "L"
                case "right": label = "R"
                case "case": label = L10n.tr("Case", "Hộp")
                default: label = part.name
                }
                let charge = formatter.percentValue(part.percent)
                return part.isCharging ? "\(label) \(charge)⚡︎" : "\(label) \(charge)"
            }.joined(separator: "  ")
        }
        if let percent = device.batteryPercent {
            let charge = formatter.percentValue(percent)
            return device.isCharging ? "\(charge) · " + L10n.tr("charging", "đang sạc") : charge
        }
        if let rssi = device.rssi {
            return "\(rssi) dBm · " + L10n.tr("Connected", "Đã kết nối")
        }
        return L10n.tr("Connected", "Đã kết nối")
    }

    // MARK: Thermal

    private var thermalDetail: some View {
        section(engine.thermal) { thermal in
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                PanelDetailGrid(entries: thermalEntries(thermal))
                if let reason = thermal.sensorsUnavailableReason {
                    UnavailableNote(.unsupported(reason))
                }
                history(available: thermal.cpuCelsius != nil)
            }
        }
    }

    private func thermalEntries(_ thermal: ThermalSnapshot) -> [PanelDetailEntry] {
        var entries = [PanelDetailEntry(L10n.tr("Pressure", "Áp lực"), thermal.pressure.label)]
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
                    processRow(process, value: processValue(process))
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

    private func processRow(_ process: ProcessRow, value: String) -> some View {
        HStack(spacing: Design.Space.s) {
            processIcon(process)
            Text(process.name)
                .font(Design.Text.body)
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Design.Space.m)
            Text(value)
                .font(Design.Text.value)
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
                .frame(width: PanelModuleView.processValueWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(process.name)
        .accessibilityValue(value)
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
                ReadoutRow(L10n.tr("Model", "Kiểu máy"), system.modelName)
                PanelDetailGrid(entries: [
                    PanelDetailEntry("Chip", system.chipName),
                    PanelDetailEntry(system.osName, system.osVersion),
                ])
            }
        }
    }

}

/// Circular macOS Control Center-style icon badge for Bluetooth peripherals.
private struct BluetoothDeviceBadge: View {
    let category: BluetoothDeviceCategory
    let isConnected: Bool

    @Environment(\.colorScheme) private var colorScheme

    private static let diameter: CGFloat = 20

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
            Image(systemName: isConnected ? category.filledSymbolName : category.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(foregroundColor)
        }
        .frame(width: Self.diameter, height: Self.diameter)
    }

    private var backgroundColor: Color {
        guard isConnected else { return Design.Palette.track }
        return colorScheme == .dark ? .white : Design.Palette.accent
    }

    private var foregroundColor: Color {
        guard isConnected else { return Design.Palette.secondaryText }
        return colorScheme == .dark ? Design.Palette.accent : .white
    }
}
