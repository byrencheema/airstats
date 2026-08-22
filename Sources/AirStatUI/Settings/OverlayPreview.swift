import SwiftUI
import AirStatKit

/// The overlay itself, drawn inside the pane that configures it.
///
/// Not a mock-up: this is `OverlayRootView` on the same engine and the same settings
/// store the real window uses, so every module, its order, the compact layout, the
/// width and the opacity are the ones that will end up on screen. The menu bar pane
/// has had a preview from the start and the overlay pane had none, which is backwards
/// — the menu bar is on screen while you configure it, and the overlay is the one
/// surface the settings window is most likely to be covering.
///
/// Capped, because the overlay is as tall as its modules make it: nine expanded is
/// about 736pt, more than this pane has. Past the cap the preview scrolls, the same
/// way the menu bar preview scrolls sideways past the width of a real menu bar.
struct OverlayPreview: View {
    let engine: MetricsEngine
    let settings: SettingsStore

    /// Starts at the cap rather than at zero: measured on the first layout pass, and a
    /// zero-height frame for that one frame is a visible flinch every time the pane
    /// opens. Held unscaled, so the scale can change without invalidating it.
    @State private var contentHeight: CGFloat = OverlayPreview.maxHeight / OverlayPreview.scale

    /// Drawn as a thumbnail rather than at size. At 1:1 a three-module overlay is
    /// taller than the switch, the module list and the size controls put together,
    /// which made the pane about the preview instead of about the settings. Scaled, it
    /// still answers what the settings do — order, layout, how wide, how faint — which
    /// is what a preview is for. The values in it are legible but not the point; the
    /// real overlay is where you read them.
    private static let scale: CGFloat = 0.65
    private static let maxHeight: CGFloat = 140

    private var overlay: OverlaySettings { settings.settings.overlay }

    private var scaledHeight: CGFloat { contentHeight * Self.scale }

    private var isScrollable: Bool { scaledHeight > Self.maxHeight }

    var body: some View {
        // The well hugs the thumbnail instead of spanning the row. Full width, it was a
        // band of empty grey with a small overlay adrift in the middle of it, which is
        // most of what made the preview feel like the pane's subject.
        HStack(alignment: .center, spacing: Design.Space.l) {
            ScrollView(.vertical) {
                OverlayRootView(engine: engine, settings: settings)
                    // What the user set, so the preview is as faint as the real thing
                    // will be. The inactive opacity is deliberately not applied: you
                    // are looking at it, which is the state this shows.
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
                    // `scaleEffect` does not change the space a view takes, so the
                    // frame has to be told what the drawing now occupies. Scaled about
                    // the centre and framed to the scaled size, which leaves the
                    // drawing's centre where the frame's is; a top anchor shifts it out
                    // of the frame by half the difference.
                    .scaleEffect(Self.scale)
                    .frame(width: CGFloat(overlay.width) * Self.scale, height: scaledHeight)
                    .padding(Design.Space.m)
            }
            .frame(width: CGFloat(overlay.width) * Self.scale + Design.Space.m * 2,
                   height: min(scaledHeight, Self.maxHeight) + Design.Space.m * 2)
            .scrollDisabled(!isScrollable)
            // The same well the menu bar preview sits in, so the two previews read as
            // the same kind of thing. It is also what the overlay's own translucency
            // has to show against: at 40% opacity the glass has to be over something.
            .background {
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            }

            if isScrollable {
                SettingsFootnote("Taller than the space here. Scroll the preview, "
                                 + "or use the compact layout to shorten it.")
            }

            Spacer(minLength: 0)
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
