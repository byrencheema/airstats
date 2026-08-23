import SwiftUI
import AppKit
import AirStatKit

/// A colour, in the terms a person picks one in.
///
/// Held as hue/saturation/brightness rather than as the sRGB triple that gets stored,
/// because the two are not interchangeable while someone is dragging. Black has no
/// hue and grey has no saturation, so a round trip through RGB loses the very thing
/// the user is about to move: drag the brightness to zero, drag it back, and a colour
/// held as RGB comes back red. Held here, it comes back the colour they started on.
struct HSB: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double

    init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue.clamped()
        self.saturation = saturation.clamped()
        self.brightness = brightness.clamped()
    }

    init(_ theme: ThemeColor) {
        let r = theme.red, g = theme.green, b = theme.blue
        let high = max(r, g, b), low = min(r, g, b)
        let delta = high - low

        brightness = high
        saturation = high == 0 ? 0 : delta / high

        if delta == 0 {
            hue = 0
        } else {
            let sector: Double
            switch high {
            case r: sector = (g - b) / delta
            case g: sector = 2 + (b - r) / delta
            default: sector = 4 + (r - g) / delta
            }
            hue = ((sector / 6).truncatingRemainder(dividingBy: 1) + 1)
                .truncatingRemainder(dividingBy: 1)
        }
    }

    var themeColor: ThemeColor {
        // The standard sextant conversion. Written out rather than routed through
        // `Color(hue:saturation:brightness:)` so that the swatch, the gradients under
        // the crosshair and the triple that gets written to disk are all the same
        // arithmetic — a picker whose preview and whose result disagree by a shade is
        // worse than one that is simply coarse.
        let sector = (hue * 6).truncatingRemainder(dividingBy: 6)
        let index = Int(sector)
        let fraction = sector - Double(index)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))

        switch index {
        case 0: return ThemeColor(red: brightness, green: t, blue: p)
        case 1: return ThemeColor(red: q, green: brightness, blue: p)
        case 2: return ThemeColor(red: p, green: brightness, blue: t)
        case 3: return ThemeColor(red: p, green: q, blue: brightness)
        case 4: return ThemeColor(red: t, green: p, blue: brightness)
        default: return ThemeColor(red: brightness, green: p, blue: q)
        }
    }

    var color: Color { Color(themeColor: themeColor) }

    /// The same hue at full strength: what the square is painted on.
    var pureHue: Color {
        HSB(hue: hue, saturation: 1, brightness: 1).color
    }

    /// Whether this is the colour some stored triple stands for, to within a step the
    /// eye cannot see. Used to tell the user's own drag apart from a change arriving
    /// from somewhere else, which must not be allowed to yank the knob mid-gesture.
    func matches(_ theme: ThemeColor) -> Bool {
        let mine = themeColor
        let tolerance = 1.0 / 512
        return abs(mine.red - theme.red) < tolerance
            && abs(mine.green - theme.green) < tolerance
            && abs(mine.blue - theme.blue) < tolerance
    }
}

private extension Double {
    func clamped() -> Double { min(max(self, 0), 1) }
}

// MARK: - Hex

extension ThemeColor {
    /// Uppercase, because a hex colour is a code rather than a word, and mixed-case
    /// codes are harder to read back to someone.
    var hexString: String {
        String(format: "#%02X%02X%02X",
               Int((red * 255).rounded()),
               Int((green * 255).rounded()),
               Int((blue * 255).rounded()))
    }

    /// Accepts what people actually paste: a leading hash or not, three digits or six,
    /// any case, surrounding space. Nil for anything else, so a half-typed value is
    /// simply not applied rather than applied as black.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, text.allSatisfy(\.isHexDigit),
              let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - Editor

/// The colour picker, in the popover rather than in a window.
///
/// macOS has one colour picker and it is a floating panel: shared by the whole
/// process, parked wherever it was last dragged, outliving the control that opened it
/// and covering the very swatch you are trying to judge. It also offers a great deal
/// this app has no use for — CMYK, opacity, palette files, an image picker — around
/// the two things it does need.
///
/// So this is a square, a hue slider and a hex field, which is the whole of the job,
/// and it lives inside the popover the swatch already opens. Nothing floats, nothing
/// is left behind, and the colour is decided next to the thing it applies to.
struct ColorEditor: View {
    @Binding var hsb: HSB
    /// Sampling takes over the screen, so the caller gets a chance to put the popover
    /// away first.
    var willSample: () -> Void = {}

    @State private var hexText: String = ""
    @FocusState private var hexFocused: Bool

    private static let squareHeight: CGFloat = 116
    private static let sliderHeight: CGFloat = 14
    private static let knob: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            square
            hueSlider
            HStack(spacing: Design.Space.s) {
                hexField
                Spacer(minLength: 0)
                sampleButton
            }
        }
        .onAppear { hexText = hsb.themeColor.hexString }
        .onChange(of: hsb) { _, new in
            // Never while the field has the insertion point: rewriting the text a user
            // is halfway through typing is how a hex field eats keystrokes.
            guard !hexFocused else { return }
            hexText = new.themeColor.hexString
        }
    }

    // MARK: Saturation and brightness

    private var square: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                ZStack {
                    Rectangle().fill(hsb.pureHue)
                    // White across and black down is exactly what saturation and
                    // brightness mean: alpha-compositing white at 1 - s and black at
                    // 1 - v reproduces the same colours the conversion above computes.
                    LinearGradient(colors: [.white, .white.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.black.opacity(0), .black],
                                   startPoint: .top, endPoint: .bottom)
                }
                // Clipped without the crosshair inside it. Every corner of this square
                // is a colour someone picks — white, black, the pure hue — and a knob
                // clipped to the shape loses half of itself at exactly the moments the
                // user most needs to see where it is.
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control,
                                            style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                        .strokeBorder(Design.Palette.primaryText.opacity(0.15))
                }

                crosshair
                    .position(x: hsb.saturation * size.width,
                              y: (1 - hsb.brightness) * size.height)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                // Zero minimum distance so a click lands a colour, rather than only a
                // drag: aiming at a shade and having nothing happen is the kind of
                // dead control people stop trusting.
                DragGesture(minimumDistance: 0).onChanged { value in
                    hsb.saturation = value.location.x / max(size.width, 1)
                    hsb.brightness = 1 - value.location.y / max(size.height, 1)
                }
            )
        }
        .frame(height: Self.squareHeight)
        .accessibilityElement()
        .accessibilityLabel("Saturation and brightness")
        .accessibilityValue("\(percent(hsb.saturation)) saturation, "
                            + "\(percent(hsb.brightness)) brightness")
        .accessibilityAdjustableAction { direction in
            hsb.brightness += direction == .increment ? 0.05 : -0.05
        }
    }

    /// Two rings rather than one: a white circle vanishes on a pale tint and a dark
    /// one vanishes in the corner every picker's crosshair spends its life in.
    private var crosshair: some View {
        Circle()
            .strokeBorder(.white, lineWidth: 2)
            .background(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 3.5))
            .frame(width: Self.knob, height: Self.knob)
            .shadow(color: .black.opacity(0.25), radius: 1)
    }

    // MARK: Hue

    private var hueSlider: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                LinearGradient(colors: Self.hueStops, startPoint: .leading, endPoint: .trailing)
                    .frame(height: Self.sliderHeight)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule().strokeBorder(Design.Palette.primaryText.opacity(0.15))
                    }
                Circle()
                    .fill(hsb.pureHue)
                    .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                    .overlay { Circle().strokeBorder(.black.opacity(0.2)) }
                    .frame(width: Self.sliderHeight + 4, height: Self.sliderHeight + 4)
                    .shadow(color: .black.opacity(0.25), radius: 1)
                    // Inset by the knob's own radius so the ends of the track are
                    // reachable: a knob centred on 0 hangs half of itself off the edge
                    // and the last few degrees of hue cannot be selected.
                    .position(x: (Self.sliderHeight + 4) / 2
                              + hsb.hue * max(width - Self.sliderHeight - 4, 1),
                              y: (Self.sliderHeight + 4) / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let inset = (Self.sliderHeight + 4) / 2
                    let travel = max(width - Self.sliderHeight - 4, 1)
                    hsb.hue = (value.location.x - inset) / travel
                }
            )
        }
        // The knob stands a little proud of the track, as AppKit's own do, so it is
        // never clipped at either end of the hue.
        .frame(height: Self.sliderHeight + 4)
        .accessibilityElement()
        .accessibilityLabel("Hue")
        .accessibilityValue("\(Int((hsb.hue * 360).rounded())) degrees")
        .accessibilityAdjustableAction { direction in
            hsb.hue = ((hsb.hue + (direction == .increment ? 1 : -1) / 36) + 1)
                .truncatingRemainder(dividingBy: 1)
        }
    }

    private static let hueStops: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12)
        .map { HSB(hue: $0, saturation: 1, brightness: 1).color }

    // MARK: Hex and sampling

    /// The way in for a colour someone already has: a brand hex, a value from a
    /// design file, the thing they matched their wallpaper to. Applied on commit
    /// rather than per keystroke, since "#F" is a valid prefix and a terrible colour.
    private var hexField: some View {
        TextField("Hex", text: $hexText)
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
            .frame(width: 92)
            .focused($hexFocused)
            .onSubmit(commitHex)
            .onChange(of: hexFocused) { _, focused in
                // Leaving the field commits it, so a typed value is not silently lost
                // by clicking away — and an unparseable one snaps back to what is
                // actually set rather than sitting there looking applied.
                if !focused { commitHex() }
            }
            .accessibilityLabel("Hex colour")
    }

    private func commitHex() {
        guard let parsed = ThemeColor(hex: hexText) else {
            hexText = hsb.themeColor.hexString
            return
        }
        hsb = HSB(parsed)
        hexText = parsed.hexString
    }

    private var sampleButton: some View {
        Button {
            willSample()
            // The system sampler, rather than a magnifier of our own: it can read
            // pixels outside this process, which nothing we could write in-app can.
            NSColorSampler().show { picked in
                guard let picked, let stored = Color(nsColor: picked).themeColor else { return }
                hsb = HSB(stored)
            }
        } label: {
            Image(systemName: "eyedropper")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Design.Palette.secondaryText)
        .help("Pick a colour from anywhere on screen")
        .accessibilityLabel("Pick a colour from the screen")
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) percent"
    }
}
