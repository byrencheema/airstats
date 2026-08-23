import AppKit
import ApplicationServices
import SwiftUI
import AirStatKit

/// Manages the optional always-on-top desktop widget window.
///
/// Everything here is window behaviour: where the desktop widget sits, how it follows the
/// user between Spaces and displays, how it gets out of the way, and how it is moved
/// and resized. The content it shows is `DesktopWidgetRootView`.
@MainActor
public final class DesktopWidgetController: NSObject, NSWindowDelegate {

    public var onVisibilityChange: ((Bool) -> Void)?
    /// Optional hook so the desktop widget's context menu can offer Settings. Left unwired,
    /// the menu simply omits the item rather than showing a dead one.
    public var onRequestSettings: (() -> Void)?

    private let engine: MetricsEngine
    private let settings: SettingsStore
    private let layout: DesktopWidgetLayout
    private let hoverProxy = DesktopWidgetHoverProxy()

    private var panel: DesktopWidgetPanel?
    private var trackingArea: NSTrackingArea?

    private var interaction: Interaction?
    private var isPointerNear = false
    /// True while the click-through escape hatch is held down.
    private var isTemporarilyInteractive = false

    private var settingsTask: Task<Void, Never>?
    private var proximityMonitor: Any?
    private var globalModifierMonitor: Any?
    private var localModifierMonitor: Any?

    /// Number of `NSEvent` monitors this controller currently owns.
    ///
    /// Exposed because monitor leaks are invisible from the outside — they show up
    /// only as an app that gets slower every time a window is shown — and this is
    /// what lets a running build be checked rather than reasoned about.
    public var activeEventMonitorCount: Int {
        [proximityMonitor, globalModifierMonitor, localModifierMonitor].compactMap { $0 }.count
    }

    public init(engine: MetricsEngine, settings: SettingsStore) {
        self.engine = engine
        self.settings = settings
        self.layout = DesktopWidgetLayout(width: settings.settings.desktopWidget.width)
        super.init()
        beginObservingSettings()
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    /// The stack the window actually ended up in, as opposed to the one that was
    /// asked for. Worth being able to read back: `isFloatingPanel` assigns the level
    /// as a side effect, so a level set in the wrong order is silently discarded and
    /// nothing about the window looks wrong until something covers it.
    public var windowLevel: NSWindow.Level? { panel?.level }

    // MARK: Presentation

    /// Bring the desktop widget into line with the current settings, creating or tearing
    /// down the window as needed.
    public func syncWithSettings() {
        if settings.settings.desktopWidget.isEnabled {
            show()
        } else {
            hide()
            // Turning the desktop widget off is a statement that it is not wanted, not that it
            // is briefly out of the way, so its view tree goes too: an ordered-out window
            // is still on AppKit's window list and holds all 4.7 MB of dirty heap
            // (`footprint`, MALLOC_SMALL, this machine) that building it cost.
            releaseWindow()
        }
    }

    private func releaseWindow() {
        guard let panel else { return }
        self.panel = nil
        trackingArea = nil
        anchorEdges = nil
        panel.interaction = nil
        panel.delegate = nil
        panel.close()
        WindowLog.log("desktop widget window released")
    }

    public func show() {
        let panel = self.panel ?? makeWindow()
        self.panel = panel
        apply(settings.settings.desktopWidget, to: panel)
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: the desktop widget must
        // appear over the frontmost app without that app losing focus.
        panel.orderFrontRegardless()
        WindowLog.log("desktop widget shown frame=\(panel.frame) level=\(panel.level.rawValue) monitors=\(activeEventMonitorCount)")
        onVisibilityChange?(true)
    }

    public func hide() {
        removeMonitors()
        guard let panel else { return }
        panel.orderOut(nil)
        isPointerNear = false
        isTemporarilyInteractive = false
        layout.isGrabbable = false
        WindowLog.log("desktop widget hidden monitors=\(activeEventMonitorCount)")
        onVisibilityChange?(false)
    }

    /// A display was attached, removed, or rearranged: a saved position can now point
    /// at coordinates no screen covers.
    public func screenConfigurationChanged() {
        guard let panel, panel.isVisible else { return }
        WindowLog.log("screen parameters changed; revalidating \(panel.frame) against \(NSScreen.screens.count) screen(s)")
        reposition()
    }

    // MARK: Window

    private func makeWindow() -> DesktopWidgetPanel {
        let root = DesktopWidgetRootView(engine: engine, settings: settings, layout: layout)
        // The window follows its content's height, so a module appearing or a metric
        // becoming unavailable resizes the desktop widget instead of clipping it.
        let hosting = ContentSizedHostingView(rootView: root)
        hosting.onContentSizeChange = { [weak self] in self?.scheduleContentResize() }

        let panel = DesktopWidgetPanel(contentView: hosting)
        panel.interaction = self
        panel.delegate = self
        panel.setContentSize(hosting.fittingSize)

        hoverProxy.onPointerEntered = { [weak self] in self?.setPointerNear(true) }
        hoverProxy.onPointerExited = { [weak self] in self?.setPointerNear(false) }
        hoverProxy.onPointerMoved = { [weak self] event in self?.updateCursor(for: event) }
        installTrackingArea(on: hosting)

        return panel
    }

    private func installTrackingArea(on view: NSView) {
        if let trackingArea { view.removeTrackingArea(trackingArea) }
        // `.inVisibleRect` keeps the area correct as the desktop widget is resized;
        // `.activeAlways` is what makes it work while another app is frontmost.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeAlways, .inVisibleRect],
                                  owner: hoverProxy,
                                  userInfo: nil)
        view.addTrackingArea(area)
        trackingArea = area
    }

    /// Apply every setting that has a window-level consequence.
    ///
    /// Idempotent on purpose: it runs on every settings revision, and anything that
    /// wrote back to settings from here would loop.
    private func apply(_ desktopWidget: DesktopWidgetSettings, to panel: DesktopWidgetPanel) {
        // Order matters and is not optional. Setting `isFloatingPanel` assigns the
        // window's level as a side effect — `.floating` when true, `.normal` when
        // false — so a level written before it is thrown away. Measured: with the two
        // lines the other way round every depth reported `kCGFloatingWindowLevel`.
        panel.isFloatingPanel = desktopWidget.depth != .wallpaper
        panel.level = desktopWidget.depth.windowLevel
        // On the wallpaper the desktop widget is part of the desktop, and a desktop does not
        // cast a shadow onto itself. Everywhere else the shadow is what lifts it off
        // whatever it is covering.
        panel.hasShadow = desktopWidget.depth != .wallpaper
        panel.collectionBehavior = desktopWidget.showsOnAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            : [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]

        // Width is handed to SwiftUI, not to the window: the hosting view reports its
        // new ideal size once it has re-laid out, and `applyContentSize` turns that
        // into a frame with the right height for the new width.
        if interaction == nil, layout.width != desktopWidget.width {
            layout.width = desktopWidget.width
        }

        applyClickThrough(desktopWidget)
        updateAlpha(animated: false)
        if interaction == nil { reposition() }
    }

    // MARK: Placement

    /// Overlaps a corner needs to be within to be considered "dropped on" it.
    private static let snapDistance: CGFloat = 32
    private static let edgeMargin: CGFloat = Design.Space.xl
    /// Mirrors the clamp `SettingsStore.sanitize` applies to `desktopWidget.width`; a drag
    /// must not be able to produce a value the store would silently change back.
    private static let widthRange: ClosedRange<Double> = 160...480
    /// How close to a side edge a press counts as a resize rather than a move.
    private static let resizeMargin: CGFloat = 6

    private func reposition() {
        guard let panel else { return }
        let frame = placement(for: settings.settings.desktopWidget, size: panel.frame.size)
        rememberEdges(frame)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }

    private func placement(for desktopWidget: DesktopWidgetSettings, size: NSSize) -> NSRect {
        // A hand-edited settings file can contain a NaN, which would poison every
        // comparison the placement makes and leave the window unplaceable.
        let saved: NSPoint? = {
            guard let x = desktopWidget.originX, let y = desktopWidget.originY, x.isFinite, y.isFinite else { return nil }
            return NSPoint(x: x, y: y)
        }()
        let frame = DesktopWidgetPlacement.resolvedFrame(corner: desktopWidget.corner,
                                                   savedOrigin: saved,
                                                   size: size,
                                                   displays: displays,
                                                   currentFrame: panel?.frame,
                                                   margin: Self.edgeMargin)
        if desktopWidget.corner == .free, let saved, frame.origin != saved {
            WindowLog.log("saved desktop widget position \(saved) adjusted to \(frame.origin) for the attached displays")
        }
        return frame
    }

    /// Read once per placement: `NSScreen.screens` is a fresh array each call.
    private var displays: [DisplayGeometry] { DisplayGeometry.current }

    /// A saved or dragged frame, pulled back onto whatever displays exist now.
    private func validated(_ frame: NSRect) -> NSRect {
        DesktopWidgetPlacement.resolvedFrame(corner: .free, savedOrigin: frame.origin, size: frame.size,
                                       displays: displays, currentFrame: frame,
                                       margin: Self.edgeMargin)
    }

    // MARK: Dimming

    private func setPointerNear(_ near: Bool) {
        guard near != isPointerNear else { return }
        isPointerNear = near
        updateAlpha(animated: true)
    }

    private func updateAlpha(animated: Bool) {
        guard let panel else { return }
        let desktopWidget = settings.settings.desktopWidget
        let isAwake = !desktopWidget.dimsWhenInactive || isPointerNear || isTemporarilyInteractive
        let target = isAwake ? desktopWidget.opacity : desktopWidget.inactiveOpacity
        guard abs(panel.alphaValue - target) > 0.001 else { return }

        guard animated, motionDuration > 0 else {
            panel.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = target
        }
    }

    /// The fade is an AppKit animation, so it consults the same accessibility gate
    /// `Design.Motion` applies to the SwiftUI side rather than inventing a second one.
    private var motionDuration: TimeInterval {
        Design.Motion.respectingAccessibility(Design.Motion.value) == nil ? 0 : 0.18
    }

    // MARK: Click-through

    /// Click-through hands every click to whatever is underneath, which also means the
    /// desktop widget can no longer be dragged, resized, or right-clicked — including to turn
    /// click-through back off. Two ways out, in order of reliability:
    ///
    /// 1. The setting lives in Settings, reachable from the status item, which is
    ///    unaffected by anything the desktop widget does. This is the guaranteed route and the
    ///    reason the toggle is not offered *only* on the desktop widget itself.
    /// 2. Holding ⌥⌘ makes the desktop widget interactive for as long as it is held, so it can
    ///    be grabbed in place. This needs the app to be trusted for accessibility —
    ///    keyboard events cannot be observed globally otherwise — so it is installed
    ///    only when that is already true, and never prompts.
    private func applyClickThrough(_ desktopWidget: DesktopWidgetSettings) {
        panel?.ignoresMouseEvents = desktopWidget.isClickThrough && !isTemporarilyInteractive

        // A window that ignores mouse events receives no tracking-area callbacks
        // either, so proximity has to come from somewhere else while it is on.
        if desktopWidget.isClickThrough && desktopWidget.dimsWhenInactive {
            installProximityMonitor()
        } else {
            removeProximityMonitor()
        }

        if desktopWidget.isClickThrough {
            installEscapeHatchMonitors()
        } else {
            removeEscapeHatchMonitors()
            if isTemporarilyInteractive {
                isTemporarilyInteractive = false
                layout.isGrabbable = false
            }
        }
    }

    public func setClickThrough(_ enabled: Bool) {
        settings.update { $0.desktopWidget.isClickThrough = enabled }
    }

    private func installProximityMonitor() {
        guard proximityMonitor == nil else { return }
        // Event-driven, not polled: this fires only when the pointer actually moves,
        // and does nothing at all unless it crosses the desktop widget's boundary.
        proximityMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                Task { @MainActor in self?.updatePointerProximity() }
            }
        WindowLog.log("desktop widget proximity monitor installed (click-through) monitors=\(activeEventMonitorCount)")
    }

    private func removeProximityMonitor() {
        guard let proximityMonitor else { return }
        NSEvent.removeMonitor(proximityMonitor)
        self.proximityMonitor = nil
    }

    private func updatePointerProximity() {
        guard let panel, panel.isVisible else { return }
        setPointerNear(panel.frame.insetBy(dx: -Design.Space.m, dy: -Design.Space.m)
            .contains(NSEvent.mouseLocation))
    }

    private func installEscapeHatchMonitors() {
        // A local monitor covers the case where AirStat itself is frontmost (its
        // Settings window is open); the global one needs accessibility trust, which we
        // check rather than request so the app never nags for a permission.
        if localModifierMonitor == nil {
            localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                Task { @MainActor in self?.updateEscapeHatch(event.modifierFlags) }
                return event
            }
        }
        if globalModifierMonitor == nil, AXIsProcessTrusted() {
            globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
                Task { @MainActor in self?.updateEscapeHatch(event.modifierFlags) }
            }
        }
        WindowLog.log("desktop widget escape-hatch monitors installed trusted=\(AXIsProcessTrusted()) monitors=\(activeEventMonitorCount)")
    }

    private func removeEscapeHatchMonitors() {
        if let globalModifierMonitor { NSEvent.removeMonitor(globalModifierMonitor) }
        if let localModifierMonitor { NSEvent.removeMonitor(localModifierMonitor) }
        globalModifierMonitor = nil
        localModifierMonitor = nil
    }

    private func removeMonitors() {
        removeProximityMonitor()
        removeEscapeHatchMonitors()
    }

    private static let escapeHatchModifiers: NSEvent.ModifierFlags = [.option, .command]

    private func updateEscapeHatch(_ flags: NSEvent.ModifierFlags) {
        let held = flags.intersection(.deviceIndependentFlagsMask) == Self.escapeHatchModifiers
        guard held != isTemporarilyInteractive else { return }
        isTemporarilyInteractive = held
        layout.isGrabbable = held
        panel?.ignoresMouseEvents = settings.settings.desktopWidget.isClickThrough && !held
        updateAlpha(animated: true)
        WindowLog.log("desktop widget escape hatch \(held ? "engaged" : "released")")
    }

    // MARK: Settings observation

    /// The desktop widget is configured from a window it does not own, so it watches the
    /// store directly. Without this, toggling click-through in Settings would change
    /// nothing until something else happened to call `syncWithSettings`.
    private func beginObservingSettings() {
        settingsTask?.cancel()
        let changes = settings.changes
        settingsTask = Task { @MainActor [weak self] in
            for await _ in changes {
                guard let self else { return }
                self.syncWithSettings()
            }
        }
    }

    // MARK: Content-driven sizing

    /// SwiftUI can invalidate its size several times in one layout pass, so the window
    /// is re-measured once on the next turn rather than on every invalidation.
    private func scheduleContentResize() {
        guard !hasPendingResize else { return }
        hasPendingResize = true
        Task { @MainActor [weak self] in
            self?.hasPendingResize = false
            self?.applyContentSize()
        }
    }

    private var hasPendingResize = false

    /// A window grows from its bottom-left corner, so a taller desktop widget would grow
    /// upwards and one pinned to the top of the screen would creep off it. Re-pin
    /// whichever edges the user's corner choice implies, then re-validate.
    private func applyContentSize() {
        guard let panel, interaction == nil, let content = panel.contentView else { return }
        let size = content.fittingSize
        guard size.width > 0, size.height > 0, size != panel.frame.size else { return }

        let desktopWidget = settings.settings.desktopWidget
        var frame = NSRect(origin: panel.frame.origin, size: size)
        if let edges = anchorEdges {
            if anchorsToTop(desktopWidget) { frame.origin.y = edges.maxY - size.height }
            if anchorsToTrailing(desktopWidget) { frame.origin.x = edges.maxX - size.width }
        }
        frame = validated(frame)
        panel.setFrame(frame, display: true)
        rememberEdges(frame)

        // Keep the stored position honest, or the desktop widget would move by the height
        // difference the next time it is created.
        if desktopWidget.corner == .free,
           desktopWidget.originX != Double(frame.minX) || desktopWidget.originY != Double(frame.minY) {
            persist(corner: .free, origin: frame.origin)
        }
    }

    // MARK: Window delegate

    public func windowDidMove(_ notification: Notification) {
        guard interaction == nil, let panel else { return }
        rememberEdges(panel.frame)
    }

    /// The edges to keep pinned when the content's height changes. Nil until the
    /// window has been placed once, so the first layout pass cannot anchor to nothing.
    private var anchorEdges: (maxX: CGFloat, maxY: CGFloat)?

    private func rememberEdges(_ frame: NSRect) {
        anchorEdges = (frame.maxX, frame.maxY)
    }

    private func anchorsToTop(_ desktopWidget: DesktopWidgetSettings) -> Bool {
        switch desktopWidget.corner {
        case .topLeft, .topRight: return true
        case .bottomLeft, .bottomRight: return false
        case .free:
            // A freely placed desktop widget keeps whichever half of the screen it lives in.
            guard let panel, let display = host(of: panel.frame) else { return true }
            return panel.frame.midY > display.visibleFrame.midY
        }
    }

    private func anchorsToTrailing(_ desktopWidget: DesktopWidgetSettings) -> Bool {
        switch desktopWidget.corner {
        case .topRight, .bottomRight: return true
        case .topLeft, .bottomLeft: return false
        case .free:
            guard let panel, let display = host(of: panel.frame) else { return false }
            return panel.frame.midX > display.visibleFrame.midX
        }
    }

    private func host(of frame: NSRect) -> DisplayGeometry? {
        DesktopWidgetPlacement.display(containing: frame, in: displays)
    }

    // MARK: Interaction

    private enum Interaction {
        case moving(windowOrigin: NSPoint, pointerOrigin: NSPoint)
        case resizing(edge: ResizeEdge, startFrame: NSRect, pointerOrigin: NSPoint)
    }

    private enum ResizeEdge { case leading, trailing }

    private func persist(corner: DesktopWidgetCorner, origin: NSPoint?) {
        settings.update {
            $0.desktopWidget.corner = corner
            $0.desktopWidget.originX = origin.map { Double($0.x) }
            $0.desktopWidget.originY = origin.map { Double($0.y) }
        }
    }
}

// MARK: - Move and resize

extension DesktopWidgetController: DesktopWidgetInteractionHandler {

    func desktopWidgetMouseDown(_ event: NSEvent) -> Bool {
        guard let panel else { return false }
        let frame = panel.frame
        let pointer = NSEvent.mouseLocation
        let x = event.locationInWindow.x

        if x <= Self.resizeMargin {
            interaction = .resizing(edge: .leading, startFrame: frame, pointerOrigin: pointer)
        } else if x >= frame.width - Self.resizeMargin {
            interaction = .resizing(edge: .trailing, startFrame: frame, pointerOrigin: pointer)
        } else {
            interaction = .moving(windowOrigin: frame.origin, pointerOrigin: pointer)
        }
        return true
    }

    func desktopWidgetMouseDragged(_ event: NSEvent) -> Bool {
        guard let panel, let interaction else { return false }
        let pointer = NSEvent.mouseLocation

        switch interaction {
        case .moving(let windowOrigin, let pointerOrigin):
            let origin = NSPoint(x: windowOrigin.x + pointer.x - pointerOrigin.x,
                                 y: windowOrigin.y + pointer.y - pointerOrigin.y)
            // Free movement during the drag; the drop is what gets validated, so the
            // desktop widget can be dragged across a display boundary.
            panel.setFrameOrigin(NSPoint(x: origin.x.rounded(), y: origin.y.rounded()))

        case .resizing(let edge, let startFrame, let pointerOrigin):
            let delta = pointer.x - pointerOrigin.x
            let raw = edge == .trailing ? startFrame.width + delta : startFrame.width - delta
            let width = min(max(raw, Self.widthRange.lowerBound), Self.widthRange.upperBound)
            let x = edge == .trailing ? startFrame.minX : startFrame.maxX - width
            // The window's height follows its content, so only the width and the
            // anchored edge are set here; SwiftUI settles the rest.
            layout.width = width
            panel.setFrame(NSRect(x: x.rounded(), y: startFrame.minY,
                                  width: width.rounded(), height: panel.frame.height),
                           display: true)
        }
        return true
    }

    func desktopWidgetMouseUp(_ event: NSEvent) -> Bool {
        guard let panel, let interaction else { return false }
        self.interaction = nil

        switch interaction {
        case .moving:
            let corner = snapCorner(for: panel.frame)
            let frame = DesktopWidgetPlacement.resolvedFrame(corner: corner,
                                                       savedOrigin: panel.frame.origin,
                                                       size: panel.frame.size,
                                                       displays: displays,
                                                       currentFrame: panel.frame,
                                                       margin: Self.edgeMargin)
            panel.setFrame(frame, display: true)
            rememberEdges(frame)
            persist(corner: corner, origin: corner == .free ? frame.origin : nil)
            WindowLog.log("desktop widget dropped corner=\(corner.rawValue) origin=\(frame.origin)")

        case .resizing:
            let width = min(max(Double(panel.frame.width), Self.widthRange.lowerBound),
                            Self.widthRange.upperBound)
            rememberEdges(panel.frame)
            // One write at the end of the gesture rather than one per frame.
            settings.update { $0.desktopWidget.width = width }
            if settings.settings.desktopWidget.corner == .free {
                persist(corner: .free, origin: panel.frame.origin)
            }
            WindowLog.log("desktop widget resized width=\(width)")
        }
        return true
    }

    /// Dropping near a corner of the current display snaps to it — which is also what
    /// converts a free position back into one that survives a resolution change.
    private func snapCorner(for frame: NSRect) -> DesktopWidgetCorner {
        guard let display = host(of: frame) else { return .free }
        return DesktopWidgetPlacement.snapCorner(for: frame, visible: display.visibleFrame,
                                           margin: Self.edgeMargin, snapDistance: Self.snapDistance)
    }

    func desktopWidgetRightMouseDown(_ event: NSEvent) {
        guard let panel, let contentView = panel.contentView else { return }
        contextMenu().popUp(positioning: nil, at: event.locationInWindow, in: contentView)
    }

    private func updateCursor(for event: NSEvent) {
        guard let panel, !panel.ignoresMouseEvents else { return }
        let x = event.locationInWindow.x
        let isEdge = x <= Self.resizeMargin || x >= panel.frame.width - Self.resizeMargin
        (isEdge ? NSCursor.resizeLeftRight : NSCursor.openHand).set()
    }
}

/// Which window stack each depth maps to.
extension DesktopWidgetDepth {
    var windowLevel: NSWindow.Level {
        switch self {
        // `.screenSaver` is the level that stays visible over a full-screen app;
        // `.floating` alone disappears the moment anything goes full screen.
        case .aboveEverything: return .screenSaver
        case .withWindows: return .floating
        // One step above the window the desktop picture is drawn in, which is the only
        // place "on the wallpaper" can mean anything: at the picture's own level the
        // ordering between the two is undefined and the desktop widget disappears behind it
        // about half the time. Still below the desktop icons and every ordinary window.
        case .wallpaper:
            return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        }
    }
}

// MARK: - Context menu

extension DesktopWidgetController {

    private func contextMenu() -> NSMenu {
        let desktopWidget = settings.settings.desktopWidget
        let menu = NSMenu()

        for corner in DesktopWidgetCorner.allCases where corner != .free {
            let item = menu.addItem(withTitle: corner.label,
                                    action: #selector(chooseCorner(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = corner.rawValue
            item.state = desktopWidget.corner == corner ? .on : .off
        }
        menu.addItem(.separator())

        let compact = menu.addItem(withTitle: "Compact", action: #selector(toggleCompact), keyEquivalent: "")
        compact.target = self
        compact.state = desktopWidget.isCompact ? .on : .off

        let dim = menu.addItem(withTitle: "Dim When Inactive",
                               action: #selector(toggleDimming), keyEquivalent: "")
        dim.target = self
        dim.state = desktopWidget.dimsWhenInactive ? .on : .off

        let layer = NSMenu()
        for depth in DesktopWidgetDepth.allCases {
            let item = layer.addItem(withTitle: depth.label,
                                     action: #selector(chooseDepth(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = depth.rawValue
            item.state = desktopWidget.depth == depth ? .on : .off
            item.toolTip = depth.detail
        }
        menu.setSubmenu(layer, for: menu.addItem(withTitle: "Layer", action: nil, keyEquivalent: ""))

        let clickThrough = menu.addItem(withTitle: "Click-Through",
                                        action: #selector(toggleClickThrough), keyEquivalent: "")
        clickThrough.target = self
        clickThrough.state = desktopWidget.isClickThrough ? .on : .off
        // The one place the user is told how to undo it, at the moment they turn it on.
        clickThrough.toolTip = "Clicks pass through to the window below. Hold ⌥⌘ to grab the desktop widget again, or turn this off in Settings."

        menu.addItem(.separator())
        if onRequestSettings != nil {
            menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "")
                .target = self
        }
        menu.addItem(withTitle: "Hide Desktop Widget", action: #selector(hideDesktopWidget), keyEquivalent: "")
            .target = self
        return menu
    }

    @objc private func chooseDepth(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let depth = DesktopWidgetDepth(rawValue: raw) else { return }
        settings.update { $0.desktopWidget.depth = depth }
    }

    @objc private func chooseCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let corner = DesktopWidgetCorner(rawValue: raw) else { return }
        persist(corner: corner, origin: nil)
    }

    @objc private func toggleCompact() {
        settings.update { $0.desktopWidget.isCompact.toggle() }
    }

    @objc private func toggleDimming() {
        settings.update { $0.desktopWidget.dimsWhenInactive.toggle() }
    }

    @objc private func toggleClickThrough() {
        settings.update { $0.desktopWidget.isClickThrough.toggle() }
    }

    @objc private func openSettings() { onRequestSettings?() }

    @objc private func hideDesktopWidget() {
        settings.update { $0.desktopWidget.isEnabled = false }
    }
}
