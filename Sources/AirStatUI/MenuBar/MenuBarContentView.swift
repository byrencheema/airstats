import AppKit
import CoreText
import AirStatKit

/// Draws the status item's contents.
///
/// Hand-drawn with Core Graphics rather than composed from SwiftUI: the menu bar
/// redraws at the sampling rate for the entire life of the session, and a layer-backed
/// AppKit view that draws a dozen glyphs and a polyline is roughly two orders of
/// magnitude cheaper per frame than hosting a SwiftUI view hierarchy here.
///
/// Three rules shape everything below.
///
/// One line. No Apple status item stacks text, and two rows in a 22-point bar means
/// two rows of type too small to read at a glance — which is the only thing a menu bar
/// readout is for.
///
/// Nothing is drawn that is not known. A sparkline with no samples is omitted, not
/// flattened to a baseline: a full-width horizontal rule is indistinguishable from a
/// metric pinned at zero. An unavailable readout collapses to a single dash.
///
/// Everything lands on device pixels. At 1x a half-pixel baseline is the difference
/// between a crisp readout and a smeared one, and this sits two pixels from Apple's
/// own perfectly-aligned glyphs.
public final class MenuBarContentView: NSView {

    private var model: MenuBarRenderModel?
    private var placements: [Placement] = []
    private var cachedWidth: CGFloat = 0

    private var fonts = FontSet(monospacedDigits: true)
    private var textCache: [TextKey: CachedText] = [:]
    private var symbolCache: [String: NSImage] = [:]
    private var tintedSymbolCache: [TintKey: NSImage] = [:]
    /// Reused across draws so downsampling a graph allocates nothing in steady state.
    private var columnScratch: [CGFloat] = []

    /// Layout constants. Only values the design system does not already fix live here;
    /// the menu bar's own geometry and type sizes come from `Design.MenuBar`.
    private enum Layout {
        /// Matches the leading/trailing inset AppKit gives a standard status item.
        static let horizontalInset = Design.MenuBar.horizontalInset
        static let graphWidth = Design.MenuBar.graphWidth
        static let graphHeight = Design.MenuBar.graphHeight
        /// One separator inside a readout — between an icon and its number, a graph and
        /// its number, a caption and what it captions. Four gaps in a deliberate ladder
        /// is what makes the grouping legible: 2 binds a glyph to its number, 4 binds
        /// the parts of one readout, 6 binds the two directions of a paired one, and
        /// the 8 between status items separates whole readouts.
        static let partGap = Design.Space.xs
        static let glyphGap = Design.Space.xxs
        static let pairGap = Design.Space.s
        static let symbolSize: CGFloat = 13
        /// Never let the item shrink to a target too small to click.
        static let minimumWidth: CGFloat = 24

        /// The battery indicator. Not in `Design.MenuBar` because none of it is
        /// reusable: these are the proportions of one drawing that exists in one place.
        ///
        /// The number inside sets all of it. Nine points is the smallest the digits can
        /// be and still survive being knocked out of the fill at 1x, "100" at nine
        /// points is 16.5 wide, and a 6.4-point cap height wants about 2.5 points of air
        /// above and below or the shell reads as a box the number is jammed into. That
        /// gives 26 by 14, which is larger than Apple's own empty indicator and has to
        /// be: theirs never has to hold three digits. The 1.86:1 body keeps the
        /// silhouette a battery rather than a long box.
        static let batteryBodyWidth: CGFloat = 26
        static let batteryBodyHeight: CGFloat = 14
        static let batteryCornerRadius: CGFloat = 4
        static let batteryStroke: CGFloat = 1
        /// The terminal on the right, and the gap that keeps it from reading as part of
        /// the shell.
        static let batteryNubWidth: CGFloat = 2
        static let batteryNubHeight: CGFloat = 6
        static let batteryNubGap: CGFloat = 1
        /// Outer edge to the fill, on both axes: enough to clear the shell's shoulders,
        /// and no more, because every point taken off the fill is a point of ink the
        /// knocked-out digits have to sit in.
        static let batteryFillInsetX: CGFloat = 2
        static let batteryFillInsetY: CGFloat = 2
        static let batteryFillRadius: CGFloat = 2
        /// A charge too small to draw honestly still gets a sliver, because an empty
        /// shell and a shell at 2% are not the same thing.
        static let batteryMinimumFill: CGFloat = 2
        /// The shell and its terminal sit back from the fill. Apple draws the outline at
        /// roughly a third of the label colour so the fill is the thing the eye lands on.
        static let batteryShellAlpha: CGFloat = 0.4
        /// The digits inside the shell. Medium rather than regular: a knocked-out stem
        /// one device pixel wide comes out as a dotted line at 1x.
        static let batteryValueFontSize: CGFloat = 9
        /// The charging bolt, beside the shell. 6.5 by 10 is `bolt.fill`'s own ink
        /// aspect of 0.639, at the largest height that still sits inside a 14-point
        /// shell's line.
        static let batteryBoltHeight: CGFloat = 10
        static let batteryBoltWidth: CGFloat = 6.5
        static let batteryBoltGap: CGFloat = 1.5
        /// The network status lights: two dots stacked, download over upload. Five
        /// points each with three between puts the pair at 13, which sits inside the
        /// bar with the same air the stacked type gets, and a five-point dot is still
        /// a disc at 1x rather than a smudge.
        static let statusDotDiameter: CGFloat = 5
        static let statusDotGap: CGFloat = 3
        /// An idle light is drawn, not hidden: a missing dot and a dark dot are not
        /// the same thing, and the pair is what makes the shape legible.
        static let statusDotIdleAlpha: CGFloat = 0.3
        /// The bolt, in a unit box with y running up as this view's coordinates do.
        ///
        /// Traced off `bolt.fill` rather than invented: the symbol was rasterised at 200
        /// points and its left and right ink edges read off row by row, and these six
        /// points reproduce them to within half a percent of the box. Three guessed
        /// polygons came first and every one of them rendered as a four-pointed star,
        /// because a bolt guessed at is symmetric and Apple's is not — the lower wedge
        /// leans a third of the width to the left of the upper one, the two ledges sit
        /// only a tenth of the height apart, and the aspect is 0.64 rather than the 0.8
        /// that looks right on paper. Drawn as a path rather than from the symbol itself
        /// because a template `NSImage` is tinted by AppKit at draw time and that tinting
        /// does not survive this view's context: the bolt came out black on a dark menu
        /// bar, which is invisible. A filled path takes the colour it is given.
        static let batteryBoltPoints: [CGPoint] = [
            CGPoint(x: 0.71, y: 1.00),
            CGPoint(x: 0.00, y: 0.44),
            CGPoint(x: 0.45, y: 0.44),
            CGPoint(x: 0.27, y: 0.00),
            CGPoint(x: 1.00, y: 0.55),
            CGPoint(x: 0.55, y: 0.55),
        ]
        /// Captions and direction glyphs support the number; they never compete with it.
        static let captionAlpha: CGFloat = 0.65
        static let unavailableAlpha: CGFloat = 0.4
        /// Dimmer than live, brighter than absent: the number is real, just old.
        static let staleAlpha: CGFloat = 0.55
        /// Denser than `Design.Chart.fillOpacity` because this plot is 11 points tall,
        /// not 28 — at the panel's opacity the fill vanishes at 1x. Not much denser: a
        /// metric that sits at 76% fills three quarters of the box, and past about a
        /// quarter opacity that stops being a graph and becomes a grey brick.
        static let graphFillOpacity = Design.Chart.fillOpacity * 1.5
    }

    public override var isFlipped: Bool { false }

    /// Drawn content only; never intercepts clicks so the status button keeps
    /// receiving them.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public func update(with model: MenuBarRenderModel) {
        guard model != self.model else { return }
        if self.model?.usesMonospacedDigits != model.usesMonospacedDigits {
            fonts = FontSet(monospacedDigits: model.usesMonospacedDigits)
            textCache.removeAll(keepingCapacity: true)
        }
        self.model = model
        layOut(model)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: max(cachedWidth, Layout.minimumWidth),
               height: NSStatusBar.system.thickness)
    }

    // MARK: Layout

    /// Everything expensive — measurement, symbol lookup, arithmetic — happens once
    /// per model change. `draw` then does nothing but snap and paint.
    private func layOut(_ model: MenuBarRenderModel) {
        placements.removeAll(keepingCapacity: true)
        guard !model.items.isEmpty else { cachedWidth = 0; return }

        var content: CGFloat = 0
        for (index, item) in model.items.enumerated() {
            if index > 0 { content += CGFloat(model.spacing) }
            let symbol = symbol(for: item)
            let geometry = geometry(for: item, symbol: symbol, model: model)
            placements.append(Placement(item: item, x: content, geometry: geometry,
                                        symbol: symbol))
            content += geometry.width
        }

        // Rounding the total up and then centring the content inside it is what keeps
        // the leading and trailing padding equal. Adding a fixed inset to each side and
        // rounding the sum leaves the remainder on one edge, which reads as the item
        // sitting slightly left in its slot.
        cachedWidth = ceil(content + Layout.horizontalInset * 2)
        let origin = ((cachedWidth - content) / 2).rounded()
        for index in placements.indices { placements[index].x += origin }
    }

    private struct Placement {
        let item: MenuBarItemRender
        var x: CGFloat
        let geometry: Geometry
        let symbol: SymbolAsset?
    }

    /// Widths of an item's parts, left to right. Every one of them is derived from the
    /// *reserved* strings rather than the live ones when fixed width is on, which is
    /// the whole mechanism that keeps the item from reflowing as a value changes.
    private struct Geometry {
        var symbol: CGFloat = 0
        var battery: CGFloat = 0
        var caption: CGFloat = 0
        var statusDot: CGFloat = 0
        var graph: CGFloat = 0
        var primaryGlyph: CGFloat = 0
        var primaryValue: CGFloat = 0
        var secondaryGlyph: CGFloat = 0
        var secondaryValue: CGFloat = 0
        /// Width of the caption-above-value column, when the item stacks. The caption
        /// and the number share this one slot instead of taking a slot each, so the
        /// item is as wide as the wider of the two rather than as wide as their sum.
        var stack: CGFloat = 0

        var width: CGFloat {
            var total: CGFloat = 0
            var placed = false
            func append(_ part: CGFloat, after gap: CGFloat) {
                guard part > 0 else { return }
                if placed { total += gap }
                total += part
                placed = true
            }
            append(symbol, after: Layout.partGap)
            append(battery, after: Layout.partGap)
            append(caption, after: Layout.partGap)
            append(statusDot, after: Layout.partGap)
            append(graph, after: Layout.partGap)
            append(stack, after: Layout.partGap)
            append(primaryGlyph, after: Layout.partGap)
            append(primaryValue, after: primaryGlyph > 0 ? Layout.glyphGap : Layout.partGap)
            append(secondaryGlyph, after: Layout.pairGap)
            append(secondaryValue, after: secondaryGlyph > 0 ? Layout.glyphGap : Layout.pairGap)
            return total
        }
    }

    /// Whether an item draws its caption above its number rather than beside it.
    ///
    /// Only when the user has asked for a caption on an item that draws a number:
    /// there is nothing to stack otherwise. A paired readout keeps its two directions
    /// side by side — that pair is already one logical row, and stacking it under a
    /// caption would be three rows of type in a 22-point bar.
    private func isStacked(_ item: MenuBarItemRender) -> Bool {
        item.caption != nil && item.style.drawsValue && !item.isUnavailable
    }

    private func geometry(for item: MenuBarItemRender, symbol: SymbolAsset?,
                          model: MenuBarRenderModel) -> Geometry {
        var geometry = Geometry()
        if let caption = item.caption, !isStacked(item) {
            geometry.caption = width(caption, role: .caption)
        }

        // An unavailable readout collapses to one dash: no graph of history that is
        // not there, and no width reserved for a number that is absent. Width still
        // cannot move as a *value* changes — only when a metric appears or disappears,
        // which is a sensor event, not a per-sample one.
        guard !item.isUnavailable else {
            geometry.primaryValue = width(MetricFormatter.unavailable, role: .value)
            return geometry
        }

        // The indicator is the whole readout: its number is inside it, and nothing else
        // is drawn beside it.
        //
        // The bolt's slot is part of the width whether or not there is a bolt in it.
        // Plugging in a charger would otherwise resize the item and drag every readout
        // to its left along with it, and a few points of air before the shell is a
        // cheaper thing to look at than a menu bar that jumps.
        if item.style == .battery {
            geometry.battery = Layout.batteryBoltWidth + Layout.batteryBoltGap
                + Layout.batteryBodyWidth + Layout.batteryNubGap + Layout.batteryNubWidth
            return geometry
        }

        // The two lights are the whole reading, and nothing else is drawn.
        if item.style == .statusDot {
            geometry.statusDot = Layout.statusDotDiameter
            return geometry
        }

        if let symbol { geometry.symbol = ceil(symbol.template.size.width) }
        if hasGraph(item) { geometry.graph = Layout.graphWidth }

        guard item.style.drawsValue else { return geometry }

        // A stacked item's number is set one size down and shares its column with the
        // caption above it, so both rows are measured here and the wider one sets the
        // width. Measuring the caption at its stacked size matters: at the single-line
        // size "TEMP" is wider than "52°C" and would have reserved a column the number
        // then sat loose inside.
        if isStacked(item), let caption = item.caption {
            let value = reservedWidth(item.primary, model: model, role: .stackedValue)
            let glyph = glyphWidth(item.primary, role: .stackedValue)
            let bottom = glyph > 0 ? glyph + Layout.glyphGap + value : value
            geometry.stack = max(width(caption, role: .stackedCaption), bottom)
            return geometry
        }

        geometry.primaryGlyph = glyphWidth(item.primary)
        geometry.primaryValue = reservedWidth(item.primary, model: model)
        if let secondary = item.secondary {
            geometry.secondaryGlyph = glyphWidth(secondary)
            geometry.secondaryValue = reservedWidth(secondary, model: model)
        }
        return geometry
    }

    /// Two samples is the least that can describe a change. Below that there is nothing
    /// to plot, and the honest thing is to draw nothing at all.
    private func hasGraph(_ item: MenuBarItemRender) -> Bool {
        guard item.style == .graph || item.style == .textAndGraph else { return false }
        return item.primary.series.count > 1 || (item.secondary?.series.count ?? 0) > 1
    }

    /// Reserving the widest possible string is what stops the menu bar shuffling every
    /// time a value gains a digit or crosses from KB to MB. The live string is still
    /// folded in, so a `widestText` that turns out not to be widest clips nothing — it
    /// only costs a reflow, which is the failure we can see and fix.
    private func reservedWidth(_ line: MenuBarLine, model: MenuBarRenderModel,
                               role: FontRole = .value) -> CGFloat {
        let measured = width(line.valueText, role: role)
        guard model.usesFixedWidth else { return measured }
        return max(measured, width(line.widestText, role: role))
    }

    /// Direction glyphs are set at the value's own size, not the caption's. One line
    /// means one type size on it; a second, smaller size reads as a third kind of thing
    /// rather than as part of the number it belongs to.
    private func glyphWidth(_ line: MenuBarLine?, role: FontRole = .value) -> CGFloat {
        guard let glyph = line?.glyph else { return 0 }
        return width(glyph, role: role)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let model, let context = NSGraphicsContext.current?.cgContext else { return }
        guard !placements.isEmpty else { return }

        // The context transform is the only reliable source of backing scale here:
        // `window?.backingScaleFactor` is nil during an offscreen render, and a
        // hardcoded 2 blurs every hairline on a 1x display.
        let scale = max(abs(context.ctm.a), 1)
        // Resolved once for the pass. Every item shares this palette unless it is
        // unavailable or threshold-coloured, so the common draw allocates no colours at
        // all — and this runs for the life of the session.
        let palette = Palette(tint: foregroundColor, isStale: model.isStale)

        context.saveGState()
        context.textMatrix = .identity
        for placement in placements {
            draw(placement, palette: palette, scale: scale, context: context)
        }
        context.restoreGState()
    }

    /// The menu bar inverts its content when the item is highlighted or when the bar
    /// itself is in the opposite appearance from the app. `labelColor` resolved against
    /// the button's effective appearance handles every case, including a dark wallpaper
    /// behind a light system appearance.
    private var foregroundColor: NSColor {
        if let button = enclosingStatusButton, button.isHighlighted {
            return .selectedMenuItemTextColor
        }
        return .labelColor
    }

    private var enclosingStatusButton: NSStatusBarButton? {
        superview as? NSStatusBarButton
    }

    private func draw(_ placement: Placement, palette: Palette,
                      scale: CGFloat, context: CGContext) {
        let item = placement.item
        let geometry = placement.geometry
        let colors = palette.colors(for: item)
        let baseline = centeredBaseline(for: .value)
        var x = placement.x
        var placed = false

        func gap(_ amount: CGFloat) {
            if placed { x += amount }
            placed = true
        }

        if let symbol = placement.symbol, geometry.symbol > 0 {
            gap(Layout.partGap)
            draw(symbol, color: colors.mark, at: CGPoint(x: x, y: bounds.midY), scale: scale)
            x += geometry.symbol
        }

        if geometry.battery > 0 {
            gap(Layout.partGap)
            drawBattery(item, x: x, colors: colors, scale: scale, context: context)
            x += geometry.battery
        }

        if let caption = item.caption, geometry.caption > 0 {
            gap(Layout.partGap)
            drawText(caption, role: .caption, x: x, baseline: centeredBaseline(for: .caption),
                     color: colors.caption, scale: scale, context: context)
            x += geometry.caption
        }

        if geometry.statusDot > 0 {
            gap(Layout.partGap)
            drawStatusDot(item, x: x, colors: colors, scale: scale, context: context)
            x += geometry.statusDot
        }

        if geometry.graph > 0 {
            gap(Layout.partGap)
            let box = CGRect(x: x, y: bounds.midY - Layout.graphHeight / 2,
                             width: geometry.graph, height: Layout.graphHeight)
            drawGraphs(item, in: box, color: colors.mark, scale: scale, context: context)
            x += geometry.graph
        }

        if geometry.stack > 0, let caption = item.caption {
            gap(Layout.partGap)
            drawStack(item, caption: caption, in: x, width: geometry.stack,
                      colors: colors, scale: scale, context: context)
            x += geometry.stack
        }

        if geometry.primaryValue > 0 {
            gap(Layout.partGap)
            if geometry.primaryGlyph > 0, let glyph = item.primary.glyph {
                drawText(glyph, role: .value, x: x, baseline: baseline,
                         color: colors.glyph, scale: scale, context: context)
                x += geometry.primaryGlyph + Layout.glyphGap
            }
            let text = item.isUnavailable ? MetricFormatter.unavailable : item.primary.valueText
            drawValue(text, reserved: geometry.primaryValue, x: x, baseline: baseline,
                      color: colors.value, scale: scale, context: context)
            x += geometry.primaryValue
        }

        if let secondary = item.secondary, geometry.secondaryValue > 0 {
            gap(Layout.pairGap)
            if geometry.secondaryGlyph > 0, let glyph = secondary.glyph {
                drawText(glyph, role: .value, x: x, baseline: baseline,
                         color: colors.glyph, scale: scale, context: context)
                x += geometry.secondaryGlyph + Layout.glyphGap
            }
            drawValue(secondary.valueText, reserved: geometry.secondaryValue, x: x,
                      baseline: baseline, color: colors.value, scale: scale, context: context)
            x += geometry.secondaryValue
        }
    }

    /// Right-aligned inside the width reserved for it. A short value leaves slack, and
    /// putting all of it on the leading side is what keeps the item's trailing ink edge
    /// fixed — so the padding either side of the whole item stays equal whatever the
    /// numbers are doing, and every value's last digit sits in the same column.
    private func drawValue(_ text: String, reserved: CGFloat, x: CGFloat, baseline: CGFloat,
                           color: CGColor, scale: CGFloat, context: CGContext) {
        let textWidth = width(text, role: .value)
        drawText(text, role: .value, x: x + reserved - textWidth, baseline: baseline,
                 color: color, scale: scale, context: context)
    }

    /// Baseline that centres a line's cap-height box on the item's midline. Cap height
    /// rather than the line box: digits and uppercase captions have no descenders, so
    /// centring the line box would sit them visibly high.
    private func centeredBaseline(for role: FontRole) -> CGFloat {
        bounds.midY - fonts[role].capHeight / 2
    }

    /// Draws a caption above its number, both centred in the column the two share.
    ///
    /// The pair is centred on the item's midline as one block, measured by cap heights
    /// for the same reason `centeredBaseline` uses them: neither row has descenders, so
    /// centring line boxes would leave the block sitting visibly high in the bar.
    ///
    /// Centred rather than aligned to one edge. The caption is almost never the same
    /// width as the number under it, and hanging both off the leading edge left "TEMP"
    /// and "52°C" looking like two unrelated items that happened to be adjacent.
    private func drawStack(_ item: MenuBarItemRender, caption: String, in x: CGFloat,
                           width columnWidth: CGFloat, colors: ItemColors,
                           scale: CGFloat, context: CGContext) {
        let captionCap = fonts[.stackedCaption].capHeight
        let valueCap = fonts[.stackedValue].capHeight
        let total = captionCap + Design.MenuBar.stackedRowGap + valueCap
        let captionBaseline = bounds.midY + total / 2 - captionCap
        let valueBaseline = bounds.midY - total / 2

        let captionWidth = width(caption, role: .stackedCaption)
        drawText(caption, role: .stackedCaption,
                 x: x + (columnWidth - captionWidth) / 2, baseline: captionBaseline,
                 color: colors.caption, scale: scale, context: context)

        let valueText = item.primary.valueText
        let glyph = item.primary.glyph
        let glyphWidth = glyph.map { width($0, role: .stackedValue) } ?? 0
        let valueWidth = width(valueText, role: .stackedValue)
        let rowWidth = glyphWidth > 0 ? glyphWidth + Layout.glyphGap + valueWidth : valueWidth
        var valueX = x + (columnWidth - rowWidth) / 2

        if let glyph, glyphWidth > 0 {
            drawText(glyph, role: .stackedValue, x: valueX, baseline: valueBaseline,
                     color: colors.glyph, scale: scale, context: context)
            valueX += glyphWidth + Layout.glyphGap
        }
        drawText(valueText, role: .stackedValue, x: valueX, baseline: valueBaseline,
                 color: colors.value, scale: scale, context: context)
    }

    /// What one item paints each of its parts with.
    private struct ItemColors {
        /// Graphs and the item's symbol.
        let mark: NSColor
        let value: CGColor
        /// The direction arrow bound to a value, dimmed but the value's colour.
        let glyph: CGColor
        let caption: CGColor
        /// The battery indicator's ink: the fill, the bolt, and the digits wherever they
        /// fall outside the fill. `mark` normally, and red at a low charge.
        ///
        /// There is deliberately no colour here for the digits *inside* the fill. They
        /// are cleared rather than painted, because the surface behind them is the
        /// user's wallpaper when the item is idle and the selection colour when it is
        /// highlighted, and no colour this app can name is right in both.
        let batteryInk: NSColor
    }

    /// The colours one draw pass works in.
    private struct Palette {
        let base: NSColor
        let solid: CGColor
        let muted: CGColor

        init(tint: NSColor, isStale: Bool) {
            // Stale numbers were true once, which is not the same as being true now.
            // Dimming them matches what the panel does rather than presenting an old
            // sample as current.
            base = isStale ? tint.withAlphaComponent(Layout.staleAlpha) : tint
            solid = base.cgColor
            muted = base.withAlphaComponent(base.alphaComponent * Layout.captionAlpha).cgColor
        }

        /// The colours one item draws with.
        ///
        /// A metric's colour reaches everything the item draws, the caption included.
        /// The caption is the part that most needs it: "CPU" set at eight points above
        /// a number is the smallest text on the bar, and its colour is what lets the
        /// eye find the readout it wants without reading any of the labels. The number
        /// stays at full strength and the caption sits back at 65% of it, so the pair
        /// reads as one readout in one colour rather than as two things.
        func colors(for item: MenuBarItemRender) -> ItemColors {
            guard var override = override(for: item) else {
                return ItemColors(mark: base, value: solid, glyph: muted, caption: muted,
                                  batteryInk: batteryInk(for: item, mark: base))
            }
            // An overridden colour is still subject to the staleness dimming the base
            // tint carries, so a coloured readout goes quiet with everything else
            // rather than being the one number that keeps claiming to be current.
            if base.alphaComponent < 1 {
                override = override.withAlphaComponent(override.alphaComponent * base.alphaComponent)
            }
            let dimmed = override.withAlphaComponent(
                override.alphaComponent * Layout.captionAlpha).cgColor
            return ItemColors(mark: override, value: override.cgColor,
                              glyph: dimmed, caption: dimmed,
                              batteryInk: batteryInk(for: item, mark: override))
        }

        /// Red at a low charge, and the item's own colour the rest of the time.
        ///
        /// The one place this view colours itself without being asked, and the exception
        /// earns itself: red on a battery is not a threshold this app invented, it is
        /// what macOS turns this exact shape at this exact charge, and a user who has
        /// read that red for twenty years should not have to learn it again. It reaches
        /// the digits as well as the fill, because at 8% the fill is a two-point sliver
        /// and the number is the part that has room to say anything.
        private func batteryInk(for item: MenuBarItemRender, mark: NSColor) -> NSColor {
            guard item.isBatteryLow else { return mark }
            return NSColor.systemRed.withAlphaComponent(mark.alphaComponent)
        }

        /// Nil whenever the item draws in the bar's own tint, which is the overwhelming
        /// majority of frames.
        private func override(for item: MenuBarItemRender) -> NSColor? {
            if item.isUnavailable {
                return base.withAlphaComponent(base.alphaComponent * Layout.unavailableAlpha)
            }
            // The menu bar is a monochrome surface and stays one by default. A colour
            // appears here only because the user went and chose one for this metric,
            // and it does not change afterwards: a readout that turned yellow, then
            // orange, then red as the number climbed was saying what the number
            // already said, in the one place on screen with no room to say anything.
            return item.tint.map(NSColor.init(themeColor:))
        }
    }

    // MARK: Status dots

    /// Two lights stacked, download above upload. Green while that direction is
    /// moving, the bar's own ink sat back while it is idle, and both red when the
    /// machine has no route out.
    ///
    /// The second place this view colours itself without being asked, and the same
    /// defence as the low battery: green for traffic and red for no link is not a
    /// convention this app invented, it is what the lights on every router mean, and
    /// a dot in the bar's own grey would be an indicator that indicates nothing. The
    /// lights keep the item's alpha so they dim with everything else when the sample
    /// is stale.
    private func drawStatusDot(_ item: MenuBarItemRender, x: CGFloat, colors: ItemColors,
                               scale: CGFloat, context: CGContext) {
        let diameter = Layout.statusDotDiameter
        let pairHeight = diameter * 2 + Layout.statusDotGap
        let top = bounds.midY + pairHeight / 2 - diameter
        let bottom = bounds.midY - pairHeight / 2
        let status = item.networkStatus

        func ink(_ lit: Bool) -> CGColor {
            let alpha = colors.mark.alphaComponent
            guard status?.isOnline ?? false else {
                return NSColor.systemRed.withAlphaComponent(alpha).cgColor
            }
            return lit
                ? NSColor.systemGreen.withAlphaComponent(alpha).cgColor
                : colors.mark.withAlphaComponent(alpha * Layout.statusDotIdleAlpha).cgColor
        }

        for (y, lit) in [(top, status?.isReceiving ?? false), (bottom, status?.isSending ?? false)] {
            let rect = snapped(CGRect(x: x, y: y, width: diameter, height: diameter), scale: scale)
            context.setFillColor(ink(lit))
            context.fillEllipse(in: rect)
        }
    }

    // MARK: Battery

    /// Draws the battery indicator: a rounded shell with a terminal on the right, filled
    /// from the left in proportion to the charge, with the percentage set inside it.
    ///
    /// Every value it needs arrives on `item`. Nothing here asks the engine what the
    /// battery is doing, because the status item redraws only when the model changes: a
    /// charge fetched at draw time would sit at whatever it was when some *other*
    /// readout last moved, and a battery that is wrong is worse than no battery.
    ///
    /// Laid out left to right as bolt slot, shell, terminal. The bolt sits outside the
    /// shell now that the number is inside it: two things cannot share those 20 points,
    /// and between a bolt drawn over the digits and a bolt beside them, the number is the
    /// one the user asked to always be able to read.
    private func drawBattery(_ item: MenuBarItemRender, x: CGFloat, colors: ItemColors,
                             scale: CGFloat, context: CGContext) {
        let pixel = 1 / scale
        let line = max(Layout.batteryStroke, pixel)
        let ink = colors.batteryInk

        if item.isBatteryCharging {
            let slot = CGRect(x: x, y: bounds.midY - Layout.batteryBoltHeight / 2,
                              width: Layout.batteryBoltWidth,
                              height: Layout.batteryBoltHeight)
            drawChargingBolt(in: slot, color: ink, scale: scale, context: context)
        }

        // Snapped outer box, then everything measured off it, so the stroke lands on a
        // half-pixel at 1x and the fill's edges land on whole ones.
        let outer = snapped(CGRect(x: x + Layout.batteryBoltWidth + Layout.batteryBoltGap,
                                   y: bounds.midY - Layout.batteryBodyHeight / 2,
                                   width: Layout.batteryBodyWidth,
                                   height: Layout.batteryBodyHeight), scale: scale)
        // The shell stays the bar's own colour even at a low charge. Reddening it too
        // turned the whole indicator into a pale pink outline around a pale pink number:
        // red at 40% is not a warning, it is a washout. macOS reddens the contents and
        // leaves the container alone, and the contrast between the two is what makes the
        // red read as a state rather than as a tint.
        let shellColor = colors.mark.withAlphaComponent(
            colors.mark.alphaComponent * Layout.batteryShellAlpha)

        let shell = outer.insetBy(dx: line / 2, dy: line / 2)
        let shellRadius = max(Layout.batteryCornerRadius - line / 2, 0)
        context.addPath(CGPath(roundedRect: shell, cornerWidth: shellRadius,
                               cornerHeight: shellRadius, transform: nil))
        context.setStrokeColor(shellColor.cgColor)
        context.setLineWidth(line)
        context.strokePath()

        let nub = snapped(CGRect(x: outer.maxX + Layout.batteryNubGap,
                                 y: bounds.midY - Layout.batteryNubHeight / 2,
                                 width: Layout.batteryNubWidth,
                                 height: Layout.batteryNubHeight), scale: scale)
        let nubRadius = min(nub.width, nub.height) / 2
        context.addPath(CGPath(roundedRect: nub, cornerWidth: nubRadius,
                               cornerHeight: nubRadius, transform: nil))
        context.setFillColor(shellColor.cgColor)
        context.fillPath()

        let track = outer.insetBy(dx: Layout.batteryFillInsetX, dy: Layout.batteryFillInsetY)
        let charge = min(max(item.batteryCharge ?? 0, 0), 1)
        // Where the fill stops is also where the digits change colour, so it is computed
        // once and both the fill and the text are drawn against it.
        var fillEdge = track.minX
        if charge > 0, track.width > 0 {
            // Snapped to whole pixels: a fill whose right edge lands mid-pixel is a grey
            // column that reads as a lower charge than the one it is drawing, and it
            // would put the digits' colour boundary on a half-covered pixel too.
            let fill = snapped(CGRect(x: track.minX, y: track.minY,
                                      width: max(track.width * charge, Layout.batteryMinimumFill),
                                      height: track.height), scale: scale)
            fillEdge = fill.maxX
            let radius = min(Layout.batteryFillRadius, fill.width / 2, fill.height / 2)
            context.addPath(CGPath(roundedRect: fill, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
            context.setFillColor(ink.cgColor)
            context.fillPath()
        }

        if let text = item.batteryValueText {
            drawBatteryValue(text, in: outer, fillEdge: fillEdge, ink: ink,
                             scale: scale, context: context)
        }
    }

    /// The percentage, centred in the shell and drawn twice.
    ///
    /// The first pass is clipped to the filled part and clears its glyphs out of the ink
    /// behind them; the second is clipped to the rest and paints them normally. The two
    /// clips meet exactly at the fill's edge, so a digit the boundary happens to run
    /// through comes out half knocked-out and half painted rather than picking one.
    ///
    /// That per-pixel split is the whole point. Choosing a single colour per digit —
    /// or worse, one colour for the whole number once the fill passes some percentage —
    /// fails precisely at the charges people look at, where the edge is under a digit.
    ///
    /// The knocked-out pass clears rather than painting a background colour. The surface
    /// behind the fill is the user's wallpaper when the item is idle and the selection
    /// colour when it is highlighted, and clearing is the only thing that is right in
    /// both. It is also what keeps this legible when the menu bar inverts: the painted
    /// pass is the resolved label colour and the cleared pass is whatever is actually
    /// behind, so neither is a colour that can end up matching its background.
    private func drawBatteryValue(_ text: String, in shell: CGRect, fillEdge: CGFloat,
                                  ink: NSColor, scale: CGFloat, context: CGContext) {
        let textWidth = width(text, role: .batteryValue)
        guard textWidth > 0 else { return }
        let x = shell.midX - textWidth / 2
        let baseline = bounds.midY - fonts[.batteryValue].capHeight / 2

        if fillEdge > shell.minX {
            context.saveGState()
            context.clip(to: CGRect(x: bounds.minX, y: bounds.minY,
                                    width: fillEdge - bounds.minX, height: bounds.height))
            context.setBlendMode(.clear)
            drawText(text, role: .batteryValue, x: x, baseline: baseline,
                     color: ink.cgColor, scale: scale, context: context)
            context.restoreGState()
        }

        context.saveGState()
        context.clip(to: CGRect(x: fillEdge, y: bounds.minY,
                                width: bounds.maxX - fillEdge, height: bounds.height))
        drawText(text, role: .batteryValue, x: x, baseline: baseline,
                 color: ink.cgColor, scale: scale, context: context)
        context.restoreGState()
    }

    private func drawChargingBolt(in slot: CGRect, color: NSColor, scale: CGFloat,
                                  context: CGContext) {
        let box = CGRect(x: snap(slot.minX, scale), y: snap(slot.minY, scale),
                         width: slot.width, height: slot.height)
        let bolt = CGMutablePath()
        for (index, point) in Layout.batteryBoltPoints.enumerated() {
            let mapped = CGPoint(x: box.minX + point.x * box.width,
                                 y: box.minY + point.y * box.height)
            index == 0 ? bolt.move(to: mapped) : bolt.addLine(to: mapped)
        }
        bolt.closeSubpath()
        context.addPath(bolt)
        context.setFillColor(color.cgColor)
        context.fillPath()
    }

    // MARK: Graphs

    /// A paired readout gets two half-height plots, so a graph of network throughput
    /// still says which direction is which. Stacking a *chart* is fine where stacking
    /// text is not: a shape still reads at half height, six-point type does not.
    private func drawGraphs(_ item: MenuBarItemRender, in box: CGRect, color: NSColor,
                            scale: CGFloat, context: CGContext) {
        guard let secondary = item.secondary else {
            drawGraph(item.primary.series, in: box, color: color, scale: scale, context: context)
            return
        }
        let half = (box.height - Design.Space.hairline) / 2
        drawGraph(item.primary.series,
                  in: CGRect(x: box.minX, y: box.maxY - half, width: box.width, height: half),
                  color: color, scale: scale, context: context)
        drawGraph(secondary.series,
                  in: CGRect(x: box.minX, y: box.minY, width: box.width, height: half),
                  color: color, scale: scale, context: context)
    }

    private func drawGraph(_ series: [Float], in rect: CGRect, color: NSColor,
                           scale: CGFloat, context: CGContext) {
        let pixel = 1 / scale
        let baseline = floor(rect.minY * scale) / scale + pixel / 2
        let top = ceil(rect.maxY * scale) / scale - pixel / 2
        let left = round(rect.minX * scale) / scale
        let right = round(rect.maxX * scale) / scale

        // One column per device pixel. Five minutes of samples squeezed into 34 points
        // is 150 values fighting over 34 columns, which is why this used to draw as
        // high-frequency noise instead of as a shape.
        let columns = max(Int(((right - left) * scale).rounded()), 2)
        guard resampleColumns(series, into: columns) else { return }

        let stepX = (right - left) / CGFloat(columns - 1)
        let span = max(top - baseline, 0)
        func point(_ index: Int) -> CGPoint {
            CGPoint(x: left + CGFloat(index) * stepX, y: baseline + columnScratch[index] * span)
        }

        // Fill first, then restate the top edge at full strength: the fill carries the
        // shape at a glance and the line keeps it legible where the shape is thin.
        context.move(to: CGPoint(x: left, y: baseline))
        for index in 0..<columns { context.addLine(to: point(index)) }
        context.addLine(to: CGPoint(x: right, y: baseline))
        context.closePath()
        context.setFillColor(color.withAlphaComponent(Layout.graphFillOpacity).cgColor)
        context.fillPath()

        context.move(to: point(0))
        for index in 1..<columns { context.addLine(to: point(index)) }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(max(pixel, 0.75))
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.strokePath()
    }

    /// Downsamples `series` into `columnScratch[0..<columns]`, keeping each bucket's
    /// peak. Peaks are what a utilisation graph is read for; averaging them away turns
    /// a spike into a bump. Returns false when there is not enough history to plot.
    private func resampleColumns(_ series: [Float], into columns: Int) -> Bool {
        guard series.count > 1 else { return false }
        if columnScratch.count < columns {
            columnScratch.append(contentsOf: repeatElement(0, count: columns - columnScratch.count))
        }
        let count = series.count
        for column in 0..<columns {
            let start = column * count / columns
            let end = max(((column + 1) * count) / columns, start + 1)
            var peak: Float = 0
            for index in start..<min(end, count) { peak = max(peak, series[index]) }
            columnScratch[column] = CGFloat(min(max(peak, 0), 1))
        }
        return true
    }

    private func draw(_ asset: SymbolAsset, color: NSColor, at center: CGPoint, scale: CGFloat) {
        guard let image = tinted(asset, color: color, scale: scale) else { return }
        let size = image.size
        let rect = CGRect(x: snap(center.x, scale),
                          y: snap(center.y - size.height / 2, scale),
                          width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    // MARK: Text

    private func drawText(_ string: String, role: FontRole, x: CGFloat, baseline: CGFloat,
                          color: CGColor, scale: CGFloat, context: CGContext) {
        guard !string.isEmpty, let cached = cachedText(string, role: role) else { return }
        context.setFillColor(color)
        // Snapped by the *ink*, not by the typographic origin: a glyph whose ink starts
        // a third of a pixel into its advance rasterises differently at each origin,
        // which is what made three identical em dashes come out three different weights.
        context.textPosition = CGPoint(x: snap(x + cached.inkOffset, scale) - cached.inkOffset,
                                       y: snap(baseline, scale))
        CTLineDraw(cached.line, context)
    }

    private func width(_ string: String, role: FontRole) -> CGFloat {
        cachedText(string, role: role)?.width ?? 0
    }

    /// Laid-out text, kept between frames. The strings a menu bar produces are a small
    /// closed set — 101 percentages, a few hundred rate strings — so after the first
    /// minute this is a pure dictionary hit and no frame allocates a line or an
    /// attributed string. The cap is only there so a pathological run of unique strings
    /// cannot grow it without bound.
    private func cachedText(_ string: String, role: FontRole) -> CachedText? {
        let key = TextKey(text: string, role: role)
        if let cached = textCache[key] { return cached }
        if textCache.count >= 512 { textCache.removeAll(keepingCapacity: true) }

        let attributed = NSAttributedString(string: string, attributes: [
            .font: fonts[role],
            // Without this Core Text paints its own default black, ignoring the fill
            // colour — and the readout stays black on an inverted menu bar.
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let cached = CachedText(
            line: line,
            width: ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))),
            // Glyph-path bounds rather than image bounds: image bounds need a context,
            // and there is none while laying out.
            inkOffset: CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).origin.x)
        textCache[key] = cached
        return cached
    }

    private func symbol(for item: MenuBarItemRender) -> SymbolAsset? {
        guard item.style == .iconAndText, let name = item.symbolName else { return nil }
        guard let template = symbol(named: name, pointSize: Layout.symbolSize) else { return nil }
        return SymbolAsset(name: name, pointSize: Layout.symbolSize, template: template)
    }

    private func symbol(named name: String, pointSize: CGFloat) -> NSImage? {
        let key = "\(name)@\(pointSize)"
        if let cached = symbolCache[key] { return cached }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let configured = image.withSymbolConfiguration(
                .init(pointSize: pointSize, weight: .regular)) else { return nil }
        configured.isTemplate = true
        symbolCache[key] = configured
        return configured
    }

    /// A symbol the view has looked up, kept with the two things needed to re-render it
    /// in a colour: `NSImage` alone cannot say what it is an image *of*.
    private struct SymbolAsset {
        let name: String
        let pointSize: CGFloat
        let template: NSImage
    }

    /// One rasterisation of a symbol. The colour is resolved, not the `NSColor` handed
    /// in: `labelColor` is one object that means white in one appearance and black in
    /// the other, so keying on it would serve a light-mode bitmap to a dark menu bar.
    private struct TintKey: Hashable {
        let name: String
        let pointSize: CGFloat
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        let scale: CGFloat
    }

    /// The symbol, in the colour it is meant to be.
    ///
    /// A template `NSImage` is tinted by AppKit only when a control draws it — a cell, a
    /// button, a menu item. Drawn by hand into a view's context it keeps its own black
    /// ink, whatever colour is set beforehand, so `Icon & Text` came out black on a dark
    /// menu bar and all but disappeared. The tint has to be applied to the image rather
    /// than asked of the context.
    ///
    /// The `.sourceIn` pass that does it composites against everything already in the
    /// context, so it cannot run in the menu bar's own context without wiping the
    /// readouts drawn to the left of the symbol. It runs in a private bitmap instead and
    /// the result composites normally. Bitmaps are cached: a colour here changes on
    /// appearance, highlight and staleness, which is a handful of values over a session,
    /// not one per frame.
    private func tinted(_ asset: SymbolAsset, color: NSColor, scale: CGFloat) -> NSImage? {
        guard let resolved = color.usingColorSpace(.sRGB) else { return asset.template }
        let key = TintKey(name: asset.name, pointSize: asset.pointSize,
                          red: resolved.redComponent, green: resolved.greenComponent,
                          blue: resolved.blueComponent, alpha: resolved.alphaComponent,
                          scale: scale)
        if let cached = tintedSymbolCache[key] { return cached }
        guard let image = rasterize(asset, color: resolved, scale: scale) else { return nil }
        if tintedSymbolCache.count >= 64 { tintedSymbolCache.removeAll(keepingCapacity: true) }
        tintedSymbolCache[key] = image
        return image
    }

    private func rasterize(_ asset: SymbolAsset, color: NSColor, scale: CGFloat) -> NSImage? {
        let size = asset.template.size
        let wide = Int((size.width * scale).rounded(.up))
        let high = Int((size.height * scale).rounded(.up))
        guard wide > 0, high > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // Before the context is made: this is what tells it the bitmap is `scale` device
        // pixels to the point rather than one, and a context built off the default 1:1
        // draws a 13-point symbol into the corner of a 26-pixel bitmap.
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        let rect = CGRect(origin: .zero, size: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        asset.template.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        rect.fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        // The colour is in the pixels now. Left as a template it would be handed back to
        // AppKit's own tinting inside the status button and painted over.
        image.isTemplate = false
        return image
    }

    // MARK: Pixel grid

    private func snap(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    private func snapped(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let x = snap(rect.minX, scale)
        let y = snap(rect.minY, scale)
        return CGRect(x: x, y: y,
                      width: snap(rect.maxX, scale) - x,
                      height: snap(rect.maxY, scale) - y)
    }

    // MARK: Type

    private enum FontRole: Hashable {
        /// Every number on the bar, at one size. There is only one line, so there is
        /// only one type size for values — and one em dash, at one weight, everywhere
        /// a value is missing.
        case value
        /// Opt-in captions. The only text on the bar that is not a number.
        case caption
        /// The same two, one size down, for an item drawing its caption above its
        /// number instead of beside it.
        case stackedValue
        case stackedCaption
        /// The digits inside the battery shell. Always monospaced and always medium,
        /// whatever the rest of the bar is set in: this number is knocked out of solid
        /// ink at nine points, and a regular weight does not survive that at 1x.
        case batteryValue
    }

    private struct FontSet {
        let value: NSFont
        let caption: NSFont
        let stackedValue: NSFont
        let stackedCaption: NSFont
        let batteryValue: NSFont

        init(monospacedDigits: Bool) {
            batteryValue = .monospacedDigitSystemFont(ofSize: Layout.batteryValueFontSize,
                                                      weight: .medium)
            let size = Design.MenuBar.valueFontSize
            value = monospacedDigits
                ? .monospacedDigitSystemFont(ofSize: size, weight: .regular)
                : .systemFont(ofSize: size, weight: .regular)
            caption = .systemFont(ofSize: Design.MenuBar.captionFontSize, weight: .medium)
            let stacked = Design.MenuBar.stackedValueFontSize
            stackedValue = monospacedDigits
                ? .monospacedDigitSystemFont(ofSize: stacked, weight: .regular)
                : .systemFont(ofSize: stacked, weight: .regular)
            stackedCaption = .systemFont(ofSize: Design.MenuBar.stackedCaptionFontSize,
                                         weight: .medium)
        }

        subscript(role: FontRole) -> NSFont {
            switch role {
            case .value: return value
            case .caption: return caption
            case .stackedValue: return stackedValue
            case .stackedCaption: return stackedCaption
            case .batteryValue: return batteryValue
            }
        }
    }

    private struct TextKey: Hashable {
        let text: String
        let role: FontRole
    }

    private struct CachedText {
        let line: CTLine
        let width: CGFloat
        /// Distance from the typographic origin to the first inked pixel.
        let inkOffset: CGFloat
    }
}

private extension MenuBarDisplayStyle {
    /// Whether this style draws a formatted number.
    var drawsValue: Bool {
        switch self {
        case .text, .textAndGraph, .iconAndText: return true
        case .graph, .battery, .statusDot: return false
        }
    }
}
