import Testing
import AppKit
@testable import AirStatKit
@testable import AirStatUI

@MainActor
@Suite("Panel scrolling")
struct PanelScrollTests {

    @Test("repeated resets still produce distinct scroll requests")
    func repeatedScrollResets() {
        let layout = PanelLayoutState()

        layout.requestScrollReset()
        let first = layout.scrollResetRequest

        layout.requestScrollReset()
        #expect(layout.scrollResetRequest == (first &+ 1))
    }

    @Test("the AppKit clip view returns to the top")
    func resetsClipView() {
        final class FlippedDocumentView: NSView {
            override var isFlipped: Bool { true }
        }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let document = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 300, height: 1_000))
        let marker = NSView(frame: .zero)
        document.addSubview(marker)
        scrollView.documentView = document
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 600))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(scrollView.contentView.bounds.minY > 0)

        #expect(PanelScrollResetter.reset(marker))
        #expect(scrollView.contentView.bounds.minY == 0)
    }
}
