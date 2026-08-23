import SwiftUI
import AirStatKit

/// The larger chart: a plot with its scale, its time window and its numbers attached.
///
/// Where `Sparkline` is a glance, this is meant to be read. It carries the three
/// things that stop a graph being decoration — what the vertical axis tops out at,
/// how much time the horizontal axis covers, and what the current value actually is.
/// Multiple series may share it (upload and download, user and system) and then share
/// a single resolved scale, so their heights are comparable.
public struct DetailChart: View {
    private let series: [ChartSeries]
    private let settings: ChartSettings
    private let height: CGFloat
    private let title: String?

    @Environment(\.metricFormatter) private var formatter

    public init(_ series: [ChartSeries],
                settings: ChartSettings = ChartSettings(),
                height: CGFloat = Design.Chart.detailHeight,
                title: String? = nil) {
        self.series = series
        self.settings = settings
        self.height = height
        self.title = title
    }

    public init(_ series: ChartSeries,
                settings: ChartSettings = ChartSettings(),
                height: CGFloat = Design.Chart.detailHeight,
                title: String? = nil) {
        self.init([series], settings: settings, height: height, title: title)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            header
            plot
            footer
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? series.first?.label ?? "Chart")
        .accessibilityValue(ChartCaption.accessibilitySummary(series, scale: scale,
                                                              formatter: formatter))
    }

    private var scale: ChartScale {
        ChartScale.resolve(series, adaptive: ChartSettings.usesAdaptiveScale)
    }

    private var hasSamples: Bool { series.contains { !$0.stats.isEmpty } }

    // MARK: Header

    /// Two variants, widest first. `ViewThatFits` is applied to the whole row rather
    /// than to each callout, because only the row knows the width they are competing
    /// for — a callout measured on its own always thinks it fits.
    @ViewBuilder
    private var header: some View {
        if title != nil || series.count > 1 || ChartSettings.showsValueLabels {
            ViewThatFits(in: .horizontal) {
                headerRow(showsSeriesNames: true)
                headerRow(showsSeriesNames: false)
            }
        }
    }

    private func headerRow(showsSeriesNames: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
            if let title {
                SwiftUI.Text(title)
                    .font(Design.Text.sectionHeader)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Design.Space.xs)
            if hasSamples && ChartSettings.showsValueLabels {
                ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                    calloutBody(item, showsName: showsSeriesNames)
                }
                // The numbers outrank the words that label them: in a 220pt desktop widget a
                // truncated "2…." is worse than a dropped name.
                .layoutPriority(1)
            }
        }
    }

    /// The newest sample, tagged with the series' colour so a two-series chart needs
    /// no separate legend. In a desktop widget-width chart the dot alone carries the
    /// identification, so the written name is the first thing to go.
    private func calloutBody(_ item: ChartSeries, showsName: Bool) -> some View {
        HStack(spacing: Design.Space.xs) {
            if series.count > 1 {
                Circle()
                    .fill(item.tint)
                    .frame(width: 5, height: 5)
                if showsName {
                    SwiftUI.Text(item.label)
                        .font(Design.Text.micro)
                        .foregroundStyle(Design.Palette.secondaryText)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            SwiftUI.Text(item.stats.last.map { item.string($0, using: formatter) }
                         ?? MetricFormatter.unavailable)
                .font(Design.Text.value)
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentTransition(.numericText())
        }
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { proxy in
            marks(in: proxy.size)
        }
        .frame(height: height)
        .overlay(alignment: .topLeading) { boundLabel }
        .overlay(alignment: .bottomLeading) { floorLabel }
        .overlay { if !hasSamples { emptyNote } }
    }

    /// One layer per mark rather than one drawing pass. See `PlotShape` for why this
    /// is not a `Canvas`.
    @ViewBuilder
    private func marks(in size: CGSize) -> some View {
        let rect = ChartLayout.plotRect(in: size)
        if rect.width > 1, rect.height > 1 {
            if !hasSamples {
                EmptyBaseline(rect: rect)
            } else {
                let scale = self.scale
                let plots = series.map { ChartPlot(rect: rect, scale: scale, samples: $0.samples) }
                ZStack {
                    if ChartSettings.showsGrid, let first = plots.first {
                        GridLayer(plot: first)
                    }
                    // Drawn back to front so the first series — the one the module is
                    // really about — ends up on top of any companion series.
                    ForEach(Array(plots.enumerated()).reversed(), id: \.offset) { index, plot in
                        SeriesLayer(plot: plot, size: size, tint: series[index].tint,
                                    style: settings.style, smoothed: ChartSettings.smoothsCurves)
                    }
                    if ChartSettings.showsValueLabels {
                        ForEach(Array(plots.enumerated()), id: \.offset) { index, plot in
                            if plot.supportsTrend, let last = plot.points.last {
                                PlotShape(ChartLayout.marker(at: CGPoint(x: rect.maxX,
                                                                         y: plot.y(last))))
                                    .fill(series[index].tint)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The top of a *fixed* vertical axis, stated in place. A derived scale is topped
    /// out by the data itself, so a label there would sit under the very peak that set
    /// it; that bound is reported in the footer instead, where nothing can cover it.
    @ViewBuilder
    private var boundLabel: some View {
        if hasSamples && !scale.isDerived {
            SwiftUI.Text(series.first?.string(scale.upperBound, using: formatter) ?? "")
                .font(Design.Text.micro)
                .foregroundStyle(Design.Palette.tertiaryText)
                .padding(.leading, Design.Space.xs)
                // Sits below the top gridline, not on it, so a series pegged at the
                // top of its domain draws its stroke above the label rather than
                // through it.
                .padding(.top, Design.Space.s)
                .accessibilityHidden(true)
        }
    }

    /// A lifted baseline has to say so. Zero baselines are left unlabelled because
    /// zero is the assumption; anything else is a claim the chart must state.
    @ViewBuilder
    private var floorLabel: some View {
        if hasSamples && scale.isExplicit && scale.lowerBound != 0 {
            SwiftUI.Text(series.first?.string(scale.lowerBound, using: formatter) ?? "")
                .font(Design.Text.micro)
                .foregroundStyle(Design.Palette.tertiaryText)
                .padding(.leading, Design.Space.xs)
                .padding(.bottom, Design.Space.xxs)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var emptyNote: some View {
        SwiftUI.Text("Collecting samples…")
            .font(Design.Text.micro)
            .foregroundStyle(Design.Palette.tertiaryText)
            .accessibilityHidden(true)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Design.Space.m) {
            SwiftUI.Text(ChartCaption.window(series.first?.span ?? 0))
                .font(Design.Text.micro)
                .foregroundStyle(Design.Palette.tertiaryText)
                .fixedSize()
            Spacer(minLength: Design.Space.xs)
            // Shed statistics from the left as width runs out rather than truncating
            // the string. The maximum is last to go: on a derived scale it is the only
            // number that says how tall the plot actually is.
            ViewThatFits(in: .horizontal) {
                ForEach(Array(statisticsTiers.enumerated()), id: \.offset) { _, tier in
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

    /// Window statistics, widest form first, for `ViewThatFits` to choose between.
    ///
    /// Prefixed by the series name when more than one is plotted, so the numbers are
    /// never silently attributed to the wrong line. When value labels are off but the
    /// scale came from the data, the peak is still printed: without it the plot's
    /// height means nothing at all.
    private var statisticsTiers: [String] {
        guard let first = series.first, !first.stats.isEmpty else { return [""] }
        let stats = first.stats
        guard ChartSettings.showsValueLabels, stats.supportsTrend else {
            return scale.isDerived ? ["peak \(first.string(scale.peak, using: formatter))"] : [""]
        }
        let prefix = series.count > 1 ? "\(first.label)  " : ""
        let minimum = "min \(first.string(stats.minimum, using: formatter))"
        let average = "avg \(first.string(stats.average, using: formatter))"
        let maximum = "max \(first.string(stats.maximum, using: formatter))"
        return [
            "\(prefix)\(minimum)  \(average)  \(maximum)",
            "\(minimum)  \(average)  \(maximum)",
            "\(average)  \(maximum)",
            maximum,
        ]
    }
}
