import SwiftUI
import AppKit
import AirStatKit

/// Root of the click-down panel.
///
/// A stack of modules in the user's order, each carrying its own headline value, over
/// a footer. The panel sizes to its content and has no chrome of its own; it scrolls
/// only in the one case where it would otherwise run off the screen.
public struct PanelRootView: View {

    private let engine: MetricsEngine
    private let settings: SettingsStore
    /// Absent in the offscreen renderer, which has no Sparkle to ask.
    private let updates: SoftwareUpdater?

    public init(engine: MetricsEngine, settings: SettingsStore, updates: SoftwareUpdater? = nil) {
        self.engine = engine
        self.settings = settings
        self.updates = updates
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pending = updates?.pending {
                PanelUpdateRow(update: pending) { [updates] in
                    // Sparkle's window is a window, and the panel closes when it loses
                    // key, so it would take the update with it on the way out.
                    actions.dismiss()
                    updates?.installPending()
                }
                PanelSeparator()
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(modules.enumerated()), id: \.element) { index, module in
                        if index > 0 { PanelSeparator(isVisible: separatorNeeded(before: index)) }
                        PanelModuleView(module: module, engine: engine, settings: settings)
                    }
                }
                .padding(.vertical, Design.Space.xs)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.top)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: Self.maximumModuleHeight)
            PanelSeparator()
            PanelFooterView()
        }
        .frame(width: PanelSettings.width)
        .environment(\.metricFormatter, MetricFormatter(settings: settings.settings.general))
    }

    @Environment(\.panelActions) private var actions

    private var modules: [PanelModule] { settings.settings.panel.visibleModules }

    /// A rule earns its place only where it delimits a block of detail.
    ///
    /// Drawing one between every module turned the panel into a ruled table — nine
    /// full-width lines competing with the content they were meant to organise. Between
    /// two collapsed summary rows there is nothing to divide: the rows already read as a
    /// list. So a separator appears only where an expanded module begins or ends, which
    /// is exactly where the eye needs to know a block started.
    private func separatorNeeded(before index: Int) -> Bool {
        let collapsed = settings.settings.panel.collapsedModules
        let previous = modules[index - 1]
        let current = modules[index]
        return !collapsed.contains(previous) || !collapsed.contains(current)
    }

    /// A ceiling the module list refuses to grow past.
    ///
    /// The footer sits outside the scroll region, so Settings and Quit stay on screen
    /// no matter how many modules are enabled or how long the process list gets — the
    /// positioning code has no answer for a window taller than `visibleFrame` beyond
    /// pinning it and letting the bottom fall away. Below the ceiling `fixedSize` still
    /// sizes the window to its content, so nothing scrolls in the ordinary case.
    private static var maximumModuleHeight: CGFloat {
        guard let visible = NSScreen.main?.visibleFrame.height else { return .infinity }
        return max(visible - Design.Space.xxl * 3, 240)
    }
}

/// Inset rule between modules. macOS insets its separators to the content margin so
/// they read as dividing the text, not as slicing the window in half.
///
/// A rule that is not wanted turns clear rather than disappearing. It reads identically
/// — a transparent hairline is nothing — but it costs the layout the same one point
/// whatever the modules around it are doing. Inserting and removing the view instead
/// meant a single toggle restructured the stack twice, because `separatorNeeded` looks
/// at both of a rule's neighbours: expanding a module flipped the rule above it and the
/// rule below it. Only the first module escaped, its leading rule being suppressed by
/// the `index > 0` test, which is exactly why every module except CPU jumped harder.
struct PanelSeparator: View {
    var isVisible = true

    var body: some View {
        Rectangle()
            .fill(isVisible ? Design.Palette.separator : .clear)
            .frame(height: Design.Space.hairline)
            .padding(.horizontal, Design.Space.panelInset)
            .accessibilityHidden(true)
    }
}

/// The whole of what a scheduled update does to the app until the user asks for more.
///
/// It sits above the modules rather than in the footer because it is news and the footer
/// is furniture, and it is one row rather than a banner because an update is not more
/// important than the readings the user opened the panel to see.
struct PanelUpdateRow: View {
    let update: PendingUpdate
    let install: @MainActor () -> Void

    /// A staged update wants a relaunch and nothing else, so the row says so instead
    /// of promising an install it has already done.
    private var headline: String {
        update.isReadyToInstall ? "AirStats \(update.version) is ready" : "AirStats \(update.version) is available"
    }

    private var action: String { update.isReadyToInstall ? "Restart" : "Install" }

    @State private var isHovering = false

    var body: some View {
        Button(action: install) {
            HStack(spacing: Design.Space.s) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.accent)
                Text(headline)
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.primaryText)
                Spacer(minLength: Design.Space.m)
                Text(action)
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.accent)
            }
            .padding(.horizontal, Design.Space.panelInset)
            .padding(.vertical, Design.Space.m)
            .background(isHovering ? Design.Palette.track : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Design.Motion.respectingAccessibility(Design.Motion.hover)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(headline)
        .accessibilityHint(update.isReadyToInstall ? "Relaunches AirStats into the new version"
                                                   : "Opens the updater to install it")
    }
}

struct PanelFooterView: View {
    @Environment(\.panelActions) private var actions

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            PanelFooterButton(title: "Settings…", symbol: "gearshape", action: actions.openSettings)
                .keyboardShortcut(",", modifiers: .command)
            Spacer(minLength: Design.Space.m)
            PanelFooterButton(title: "Quit", symbol: "power", action: actions.quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, Design.Space.s)
        .padding(.vertical, Design.Space.xs)
    }
}

/// A footer control styled like a macOS menu item rather than a hyperlink: the whole
/// row highlights on hover, and the hit target is the highlight.
struct PanelFooterButton: View {
    let title: String
    let symbol: String
    let action: @MainActor () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.s) {
                Image(systemName: symbol)
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.secondaryText)
                Text(title)
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.primaryText)
            }
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .fill(isHovering ? Design.Palette.track : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Design.Motion.respectingAccessibility(Design.Motion.hover)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(title)
    }
}
