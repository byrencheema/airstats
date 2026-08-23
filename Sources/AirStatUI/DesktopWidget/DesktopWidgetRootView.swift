import SwiftUI
import AppKit
import AirStatKit

/// Interaction state the window controller owns and the desktop widget's content reacts to.
///
/// Width lives here rather than being read straight from settings so a resize drag
/// can update sixty times a second without writing sixty configuration files; the
/// controller persists the final value once the drag ends.
@MainActor
@Observable
final class DesktopWidgetLayout {
    var width: Double
    /// True while the click-through escape hatch is held, so the desktop widget can show
    /// that it is temporarily grabbable.
    var isGrabbable: Bool = false

    init(width: Double) { self.width = width }
}

/// The desktop widget's own presentation: denser and quieter than the panel.
///
/// The panel is a place you look *at*; the desktop widget is something you look *past*.
/// So every module here is the same three things in the same order: a header line
/// carrying the one reading that matters, a bar, and supporting rows indented under
/// the title. Compact keeps one supporting row, expanded keeps them all. Nothing here
/// gets the panel's charts, its two-column grids or its 20pt headline.
struct DesktopWidgetRootView: View {
    let engine: MetricsEngine
    let settings: SettingsStore
    var layout: DesktopWidgetLayout?

    private var desktopWidget: DesktopWidgetSettings { settings.settings.desktopWidget }

    /// A decoded configuration can repeat a module; identity in a `ForEach` must be
    /// unique or SwiftUI will reuse the wrong view.
    private var modules: [PanelModule] {
        var seen = Set<PanelModule>()
        return desktopWidget.modules.filter { seen.insert($0).inserted }
    }

    private var width: CGFloat { CGFloat(layout?.width ?? desktopWidget.width) }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            ForEach(modules, id: \.self) { module in
                DesktopWidgetModuleView(module: module, engine: engine, isCompact: desktopWidget.isCompact)
            }
        }
        // Equal top and bottom. A window with more space under its content than over
        // it reads as bottom-heavy long before anyone works out why.
        .padding(.horizontal, Design.Space.l)
        .padding(.vertical, Design.Space.m)
        .frame(width: width, alignment: .leading)
        .environment(\.metricFormatter, MetricFormatter(settings: settings.settings.general))
        .floatingSurface(in: shape)
        .overlay {
            shape.strokeBorder(borderColor, lineWidth: Design.Space.hairline)
        }
        .animation(Design.Motion.respectingAccessibility(Design.Motion.hover),
                   value: layout?.isGrabbable ?? false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AirStats desktop widget")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
    }

    /// The border is normally just enough edge definition to survive a busy
    /// wallpaper; while the escape hatch is held it turns accent-coloured, which is
    /// the only signal the user gets that a click-through desktop widget is grabbable again.
    private var borderColor: Color {
        (layout?.isGrabbable ?? false) ? Design.Palette.accent : Design.Palette.separator
    }
}

// MARK: - One module

private struct DesktopWidgetModuleView: View {
    let module: PanelModule
    let engine: MetricsEngine
    let isCompact: Bool

    @Environment(\.metricFormatter) private var formatter

    /// Width of the header's glyph gutter. Everything below the header is inset past
    /// it, so a module's detail sits under its own title rather than hanging out to
    /// the left of it, and the icons are the only thing in the left margin.
    static let iconColumn: CGFloat = 12
    static let indent = iconColumn + Design.Space.s
    /// Bar height, and the height reserved where a module has no bar to draw.
    static let barHeight: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            switch readout {
            case .value(let readout):
                DesktopWidgetHeaderRow(readout: readout)
                barRow(fraction: readout.fraction, tint: readout.tint)
                ForEach(details(of: readout)) { detail in
                    DesktopWidgetDetailRow(detail: detail)
                        .padding(.leading, Self.indent)
                }
            case .failure(let failure):
                // One line, not four. The panel has room to explain why a sensor is
                // missing; a HUD that spends three lines saying "no reading" is
                // charging full price for a module that has nothing to report.
                DesktopWidgetHeaderRow(readout: DesktopWidgetReadout(module: module, value: nil),
                                 failure: failure)
                if failure == .pending { pendingReservation }
            }
        }
    }

    /// Compact shows exactly one supporting line, expanded shows all of them.
    ///
    /// There used to be a third tier between the header and these rows, a dimmer
    /// "secondary" line, and it inverted the thing it was meant to rank: the busiest
    /// process and the machine's own chip name were set smaller and fainter than the
    /// rows underneath them. Collapsing it into the top of this list is what makes a
    /// compact module a fixed three lines tall for every metric.
    private func details(of readout: DesktopWidgetReadout) -> [DesktopWidgetDetail] {
        isCompact ? Array(readout.details.prefix(1)) : readout.details
    }

    /// The bar, or the space one would have taken.
    ///
    /// A rate has no maximum and so never gets a bar, but if the row simply vanished
    /// then Network and Disk would be different heights and a column of modules would
    /// step up and down as the user reordered them. Reserving the height costs three
    /// points and keeps every module on the same rhythm.
    @ViewBuilder
    private func barRow(fraction: Double?, tint: Color) -> some View {
        Group {
            if let fraction {
                // The bar carries the metric's identity colour, whatever the value
                // is doing: the length is the reading, and a bar that also changed
                // hue was saying the same thing twice in a louder voice.
                CapacityBar(fraction: fraction, tint: tint, height: Self.barHeight)
            } else {
                Color.clear.frame(height: Self.barHeight)
            }
        }
        .padding(.leading, Self.indent)
    }

    /// The rest of a module, held open while its first sample is still being taken.
    ///
    /// Every module is `.pending` until its collector's first sample lands, and the
    /// ones that difference two samples stay pending for a tick after that. A pending
    /// module drawn as its one honest line is a fraction of the height it is about to
    /// become; a few of those and the desktop widget opens short and then jumps, which looks
    /// like a bug in the window rather than a metric that has not arrived. The other
    /// failures get no reservation on purpose: an unsupported sensor is not about to
    /// start working, and holding space for it would be holding space forever.
    ///
    /// Real rows rather than fixed heights, hidden rather than omitted, so the
    /// reservation cannot drift out of step with what replaces it.
    @ViewBuilder
    private var pendingReservation: some View {
        barRow(fraction: nil, tint: .clear)
        // A real string, not an empty one: an empty `Text` lays out at zero height and
        // would reserve nothing at all.
        ForEach(Array(0..<reservedRowCount), id: \.self) { _ in
            DesktopWidgetDetailRow(detail: DesktopWidgetDetail("pending", "\u{2014}", "\u{2014}"))
                .padding(.leading, Self.indent)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    /// How many supporting rows to hold open for a module that has not reported yet.
    ///
    /// Compact keeps one line whatever the metric is, so one is all it can need.
    /// Expanded is the case the single reserved row used to get wrong: a module that
    /// arrives with four rows still jumped three lines, which is the jump the
    /// reservation exists to prevent. The counts below are each module's guaranteed
    /// rows — the ones that do not depend on the reading — so the reservation is never
    /// taller than what replaces it.
    private var reservedRowCount: Int {
        isCompact ? 1 : Self.guaranteedDetailRows(module)
    }

    static func guaranteedDetailRows(_ module: PanelModule) -> Int {
        switch module {
        case .cpu, .memory, .system: return 3
        case .processes: return 4
        case .network, .disk: return 2
        case .gpu, .battery, .thermal: return 1
        }
    }

    // MARK: Snapshot → readout

    /// Every module collapses to the same shape, so the desktop widget has exactly one
    /// layout to get right instead of nine.
    private var readout: MetricState<DesktopWidgetReadout> {
        switch module {
        case .cpu: return cpuReadout
        case .memory: return memoryReadout
        case .gpu: return gpuReadout
        case .network: return networkReadout
        case .disk: return diskReadout
        case .battery: return batteryReadout
        case .thermal: return thermalReadout
        case .processes: return processReadout
        case .system: return systemReadout
        }
    }

    private var cpuReadout: MetricState<DesktopWidgetReadout> {
        engine.cpu.map { cpu in
            var readout = DesktopWidgetReadout(module: module, value: formatter.percent(cpu.total.busy))
            readout.fraction = cpu.total.busy
            readout.details = [
                DesktopWidgetDetail("user", "User", formatter.percent(cpu.total.user)),
                DesktopWidgetDetail("system", "System", formatter.percent(cpu.total.system)),
                DesktopWidgetDetail("load", "Load", formatter.fixed(cpu.loadAverage.one, decimals: 2)),
            ]
            return readout
        }
    }

    private var memoryReadout: MetricState<DesktopWidgetReadout> {
        engine.memory.map { memory in
            var readout = DesktopWidgetReadout(module: module, value: formatter.percent(memory.usedFraction))
            readout.fraction = memory.usedFraction
            readout.details = [
                DesktopWidgetDetail("used", "Used",
                              "\(formatter.memory(memory.usedBytes)) of \(formatter.memory(memory.totalBytes))"),
                DesktopWidgetDetail("pressure", "Pressure", formatter.percent(memory.pressureFraction)),
                DesktopWidgetDetail("swap", "Swap", formatter.memory(memory.swapUsedBytes)),
            ]
            return readout
        }
    }

    private var gpuReadout: MetricState<DesktopWidgetReadout> {
        engine.gpu.map { gpu in
            let device = gpu.primary
            let utilization = device?.utilization
            var readout = DesktopWidgetReadout(
                module: module,
                value: utilization.map { formatter.percent($0) } ?? MetricFormatter.unavailable)
            readout.fraction = utilization
            if let device, let used = device.vramUsedBytes, let total = device.vramTotalBytes, total > 0 {
                readout.details = [
                    DesktopWidgetDetail("vram", device.memoryLabel,
                                  "\(formatter.memory(used)) of \(formatter.memory(total))"),
                ]
            }
            return readout
        }
    }

    private var networkReadout: MetricState<DesktopWidgetReadout> {
        engine.network.map { network in
            // The headline keeps its arrow because a bare rate does not say which
            // direction it is going. The line below it is a labelled row like every
            // other, rather than a bare "↑ 340 KB/s" floating against the right edge.
            var readout = DesktopWidgetReadout(
                module: module,
                value: "↓ " + formatter.networkRate(network.downloadBytesPerSecond))
            var details = [
                DesktopWidgetDetail("up", "Upload", formatter.networkRate(network.uploadBytesPerSecond)),
                DesktopWidgetDetail("type", "Link", network.connectionType.label),
            ]
            if let ssid = network.wifi?.ssid {
                details.append(DesktopWidgetDetail("ssid", "Network", ssid))
            }
            readout.details = details
            return readout
        }
    }

    private var diskReadout: MetricState<DesktopWidgetReadout> {
        engine.disk.map { disk in
            let root = disk.rootVolume
            var readout = DesktopWidgetReadout(
                module: module,
                value: root.map { formatter.percent($0.usedFraction) } ?? MetricFormatter.unavailable)
            readout.fraction = root?.usedFraction
            readout.details = [
                DesktopWidgetDetail("read", "Read", formatter.diskRate(disk.readBytesPerSecond)),
                DesktopWidgetDetail("write", "Write", formatter.diskRate(disk.writeBytesPerSecond)),
            ]
            if let root {
                readout.details.insert(
                    DesktopWidgetDetail("free", "Free", formatter.storage(root.freeBytes)), at: 0)
            }
            return readout
        }
    }

    private var batteryReadout: MetricState<DesktopWidgetReadout> {
        engine.power.map { power in
            guard power.hasBattery, let percentage = power.percentage else {
                // A desktop Mac has no battery to report; system draw is the honest
                // substitute, and an em dash when even that is unavailable.
                var readout = DesktopWidgetReadout(module: module, value: formatter.watts(power.systemWatts))
                readout.details = [
                    DesktopWidgetDetail("source", "Source", power.isPluggedIn ? "AC power" : "Unknown"),
                ]
                return readout
            }
            var readout = DesktopWidgetReadout(module: module,
                                         value: formatter.percentValue(percentage))
            readout.fraction = percentage / 100
            readout.details = [
                DesktopWidgetDetail("state", "Status", batteryCaption(power)),
                DesktopWidgetDetail("power", "Draw", formatter.watts(power.batteryWatts)),
            ]
            return readout
        }
    }

    private func batteryCaption(_ power: PowerSnapshot) -> String {
        if power.isFullyCharged { return "Fully charged" }
        if power.isCharging {
            guard let full = power.timeToFull else { return "Charging" }
            return "\(formatter.duration(full)) to full"
        }
        guard let empty = power.timeToEmpty else {
            return power.isPluggedIn ? "Plugged in" : "On battery"
        }
        return "\(formatter.duration(empty)) left"
    }

    private var thermalReadout: MetricState<DesktopWidgetReadout> {
        engine.thermal.map { thermal in
            var readout = DesktopWidgetReadout(module: module,
                                         value: formatter.temperature(thermal.cpuCelsius))
            readout.details = [DesktopWidgetDetail("pressure", "Pressure", thermal.pressure.label)]
            if let fan = thermal.fans.first {
                readout.details.append(DesktopWidgetDetail("fan", fan.name, formatter.rpm(fan.currentRPM)))
            }
            return readout
        }
    }

    private var processReadout: MetricState<DesktopWidgetReadout> {
        engine.processes.map { snapshot in
            var readout = DesktopWidgetReadout(module: module,
                                         value: formatter.count(snapshot.totalProcessCount))
            // The busiest process is the first of these rather than a quieter line
            // above them, so the loudest reading is not the faintest thing on screen.
            readout.details = snapshot.processes
                .sorted { $0.cpuPercent > $1.cpuPercent }
                .prefix(4)
                .map { DesktopWidgetDetail("pid-\($0.pid)", $0.name,
                                     formatter.unclampedPercent($0.cpuPercent)) }
            return readout
        }
    }

    private var systemReadout: MetricState<DesktopWidgetReadout> {
        engine.system.map { system in
            var readout = DesktopWidgetReadout(module: module, value: formatter.uptime(system.uptime))
            readout.details = [
                DesktopWidgetDetail("chip", "Chip", system.chipName),
                DesktopWidgetDetail("os", system.osName, system.osVersion),
                DesktopWidgetDetail("host", "Host", system.computerName),
            ]
            return readout
        }
    }
}

// MARK: - Rows

private struct DesktopWidgetHeaderRow: View {
    let readout: DesktopWidgetReadout
    /// Set when the metric has no reading. The reason takes the value's place instead
    /// of adding a line under it.
    var failure: MetricFailure?

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Image(systemName: readout.symbol)
                .font(.system(size: 10, weight: .medium))
                // The glyph belongs to the title beside it, not to the measurement, so
                // it takes the title's colour. A metric's colour is for the things that
                // *are* the metric — this module's bar, its charts, its number in the
                // menu bar — and a coloured icon on a grey label was the app disagreeing
                // with itself about which of the two the colour meant.
                .foregroundStyle(Design.Palette.secondaryText)
                .frame(width: DesktopWidgetModuleView.iconColumn)
            SwiftUI.Text(readout.title)
                .font(Design.Text.sectionHeader)
                .foregroundStyle(Design.Palette.secondaryText)
                .lineLimit(1)
            Spacer(minLength: Design.Space.m)
            LineStrut(font: Design.Text.desktopWidgetValue)
            if let failure {
                SwiftUI.Text(failure.shortLabel)
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.tertiaryText)
                    .lineLimit(1)
            } else if let value = readout.value {
                SwiftUI.Text(value)
                    .font(Design.Text.desktopWidgetValue)
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        // The short label says there is no reading; the tooltip and VoiceOver still
        // say why, which is the part that does not fit on the line.
        .modifier(FailureHelp(failure: failure))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(readout.title)
        .accessibilityValue(failure.map { "Unavailable. \($0.message)" } ?? readout.value ?? "")
    }
}

/// Holds a row at the height of one line of `font`, whatever the row is showing.
///
/// Without it a module whose value has not arrived, or never will, has a header a few
/// points shorter than its neighbours', because the reason it prints is caption-sized
/// and a reading is not. A zero-width hidden glyph tracks the font's own metrics, so
/// changing the type scale cannot leave a hardcoded height behind.
private struct LineStrut: View {
    let font: Font

    var body: some View {
        SwiftUI.Text(verbatim: "0")
            .font(font)
            .hidden()
            .frame(width: 0)
            .accessibilityHidden(true)
    }
}

/// A supporting line under a module's header.
///
/// Not `ReadoutRow`. The panel's row sets its value at full label colour, which is
/// right under a 20pt headline and wrong under a 14pt one: at that distance a fan
/// speed in full contrast reads as something you are being told to look at. These sit
/// a size and a step of contrast below the header, which is the whole point of them.
private struct DesktopWidgetDetailRow: View {
    let detail: DesktopWidgetDetail

    var body: some View {
        HStack(spacing: Design.Space.rowGap) {
            SwiftUI.Text(detail.label)
                .font(Design.Text.caption)
                .foregroundStyle(Design.Palette.tertiaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Design.Space.s)
            SwiftUI.Text(detail.value)
                .font(Design.Text.desktopWidgetDetailValue)
                .foregroundStyle(Design.Palette.secondaryText)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detail.label)
        .accessibilityValue(detail.value)
    }
}

/// `.help` only where there is something to explain, so a healthy module does not
/// carry an empty tooltip around.
private struct FailureHelp: ViewModifier {
    let failure: MetricFailure?

    func body(content: Content) -> some View {
        if let failure {
            content.help(failure.message)
        } else {
            content
        }
    }
}

// MARK: - Model

private struct DesktopWidgetDetail: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String

    init(_ id: String, _ label: String, _ value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

/// `Equatable` and `Sendable` because it travels inside a `MetricState`, which is how
/// every module gets the same honest handling of an unavailable metric for free.
private struct DesktopWidgetReadout: Equatable, Sendable {
    var title: String
    var symbol: String
    var tint: Color
    /// Nil renders no value at all, which is what the header shows above an
    /// `UnavailableNote` — never a zero standing in for a number we do not have.
    var value: String?
    var fraction: Double?
    var details: [DesktopWidgetDetail] = []

    init(module: PanelModule, value: String?) {
        self.title = module.label
        self.symbol = module.symbolName
        self.tint = Design.Palette.metric(module.requiredSource)
        self.value = value
    }
}
