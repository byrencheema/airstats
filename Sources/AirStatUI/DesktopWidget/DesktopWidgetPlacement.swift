import AppKit
import AirStatKit

/// One display, reduced to the two rectangles that decide where a window may sit.
public struct DisplayGeometry: Equatable, Sendable {
    /// Full bounds in the global coordinate space.
    public var frame: NSRect
    /// Bounds minus the menu bar and Dock. On a notched display this already excludes
    /// the taller menu bar, so nothing here needs to know what a notch is.
    public var visibleFrame: NSRect

    public init(frame: NSRect, visibleFrame: NSRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    public init(_ screen: NSScreen) {
        self.init(frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    @MainActor
    public static var current: [DisplayGeometry] { NSScreen.screens.map(DisplayGeometry.init) }
}

/// Where the desktop widget goes, as pure geometry.
///
/// Deliberately separated from the window it positions. Display arrangements that
/// break placement — a saved position on a monitor that has since been unplugged, a
/// screen mounted above the primary so its coordinates are positive-Y, a laptop
/// display that is now the second screen — are close to impossible to stage by hand
/// and trivial to state as rectangles, so the rules live somewhere they can be
/// checked without a Mac in that configuration.
public enum DesktopWidgetPlacement {

    /// The display a frame mostly sits on, by overlap area. Nil when it overlaps none
    /// of them, which is the signal that a stored position is stale.
    public static func display(containing frame: NSRect,
                               in displays: [DisplayGeometry]) -> DisplayGeometry? {
        var best: (display: DisplayGeometry, area: CGFloat)?
        for display in displays {
            let intersection = display.frame.intersection(frame)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            guard area > 0 else { continue }
            if best == nil || area > best!.area { best = (display, area) }
        }
        return best?.display
    }

    /// Pull a frame fully inside `bounds`. A frame larger than the bounds is pinned to
    /// the top-leading corner rather than being pushed off the opposite edge.
    public static func clamp(_ frame: NSRect, into bounds: NSRect) -> NSRect {
        var result = frame
        result.origin.x = min(max(frame.minX, bounds.minX),
                              max(bounds.maxX - frame.width, bounds.minX))
        result.origin.y = min(max(frame.minY, bounds.minY),
                              max(bounds.maxY - frame.height, bounds.minY))
        return NSRect(x: result.origin.x.rounded(), y: result.origin.y.rounded(),
                      width: frame.width, height: frame.height)
    }

    public static func cornerFrame(_ corner: DesktopWidgetCorner, size: NSSize,
                                   visible: NSRect, margin: CGFloat) -> NSRect {
        let origin: NSPoint
        switch corner {
        case .topLeft:
            origin = NSPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin)
        case .bottomLeft:
            origin = NSPoint(x: visible.minX + margin, y: visible.minY + margin)
        case .bottomRight:
            origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
        // A free desktop widget with no saved position has never been placed; the default
        // corner is the same one `DesktopWidgetSettings` starts at.
        case .topRight, .free:
            origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
        }
        return clamp(NSRect(origin: origin, size: size), into: visible)
    }

    /// The frame the desktop widget should occupy right now.
    ///
    /// - Parameters:
    ///   - currentFrame: where the window is at the moment, used to keep a corner on
    ///     the display the desktop widget already lives on instead of yanking it to the primary.
    public static func resolvedFrame(corner: DesktopWidgetCorner,
                                     savedOrigin: NSPoint?,
                                     size: NSSize,
                                     displays: [DisplayGeometry],
                                     currentFrame: NSRect?,
                                     margin: CGFloat) -> NSRect {
        guard let primary = displays.first else {
            return NSRect(origin: savedOrigin ?? .zero, size: size)
        }
        switch corner {
        case .free:
            guard let savedOrigin else {
                return cornerFrame(.topRight, size: size, visible: primary.visibleFrame, margin: margin)
            }
            let proposed = NSRect(origin: savedOrigin, size: size)
            guard let display = display(containing: proposed, in: displays) else {
                // The display this position named is gone. A corner of the primary is
                // the only placement guaranteed to be somewhere the user can see.
                return cornerFrame(.topRight, size: size, visible: primary.visibleFrame, margin: margin)
            }
            return clamp(proposed, into: display.visibleFrame)
        default:
            let host = currentFrame.flatMap { display(containing: $0, in: displays) } ?? primary
            return cornerFrame(corner, size: size, visible: host.visibleFrame, margin: margin)
        }
    }

    /// The corner a dropped desktop widget should snap to, or `.free` when it was dropped
    /// somewhere in the middle. Snapping is what converts a hand-placed desktop widget into a
    /// position that survives a resolution change.
    public static func snapCorner(for frame: NSRect, visible: NSRect,
                                  margin: CGFloat, snapDistance: CGFloat) -> DesktopWidgetCorner {
        let corners: [DesktopWidgetCorner] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        for corner in corners {
            let target = cornerFrame(corner, size: frame.size, visible: visible, margin: margin)
            if hypot(target.minX - frame.minX, target.minY - frame.minY) <= snapDistance {
                return corner
            }
        }
        return .free
    }
}
