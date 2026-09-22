import SwiftUI
import AirStatKit

/// What a module charts over time.
///
/// The headline series is what the chart is about. A module that reports a pair,
/// network and disk, names the other direction as `secondary`, and it is drawn as a
/// thinner line in the same tint so a day of uploads leaves a trace in a chart that
/// is mostly downloads. `shading` is a 0 or 1 series whose 1 stretches are washed
/// behind the plot: for the battery, the hours on the charger, which is where every
/// change of slope on a charge line comes from. The wash is only drawn when the
/// window holds both states. A window spent entirely on power washed edge to edge
/// reads as a disabled chart, and says nothing the header's "charging" does not.
public struct ModuleHistory: Equatable, Sendable {
    public let key: SeriesKey
    public let secondary: SeriesKey?
    /// One character each, to tell the pair apart in a footer that has no room for
    /// their names.
    public let glyph: String
    public let secondaryGlyph: String
    public let domain: ClosedRange<Double>?
    public let shading: SeriesKey?

    public init(_ key: SeriesKey, secondary: SeriesKey? = nil,
                glyphs: (String, String) = ("", ""),
                domain: ClosedRange<Double>? = nil, shading: SeriesKey? = nil) {
        self.key = key
        self.secondary = secondary
        self.glyph = glyphs.0
        self.secondaryGlyph = glyphs.1
        self.domain = domain
        self.shading = shading
    }
}

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
///
/// Drawn in as few layers as the picture allows. Every `PlotShape` is a Core
/// Animation layer with its own 2x backing store, and four open charts of seven
/// layers each were most of what the panel cost while open. At rest a chart is the
/// grid, the band and one stroke that carries the line, the lone-minute dots and the
/// now marker; a pair adds a stroke, the battery adds its shading.
public struct HistoryChart: View {
    private let module: ModuleHistory
    private let history: MetricHistory
    private let day: MinuteHistory
    private let settings: ChartSettings
    private let lineTint: Color
    private let bandTint: Color
    private let height: CGFloat
    /// Nil until the user picks: the chart opens on the day once there is an hour
    /// of it, and on the live span before that, so it never opens on a lone dot.
    @Binding private var range: HistoryRange?

    @State private var scrub: Scrub?
    @Environment(\.metricFormatter) private var formatter
    /// Whether the module this chart sits in is still unfolding. Set by the panel;
    /// false everywhere else, so previews and the renderer draw the plot at once.
    @Environment(\.isDisclosureInProgress) private var isDisclosing
    /// Whether this chart came into being mid-unfold. Only then does the plot wait.
    @State private var appearedWhileDisclosing = false

    public init(_ module: ModuleHistory,
                history: MetricHistory,
                day: MinuteHistory,
                settings: ChartSettings,
                tint: Color,
                band: Color,
                height: CGFloat = Design.Chart.detailHeight,
                range: Binding<HistoryRange?>) {
        self.module = module
        self.history = history
        self.day = day
        self.settings = settings
        self.lineTint = tint
        self.bandTint = band
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
        .accessibilityLabel("\(module.key.label) history")
        .accessibilityValue(summary(window))
    }

    /// Where the pointer is, as a fraction of the window, and what is under it.
    private struct Scrub: Equatable {
        var fraction: Double
        var column: BandColumn?
        var secondary: BandColumn?
        var shade: BandColumn?
    }

    /// One series over one range, with the figures the footer states.
    private struct Track {
        let isEmpty: Bool
        let supportsTrend: Bool
        let minimum: Double
        let average: Double
        let maximum: Double
        let last: Double?
        /// How much of a day-long window has actually been collected.
        let collectedSpan: TimeInterval
        /// The process behind the window's high, when that minute was looked at.
        let peakNote: String?
        private let recent: ChartSeries
        private let minutes: MinuteSeries?

        init(recent: ChartSeries) {
            self.recent = recent
            minutes = nil
            let stats = recent.stats
            isEmpty = stats.isEmpty
            supportsTrend = stats.supportsTrend
            minimum = stats.minimum
            average = stats.average
            maximum = stats.maximum
            last = stats.last
            collectedSpan = recent.span
            peakNote = nil
        }

        init(minutes: MinuteSeries, recent: ChartSeries) {
            self.recent = recent
            self.minutes = minutes
            isEmpty = minutes.isEmpty
            supportsTrend = minutes.sampledCount >= Design.Chart.minimumPoints
            minimum = minutes.minimum
            average = minutes.average
            maximum = minutes.maximum
            last = minutes.last
            collectedSpan = minutes.collectedSpan
            var peak: Int?
            for index in minutes.counts.indices where minutes.counts[index] > 0 {
                if peak == nil || minutes.maxima[index] > minutes.maxima[peak!] { peak = index }
            }
            peakNote = peak.flatMap { minutes.notes[$0] }
        }

        func plot(in rect: CGRect, scale: ChartScale) -> BandPlot {
            if let minutes {
                return BandPlot(rect: rect, scale: scale, minutes: minutes)
            }
            return BandPlot(rect: rect, scale: scale, samples: recent.samples)
        }
    }

    /// Everything one range needs, resolved once per body.
    private struct Window {
        let range: HistoryRange
        let span: TimeInterval
        let end: Date
        let scale: ChartScale
        let format: ChartValueFormat
        let primary: Track
        let secondary: Track?
        let shade: Track?

        var isEmpty: Bool { primary.isEmpty }
        var supportsTrend: Bool { primary.supportsTrend }
        var collectedSpan: TimeInterval { primary.collectedSpan }

        init(range: HistoryRange, span: TimeInterval, end: Date, format: ChartValueFormat,
             primary: Track, secondary: Track?, shade: Track?,
             domain: ClosedRange<Double>?, naturalUpperBound: Double?) {
            self.range = range
            self.span = span
            self.end = end
            self.format = format
            self.primary = primary
            self.secondary = secondary
            self.shade = shade
            scale = ChartScale.resolve(peak: Swift.max(primary.maximum, secondary?.maximum ?? 0),
                                       domain: domain,
                                       naturalUpperBound: naturalUpperBound,
                                       adaptive: ChartSettings.usesAdaptiveScale)
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

    /// The day once it can show one, otherwise whatever the live ring holds.
    public static let dayDefaultThreshold: TimeInterval = 3_600
    /// The shading series is 0 or 1 per sample; a column is shaded when more of its
    /// minute was spent at 1.
    static let shadeThreshold = 0.5
    /// The fraction of the scale below which data leaves the ceiling label alone.
    static let boundLabelBand = 0.85

    private var resolvedRange: HistoryRange {
        range ?? (day.collectedSpan(of: module.key) >= Self.dayDefaultThreshold ? .day : .recent)
    }

    private var window: Window {
        let recent = ChartSeries(module.key, from: history, tint: lineTint, domain: module.domain)
        let secondary = module.secondary.map { ChartSeries($0, from: history, tint: lineTint) }
        let shade = module.shading.map { ChartSeries($0, from: history, tint: lineTint) }
        switch resolvedRange {
        case .recent:
            // An empty series has no span, and a frame with no span labels every
            // mark "now". The window it will fill is the configured one, so the
            // axis says so from the first frame.
            return Window(range: .recent, span: recent.stats.isEmpty ? settings.historyDuration : recent.span,
                          end: history.lastSampleDate ?? Date(), format: recent.format,
                          primary: Track(recent: recent),
                          secondary: secondary.map { Track(recent: $0) },
                          shade: shade.map { Track(recent: $0) },
                          domain: module.domain, naturalUpperBound: module.key.naturalUpperBound)
        case .day:
            let minutes = day.series(module.key)
            return Window(range: .day, span: minutes.span, end: minutes.end, format: recent.format,
                          primary: Track(minutes: minutes, recent: recent),
                          secondary: secondary.map { Track(minutes: day.series($0.key), recent: $0) },
                          shade: shade.map { Track(minutes: day.series($0.key), recent: $0) },
                          domain: module.domain, naturalUpperBound: module.key.naturalUpperBound)
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
        // The plot arrives after the rows, not with them.
        //
        // Revealed top-down with the rest of the detail, the grid and the trace swept
        // past under the clip for the length of the unfold, and at 0.18s that read as
        // a flicker rather than a reveal. The axis and the footer are text and unfold
        // with the rows; the plot holds back until the height has settled and then
        // fades in as one piece. A chart that was already on screen when some other
        // module started unfolding is not touched.
        .opacity(isDisclosing && appearedWhileDisclosing ? 0 : 1)
        .animation(Design.Motion.respectingAccessibility(Design.Motion.chartReveal), value: isDisclosing)
        .onAppear { appearedWhileDisclosing = isDisclosing }
    }

    /// One layer per mark rather than one drawing pass. See `PlotShape` for why this
    /// is not a `Canvas`, and the type comment for why there are so few of them.
    @ViewBuilder
    private func marks(_ window: Window, in size: CGSize) -> some View {
        let rect = ChartLayout.plotRect(in: size)
        if rect.width > 1, rect.height > 1 {
            if window.isEmpty {
                // The frame the plot will have, drawn before there is a plot, so the
                // first samples land inside a chart instead of turning a blank into
                // one. What Activity Monitor does with its empty history.
                ZStack {
                    if ChartSettings.showsGrid {
                        PlotShape(BandPlot.gridPath(in: rect, marks: HistoryAxis.marks))
                            .stroke(Design.Palette.primaryText.opacity(Design.Chart.gridOpacity),
                                    lineWidth: Design.Space.hairline)
                    }
                    EmptyBaseline(rect: rect)
                }
            } else {
                let plot = window.primary.plot(in: rect, scale: window.scale)
                let secondary = window.secondary.map { $0.plot(in: rect, scale: window.scale) }
                let shade = window.shade.map { $0.plot(in: rect, scale: Self.unitScale) }
                ZStack {
                    if let shade, shade.straddles(Self.shadeThreshold) {
                        ShadeLayer(plot: shade)
                    }
                    if ChartSettings.showsGrid {
                        PlotShape(plot.gridPath(marks: HistoryAxis.marks))
                            .stroke(Design.Palette.primaryText.opacity(Design.Chart.gridOpacity),
                                    lineWidth: Design.Space.hairline)
                    }
                    if let secondary {
                        SecondaryLayer(plot: secondary, tint: lineTint)
                    }
                    BandLayer(plot: plot, lineTint: lineTint, bandTint: bandTint,
                              style: settings.style, levelsWhenSparse: window.range == .recent,
                              scrubbed: scrub.map { plot.column(at: rect.minX + rect.width * CGFloat($0.fraction)) })
                    if let scrub {
                        crosshair(plot, at: scrub.fraction)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point):
                        let column = plot.column(at: point.x)
                        scrub = Scrub(fraction: plot.fraction(of: column), column: plot.columns[column],
                                      secondary: secondary?.columns[column], shade: shade?.columns[column])
                    case .ended:
                        scrub = nil
                    }
                }
            }
        }
    }

    private static let unitScale = ChartScale(upperBound: 1, isDerived: false, peak: 1)

    /// A hairline at the scrubbed column. The marker on its mean is part of the
    /// line's own stroke, see `BandLayer`; a gap column gets the hairline alone,
    /// since there is no value to mark and the footer says so.
    private func crosshair(_ plot: BandPlot, at fraction: Double) -> some View {
        let column = plot.column(at: plot.rect.minX + plot.rect.width * CGFloat(fraction))
        let x = plot.x(column)
        var hairline = Path()
        hairline.move(to: CGPoint(x: x, y: plot.rect.minY))
        hairline.addLine(to: CGPoint(x: x, y: plot.rect.maxY))
        return PlotShape(hairline)
            .stroke(Design.Palette.secondaryText.opacity(0.5), lineWidth: Design.Space.hairline)
    }

    /// The top of a fixed vertical axis, stated in place; a derived one is reported
    /// in the footer, where nothing can cover it. Left out when the data reaches
    /// the band the label sits in: a line along the ceiling states the ceiling
    /// better than a label it runs through, and a full battery sits there for hours.
    @ViewBuilder
    private func boundLabel(_ window: Window) -> some View {
        if !window.isEmpty && !window.scale.isDerived,
           window.primary.maximum < window.scale.lowerBound + window.scale.span * Self.boundLabelBand {
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
            HistoryRangePicker(range: Binding(get: { resolvedRange }, set: { range = $0 }),
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
    /// right third of its axis has to explain the empty two thirds. A pair labels
    /// its figures with the glyphs and drops the minimum, which for a rate is zero
    /// and says nothing. The process behind a high follows the figure it explains.
    private func statisticsTiers(_ window: Window) -> [String] {
        guard !window.isEmpty else { return [""] }
        let separator = "  ·  "
        var lead: [String] = []
        if let scrub {
            lead.append(scrubReadout(scrub, in: window))
        } else if window.range == .day, window.collectedSpan < window.span - 3_600 {
            lead.append("since \(HistoryAxis.clock(window.end.addingTimeInterval(-window.collectedSpan)))")
        }
        let prefix = lead.isEmpty ? "" : lead.joined() + separator
        guard window.supportsTrend else {
            // Too few points for a trend: the peak alone on a derived scale, since it
            // is what says how tall the plot is, and otherwise just the lead.
            guard window.scale.isDerived else { return [lead.joined()] }
            let peak = "peak \(window.string(window.scale.peak, using: formatter))"
            return [prefix + peak, lead.joined()]
        }
        let primary = window.primary
        let average = "avg \(window.string(primary.average, using: formatter))"
        let maximum = "max \(window.string(primary.maximum, using: formatter))"
        let explained = primary.peakNote.map { "\(maximum) \($0)" } ?? maximum
        var tiers: [String]
        if let secondary = window.secondary {
            let other = "\(module.secondaryGlyph) avg \(window.string(secondary.average, using: formatter))"
                + "  max \(window.string(secondary.maximum, using: formatter))"
            let otherMax = "\(module.secondaryGlyph) max \(window.string(secondary.maximum, using: formatter))"
            tiers = [
                "\(prefix)\(module.glyph) \(average)  \(maximum)   \(other)",
                "\(prefix)\(module.glyph) \(maximum)   \(otherMax)",
                "\(prefix)\(maximum)",
            ]
        } else {
            let minimum = "min \(window.string(primary.minimum, using: formatter))"
            tiers = [
                "\(prefix)\(minimum)  \(average)  \(explained)",
                "\(prefix)\(average)  \(explained)",
                "\(prefix)\(maximum)",
            ]
        }
        if !lead.isEmpty { tiers.append(lead.joined()) }
        return tiers
    }

    /// The time under the pointer and what was measured there: both directions of
    /// a pair, the charger state under a charge, and the process behind a high.
    private func scrubReadout(_ scrub: Scrub, in window: Window) -> String {
        var parts = [window.timeLabel(at: scrub.fraction)]
        guard let column = scrub.column else {
            parts.append("no samples")
            return parts.joined(separator: "  ")
        }
        if window.secondary != nil {
            parts.append("\(module.glyph) \(window.string(column.mean, using: formatter))")
            if let other = scrub.secondary {
                parts.append("\(module.secondaryGlyph) \(window.string(other.mean, using: formatter))")
            }
        } else {
            parts.append(window.string(column.mean, using: formatter))
        }
        if window.shade != nil, let shade = scrub.shade {
            parts.append(shade.mean >= Self.shadeThreshold ? "on power" : "on battery")
        }
        if let note = column.note { parts.append(note) }
        return parts.joined(separator: "  ")
    }

    private func summary(_ window: Window) -> String {
        let over = window.range == .day ? "the last 24 hours" : ChartCaption.window(window.span)
        guard !window.isEmpty else { return "No history yet over \(over)." }
        func sentence(_ label: String, _ track: Track) -> String {
            var text = label
            if let last = track.last { text += ": now \(window.string(last, using: formatter))" }
            if track.supportsTrend {
                text += ", average \(window.string(track.average, using: formatter))"
                text += ", range \(window.string(track.minimum, using: formatter))"
                text += " to \(window.string(track.maximum, using: formatter))"
            }
            if let note = track.peakNote { text += ", highest while \(note) led" }
            return text
        }
        var text = sentence("\(module.key.label) over \(over)", window.primary)
        if let secondary = module.secondary, let track = window.secondary {
            text += ". " + sentence(secondary.label, track)
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
/// Bars keep their meaning from the sparkline, a bar to each column's high, with the
/// now marker in the same fill. The line style draws the low-to-high band with the
/// mean through it; the filled style fills from the floor to the high instead, one
/// shape rather than a band and a wash, so it costs the same one layer. The stroke
/// carries the line, the lone-minute dots and the marker, which sits on the newest
/// column at rest and on the scrubbed one while the pointer is over the plot.
struct BandLayer: View {
    let plot: BandPlot
    let lineTint: Color
    let bandTint: Color
    let style: ChartStyle
    /// Whether too few points draw as a dashed level across the whole plot, the way
    /// the sparkline does. Right for a short window, where the level is the reading.
    /// Wrong for a day: a dashed line across 24 hours of axis claims a value for
    /// hours that have not happened, so a day draws only the minutes it has.
    var levelsWhenSparse = true
    /// The column under the pointer, which takes the marker from the newest one.
    var scrubbed: Int? = nil

    var body: some View {
        if !plot.isEmpty {
            if plot.supportsTrend || !levelsWhenSparse {
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

    private var marked: Int? { scrubbed ?? plot.newestSampled }

    @ViewBuilder
    private var trend: some View {
        switch style {
        case .bars:
            PlotShape(plot.barPath(newest: marked)).fill(lineTint)
        case .filledLine, .line:
            PlotShape(style == .filledLine ? plot.filledBandPath() : plot.bandPath()).fill(bandTint)
            PlotShape(plot.strokeMarksPath(lineWidth: Design.Chart.lineWidth, newest: marked))

                .stroke(lineTint, style: StrokeStyle(lineWidth: Design.Chart.lineWidth,
                                                     lineCap: .round, lineJoin: .round))
        }
    }
}

/// The other half of a pair: the mean alone, thinner and quieter than the headline
/// series, with the same dots for lone minutes. No band, since two bands in one tint
/// are a muddle, and no marker, since the footer already reads both directions.
struct SecondaryLayer: View {
    let plot: BandPlot
    let tint: Color

    static let lineWidth: CGFloat = 1

    var body: some View {
        if !plot.isEmpty {
            PlotShape(plot.strokeMarksPath(lineWidth: Self.lineWidth))
                .stroke(tint.opacity(0.55), style: StrokeStyle(lineWidth: Self.lineWidth,
                                                              lineCap: .round, lineJoin: .round))
        }
    }
}

/// The stretches of the window a 0 or 1 series spent at 1, washed behind the plot.
struct ShadeLayer: View {
    let plot: BandPlot

    var body: some View {
        PlotShape(plot.spanPath { $0.mean >= HistoryChart.shadeThreshold })
            .fill(Design.Palette.primaryText.opacity(Design.Chart.gridOpacity * 0.75))
    }
}

/// The last 24 hours as a shape and nothing else: no axis, no footer, no scrub.
///
/// For the desktop widget, which is looked past rather than at, and which ignores
/// the pointer when it is click-through. It answers "was it busy today" at a glance
/// and leaves the reading to the panel.
public struct HistorySilhouette: View {
    private let module: ModuleHistory
    private let minutes: MinuteSeries
    private let secondary: MinuteSeries?
    private let shade: MinuteSeries?
    private let tint: Color
    private let style: ChartStyle
    private let height: CGFloat

    @Environment(\.metricFormatter) private var formatter

    public init(_ module: ModuleHistory, day: MinuteHistory, tint: Color, style: ChartStyle,
                height: CGFloat) {
        self.module = module
        self.minutes = day.series(module.key)
        self.secondary = module.secondary.map { day.series($0) }
        self.shade = module.shading.map { day.series($0) }
        self.tint = tint
        self.style = style
        self.height = height
    }

    public var isEmpty: Bool { minutes.isEmpty }

    public var body: some View {
        GeometryReader { proxy in
            let rect = ChartLayout.plotRect(in: proxy.size)
            if rect.width > 1, rect.height > 1 {
                // The baseline is the axis, drawn whether or not the day has filled:
                // without it a first minute of data is a dot floating in blank space,
                // and the blank has no frame to read as "the rest of the day". The
                // panel gets the same frame from its gridlines and time labels.
                EmptyBaseline(rect: rect)
                if !minutes.isEmpty {
                    let scale = self.scale
                    if let shade {
                        let plot = BandPlot(rect: rect, scale: scale, minutes: shade)
                        if plot.straddles(HistoryChart.shadeThreshold) {
                            ShadeLayer(plot: plot)
                        }
                    }

                    if let secondary {
                        SecondaryLayer(plot: BandPlot(rect: rect, scale: scale, minutes: secondary),
                                       tint: tint)
                    }
                    BandLayer(plot: BandPlot(rect: rect, scale: scale, minutes: minutes),
                              lineTint: tint,
                              bandTint: tint.opacity(Design.Chart.fillOpacity * 1.5),
                              style: style, levelsWhenSparse: false)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(minutes.key.label), last 24 hours")
        .accessibilityValue(summary)
    }

    private var scale: ChartScale {
        ChartScale.resolve(peak: Swift.max(minutes.maximum, secondary?.maximum ?? 0),
                           domain: module.domain,
                           naturalUpperBound: module.key.naturalUpperBound,
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
    /// What a module's history chart draws. Nil for modules with nothing to chart
    /// over time.
    ///
    /// Temperature gets a stated band: a die swinging 44 to 58 degrees against a
    /// zero baseline is a flat line four fifths of the way up the plot. Network and
    /// disk are pairs, labelled the way the menu bar labels them. The battery is
    /// shaded where the Mac was on the charger.
    public var historySeries: ModuleHistory? {
        switch self {
        case .cpu: return ModuleHistory(.cpuTotal)
        case .memory: return ModuleHistory(.memoryUsed)
        case .gpu: return ModuleHistory(.gpuUtilization)
        case .network: return ModuleHistory(.networkDownload, secondary: .networkUpload, glyphs: ("↓", "↑"))
        case .disk: return ModuleHistory(.diskRead, secondary: .diskWrite, glyphs: ("R", "W"))
        case .battery: return ModuleHistory(.batteryPercent, shading: .batteryPlugged)
        case .thermal: return ModuleHistory(.cpuTemperature, domain: 30...100)
        case .processes, .system: return nil
        }
    }
}
