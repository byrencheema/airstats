import SwiftUI
import AirStatKit

/// A compact inline trend, sized to sit beside a readout row rather than to be
/// studied on its own. No axes, no legend, one series.
///
/// This is the workhorse: there is one of these per module, redrawing every sample,
/// for as long as the app is open. It is a single `Canvas` and at most two paths.
public struct Sparkline: View {
    private let series: ChartSeries
    private let settings: ChartSettings
    private let height: CGFloat

    @Environment(\.metricFormatter) private var formatter

    public init(_ series: ChartSeries,
                settings: ChartSettings = ChartSettings(),
                height: CGFloat = Design.Chart.sparklineHeight) {
        self.series = series
        self.settings = settings
        self.height = height
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if !series.stats.isEmpty && (scale.isDerived || scale.isExplicit) {
                scaleCaption
            }
            GeometryReader { proxy in
                plot(in: proxy.size)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(series.label) trend")
        .accessibilityValue(ChartCaption.accessibilitySummary([series], scale: scale,
                                                              formatter: formatter))
    }

    private var scale: ChartScale {
        ChartScale.resolve([series], adaptive: ChartSettings.usesAdaptiveScale)
    }

    /// The caption is not decoration and not subject to `showsValueLabels`: whenever
    /// the vertical axis is something other than the assumed 0-to-natural-maximum, it
    /// *is* the axis. Without it a flat-looking line at 2 KB/s and one at 100 MB/s are
    /// the same picture, and a 30–100 °C band is indistinguishable from a 0 baseline.
    ///
    /// Which is exactly why it must never truncate — "peak 4.4…" is worse than nothing,
    /// because it looks like a number while withholding the digits that matter. The
    /// words go first, and below that the figures shrink rather than clip.
    private var scaleCaption: some View {
        let long: String
        let short: String
        if scale.isExplicit {
            let low = series.string(scale.lowerBound, using: formatter)
            let high = series.string(scale.upperBound, using: formatter)
            long = "\(low)–\(high)"
            short = high
        } else {
            short = series.string(scale.peak, using: formatter)
            long = "peak \(short)"
        }
        return ViewThatFits(in: .horizontal) {
            captionText(long, fixed: true)
            captionText(short, fixed: true)
            captionText(short, fixed: false).minimumScaleFactor(0.7)
        }
    }

    private func captionText(_ string: String, fixed: Bool) -> some View {
        SwiftUI.Text(string)
            .font(Design.Text.micro)
            .foregroundStyle(Design.Palette.tertiaryText)
            .lineLimit(1)
            .fixedSize(horizontal: fixed, vertical: false)
    }

    /// One layer per mark rather than one drawing pass. See `PlotShape` for why this
    /// is not a `Canvas`.
    @ViewBuilder
    private func plot(in size: CGSize) -> some View {
        let rect = ChartLayout.plotRect(in: size)
        if rect.width > 1, rect.height > 1 {
            if series.stats.isEmpty {
                EmptyBaseline(rect: rect)
            } else {
                let scale = self.scale
                let plot = ChartPlot(rect: rect, scale: scale, samples: series.samples)
                ZStack {
                    // A midline only means something against a fixed domain. On a
                    // derived scale "half of the window peak" is not a fact about the
                    // machine.
                    if ChartSettings.showsGrid && !scale.isDerived {
                        GridLayer(rect: rect, divisions: 2, interiorOnly: true)
                    }
                    SeriesLayer(plot: plot, size: size, tint: series.tint,
                                style: settings.style, smoothed: ChartSettings.smoothsCurves)
                    if ChartSettings.showsValueLabels, plot.supportsTrend,
                       let last = plot.points.last {
                        PlotShape(ChartLayout.marker(at: CGPoint(x: rect.maxX, y: plot.y(last))))
                            .fill(series.tint)
                    }
                }
            }
        }
    }
}

// MARK: - Layout

enum ChartLayout {

    /// Inset so a sample at the top of the domain draws its full stroke, and the
    /// end-of-line marker its full circle, instead of being sliced by the frame —
    /// the fixture waveform's spike exists to catch exactly that.
    ///
    /// The bottom is left flush: a filled area has to meet the baseline, and a value
    /// of zero is legitimately drawn as a line sitting on the floor.
    static let edgeInset: CGFloat = 2

    static func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: edgeInset,
               y: edgeInset,
               width: max(size.width - edgeInset * 2, 0),
               height: max(size.height - edgeInset, 0))
    }

    /// The dot marking the newest sample at the right edge of a line.
    static func marker(at point: CGPoint, radius: CGFloat = 2) -> Path {
        Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                               width: radius * 2, height: radius * 2))
    }
}
