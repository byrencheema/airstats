import Testing
import AppKit
@testable import AirStatKit
@testable import AirStatUI

@Suite("Desktop Widget depth maps onto window levels in the right order")
@MainActor
struct DesktopWidgetDepthTests {

    /// The three depths only mean anything relative to each other, and to the ordinary
    /// windows they are meant to sit above or below.
    @Test("each depth lands on the side of normal windows it claims to")
    func levelsAreOrdered() {
        let normal = NSWindow.Level.normal.rawValue
        #expect(DesktopWidgetDepth.wallpaper.windowLevel.rawValue < normal)
        #expect(DesktopWidgetDepth.withWindows.windowLevel.rawValue > normal)
        #expect(DesktopWidgetDepth.aboveEverything.windowLevel.rawValue
                > DesktopWidgetDepth.withWindows.windowLevel.rawValue)
    }

    /// The controller assigns `isFloatingPanel` before `level` because the setter has
    /// a side effect on the level. If AppKit ever stops doing that the ordering stops
    /// mattering; if this starts failing the other way, the desktop widget is silently back
    /// to floating at every depth.
    @Test("isFloatingPanel overwrites the level, which is why the controller sets it first")
    func floatingPanelFlagOverwritesTheLevel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .screenSaver
        panel.isFloatingPanel = false
        #expect(panel.level != .screenSaver)

        panel.isFloatingPanel = false
        panel.level = DesktopWidgetDepth.wallpaper.windowLevel
        #expect(panel.level == DesktopWidgetDepth.wallpaper.windowLevel)
    }

    /// At the desktop picture's own level the ordering between the two windows is
    /// undefined, and the desktop widget vanishes behind the wallpaper about half the time.
    @Test("the wallpaper depth sits above the desktop picture, not level with it")
    func wallpaperClearsTheDesktopPicture() {
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        #expect(DesktopWidgetDepth.wallpaper.windowLevel.rawValue > desktop)
        #expect(DesktopWidgetDepth.wallpaper.windowLevel.rawValue
                < Int(CGWindowLevelForKey(.desktopIconWindow)))
    }
}
