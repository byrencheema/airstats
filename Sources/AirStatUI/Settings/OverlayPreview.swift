import SwiftUI
import AirStatKit

/// The overlay, drawn beside the list of modules that fills it.
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
