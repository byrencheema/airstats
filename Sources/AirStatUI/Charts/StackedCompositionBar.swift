import SwiftUI
import AirStatKit

/// One labelled slice of a whole.
public struct CompositionSegment: Equatable, Identifiable {
    public let id: String
    public let label: String
    /// The abbreviation used when the legend has to fit on one line. Defaults to
    /// `label`; supply something shorter for the words that are the reason it does
    /// not fit ("Compressed" is 60pt of a 340pt panel on its own).
    public let shortLabel: String
    /// In whatever unit `StackedCompositionBar`'s format expects — bytes, for both
    /// the memory and disk breakdowns.
    public let value: Double
    public let tint: Color
    /// Free space, purgeable space: real parts of the total, but not *consumption*.
    /// Drawn as track rather than colour so the eye reads the bar as "how much is
    /// taken" without the app having to hide anything.
    public let isRemainder: Bool

    public init(id: String, label: String, shortLabel: String? = nil,
                value: Double, tint: Color, isRemainder: Bool = false) {
        self.id = id
        self.label = label
        self.shortLabel = shortLabel ?? label
        self.value = max(0, value)
        self.tint = tint
        self.isRemainder = isRemainder
    }
}

/// A single horizontal bar split into labelled segments, with a legend beneath.
///
/// Memory (app / wired / compressed / cached / free) and disk (used / purgeable /
/// free) are the same picture: a fixed total, divided. Both get the same component so
/// they read as the same kind of fact.
public struct StackedCompositionBar: View {
    private let segments: [CompositionSegment]
    private let format: ChartValueFormat
    private let barHeight: CGFloat
    private let showsLegend: Bool
    private let accessibilityTitle: String

    @Environment(\.metricFormatter) private var formatter

    public init(_ segments: [CompositionSegment],
                format: ChartValueFormat,
                title: String,
                barHeight: CGFloat = 10,
                showsLegend: Bool = true) {
        self.segments = segments
        self.format = format
        self.accessibilityTitle = title
        self.barHeight = barHeight
        self.showsLegend = showsLegend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            GeometryReader { proxy in
                bar(in: proxy.size)
            }
            .frame(height: barHeight)
            if showsLegend { legend }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilityValue)
    }

    private var total: Double { segments.reduce(0) { $0 + $1.value } }

    /// One shape per segment rather than one drawing pass; see `PlotShape` for why
    /// this is not a `Canvas`.
    @ViewBuilder
    private func bar(in size: CGSize) -> some View {
        let outline = Path(roundedRect: CGRect(origin: .zero, size: size),
                           cornerRadius: min(Design.Radius.bar, size.height / 2),
                           style: .continuous)
        ZStack {
            PlotShape(outline).fill(Design.Palette.track)
            if total > 0, size.width > 0 {
                ZStack {
                    ForEach(Array(fills(in: size).enumerated()), id: \.offset) { _, fill in
                        PlotShape(fill.path).fill(fill.tint)
                    }
                }
                // Segments are drawn inside the rounded outline rather than as rounded
                // shapes of their own, so the bar reads as one object that has been
                // divided.
                .clipShape(PlotShape(outline))
            }
        }
    }

    private struct Fill {
        let path: Path
        let tint: Color
    }

    private func fills(in size: CGSize) -> [Fill] {
        var result: [Fill] = []
        var x: CGFloat = 0
        for segment in segments {
            let width = CGFloat(segment.value / total) * size.width
            // A segment that exists must be visible. Below a hairline it would round
            // away to nothing, and "0.3 GB of swap" would look identical to none.
            let drawn = segment.value > 0 ? max(width, Design.Space.hairline) : 0
            defer { x += width }
            guard drawn > 0, !segment.isRemainder else { continue }
            result.append(Fill(path: Path(CGRect(x: x, y: 0, width: drawn, height: size.height)),
                               tint: segment.tint))
            // A hairline gap keeps two adjacent segments of similar weight apart
            // without needing a border colour that would fight the palette.
            if drawn > Design.Space.xs {
                result.append(Fill(path: Path(CGRect(x: x + drawn - Design.Space.hairline, y: 0,
                                                     width: Design.Space.hairline,
                                                     height: size.height)),
                                   tint: Design.Palette.track))
            }
        }
        return result
    }

    // MARK: Legend

    /// Widest form first: one line with full words, one line with abbreviations, then
    /// two columns over as many rows as it takes.
    ///
    /// The two-column grid costs about 47pt for five segments where a single line costs
    /// 12pt, and in a 340pt panel that difference is the module. So the single line is
    /// tried first and only genuinely gives way when the words will not fit.
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            inlineLegend(abbreviated: false)
            inlineLegend(abbreviated: true)
            gridLegend
        }
        .accessibilityHidden(true)
    }

    private func inlineLegend(abbreviated: Bool) -> some View {
        HStack(spacing: Design.Space.m) {
            ForEach(segments) { segment in
                entry(segment, abbreviated: abbreviated).fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    private var gridLegend: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            ForEach(Array(legendRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Design.Space.l) {
                    ForEach(row) { segment in
                        entry(segment, abbreviated: false)
                    }
                    if row.count == 1 { Spacer(minLength: 0) }
                }
            }
        }
    }

    private var legendRows: [[CompositionSegment]] {
        stride(from: 0, to: segments.count, by: 2).map { start in
            Array(segments[start..<min(start + 2, segments.count)])
        }
    }

    private func entry(_ segment: CompositionSegment, abbreviated: Bool) -> some View {
        HStack(spacing: Design.Space.s) {
            // The remainder swatch gets an outline: filled with the track colour alone
            // it reads as a missing swatch rather than as "this part is empty".
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(segment.isRemainder ? Design.Palette.track : segment.tint)
                .overlay {
                    if segment.isRemainder {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .strokeBorder(Design.Palette.separator, lineWidth: Design.Space.hairline)
                    }
                }
                .frame(width: 6, height: 6)
            SwiftUI.Text(abbreviated ? segment.shortLabel : segment.label)
                .font(Design.Text.caption)
                .foregroundStyle(Design.Palette.secondaryText)
                .lineLimit(1)
            SwiftUI.Text(format.string(segment.value, using: formatter))
                .font(Design.Text.micro.monospacedDigit())
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityValue: String {
        guard total > 0 else { return "No data" }
        let parts = segments.map { segment in
            let share = formatter.percent(segment.value / total)
            return "\(segment.label) \(format.string(segment.value, using: formatter)), \(share)"
        }
        return "Total \(format.string(total, using: formatter)). " + parts.joined(separator: ". ")
    }
}

extension CompositionSegment {
    /// Memory's breakdown as the panel draws it: four shades of the memory tint for the
    /// parts in use, and free memory last as the remainder.
    public static func memory(_ memory: MemorySnapshot) -> [CompositionSegment] {
        let tint = Design.Palette.metric(.memory)
        let shades = ChartPalette.composition(tint, count: 4)
        return [
            CompositionSegment(id: "app", label: L10n.tr("App", "Ứng dụng"), shortLabel: L10n.tr("App", "App"),
                               value: Double(memory.appBytes), tint: shades[0]),
            CompositionSegment(id: "wired", label: L10n.tr("Wired", "Hệ thống"), shortLabel: L10n.tr("Wired", "Hệ thống"),
                               value: Double(memory.wiredBytes), tint: shades[1]),
            CompositionSegment(id: "compressed", label: L10n.tr("Compressed", "Đã nén"), shortLabel: L10n.tr("Comp", "Nén"),
                               value: Double(memory.compressedBytes), tint: shades[2]),
            CompositionSegment(id: "cached", label: L10n.tr("Cached", "Đệm"), shortLabel: L10n.tr("Cached", "Đệm"),
                               value: Double(memory.cachedBytes), tint: shades[3]),
            CompositionSegment(id: "free", label: L10n.tr("Free", "Trống"),
                               value: Double(memory.freeBytes),
                               tint: Design.Palette.track, isRemainder: true),
        ]
    }
}
