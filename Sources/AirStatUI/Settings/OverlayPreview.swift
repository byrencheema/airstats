import SwiftUI
import AirStatKit

/// The overlay, drawn beside the controls that shape it.
///
/// Not a mock-up: this is `OverlayRootView` on the same engine and the same settings
/// store the real window uses, so every module, its order, the compact layout, the
/// width and the opacity are the ones that will end up on screen. The menu bar pane
/// has had a preview from the start and the overlay pane had none, which is backwards
/// — the menu bar is on screen while you configure it, and the overlay is the one
/// surface the settings window is most likely to be covering.
///
/// Drawn as a thumbnail rather than at size. At 1:1 a three-module overlay is taller
/// than the switch, the module list and the size controls put together, which made the
/// pane about the preview instead of about the settings. Scaled, it still answers what
/// the settings do — order, layout, how wide, how faint — which is what a preview is
/// for. The values in it are legible but not the point; the real overlay is where you
/// read them.
struct OverlayPreview: View {
    let engine: MetricsEngine
    let settings: SettingsStore

    /// Starts at the cap rather than at zero: measured on the first layout pass, and a
    /// zero-height frame for that one frame is a visible flinch every time the pane
    /// opens. Held unscaled, so the scale can change without invalidating it.
    @State private var contentHeight: CGFloat = OverlayPreview.maxHeight / OverlayPreview.scale

    private static let scale: CGFloat = 0.65
    /// Tall enough that nothing anyone is likely to have set needs scrolling: the
    /// shipped three compact modules come to about 105pt here, and six still fit.
    private static let maxHeight: CGFloat = 190

    /// Widest the column can get, so the controls beside it keep a usable width even
    /// at the largest overlay. Past this the thumbnail scrolls sideways rather than
    /// squeezing the rest of the row.
    static let maxWidth: CGFloat = 200

    private var overlay: OverlaySettings { settings.settings.overlay }

    private var scaledHeight: CGFloat { contentHeight * Self.scale }

    private var scaledWidth: CGFloat { CGFloat(overlay.width) * Self.scale }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            OverlayRootView(engine: engine, settings: settings)
                // What the user set, so the preview is as faint as the real thing will
                // be. The inactive opacity is deliberately not applied: you are looking
                // at it, which is the state this shows.
                .opacity(overlay.opacity)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.height, initial: true) { _, height in
                                contentHeight = height
                            }
                    }
                }
                // Measured before this, so the height above is the overlay's own.
                // `scaleEffect` does not change the space a view takes, so the frame
                // has to be told what the drawing now occupies. Scaled about the centre
                // and framed to the scaled size, which leaves the drawing's centre
                // where the frame's is; a top anchor shifts it out of the frame by half
                // the difference.
                .scaleEffect(Self.scale)
                .frame(width: scaledWidth, height: scaledHeight)
                .padding(Design.Space.m)
        }
        .frame(width: min(scaledWidth, Self.maxWidth) + Design.Space.m * 2,
               height: min(scaledHeight, Self.maxHeight) + Design.Space.m * 2)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Overlay preview")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let names = overlay.modules.map(\.label).joined(separator: ", ")
        let layout = overlay.isCompact ? "compact" : "expanded"
        return "\(names). \(layout), \(Int(overlay.width.rounded())) points wide, "
            + "\(Int((overlay.opacity * 100).rounded())) percent opaque"
    }
}

/// A slider narrow enough for the column beside the preview.
///
/// `SettingsSlider` writes its bounds at the ends of the track, which is right for a
/// row that has the pane's full width. Here the preview takes half of it, and the
/// bounds are the first thing worth giving up: the thumbnail already shows what wider
/// and fainter look like, which is more than a pair of numbers would say.
struct CompactSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: Design.Space.m) {
            Text(title)
                .lineLimit(1)
                // The label takes the slack, not the slider. A Slider handed a
                // flexible or fixed width draws its track at an ideal size inside it
                // and leaves the rest in front, so the gap between the label and the
                // track came out wider than the track; a minimum is the one constraint
                // it grows to meet.
                .frame(maxWidth: .infinity, alignment: .leading)
            Slider(value: value, in: range)
                .frame(minWidth: 150)
            Text(format(value.wrappedValue))
                .font(.body.monospacedDigit())
                .foregroundStyle(Design.Palette.secondaryText)
                .frame(width: 48, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(format(value.wrappedValue))
    }
}

/// A toggle with its switch at the row's trailing edge, for the same column.
///
/// A bare `Toggle` in a stack puts its switch directly after the label, so five of them
/// make a ragged right edge where a `Form` would have given a straight one.
struct CompactToggle: View {
    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: Design.Space.m) {
            Text(title)
            Spacer(minLength: Design.Space.m)
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}
