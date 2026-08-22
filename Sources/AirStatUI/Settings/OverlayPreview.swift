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
    /// opens.
    @State private var contentHeight: CGFloat = OverlayPreview.maxHeight

    private static let maxHeight: CGFloat = 210

    private var overlay: OverlaySettings { settings.settings.overlay }

    private var isScrollable: Bool { contentHeight > Self.maxHeight }

    var body: some View {
        VStack(spacing: Design.Space.s) {
            ScrollView(.vertical) {
                OverlayRootView(engine: engine, settings: settings)
                    // What the user set, so the preview is as faint as the real thing
                    // will be. The inactive opacity is deliberately not applied: you
                    // are looking at it, which is the state this shows.
                    .opacity(overlay.opacity)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Design.Space.l)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onChange(of: proxy.size.height, initial: true) { _, height in
                                    contentHeight = height
                                }
                        }
                    }
            }
            .frame(height: min(contentHeight, Self.maxHeight))
            .scrollDisabled(!isScrollable)

            if isScrollable {
                SettingsFootnote("Taller than the space here. Scroll the preview, "
                                 + "or use the compact layout to shorten it.")
            }
        }
        .frame(maxWidth: .infinity)
        // The same well the menu bar preview sits in, so the two previews read as the
        // same kind of thing. It is also what the overlay's own translucency has to
        // show against: at 40% opacity the glass has to be over something.
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
