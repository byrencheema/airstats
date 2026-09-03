import Testing
import Foundation
import SwiftUI
import AppKit
@testable import AirStatKit
@testable import AirStatUI

@MainActor
@Suite("Panel core rows")
struct PanelCoreRowTests {

    private var contentWidth: CGFloat {
        CGFloat(PanelSettings.width) - 2 * Design.Space.panelInset
    }

    private func fittingWidth(of view: some View) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    private func row(cores count: Int, slot: CGFloat) -> PanelCoreRow {
        let loads = Array(repeating: CPULoad(user: 1, system: 0, idle: 0), count: count)
        return PanelCoreRow(label: "\(count) P-cores", loads: loads, busy: 1,
                            tint: .red, slotWidth: slot)
    }

    /// The M4 Max ships ten P-cores and the M3 Ultra twenty-four. At the preferred
    /// slot either cluster is wider than the panel, and the row used to push every
    /// module under it out through both sides of the window.
    @Test("a wide cluster at its shared slot fits the panel's content width",
          arguments: [8, 10, 12, 16, 24, 32])
    func wideClusterFits(count: Int) {
        let slot = PanelCoreRow.slotWidth(sharedAcross: count)
        let width = fittingWidth(of: row(cores: count, slot: slot))
        #expect(width <= contentWidth + 0.5, "\(count) cores need \(width)pt of \(contentWidth)")
    }

    @Test("a cluster that fits keeps the preferred slot")
    func smallClusterKeepsPreferredSlot() {
        #expect(PanelCoreRow.slotWidth(sharedAcross: 6) == PanelCoreRow.preferredSlotWidth)
        #expect(PanelCoreRow.slotWidth(sharedAcross: 0) == PanelCoreRow.preferredSlotWidth)
    }

    @Test("the shared slot is narrower than the preferred one only when it has to be")
    func slotShrinksOnlyWhenNeeded() {
        let ten = PanelCoreRow.slotWidth(sharedAcross: 10)
        let twentyFour = PanelCoreRow.slotWidth(sharedAcross: 24)
        #expect(ten < PanelCoreRow.preferredSlotWidth)
        #expect(twentyFour < ten)
        #expect(twentyFour > 2)
    }
}
