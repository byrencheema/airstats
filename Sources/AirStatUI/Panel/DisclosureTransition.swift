import SwiftUI

/// True inside a module while the panel is animating a disclosure. Content that
/// would rather arrive after the unfold than during it reads this.
private struct DisclosureInProgressKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isDisclosureInProgress: Bool {
        get { self[DisclosureInProgressKey.self] }
        set { self[DisclosureInProgressKey.self] = newValue }
    }
}

extension AnyTransition {
    /// A module's detail unfolding from under its header.
    ///
    /// Inserted detail used to arrive at full size and fade in while the rows beneath
    /// slid down to make room, so for the length of the slide it overlapped them. This
    /// grows the detail's frame from nothing to its full height, anchored at the top and
    /// clipped, so what the rows beneath are pushed by is exactly what has been revealed.
    /// The header above it never has a reason to move.
    static let disclosure = AnyTransition
        .modifier(active: DisclosureReveal(fraction: 0), identity: DisclosureReveal(fraction: 1))
        .combined(with: .opacity)
}

/// Clips its content to `fraction` of its full height, from the top.
struct DisclosureReveal: ViewModifier, Animatable {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func body(content: Content) -> some View {
        RevealLayout(fraction: fraction) {
            // Clipped by a shape on the content rather than `clipped()` on the layout.
            // The layout's frame changes every frame of the reveal, and a clip rect
            // that follows a changing frame is geometry SwiftUI animates on its own,
            // so it chased each new height with the same ease and ran a beat behind
            // the rows below. The content's frame never changes, only the shape drawn
            // over it, and the shape is not animatable, so it is wherever `fraction`
            // says it is.
            content.clipShape(TopFraction(fraction: fraction))
        }
    }
}

/// The top `fraction` of a rect.
private struct TopFraction: Shape {
    var fraction: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * fraction))
    }
}

/// Lays its one subview out at full size and reports only `fraction` of that height.
///
/// A `frame(height:)` cannot do this: it needs the full height as a number, and the
/// detail's height is whatever its rows and chart add up to on the day. A layout can
/// ask the subview.
private struct RevealLayout: Layout {
    var fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let full = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? full.width, height: full.height * fraction)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let full = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                      proposal: ProposedViewSize(width: bounds.width, height: full.height))
    }
}
