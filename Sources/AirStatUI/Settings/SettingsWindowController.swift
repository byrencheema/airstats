import AppKit
import SwiftUI
import AirStatKit

/// Standard document-less preferences window.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let engine: MetricsEngine
    private let settings: SettingsStore
    private let updater: SoftwareUpdater?
    /// Shared with the threshold monitor, so the notifications pane reports the same
    /// grant the alerts actually depend on rather than a second opinion.
    private let authority: NotificationAuthority?
    private var window: NSWindow?

    public init(engine: MetricsEngine, settings: SettingsStore,
                updater: SoftwareUpdater? = nil,
                authority: NotificationAuthority? = nil) {
        self.engine = engine
        self.settings = settings
        self.updater = updater
        self.authority = authority
        super.init()
    }

    public func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        // Two preferences are process state rather than stored values, so they take
        // effect only when something applies them. Doing it here means opening
        // settings always reconciles the app with what the user asked for, whatever
        // happened at launch.
        applyProcessPreferences()
        // A menu bar app is an accessory; it must activate explicitly or the
        // settings window opens behind whatever the user was doing.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    /// Panes of forms, chart galleries and colour wells cost 12.6 MB of dirty,
    /// non-reclaimable heap (`footprint`, MALLOC_SMALL, this machine) once they have
    /// been built. Settings is opened rarely and closed for the rest of the session, so
    /// keeping that resident until quit is the worst of both worlds — the window is
    /// discarded on close and rebuilt on the next `show`.
    public func windowWillClose(_ notification: Notification) {
        // The colour panel is not ours and does not go with the window; left alone it
        // stays on screen editing a swatch that no longer exists.
        ColorPanel.close()
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow()
        let root = SettingsRootView(settings: settings, engine: engine,
                                    updater: updater,
                                    authority: authority) { [weak window] tab in
            window?.title = tab.label
        }
        window.delegate = self
        window.title = "AirStats Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false

        // The same glass the click-down panel is made of, so the two surfaces read as
        // one app rather than as a floating panel and a stock preferences window.
        //
        // A translucent window has to be non-opaque with no fill of its own, or the
        // window's own background sits in front of the material and the translucency
        // stops at the content edge. That is also what squares the corners off: the
        // frame view only rounds and masks the content while the window draws itself
        // normally. So the rounding comes back here, from the backdrop's own layer —
        // which is exactly how `PanelWindow` gets its corners.
        window.titlebarAppearsTransparent = true
        // The pane's name is in the source list next to it, selected. Repeating it in
        // a titlebar the panel does not have is the one thing that would still say
        // "settings window".
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear

        let backdrop = GlassBackdropView(material: .hudWindow,
                                         cornerRadius: Design.Radius.panel,
                                         state: .active)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        window.contentView = backdrop

        window.setContentSize(SettingsRootView.windowSize)
        window.setFrameAutosaveName("AirStatsSettingsWindow")
        return window
    }

    private func applyProcessPreferences() {
        switch settings.settings.general.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.setActivationPolicy(settings.settings.general.showsDockIcon ? .regular : .accessory)
    }
}

/// The settings window's content: a source list of panes beside the selected one,
/// which is the shape macOS System Settings uses.
struct SettingsRootView: View {
    let settings: SettingsStore
    let engine: MetricsEngine?
    /// Nil in the offscreen renderer, which has no app lifecycle to hang an updater on.
    let updater: SoftwareUpdater?
    /// Nil for the same reason: `UNUserNotificationCenter` traps outside an app bundle.
    let authority: NotificationAuthority?
    /// Lets the window title follow the selected pane, which is what System
    /// Settings does and what `navigationTitle` used to give us for free.
    var onPaneChange: ((SettingsTab) -> Void)?

    @State private var tab: SettingsTab

    /// Fixed rather than resizable, so the offscreen renderer measures the same
    /// window the user gets. Each pane scrolls its own form.
    ///
    /// Taller than the 560 it was: the content view now runs under the titlebar, and
    /// the strip the traffic lights sit in is height the panes used to have.
    static let windowSize = NSSize(width: 760, height: 588)

    /// Clearance for the traffic lights, which float over the content now that the
    /// titlebar draws nothing. Content starts below it rather than scrolling under it:
    /// a form row sliding behind three buttons is worse than a band of plain glass.
    private static let titlebarInset: CGFloat = 28

    init(settings: SettingsStore, engine: MetricsEngine? = nil, updater: SoftwareUpdater? = nil,
         authority: NotificationAuthority? = nil,
         initialTab: SettingsTab? = nil, onPaneChange: ((SettingsTab) -> Void)? = nil) {
        self.settings = settings
        self.engine = engine
        self.updater = updater
        self.authority = authority
        self.onPaneChange = onPaneChange
        _tab = State(initialValue: initialTab ?? SettingsTab.renderDefault)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: SettingsRootView.sidebarWidth)
            // Neither column carries a material of its own any more: the window is a
            // single sheet of glass and two materials laid over it would be two
            // different glasses. What separated the columns was the difference between
            // those materials, so a rule takes over the job — the same inset hairline
            // the panel divides its modules with.
            Rectangle()
                .fill(Design.Palette.separator)
                .frame(width: Design.Space.hairline)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                pane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                paneFooter
            }
        }
        .padding(.top, SettingsRootView.titlebarInset)
        .frame(width: windowWidth, height: windowHeight)
        .onAppear { onPaneChange?(tab) }
        .onChange(of: tab) { _, newValue in
            // The colour wheel belongs to the row that opened it. Leaving another
            // pane's swatch being edited from a floating window is how you end up
            // dragging a colour onto something you cannot see.
            ColorPanel.close()
            onPaneChange?(newValue)
        }
    }

    /// Laid out by hand rather than with `NavigationSplitView`, which drew an opaque
    /// black 0.5pt rule between the columns — measured `#000000` at the seam in both
    /// appearances, in the real window as well as the render. The sidebar's own
    /// material is what separates the columns on macOS; there is no rule to draw.
    ///
    /// Buttons rather than a `List`: every row stays keyboard-focusable, and the
    /// source list survives offscreen rendering, which an `NSTableView` does not.
    private var sidebar: some View {
        ScrollView {
            VStack(spacing: Design.Space.xxs) {
                // The window's title bar is transparent and carries no title, so the
                // mark is what says whose settings these are.
                //
                // Set as a masthead rather than as a row. At the rows' own type size,
                // with their glyph column and their inset, it was a row — one that did
                // nothing when clicked, sitting directly above six that do. Smaller
                // caps, the metrics tint, and a rule under it put it in a different
                // register: this labels the list, it is not the top of it.
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    HStack(spacing: Design.Space.xs) {
                        LogoMark(size: 13)
                        Text("AIRSTATS")
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.6)
                    }
                    .foregroundStyle(Design.Palette.tertiaryText)
                    Rectangle()
                        .fill(Design.Palette.separator)
                        .frame(height: Design.Space.hairline)
                }
                .padding(.horizontal, Design.Space.m)
                .padding(.bottom, Design.Space.xs)
                .accessibilityHidden(true)

                ForEach(SettingsTab.allCases) { item in
                    if item.startsGroup {
                        Rectangle()
                            .fill(Design.Palette.separator)
                            .frame(height: Design.Space.hairline)
                            .padding(.horizontal, Design.Space.m)
                            .padding(.vertical, Design.Space.xs)
                            .accessibilityHidden(true)
                    }
                    Button {
                        tab = item
                    } label: {
                        HStack(spacing: Design.Space.s) {
                            Image(systemName: item.symbolName)
                                // SF Symbols differ in width, and a Label leaves that
                                // difference in the layout: the eight titles started
                                // at x positions spanning 6pt. A fixed box centres
                                // them, and the explicit size keeps the widest glyph
                                // (keyboard, menubar.rectangle) from spilling out of
                                // it and dragging its title along.
                                .font(.system(size: 13))
                                .frame(width: 22, alignment: .center)
                            Text(item.label)
                        }
                            // The source-list selection pair, not the accent colour:
                            // these two track each other through graphite, increased
                            // contrast and an inactive window, which accent plus a
                            // hardcoded white does not.
                            .foregroundStyle(item == tab
                                             ? Color(nsColor: .alternateSelectedControlTextColor)
                                             : Design.Palette.primaryText)
                            .padding(.horizontal, Design.Space.m)
                            .padding(.vertical, Design.Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                                    .fill(item == tab
                                          ? Color(nsColor: .selectedContentBackgroundColor)
                                          : Color.clear)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: Design.Radius.control,
                                                           style: .continuous))
                    }
                    .buttonStyle(.plain)
                    // A Button already publishes its label subtree as one element, so
                    // naming it here is all it takes to announce "General, selected,
                    // button" instead of walking into the row's decoration.
                    //
                    // Not `.accessibilityElement(children: .ignore)`, which reads the
                    // same but builds a replacement element in place of the button and
                    // so carries no press action. The rows still announced themselves
                    // as buttons, because a trait is a description and not an action,
                    // and nothing happened when VoiceOver activated them.
                    .accessibilityLabel(item.label)
                    .accessibilityAddTraits(item == tab ? [.isSelected, .isButton] : .isButton)
                    .accessibilityHint("Show \(item.label) settings")
                }
            }
            .padding(Design.Space.m)
        }
        .accessibilityLabel("Settings sections")
    }

    private var windowWidth: CGFloat { SettingsRootView.windowSize.width }
    private var windowHeight: CGFloat { SettingsRootView.windowSize.height }
    private static let sidebarWidth: CGFloat = 184

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case .general: GeneralPane(settings: settings, updater: updater)
        case .menuBar: MenuBarPane(settings: settings, engine: engine)
        case .appearance: AppearancePane(settings: settings)
        case .overlay: OverlayPane(settings: settings, engine: engine)
        case .notifications: NotificationsPane(settings: settings, engine: engine,
                                               authority: authority)
        case .shortcuts: ShortcutsPane(settings: settings)
        case .about: AboutPane(settings: settings, engine: engine, updater: updater)
        }
    }

    /// One bar under every pane, carrying that pane's restore-defaults.
    ///
    /// It was a section at the bottom of each pane's form, which put a destructive
    /// control in a different place on every pane — and always behind a scroll, since
    /// it is by definition the last thing. As a bar it is in one place, reachable
    /// without scrolling, and outside the form, which is the right register for a
    /// control that acts on the form rather than being part of it.
    @ViewBuilder
    private var paneFooter: some View {
        if !tab.sections.isEmpty {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Design.Palette.separator)
                    .frame(height: Design.Space.hairline)
                    .accessibilityHidden(true)
                HStack {
                    Spacer()
                    RestoreDefaultsButton(settings: settings,
                                          sections: tab.sections,
                                          title: tab.label)
                }
                .padding(.horizontal, Design.Space.l)
                .padding(.vertical, Design.Space.s)
            }
        }
    }
}
