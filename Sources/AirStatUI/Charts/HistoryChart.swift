import SwiftUI
import AirStatKit

/// A module's history, at the span the user keeps and over the last day.
///
/// The chart under an expanded module's rows. Two fixed ranges in the footer, where
/// the time span caption already sits: the "Keep history for" span, drawn from the
/// raw ring, and 24 hours, drawn from the minute tier as a band between each
/// column's low and high with the mean through it. Hovering scrubs; the time and the
/// value go into the footer beside the window statistics, and only a hairline and a
/// point marker stay on the plot, so nothing covers the data it is describing.
///
/// Monochrome by the panel's own policy, so the tints are the caller's: the panel
/// passes its label colours, the desktop widget passes the metric's.
public struct HistoryChart: View {
    private let key: SeriesKey
    private let history: MetricHistory
    private let day: MinuteHistory
    private let settings: ChartSettings
    private let lineTint: Color
    private let bandTint: Color
    private let domain: ClosedRange<Double>?
    private let height: CGFloat
    @Binding private var range: HistoryRange

    @State private var scrub: Scrub?
    @Environment(\.metricFormatter) private var formatter

    public init(_ key: SeriesKey,
                history: MetricHistory,
                day: MinuteHistory,
                settings: ChartSettings,
                tint: Color,
                band: Color,
                domain: ClosedRange<Double>? = nil,
                height: CGFloat = Design.Chart.detailHeight,
                range: Binding<HistoryRange>) {
        self.key = key
        self.history = history
        self.day = day
        self.settings = settings
        self.lineTint = tint
        self.bandTint = band
        self.domain = domain
        self.height = height
        self._range = range
    }

    public var body: some View {
        let window = self.window
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            plot(window)
            axis(window)
            footer(window)
                .padding(.top, Design.Space.xxs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(key.label) history")
        .accessibilityValue(summary(window))
    }

    /// Where the pointer is, as a fraction of the window, and what is under it.
    private struct Scrub: Equatable {
        var fraction: Double
        var column: BandColumn?
    }

    /// Everything one range needs, resolved once per body.
    private struct Window {
        let range: HistoryRange
        let span: TimeInterval
        let end: Date
        let scale: ChartScale
        let format: ChartValueFormat
        let isEmpty: Bool
        let supportsTrend: Bool
        let minimum: Double
        let average: Double
        let maximum: Double
        let last: Double?
        /// How much of a day-long window has actually been collected.
        let collectedSpan: TimeInterval
        private let recent: ChartSeries
        private let minutes: MinuteSeries?

        init(recent: ChartSeries, end: Date, domain: ClosedRange<Double>?) {
            range = .recent
            self.recent = recent
            minutes = nil
            span = recent.span
            self.end = end
            format = recent.format
            let stats = recent.stats
            isEmpty = stats.isEmpty
            supportsTrend = stats.supportsTrend
            minimum = stats.minimum
            average = stats.average
            maximum = stats.maximum
            last = stats.last
            collectedSpan = recent.span
            scale = ChartScale.resolve(peak: stats.maximum, domain: domain,
                                       naturalUpperBound: recent.key.naturalUpperBound,
                                       adaptive: ChartSettings.usesAdaptiveScale)
        }

        init(minutes: MinuteSeries, recent: ChartSeries, domain: ClosedRange<Double>?) {
            range = .day
            self.recent = recent
            self.minutes = minutes
            span = minutes.span
            end = minutes.end
            format = recent.format
            isEmpty = minutes.isEmpty
            supportsTrend = minutes.sampledCount >= Design.Chart.minimumPoints
            minimum = minutes.minimum
            average = minutes.average
            maximum = minutes.maximum
            last = minutes.last
            collectedSpan = minutes.collectedSpan
            scale = ChartScale.resolve(peak: minutes.maximum, domain: domain,
                                       naturalUpperBound: minutes.key.naturalUpperBound,
                                       adaptive: ChartSettings.usesAdaptiveScale)
        }

        func plot(in rect: CGRect) -> BandPlot {
            if let minutes {
                return BandPlot(rect: rect, scale: scale, minutes: minutes)
            }
            return BandPlot(rect: rect, scale: scale, samples: recent.samples)
        }

        func string(_ value: Double, using formatter: MetricFormatter) -> String {
            format.string(value, using: formatter)
        }

        /// Wall clock at a fraction of the window.
        func date(at fraction: Double) -> Date {
            end.addingTimeInterval(-span * (1 - fraction))
        }

        /// A day is read in clock time, a short window as time before now.
        func timeLabel(at fraction: Double) -> String {
            span >= 7_200 ? HistoryAxis.clock(date(at: fraction))
                          : HistoryAxis.relative(-span * (1 - fraction))
        }
    }

    private var window: Window {
        let recent = ChartSeries(key, from: history, tint: lineTint, domain: domain)
        switch range {
        case .recent:
            return Window(recent: recent, end: history.lastSampleDate ?? Date(), domain: domain)
        case .day:
            return Window(minutes: day.series(key), recent: recent, domain: domain)
        }
    }

    private func plot(_ window: Window) -> some View {
        GeometryReader { proxy in
            marks(window, in: proxy.size)
        }
        .frame(height: height)
        .overlay(alignment: .topLeading) { boundLabel(window) }
        .overlay(alignment: .bottomLeading) { floorLabel(window) }
        .overlay {
            if window.isEmpty {
                SwiftUI.Text(window.range == .day ? "Collecting the day…" : "Collecting samples…")
                    .font(Design.Text.micro)
                    .foregroundStyle(Design.Palette.tertiaryText)
                    .accessibilityHidden(true)
            }
        }
    }

    /// One layer per mark rather than one drawing pass. See `PlotShape` for why this
    /// is not a `Canvas`.
    @ViewBuilder
    private func marks(_ window: Window, in size: CGSize) -> some View {
        let rect = ChartLayout.plotRect(in: size)
        if rect.width > 1, rect.height > 1 {
            if window.isEmpty {
                EmptyBaseline(rect: rect)
            } else {
                let plot = window.plot(in: rect)
                ZStack {
                    if ChartSettings.showsGrid {
                        GridLayer(rect: rect)
                        PlotShape(plot.timeGridPath(marks: HistoryAxis.marks))
                            .stroke(Design.Palette.primaryText.opacity(Design.Chart.gridOpacity),
                                    lineWidth: Design.Space.hairline)
                    }
                    BandLayer(plot: plot, size: size, lineTint: lineTint, bandTint: bandTint,
                              style: settings.style)
                    if let scrub {
                        crosshair(plot, at: scrub.fraction)
                    } else if plot.supportsTrend, let last = window.last,
                              let newest = plot.columns.lastIndex(where: { $0 != nil }) {
                        PlotShape(ChartLayout.marker(at: CGPoint(x: plot.x(newest), y: plot.y(last))))
                            .fill(lineTint)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point):
                        let column = plot.column(at: point.x)
                        scrub = Scrub(fraction: plot.fraction(of: column), column: plot.columns[column])
                    case .ended:
                        scrub = nil
                    }
                }
            }
        }
    }

    /// A hairline at the scrubbed column and a marker on its mean. A gap column gets
    /// the hairline alone: there is no value to mark, and the footer says so.
    @ViewBuilder
    private func crosshair(_ plot: BandPlot, at fraction: Double) -> some View {
        let column = plot.column(at: plot.rect.minX + plot.rect.width * CGFloat(fraction))
        let x = plot.x(column)
        var hairline = Path()
        let _ = hairline.move(to: CGPoint(x: x, y: plot.rect.minY))
        let _ = hairline.addLine(to: CGPoint(x: x, y: plot.rect.maxY))
        PlotShape(hairline)
            .stroke(Design.Palette.secondaryText.opacity(0.5), lineWidth: Design.Space.hairline)
        if let value = plot.columns[column] {
            PlotShape(ChartLayout.marker(at: CGPoint(x: x, y: plot.y(value.mean)), radius: 2.5))
                .fill(lineTint)
        }
    }

    /// The top of a fixed vertical axis, stated in place; a derived one is reported
    /// in the footer, where nothing can cover it.
    @ViewBuilder
    private func boundLabel(_ window: Window) -> some View {
        if !window.isEmpty && !window.scale.isDerived {
            SwiftUI.Text(window.string(window.scale.upperBound, using: formatter))
                .font(Design.Text.micro)
                .foregroundStyle(Design.Palette.tertiaryText)
                .padding(.leading, Design.Space.xs)
                .padding(.top, Design.Space.s)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func floorLabel(_ window: Window) -> some View {
        if !window.isEmpty && window.scale.isExplicit && window.scale.lowerBound != 0 {
            SwiftUI.Text(window.string(window.scale.lowerBound, using: formatter))
                .font(Design.Text.micro)
                .foregroundStyle(Design.Palette.tertiaryText)
                .padding(.leading, Design.Space.xs)
                .padding(.bottom, Design.Space.xxs)
                .accessibilityHidden(true)
        }
    }

    /// Four time labels under the plot, at the same marks the vertical gridlines
    /// sit on. The ends hug the plot's edges; the middle two are centred on theirs.
    private func axis(_ window: Window) -> some View {
        let labels = HistoryAxis.labels(span: window.span, end: window.end)
        return GeometryReader { proxy in
            let rect = ChartLayout.plotRect(in: proxy.size)
            ZStack(alignment: .leading) {
                axisLabel(labels[0])
                    .frame(maxWidth: .infinity, alignment: .leading)
                axisLabel(labels[3])
                    .frame(maxWidth: .infinity, alignment: .trailing)
                ForEach(1..<3, id: \.self) { index in
                    axisLabel(labels[index])
                        .position(x: rect.minX + rect.width * CGFloat(HistoryAxis.marks[index]),
                                  y: proxy.size.height / 2)
                }
            }
            .padding(.horizontal, ChartLayout.edgeInset)
        }
        .frame(height: Design.Text.captionSize)
        .accessibilityHidden(true)
    }

    private func axisLabel(_ text: String) -> some View {
        SwiftUI.Text(text)
            .font(Design.Text.micro)
            .foregroundStyle(Design.Palette.tertiaryText)
            .lineLimit(1)
            .fixedSize()
    }

    private func footer(_ window: Window) -> some View {
        HStack(spacing: Design.Space.m) {
            HistoryRangePicker(range: $range,
                               recentLabel: HistoryRange.label(forSpan: settings.historyDuration))
            Spacer(minLength: Design.Space.xs)
            ViewThatFits(in: .horizontal) {
                ForEach(Array(statisticsTiers(window).enumerated()), id: \.offset) { _, tier in
                    SwiftUI.Text(tier)
                        .font(Design.Text.micro)
                        .foregroundStyle(Design.Palette.tertiaryText)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Widest first, for `ViewThatFits`. While scrubbing the time and the value lead
    /// and the statistics are what gets shed; otherwise the maximum is the last to go,
    /// since on a derived scale it is the only number that says how tall the plot is.
    /// A day still being collected says since when, because a plot that occupies the
    /// right third of its axis has to explain the empty two thirds.
    private func statisticsTiers(_ window: Window) -> [String] {
        guard !window.isEmpty else { return [""] }
        var lead: [String] = []
        if let scrub {
            let value = scrub.column.map { window.string($0.mean, using: formatter) } ?? "no samples"
            lead.append("\(window.timeLabel(at: scrub.fraction))  \(value)")
        } else if window.range == .day, window.collectedSpan < window.span - 3_600 {
            lead.append("since \(HistoryAxis.clock(window.end.addingTimeInterval(-window.collectedSpan)))")
        }
        let prefix = lead.isEmpty ? "" : lead.joined() + "  ·  "
        guard window.supportsTrend else {
            let peak = window.scale.isDerived ? "peak \(window.string(window.scale.peak, using: formatter))" : ""
            return [prefix + peak, lead.joined()]
        }
        let minimum = "min \(window.string(window.minimum, using: formatter))"
        let average = "avg \(window.string(window.average, using: formatter))"
        let maximum = "max \(window.string(window.maximum, using: formatter))"
        var tiers = [
            "\(prefix)\(minimum)  \(average)  \(maximum)",
            "\(prefix)\(average)  \(maximum)",
            "\(prefix)\(maximum)",
        ]
        if !lead.isEmpty { tiers.append(lead.joined()) }
        return tiers
    }

    private func summary(_ window: Window) -> String {
        let over = window.range == .day ? "the last 24 hours" : ChartCaption.window(window.span)
        guard !window.isEmpty else { return "No history yet over \(over)." }
        var text = "\(key.label) over \(over)"
        if let last = window.last { text += ": now \(window.string(last, using: formatter))" }
        if window.supportsTrend {
            text += ", average \(window.string(window.average, using: formatter))"
            text += ", range \(window.string(window.minimum, using: formatter))"
            text += " to \(window.string(window.maximum, using: formatter))"
        }
        return text + "."
    }
}

/// The two ranges, as a quiet segmented control that fits a chart footer.
struct HistoryRangePicker: View {
    @Binding var range: HistoryRange
    let recentLabel: String

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            segment(.recent, label: recentLabel)
            segment(.day, label: "24h")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Range")
    }

    private func segment(_ value: HistoryRange, label: String) -> some View {
        let selected = range == value
        return Button {
            range = value
        } label: {
            SwiftUI.Text(label)
                .font(Design.Text.micro.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Design.Palette.primaryText : Design.Palette.tertiaryText)
                .padding(.horizontal, Design.Space.s)
                .padding(.vertical, Design.Space.hairline)
                .background {
                    if selected {
                        Capsule(style: .continuous).fill(Design.Palette.track)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The band and the mean, in the style the user chose.
///
/// Bars keep their meaning from the sparkline, a bar to each column's high. The two
/// line styles draw the low-to-high band with the mean through it; the filled one
/// also washes the area under the mean, which is the difference between them
/// everywhere else in the app.
struct BandLayer: View {
    let plot: BandPlot
    let size: CGSize
    let lineTint: Color
    let bandTint: Color
    let style: ChartStyle

    var body: some View {
        if !plot.isEmpty {
            if plot.supportsTrend {
                trend
            } else {
                level
            }
        }
    }

    private var level: some View {
        PlotShape(plot.levelPath())
            .stroke(lineTint.opacity(0.45),
                    style: StrokeStyle(lineWidth: Design.Chart.lineWidth, lineCap: .butt, dash: [2, 3]))
    }

    @ViewBuilder
    private var trend: some View {
        switch style {
        case .bars:
            PlotShape(plot.barPath()).fill(lineTint)
        case .filledLine:
            PlotShape(plot.areaPath()).fill(areaGradient)
            PlotShape(plot.bandPath()).fill(bandTint)
            line
        case .line:
            PlotShape(plot.bandPath()).fill(bandTint)
            line
        }
    }

    private var line: some View {
        PlotShape(plot.linePath())
            .stroke(lineTint, style: StrokeStyle(lineWidth: Design.Chart.lineWidth,
                                                 lineCap: .round, lineJoin: .round))
    }

    private var areaGradient: LinearGradient {
        let height = max(size.height, 1)
        return LinearGradient(
            gradient: Gradient(colors: [lineTint.opacity(Design.Chart.fillOpacity), lineTint.opacity(0)]),
            startPoint: UnitPoint(x: 0.5, y: plot.rect.minY / height),
            endPoint: UnitPoint(x: 0.5, y: plot.rect.maxY / height))
    }
}

/// The last 24 hours as a shape and nothing else: no axis, no footer, no scrub.
///
/// For the desktop widget, which is looked past rather than at, and which ignores
/// the pointer when it is click-through. It answers "was it busy today" at a glance
/// and leaves the reading to the panel.
public struct HistorySilhouette: View {
    private let minutes: MinuteSeries
    private let tint: Color
    private let style: ChartStyle
    private let domain: ClosedRange<Double>?
    private let height: CGFloat

    @Environment(\.metricFormatter) private var formatter

    public init(_ key: SeriesKey, day: MinuteHistory, tint: Color, style: ChartStyle,
                domain: ClosedRange<Double>? = nil, height: CGFloat) {
        self.minutes = day.series(key)
        self.tint = tint
        self.style = style
        self.domain = domain
        self.height = height
    }

    public var isEmpty: Bool { minutes.isEmpty }

    public var body: some View {
        GeometryReader { proxy in
            let rect = ChartLayout.plotRect(in: proxy.size)
            if rect.width > 1, rect.height > 1 {
                if minutes.isEmpty {
                    EmptyBaseline(rect: rect)
                } else {
                    BandLayer(plot: BandPlot(rect: rect, scale: scale, minutes: minutes),
                              size: proxy.size, lineTint: tint,
                              bandTint: tint.opacity(Design.Chart.fillOpacity * 1.5),
                              style: style)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(minutes.key.label), last 24 hours")
        .accessibilityValue(summary)
    }

    private var scale: ChartScale {
        ChartScale.resolve(peak: minutes.maximum, domain: domain,
                           naturalUpperBound: minutes.key.naturalUpperBound,
                           adaptive: ChartSettings.usesAdaptiveScale)
    }

    private var summary: String {
        guard !minutes.isEmpty else { return "No history yet." }
        let format = ChartValueFormat.standard(for: minutes.key)
        return "average \(format.string(minutes.average, using: formatter)), range "
            + "\(format.string(minutes.minimum, using: formatter)) to "
            + "\(format.string(minutes.maximum, using: formatter))."
    }
}

extension SeriesKey {
    /// The series' upper bound when one genuinely exists.
    ///
    /// `isNormalized` covers the 0...1 metrics; battery is the one series stored as
    /// 0...100 that still has a real ceiling. Everything else has no maximum this app
    /// can know, which is what forces those charts onto a data-derived scale.
    public var naturalUpperBound: Double? {
        if isNormalized { return 1 }
        return self == .batteryPercent ? 100 : nil
    }
}

extension PanelModule {
    /// The series a module's history chart draws, with the fixed band it plots
    /// against when it has one. Nil for modules with nothing to chart over time.
    ///
    /// Temperature gets a stated band: a die swinging 44 to 58 degrees against a
    /// zero baseline is a flat line four fifths of the way up the plot.
    public var historySeries: (key: SeriesKey, domain: ClosedRange<Double>?)? {
        switch self {
        case .cpu: return (.cpuTotal, nil)
        case .memory: return (.memoryUsed, nil)
        case .gpu: return (.gpuUtilization, nil)
        case .network: return (.networkDownload, nil)
        case .disk: return (.diskRead, nil)
        case .battery: return (.batteryPercent, nil)
        case .thermal: return (.cpuTemperature, 30...100)
        case .processes, .system: return nil
        }
    }
}
