import SwiftUI
import AppKit
import AirStatKit

/// The one-glance answer for a module, shown on its header line.
///
/// Everything below the header is detail the user reads second; this is what they
/// read first, so each module contributes exactly one of them.
struct PanelSummary {
    /// Whether the primary reads as a measurement or as a state. A state ("Nominal",
    /// "AC") set at headline size looks like a mistake, so it drops to value size.
    enum Emphasis { case measurement, state }

    var value: String?
    var caption: String?
    /// Replaces the module's own glyph. A full battery icon on a Mac that has no
    /// battery states something untrue before the reader gets to the words.
    var icon: String?
    var symbol: String?
    var emphasis: Emphasis = .measurement
    /// The history the header trace draws. `ChartScale` decides the domain from the
    /// key, so a module never picks its own axis.
    var series: SeriesKey?
}

/// One module of the panel: a header that carries the headline value, and detail
/// that the user can collapse away.
struct PanelModuleView: View {
    let module: PanelModule
    let engine: MetricsEngine
    let settings: SettingsStore
    var layout: PanelLayoutState?
    /// Width of the qualifier column beside the headline value, shared by every row so
    /// the numbers keep one right edge. See `PanelSummary.captionColumnWidth(for:)`.
    var captionColumnWidth: CGFloat

    @State private var isHovering = false

    /// Derived from the store rather than read from the environment so a module is
    /// correct wherever it is hosted, and injected below so the primitives it draws
    /// cannot disagree with it.
    var formatter: MetricFormatter {
        MetricFormatter(settings: settings.settings.general)
    }

    var isExpanded: Bool {
        let collapsed = layout?.collapsedModulesOverride
            ?? settings.settings.panel.collapsedModules
        return !collapsed.contains(module)
    }

    /// What the panel fills its bars and core cells with.
    ///
    /// The label colour, not `Palette.metric`. Nine modules each in their own hue is
    /// nine colours competing in a 340pt window, and the bar is the content here —
    /// nothing sits on top of it — so it takes the colour text takes.
    static let barTint = Design.Palette.primaryText

    var tint: Color { Self.barTint }

    /// Charts sit in the header beside the headline number, so they stay a step quieter
    /// than the bars: a stroked line reads at secondary weight where a filled bar does
    /// not.
    var traceTint: Color { Design.Palette.secondaryText }

    /// A module glyph is a thin shape beside a heading it does not compete with, so it
    /// sits at secondary weight — nine icons at full strength is a wall.
    private var iconColor: Color { Design.Palette.secondaryText }

    /// Width of the header trace. Set by `Sparkline`'s peak caption rather than by the
    /// line: on a data-derived scale that caption is the axis, and a trace too narrow
    /// to print "peak 4.4 MB/s" is a picture with no units.
    private static let traceWidth: CGFloat = 68

    /// Kept at or under the height of the headline text beside it, so the trace never
    /// becomes the thing that decides how tall a module is.
    private static let traceHeight = Design.Chart.sparklineHeight - Design.Space.xs

    /// The trace's left edge is set by whatever the headline number happens to be wide,
    /// so the sparklines on two expanded modules can sit a few points out of step.
    ///
    /// Left alone deliberately. Reserving a column for the number as well fixes it, but
    /// at 340pt the header has no budget for a fourth reserved column: measured, a 76pt
    /// value column truncated "Memory" to "Mem…" and a network rate to "2.4…". A number
    /// you cannot read is a worse trade than two traces a few points apart, and the
    /// numbers themselves — the thing being scanned — already share a right edge via
    /// `captionColumnWidth`.

    /// Reserved width for the process list's value column, sized for the widest
    /// reading it can hold ("412.6%", "4.3 GB") so the column never reflows as
    /// processes come and go.
    static let processValueWidth: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            detail
                .padding(.horizontal, Design.Space.panelInset)
                .padding(.top, Design.Space.xxs)
                .clipped()
                .transition(.opacity)
        }
        .padding(.vertical, Design.Space.xxs)
        .environment(\.metricFormatter, formatter)
    }

    // MARK: Header

    private var header: some View {
        Button(action: toggleCollapsed) {
            HStack(spacing: Design.Space.m) {
                Image(systemName: "chevron.right")
                    .font(Design.Text.micro.weight(.semibold))
                    .foregroundStyle(Design.Palette.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Design.Space.m)
                Image(systemName: summary.icon ?? module.symbolName)
                    .font(Design.Text.sectionHeader)
                    .foregroundStyle(iconColor)
                    .frame(width: Design.Space.xl)
                Text(module.label)
                    .font(Design.Text.sectionHeader)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: Design.Space.s)
                trace
                headlineValue
                    // The number outranks the gap in front of it: without this the
                    // `HStack` splits any shortfall between the `Spacer` and the value,
                    // so "7.4 GB" could render as "7.4…" with slack sitting unused to
                    // its left.
                    .layoutPriority(1)
            }
            .padding(.horizontal, Design.Space.panelInset)
            .contentShape(Rectangle())
            .background(hoverHighlight)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Design.Motion.respectingAccessibility(Design.Motion.hover)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(module.label)
        .accessibilityValue(summary.value ?? "")
        .accessibilityHint(isExpanded ? "Collapse" : "Expand")
    }

    @ViewBuilder
    private var hoverHighlight: some View {
        RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            // Rows move under a stationary pointer during disclosure. Hiding the
            // highlight while they travel prevents it flashing from one row to the
            // next; onHover still tracks the final row underneath for the next frame.
            .fill(isHovering && layout?.isDisclosureTransitionActive != true
                  ? Design.Palette.track : .clear)
            .padding(.horizontal, Design.Space.s)
    }

    /// The header trace, drawn only while the module is expanded.
    ///
    /// Collapsed modules form a list, and a list only reads as one if its rows share a
    /// shape. Only some metrics have a chartable series, so drawing traces in the
    /// collapsed state gave GPU and Network a squiggle (and Network a "peak" caption)
    /// while Disk, Battery and Temperature had none — a ragged column that made the
    /// summary harder to scan than the numbers alone. Expanded, the trace has room and
    /// context, so it stays there.
    @ViewBuilder
    private var trace: some View {
        if isExpanded, let key = summary.series {
            let series = ChartSeries(key, from: engine.history, tint: traceTint)
            if series.stats.supportsTrend {
                Sparkline(series, settings: settings.settings.charts, height: Self.traceHeight)
                    .frame(width: Self.traceWidth)
            }
        }
    }

    @ViewBuilder
    private var headlineValue: some View {
        if let value = summary.value {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                if let symbol = summary.symbol {
                    Image(systemName: symbol)
                        .font(Design.Text.caption.weight(.semibold))
                        .foregroundStyle(Design.Palette.secondaryText)
                }
                Text(value)
                    .font(summary.emphasis == .measurement ? Design.Text.headline : Design.Text.value)
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                // The qualifier sits in a shared column so it cannot push the number.
                //
                // Inline, a caption shifted its value left by its own width, so across the
                // collapsed list the numbers ended at x = 254, 282, 285, 300, 323, 324 —
                // a 70pt ragged spread that made the column impossible to scan even though
                // the right edge looked tidy. Every row takes the slot whether or not it
                // has a caption, which puts every number's right edge on the same line.
                // When no row has one there is no column at all.
                if captionColumnWidth > 0 {
                    Text(summary.caption ?? "")
                        .font(Design.Text.caption)
                        .foregroundStyle(Design.Palette.tertiaryText)
                        .lineLimit(1)
                        .frame(width: captionColumnWidth, alignment: .leading)
                        .accessibilityHidden(summary.caption == nil)
                }
            }
        }
    }

    private func toggleCollapsed() {
        if let coordinate = layout?.toggleModule {
            coordinate(module)
            return
        }
        withAnimation(Design.Motion.respectingAccessibility(Design.Motion.disclosure)) {
            settings.update { s in
                if s.panel.collapsedModules.contains(module) {
                    s.panel.collapsedModules.remove(module)
                } else {
                    s.panel.collapsedModules.insert(module)
                }
            }
        }
    }

    // MARK: Summary

    private var summary: PanelSummary {
        .make(for: module, engine: engine, formatter: formatter)
    }

}

extension PanelSummary {
    /// The one-glance answer for `module`, or an empty summary while it has nothing yet.
    @MainActor
    static func make(for module: PanelModule, engine: MetricsEngine,
                     formatter: MetricFormatter) -> PanelSummary {
        switch module {
        case .cpu:
            guard let cpu = engine.cpu.value else { return PanelSummary() }
            return PanelSummary(value: formatter.percent(cpu.total.busy),
                                series: .cpuTotal)
        case .memory:
            guard let memory = engine.memory.value else { return PanelSummary() }
            return PanelSummary(value: formatter.memory(memory.usedBytes),
                                caption: "used",
                                series: .memoryUsed)
        case .gpu:
            guard let gpu = engine.gpu.value, let device = gpu.primary else { return PanelSummary() }
            guard let utilization = device.utilization else {
                return PanelSummary(value: device.name, emphasis: .state)
            }
            return PanelSummary(value: formatter.percent(utilization),
                                // Device identity belongs in the expanded detail: it is
                                // the only caption long enough to break the column.
                                caption: nil,
                                series: .gpuUtilization)
        case .network:
            guard let network = engine.network.value else { return PanelSummary() }
            // The Wi-Fi row below already names the connection; the caption is only
            // needed when there is no signal row to carry it.
            return PanelSummary(value: formatter.networkRate(network.downloadBytesPerSecond),
                                caption: network.wifi == nil ? network.connectionType.label : nil,
                                symbol: "arrow.down",
                                series: .networkDownload)
        case .disk:
            guard let disk = engine.disk.value, let root = disk.rootVolume else { return PanelSummary() }
            return PanelSummary(value: formatter.storage(root.availableBytes),
                                caption: "free")
        case .battery:
            guard let power = engine.power.value else { return PanelSummary() }
            guard power.hasBattery, let percentage = power.percentage else {
                return PanelSummary(value: power.isPluggedIn ? "AC" : MetricFormatter.unavailable,
                                    icon: "powerplug",
                                    emphasis: .state)
            }
            return PanelSummary(value: formatter.percentValue(percentage),
                                caption: power.isCharging ? "charging" : nil)
        case .thermal:
            guard let thermal = engine.thermal.value else { return PanelSummary() }
            guard let celsius = thermal.cpuCelsius else {
                return PanelSummary(value: thermal.pressure.label,
                                    emphasis: .state)
            }
            // No trace: charts here are drawn from a zero baseline, and on that axis a
            // die swinging 44–58 °C is a flat line four fifths of the way up. The
            // caption would be the only thing saying anything.
            return PanelSummary(value: formatter.temperature(celsius))
        case .processes:
            guard let processes = engine.processes.value else { return PanelSummary() }
            return PanelSummary(value: formatter.count(processes.totalProcessCount),
                                caption: "running")
        case .system:
            guard let system = engine.system.value else { return PanelSummary() }
            return PanelSummary(value: formatter.uptime(system.uptime), caption: "uptime")
        }
    }

    /// The width the qualifier column needs to hold the widest caption in `summaries`.
    ///
    /// Measured from what is on screen rather than reserved for the longest caption the
    /// panel can ever show: sized for "charging", the column stood mostly empty on any
    /// Mac that was not charging and the whole right edge read as a gap. Every row still
    /// takes the same width, so the numbers keep their shared right edge; that edge
    /// just sits where the captions actually end.
    static func captionColumnWidth(for summaries: [PanelSummary]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: Design.Text.captionSize)
        let widest = summaries.compactMap(\.caption).map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return ceil(widest)
    }
}
