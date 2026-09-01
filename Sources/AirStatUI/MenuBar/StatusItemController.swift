import AppKit
import AirStatKit

/// What the menu bar is currently made of.
///
/// Either one item drawing every readout, one item per enabled readout in the user's
/// order, or no item at all. Derived from settings and compared as a whole, so flipping
/// the combine switch or enabling a readout is a single value change the controller
/// can act on without inspecting anything else.
enum MenuBarItemLayout: Equatable {
    case combined
    case separate([UUID])
    /// The user has taken the app out of the menu bar. Nothing is installed, and the
    /// bar reports as invisible so sampling throttles the same way it does when the
    /// items are pushed off by crowding.
    case hidden

    init(settings: MenuBarSettings) {
        guard settings.isVisible else {
            self = .hidden
            return
        }
        let enabled = settings.enabledItems.map(\.id)
        // Separate items with nothing enabled would put no item on the bar at all, and
        // with it no way back into the app short of a hot key. The combined item draws
        // an empty readout at a clickable minimum width, so it stands in.
        guard !settings.usesCombinedItem, !enabled.isEmpty else {
            self = .combined
            return
        }
        self = .separate(enabled)
    }
}

/// Owns the app's `NSStatusItem`s and the custom views drawn inside them.
///
/// The menu bar is the most scrutinised surface in the app: it sits two pixels from
/// Apple's own glyphs, redraws constantly, and must never jitter, blur, or push its
/// neighbours around. Everything here exists to serve that.
///
/// There is one item per enabled readout when the user has turned the combine switch
/// off, and one item for all of them when it is on. Separate items are what let the
/// user drag a readout to sit beside Wi-Fi rather than beside our other numbers, and
/// what lets macOS drop them one at a time instead of losing the whole bar at once.
@MainActor
public final class StatusItemController {

    public var onPrimaryAction: (() -> Void)?
    public var onSecondaryAction: (() -> Void)?
    public var onVisibilityChange: ((Bool) -> Void)?

    private let engine: MetricsEngine
    private let settings: SettingsStore
    private var hosted: [Hosted] = []
    private var layout: MenuBarItemLayout?
    /// The item the user last clicked. Everything anchored to "the status item" means
    /// this one, because with several of them the only sensible answer is the one the
    /// user just touched.
    private var activeItem: NSStatusItem?
    private var renderTask: Task<Void, Never>?
    private var lastReportedVisibility: Bool?

    /// One status item and the view drawing into it. `readout` is the id of the single
    /// readout it draws, or nil for the combined item, which draws them all.
    private struct Hosted {
        let readout: UUID?
        let item: NSStatusItem
        let content: MenuBarContentView
        let visibility: NSKeyValueObservation
    }

    public init(engine: MetricsEngine, settings: SettingsStore) {
        self.engine = engine
        self.settings = settings
    }

    // MARK: Installation

    public func install() {
        syncLayout()
        beginRendering()
        render()
    }

    public func remove() {
        renderTask?.cancel()
        renderTask = nil
        tearDownItems()
        layout = nil
    }

    /// The combined item keeps the name it has always had, so an install that predates
    /// separate items does not lose the position the user dragged it to.
    static let combinedAutosaveName = "AirStatsStatusItem"

    /// Per-readout items are keyed by the readout's own id rather than by its metric.
    /// Two readouts of the same metric are allowed, and keyed by metric they would
    /// share one saved position and fight over it. The consequence is that turning a
    /// readout off and back on returns it to where the user dragged it, since that
    /// keeps the config and its id, while deleting one and adding it again mints a new
    /// id and starts from the default position, which is what a new readout should do.
    static func autosaveName(for readout: UUID) -> String {
        "\(combinedAutosaveName)-\(readout.uuidString)"
    }

    /// Brings the installed items in line with the settings. A no-op unless the combine
    /// switch moved or the set of enabled readouts changed, so an unrelated settings
    /// write costs one comparison and no menu bar churn.
    ///
    /// When it does change, every item is rebuilt rather than the difference applied.
    /// Placement is the reason: an item is only ever inserted at the end of our run, so
    /// keeping the survivors and appending a newly enabled readout would put it at one
    /// end of the bar instead of in the slot the user put it in. Rebuilding puts the
    /// whole run back in order, and anything the user has dragged elsewhere returns to
    /// where they dragged it from its autosaved position.
    private func syncLayout() {
        let desired = MenuBarItemLayout(settings: settings.settings.menuBar)
        guard desired != layout else { return }
        tearDownItems()
        layout = desired

        switch desired {
        case .combined:
            if let entry = makeItem(readout: nil,
                                    autosaveName: StatusItemController.combinedAutosaveName,
                                    label: "AirStats system statistics") {
                hosted = [entry]
            }

        case .separate:
            // Built back to front: an item with no saved position lands to the left of
            // the ones already on the bar, so making the last readout first leaves the
            // first one leftmost and the configured order reads left to right. A
            // readout the user has since dragged somewhere else keeps that position.
            let configs = settings.settings.menuBar.enabledItems
            let built = configs.reversed().compactMap { config in
                makeItem(readout: config.id,
                         autosaveName: StatusItemController.autosaveName(for: config.id),
                         label: "AirStats \(config.metric.label)")
            }
            hosted = built.reversed()

        case .hidden:
            break
        }
        reportVisibility()
    }

    private func makeItem(readout: UUID?, autosaveName: String, label: String) -> Hosted? {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = [.removalAllowed]
        item.autosaveName = autosaveName

        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return nil
        }
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(label)

        let content = MenuBarContentView(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            content.topAnchor.constraint(equalTo: button.topAnchor),
            content.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])

        return Hosted(readout: readout, item: item, content: content,
                      visibility: observeVisibility(of: item))
    }

    /// Every item goes, observations first: a `removeStatusItem` fires the visibility
    /// observer on the way out, and reporting a bar that is only half torn down as
    /// invisible would throttle sampling for the moment it takes to build the new one.
    private func tearDownItems() {
        for entry in hosted {
            entry.visibility.invalidate()
            NSStatusBar.system.removeStatusItem(entry.item)
        }
        hosted.removeAll()
        activeItem = nil
    }

    // MARK: Geometry

    /// Screen-space rect of the status item button the panel should hang from, which is
    /// the one the user last clicked. Nil when the item is not currently on screen.
    public var anchorRect: NSRect? {
        guard let button = anchorItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    public var anchorScreen: NSScreen? {
        anchorItem?.button?.window?.screen ?? NSScreen.main
    }

    /// The last item clicked, or the first one when the panel is being opened by a hot
    /// key or a menu rather than by a click.
    private var anchorItem: NSStatusItem? {
        if let activeItem, hosted.contains(where: { $0.item === activeItem }) { return activeItem }
        return hosted.first?.item
    }

    public func presentMenu(_ menu: NSMenu) {
        guard let item = anchorItem else { return }
        item.menu = menu
        item.button?.performClick(nil)
        // Detach immediately so the next left-click goes back to our action.
        item.menu = nil
    }

    // MARK: Visibility

    /// `NSStatusItem.isVisible` goes false when the item is pushed off the menu bar
    /// (too many items, or hidden behind the notch). That is the strongest signal we
    /// have that nobody can see our readouts, so it drives sampling throttling.
    private func observeVisibility(of item: NSStatusItem) -> NSKeyValueObservation {
        item.observe(\.isVisible, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.reportVisibility() }
        }
    }

    /// Separate items are hidden one at a time, so one readout falling off the bar says
    /// nothing about the rest: sampling only throttles once every item is gone.
    private func reportVisibility() {
        let visible = hosted.contains { $0.item.isVisible }
        guard lastReportedVisibility != visible else { return }
        lastReportedVisibility = visible
        onVisibilityChange?(visible)
    }

    // MARK: Rendering

    /// Re-render whenever the engine publishes or settings change. Observation-driven
    /// rather than timer-driven: no snapshot, no redraw, no wakeup.
    private func beginRendering() {
        renderTask?.cancel()
        let changes = ObservedChanges { [engine, settings] in
            _ = engine.snapshot
            _ = settings.revision
        }
        renderTask = Task { @MainActor [weak self] in
            for await _ in changes {
                guard let self else { return }
                self.render()
            }
        }
    }

    private func render() {
        // Settings are read here rather than watched separately, so the combine switch
        // takes effect on the same pass that redraws the numbers under it.
        syncLayout()
        guard !hosted.isEmpty else { return }
        let model = MenuBarRenderModel(snapshot: engine.snapshot,
                                       history: engine.history,
                                       settings: settings.settings,
                                       isStale: engine.isStale)
        for entry in hosted {
            let slice = StatusItemController.slice(model, readout: entry.readout)
            entry.content.update(with: slice)
            entry.item.length = entry.content.intrinsicContentSize.width
            entry.item.button?.setAccessibilityValue(slice.accessibilityDescription)
        }
    }

    /// The whole-bar model narrowed to the one readout an item draws.
    ///
    /// A slice of the finished model rather than a second, per-item build of it: the
    /// item then draws exactly what it would have drawn in the combined bar, including
    /// the joint normalisation a paired metric's graphs depend on, and each item still
    /// redraws only when its own slice changes.
    static func slice(_ model: MenuBarRenderModel, readout: UUID?) -> MenuBarRenderModel {
        guard let readout else { return model }
        var slice = model
        slice.items = model.items.filter { $0.id == readout }
        return slice
    }

    // MARK: Input

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        // Recorded before the action runs, because the action is what reads `anchorRect`
        // and the panel belongs under the item that was clicked.
        activeItem = hosted.first { $0.item.button === sender }?.item
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            onSecondaryAction?()
        } else {
            onPrimaryAction?()
        }
    }
}
