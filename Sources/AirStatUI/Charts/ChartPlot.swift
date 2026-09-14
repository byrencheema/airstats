import SwiftUI
import AirStatKit

/// Turns samples into `Path`s.
///
/// Everything a chart draws is one path per visual layer — a line, a fill, the whole
/// bar set — rather than a view per data point. At the sampling rate, for the life of
/// a session, that difference is the whole performance story: a 150-point sparkline
/// costs one path build, not 150 view identities for SwiftUI to diff.
struct ChartPlot {
    let rect: CGRect
    let scale: ChartScale
    /// Oldest-to-newest, already reduced to at most one value per drawable column.
    let points: ContiguousArray<Double>

    init(rect: CGRect, scale: ChartScale, samples: SampleRing) {
        self.rect = rect
        self.scale = scale
        self.points = Self.reduce(samples, columns: Self.columnCount(for: rect.width))
    }

    /// One point per available column at most. Below ~1pt per sample the extra
    /// samples cannot be seen, and building a path with them is pure cost.
    private static func columnCount(for width: CGFloat) -> Int {
        max(2, Int(width.rounded(.up)))
    }

    /// Bucket the ring down to `columns` values, keeping each bucket's **maximum**.
    ///
    /// Plain striding would silently drop a one-sample spike, which is precisely the
    /// event a system monitor exists to show. Taking the maximum never invents a value
    /// that was not sampled, and it never hides one.
    private static func reduce(_ ring: SampleRing, columns: Int) -> ContiguousArray<Double> {
        let n = ring.count
        guard n > 0 else { return [] }
        guard n > columns else {
            var out = ContiguousArray<Double>()
            out.reserveCapacity(n)
            for i in 0..<n { out.append(Double(ring[i])) }
            return out
        }
        var out = ContiguousArray<Double>()
        out.reserveCapacity(columns)
        for column in 0..<columns {
            let start = column * n / columns
            let end = max(start + 1, (column + 1) * n / columns)
            var peak = -Double.greatestFiniteMagnitude
            for i in start..<min(end, n) { peak = max(peak, Double(ring[i])) }
            out.append(peak)
        }
        return out
    }

    var count: Int { points.count }
    var isEmpty: Bool { points.isEmpty }
    /// Below `Design.Chart.minimumPoints` a line would imply a trend two samples
    /// cannot support, so callers draw a flat level instead.
    var supportsTrend: Bool { points.count >= Design.Chart.minimumPoints }

    func x(_ index: Int) -> CGFloat {
        guard count > 1 else { return rect.midX }
        return rect.minX + rect.width * CGFloat(index) / CGFloat(count - 1)
    }

    func y(_ value: Double) -> CGFloat {
        let fraction = min(max((value - scale.lowerBound) / scale.span, 0), 1)
        return rect.maxY - rect.height * CGFloat(fraction)
    }

    // MARK: Paths

    /// The trend line. `smoothed` uses monotone cubic interpolation, which by
    /// construction cannot bulge outside the two samples it joins — an ordinary
    /// Catmull-Rom spline will happily arc above 100 % CPU between two 99 % samples.
    func linePath(smoothed: Bool) -> Path {
        var path = Path()
        guard count > 0 else { return path }
        guard count > 1 else {
            let y = y(points[0])
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            return path
        }
        if smoothed && count > 2 {
            appendMonotoneCurve(to: &path)
        } else {
            path.move(to: CGPoint(x: x(0), y: y(points[0])))
            for i in 1..<count { path.addLine(to: CGPoint(x: x(i), y: y(points[i]))) }
        }
        return path
    }

    /// The line closed down to the baseline, for filled styles.
    func areaPath(smoothed: Bool) -> Path {
        var path = linePath(smoothed: smoothed)
        guard !path.isEmpty else { return path }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    /// Every bar as subpaths of a single `Path`, so the bar style costs one fill
    /// regardless of how many samples are on screen.
    func barPath() -> Path {
        var path = Path()
        guard count > 0 else { return path }
        let slot = rect.width / CGFloat(count)
        // A gap is what makes bars read as bars. Without one, 150 samples across a
        // panel merge into a solid mass indistinguishable from a filled area — which
        // is a different style the user could have picked.
        let gap = min(max(slot * 0.25, 0.4), 1.5)
        let width = max(slot - gap, 0.6)
        for i in 0..<count {
            let top = y(points[i])
            // A non-zero sample must never render as nothing; a hairline reads as
            // "a little", an empty column reads as "none", and they are different.
            let height = max(rect.maxY - top, points[i] > 0 ? 1 : 0)
            guard height > 0 else { continue }
            path.addRect(CGRect(x: rect.minX + CGFloat(i) * slot,
                                y: rect.maxY - height,
                                width: width,
                                height: height))
        }
        return path
    }

    /// A flat line at the newest value, used when there are too few samples for a
    /// trend. It asserts a level, which is known, and no direction, which is not.
    func levelPath() -> Path {
        var path = Path()
        let value = points.last ?? 0
        let level = isEmpty ? rect.maxY : y(value)
        path.move(to: CGPoint(x: rect.minX, y: level))
        path.addLine(to: CGPoint(x: rect.maxX, y: level))
        return path
    }

    /// Horizontal gridlines. `interiorOnly` omits the lines on the frame itself,
    /// which at sparkline height would draw a box around 28 points of chart.
    static func gridPath(in rect: CGRect, divisions: Int = 4, interiorOnly: Bool = false) -> Path {
        var path = Path()
        guard divisions > 0 else { return path }
        let steps = interiorOnly ? Array(1..<divisions) : Array(0...divisions)
        for step in steps {
            let y = rect.maxY - rect.height * CGFloat(step) / CGFloat(divisions)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }

    /// Fritsch–Carlson monotone cubic Hermite.
    ///
    /// The tangent limiter is the whole point: clamping each segment's slopes into the
    /// circle of radius 3 guarantees the curve stays monotone across every interval,
    /// which means it never leaves the range of the two samples it connects. The drawn
    /// curve is smoothed; the data behind it is untouched.
    private func appendMonotoneCurve(to path: inout Path) {
        let n = count
        var xs = ContiguousArray<CGFloat>(); xs.reserveCapacity(n)
        var ys = ContiguousArray<CGFloat>(); ys.reserveCapacity(n)
        for i in 0..<n {
            xs.append(x(i))
            ys.append(y(points[i]))
        }

        var secants = ContiguousArray<CGFloat>(); secants.reserveCapacity(n - 1)
        for i in 0..<(n - 1) {
            let dx = xs[i + 1] - xs[i]
            secants.append(dx > 0 ? (ys[i + 1] - ys[i]) / dx : 0)
        }

        var tangents = ContiguousArray<CGFloat>(repeating: 0, count: n)
        tangents[0] = secants[0]
        tangents[n - 1] = secants[n - 2]
        for i in 1..<(n - 1) {
            // A sign change is a local extremum; a zero tangent there is what stops the
            // curve overshooting through a peak.
            tangents[i] = secants[i - 1] * secants[i] <= 0 ? 0 : (secants[i - 1] + secants[i]) / 2
        }
        for i in 0..<(n - 1) where secants[i] == 0 {
            tangents[i] = 0
            tangents[i + 1] = 0
        }
        for i in 0..<(n - 1) where secants[i] != 0 {
            let a = tangents[i] / secants[i]
            let b = tangents[i + 1] / secants[i]
            let magnitude = a * a + b * b
            if magnitude > 9 {
                let t = 3 / magnitude.squareRoot()
                tangents[i] = t * a * secants[i]
                tangents[i + 1] = t * b * secants[i]
            }
        }

        path.move(to: CGPoint(x: xs[0], y: ys[0]))
        for i in 0..<(n - 1) {
            let dx = (xs[i + 1] - xs[i]) / 3
            path.addCurve(to: CGPoint(x: xs[i + 1], y: ys[i + 1]),
                          control1: CGPoint(x: xs[i] + dx, y: ys[i] + tangents[i] * dx),
                          control2: CGPoint(x: xs[i + 1] - dx, y: ys[i + 1] - tangents[i + 1] * dx))
        }
    }
}

// MARK: - Shared drawing

/// An already-built `Path`, wrapped so it can be filled, stroked and clipped as a view.
///
/// Every chart in the app draws through this. `Canvas` is the obvious tool for the job
/// and is the one thing that must not be used here: the first `Canvas` to render
/// anywhere in the process brings up SwiftUI's Metal renderer, and the GPU arena it
/// allocates is charged to the app and never handed back. Measured on an M3 Pro, one
/// `Canvas` in the panel took the process from 12 MB to 112 MB the first time the panel
/// was opened — 93 MB of `Owned physical footprint (unmapped) (graphics)` plus 3.5 MB
/// of `IOAccelerator` — and it stayed there for the rest of the session. The same
/// drawing expressed as shapes costs nothing measurable, because Core Animation
/// rasterises paths without ever touching the GPU renderer.
///
/// The path is built in the coordinate space of the view this is applied to, so its
/// points are absolute and `path(in:)` ignores the rect it is handed.
struct PlotShape: Shape {
    let built: Path

    init(_ built: Path) { self.built = built }

    func path(in rect: CGRect) -> Path { built }
}

/// One series in the style the user chose. Kept in one place so a sparkline and a
/// detail chart can never disagree about what "filled line" looks like.
struct SeriesLayer: View {
    let plot: ChartPlot
    /// The size of the view the plot was laid out in. Only the gradient needs it, and
    /// only because SwiftUI resolves gradient stops against the view rather than
    /// against the plot rect inside it.
    let size: CGSize
    let tint: Color
    let style: ChartStyle
    let smoothed: Bool
    var lineWidth: CGFloat = Design.Chart.lineWidth

    var body: some View {
        if !plot.isEmpty {
            if plot.supportsTrend {
                trend
            } else {
                level
            }
        }
    }

    /// Dashed, dimmed, and capped with the current-value marker: it states a level
    /// without asserting a direction, and it does not read as a rule drawn across the
    /// chart.
    private var level: some View {
        ZStack {
            PlotShape(plot.levelPath())
                .stroke(tint.opacity(0.45),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt, dash: [2, 3]))
            if let last = plot.points.last {
                PlotShape(ChartLayout.marker(at: CGPoint(x: plot.rect.maxX, y: plot.y(last))))
                    .fill(tint)
            }
        }
    }

    private var trend: some View {
        ZStack {
            switch style {
            case .bars:
                PlotShape(plot.barPath()).fill(tint)
            case .filledLine:
                PlotShape(plot.areaPath(smoothed: smoothed)).fill(areaGradient)
                linePath
            case .line:
                linePath
            }
        }
    }

    private var linePath: some View {
        PlotShape(plot.linePath(smoothed: smoothed))
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round,
                                             lineJoin: .round))
    }

    /// Anchored to the plot rect rather than to the view. On a 28-point sparkline the
    /// two differ by the 2-point top inset, which is 7 % of the ramp — enough to make
    /// the fill visibly paler at the peak than the same chart at detail height.
    private var areaGradient: LinearGradient {
        let height = max(size.height, 1)
        return LinearGradient(
            gradient: Gradient(colors: [tint.opacity(Design.Chart.fillOpacity * 2),
                                        tint.opacity(0)]),
            startPoint: UnitPoint(x: 0.5, y: plot.rect.minY / height),
            endPoint: UnitPoint(x: 0.5, y: plot.rect.maxY / height))
    }
}

/// Horizontal gridlines for a plot.
struct GridLayer: View {
    let rect: CGRect
    var divisions: Int = 4
    var interiorOnly: Bool = false

    var body: some View {
        PlotShape(ChartPlot.gridPath(in: rect, divisions: divisions, interiorOnly: interiorOnly))
            .stroke(Design.Palette.primaryText.opacity(Design.Chart.gridOpacity),
                    lineWidth: Design.Space.hairline)
    }
}

/// The "nothing sampled yet" state: a baseline, drawn deliberately, so an empty chart
/// reads as a chart waiting for data rather than as a broken one.
struct EmptyBaseline: View {
    let rect: CGRect

    var body: some View {
        PlotShape(path)
            .stroke(Design.Palette.track,
                    style: StrokeStyle(lineWidth: Design.Chart.lineWidth, lineCap: .round,
                                       dash: [2, 4]))
    }

    private var path: Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - Design.Space.hairline))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - Design.Space.hairline))
        return path
    }
}
