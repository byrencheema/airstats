import AppKit
import SwiftUI

/// A hosting view that tells its owner when SwiftUI's ideal size changes.
///
/// Shared by both of AirStat's windows, which have the same problem: they are
/// borderless panels whose height is whatever their content currently needs — a module
/// collapsing, a volume being ejected, a metric becoming unavailable all change it.
///
/// `NSHostingView.sizingOptions = [.preferredContentSize]` looks like the answer and is
/// not: outside an `NSHostingController` it suppresses the intrinsic content size
/// (`fittingSize` becomes zero) without ever resizing the window, which leaves a
/// zero-by-zero window that is ordered front and shows nothing at all. So the view
/// keeps its intrinsic size and reports every invalidation instead, and the controller
/// decides what the window's new frame should be — which is where the decision belongs
/// anyway, because it also has to keep the window anchored and on screen.
@MainActor
final class ContentSizedHostingView<Content: View>: NSHostingView<Content> {

    var onContentSizeChange: (() -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onContentSizeChange?()
    }
}
