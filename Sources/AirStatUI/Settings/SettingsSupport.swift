import SwiftUI
import AppKit
import AirStatKit

// MARK: - Panes

/// The settings window's panes, in sidebar order and in groups.
///
/// Charts was its own pane of two settings and a wall of prose about four more that no
/// longer exist; it is a section of Appearance now, next to the colours it shares a
/// subject with. Shortcuts went the other way: folded into General, it ended up below
/// Sampling and Units in a scroll nobody reached, which is a poor place for the one
/// setting a user arrives already looking for. Three rows is a thin pane, but a pane
/// is findable and the bottom of another pane's scroll is not.
public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    // Order is the source list's order, and it is grouped: what the app is, then the
    // three things it does, then how it looks and how you reach it, then about. A flat
    // list of six left "Appearance" sitting between "Menu Bar" and "Overlay", which
    // are the two surfaces it applies to.
    case general
    case menuBar, overlay, notifications
    case appearance, shortcuts
    case about

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .general: return "General"
        case .menuBar: return "Menu Bar"
        case .appearance: return "Appearance"
        case .overlay: return "Overlay"
        case .notifications: return "Notifications"
        case .shortcuts: return "Shortcuts"
        case .about: return "About"
        }
    }

    /// Whether a rule is drawn above this row in the source list. The groups are the
    /// hierarchy: without them the panes read as one undifferentiated list, and
    /// nothing says that Menu Bar, Overlay and Notifications are the same kind of
    /// thing while General and About are not.
    var startsGroup: Bool {
        switch self {
        case .menuBar, .appearance, .about: return true
        default: return false
        }
    }

    public var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .menuBar: return "menubar.rectangle"
        case .appearance: return "paintpalette"
        case .overlay: return "macwindow.on.rectangle"
        case .notifications: return "bell.badge"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }

    /// The settings subtrees this pane edits, so a pane can offer its own
    /// restore-defaults without hardcoding the mapping. About edits nothing of its own.
    public var sections: [SettingsStore.SettingsSection] {
        switch self {
        case .general: return [.general]
        case .menuBar: return [.menuBar]
        case .appearance: return [.theme, .charts]
        case .overlay: return [.overlay]
        case .notifications: return [.notifications]
        case .shortcuts: return [.shortcuts]
        case .about: return []
        }
    }

    /// Which pane the offscreen renderer opens on.
    ///
    /// The render harness constructs `SettingsRootView` with no arguments, so the
    /// only way to inspect a pane other than the first is to let the environment
    /// choose it. `AIRSTAT_SETTINGS_TAB=overlay AirStats --render settings` renders
    /// the overlay pane; unset, it behaves exactly as the real window does.
    static var renderDefault: SettingsTab {
        guard let raw = ProcessInfo.processInfo.environment["AIRSTAT_SETTINGS_TAB"],
              let tab = SettingsTab(rawValue: raw) else { return .general }
        return tab
    }
}

// MARK: - Bindings

@MainActor
extension SettingsStore {
    /// A binding that routes every write through `update`, so clamping, the
    /// revision bump and the debounced save can never be bypassed by a control.
    func binding<Value>(_ keyPath: WritableKeyPath<AirStatKit.Settings, Value>) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: keyPath] },
                set: { newValue in self.update { $0[keyPath: keyPath] = newValue } })
    }

    /// As above, with a hook that runs after the store has accepted the change —
    /// for the handful of settings that also need a system-level side effect.
    func binding<Value>(_ keyPath: WritableKeyPath<AirStatKit.Settings, Value>,
                        onChange: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: keyPath] },
                set: { newValue in
                    self.update { $0[keyPath: keyPath] = newValue }
                    onChange(self.settings[keyPath: keyPath])
                })
    }

    /// A slider binding that quantises on write.
    ///
    /// Quantising here rather than through `Slider(step:)` keeps the value tidy
    /// without AppKit drawing a tick for every step — twenty-five ticks under a
    /// spacing slider is noise, not guidance.
    func quantized(_ keyPath: WritableKeyPath<AirStatKit.Settings, Double>,
                   step: Double) -> Binding<Double> {
        Binding(get: { self.settings[keyPath: keyPath] },
                set: { newValue in
                    self.update { $0[keyPath: keyPath] = (newValue / step).rounded() * step }
                })
    }

    /// Membership in a set, expressed as a toggle.
    func membership<Element: Hashable>(_ keyPath: WritableKeyPath<AirStatKit.Settings, Set<Element>>,
                                       _ element: Element) -> Binding<Bool> {
        Binding(get: { self.settings[keyPath: keyPath].contains(element) },
                set: { isOn in
                    self.update {
                        if isOn { $0[keyPath: keyPath].insert(element) }
                        else { $0[keyPath: keyPath].remove(element) }
                    }
                })
    }
}

// MARK: - Materials

/// Applies the grouped-form look this window uses: the window's own fill behind the
/// scroll view, so SwiftUI's section boxes read as raised against it.
///
/// Without this the section fill lands within two levels of the background —
/// measured `#F5F5F5` boxes on an `#F7F7F7` window, a contrast ratio of about
/// 1.03:1 — and the grouping exists only as a hairline border.
extension View {
    func settingsFormStyle() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
    }
}

// MARK: - Availability

/// What this particular Mac can actually report.
///
/// The app's promise is never to show a number it does not have, and that promise
/// has to start here: offering "CPU Temperature" with the same affordance as
/// "CPU Usage" on a machine whose sensors are unreadable buys the user a readout
/// that will be a dash forever, with nothing to explain why.
///
/// Every answer comes from the live snapshot — a source that reported
/// `.unsupported`, or a value present but missing the specific field a readout
/// needs (a desktop with no battery, a fanless Mac, Apple Silicon core frequency).
struct MetricAvailability {
    private let snapshot: SystemSnapshot

    init(snapshot: SystemSnapshot) { self.snapshot = snapshot }

    /// Nil when the readout will work here; otherwise why it will not.
    func note(for metric: MenuBarMetric) -> String? {
        if let sourceNote = note(for: metric.requiredSource) { return sourceNote }
        switch metric {
        case .cpuFrequency:
            // No public API reports Apple Silicon core frequency, so this readout
            // cannot work on any current Mac.
            return "macOS does not report core frequency on Apple Silicon."
        case .cpuTemperature:
            guard let thermal = snapshot.thermal.value else { return nil }
            if thermal.cpuCelsius == nil {
                return thermal.sensorsUnavailableReason ?? "No readable CPU temperature sensor."
            }
        case .fanSpeed:
            if let thermal = snapshot.thermal.value, thermal.fans.isEmpty {
                return "This Mac has no fans."
            }
        case .battery, .batteryTime:
            if let power = snapshot.power.value, power.percentage == nil {
                return "This Mac has no battery."
            }
        case .systemPower:
            if let power = snapshot.power.value, power.systemWatts == nil {
                return "This Mac does not report system power draw."
            }
        case .gpuUsage:
            if let gpu = snapshot.gpu.value, gpu.primary?.utilization == nil {
                return "No GPU utilisation source on this Mac."
            }
        default:
            return nil
        }
        return nil
    }

    func note(for module: PanelModule) -> String? { note(for: module.requiredSource) }

    func note(for metric: ThresholdMetric) -> String? { note(for: metric.requiredSource) }

    /// Only `.unsupported` counts. A sample that failed this cycle or a permission
    /// the user can still grant are both recoverable, and greying a control the
    /// user could fix would be its own kind of dishonesty.
    private func note(for source: CollectorID) -> String? {
        let state: MetricFailure?
        switch source {
        case .cpu: state = snapshot.cpu.failure
        case .memory: state = snapshot.memory.failure
        case .gpu: state = snapshot.gpu.failure
        case .network: state = snapshot.network.failure
        case .disk: state = snapshot.disk.failure
        case .power: state = snapshot.power.failure
        case .thermal: state = snapshot.thermal.failure
        case .processes: state = snapshot.processes.failure
        case .system: state = snapshot.system.failure
        }
        guard let state, state.isPermanent else { return nil }
        return state.message
    }
}

/// The snapshot the settings window reasons about: live when the app is running,
/// and a named fixture set when it is not.
///
/// The fixture is selectable so the offscreen renderer can reach the states that
/// matter here — `degraded` (a Mac missing sensors) and `pending` (nothing sampled
/// yet) — which it otherwise never sees, leaving every scenario render identical.
@MainActor
enum SettingsPreview {
    static var fixtureScenario: OffscreenRenderer.Scenario {
        guard let raw = ProcessInfo.processInfo.environment["AIRSTAT_PREVIEW_SCENARIO"],
              let scenario = OffscreenRenderer.Scenario(rawValue: raw) else { return .nominal }
        return scenario
    }

    static func snapshot(_ engine: MetricsEngine?) -> SystemSnapshot {
        engine?.snapshot ?? fixtureScenario.snapshot
    }

    static func history(_ engine: MetricsEngine?) -> MetricHistory {
        engine?.history ?? fixtureScenario.history
    }
}

/// A row's trailing "not available here" marker, with the reason on hover and in
/// the accessibility value rather than as a wall of text next to every control.
struct UnavailableBadge: View {
    let reason: String

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: "minus.circle")
            Text("Unavailable")
        }
        .font(.callout)
        .foregroundStyle(Design.Palette.tertiaryText)
        .help(reason)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Not available on this Mac")
        .accessibilityValue(reason)
    }
}

// MARK: - Shared controls

/// Restores what one pane edits to its shipped defaults, behind a confirmation
/// because it is the only irreversible control in the window.
///
/// Takes a list rather than a single section: a pane can now edit more than one
/// subtree, and a button that quietly restored half of what the user was looking at
/// would be worse than no button.
struct RestoreDefaultsButton: View {
    let settings: SettingsStore
    let sections: [SettingsStore.SettingsSection]
    let title: String

    @State private var isConfirming = false

    var body: some View {
        Button("Restore Defaults") { isConfirming = true }
            .confirmationDialog("Restore \(title) settings to their defaults?",
                                isPresented: $isConfirming) {
                Button("Restore Defaults", role: .destructive) {
                    for section in sections { settings.resetSection(section) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only \(title) is affected. Other settings are left alone.")
            }
            .accessibilityHint("Restores \(title) to its default values")
    }
}

/// The shared colour panel, closed rather than left standing.
///
/// `ColorPicker` opens the one process-wide `NSColorPanel` and never takes
/// responsibility for closing it, so the wheel outlives the row that opened it: switch
/// panes, or close the whole window, and it is still floating there editing a swatch
/// nobody can see. Nothing in AppKit does this for us.
enum ColorPanel {
    static func close() {
        guard NSColorPanel.sharedColorPanelExists else { return }
        NSColorPanel.shared.orderOut(nil)
    }
}

/// Explanatory text under a control, styled as a macOS settings footnote.
struct SettingsFootnote: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(Design.Palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            // A Form row aligns its trailing content, and a footer inherits that:
            // without both of these the prose sets ragged-left and reads as a value
            // rather than an aside.
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An inline caution — a login-item failure, a shortcut conflict, a setting the
/// model refused to apply. Never used for anything the user can simply undo.
struct SettingsCaution: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning. \(text)")
    }
}

// MARK: - Row lists

/// A bordered box of rows, standing in for `List`.
///
/// `List` is an `NSTableView`, and an `NSTableView` draws nothing when a windowless
/// process asks a view tree to cache its display — which would leave every
/// reorderable list in this window blank in the only review tool the project has.
/// A stack of rows draws the same thing, renders offscreen, and keeps drag
/// reordering through `draggable`/`dropDestination`.
struct SettingsListBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .strokeBorder(Design.Palette.separator)
            }
    }
}

/// One row of a `SettingsListBox`, with its separator, selection fill and the
/// insertion line shown while something is dragged over it.
struct SettingsListRow<Content: View>: View {
    var isFirst: Bool = false
    var isDropTarget: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if isDropTarget {
                Rectangle()
                    .fill(Design.Palette.accent)
                    .frame(height: 2)
            } else if !isFirst {
                Divider()
            }
            content
                .padding(.horizontal, Design.Space.m)
                .padding(.vertical, Design.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
    }
}

/// A module's glyph and name, with the glyph in a fixed box.
///
/// SF Symbols differ in width, and `Label` leaves that difference in the layout —
/// a column of module names that starts at nine different x positions reads as
/// sloppy long before anyone works out why.
struct ModuleLabel: View {
    let module: PanelModule

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Image(systemName: module.symbolName)
                .frame(width: 18, alignment: .center)
                .foregroundStyle(Design.Palette.metric(module.requiredSource))
            Text(module.label)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(module.label)
    }
}

/// Move-up / move-down buttons for a reorderable list.
///
/// Drag reordering is the fast path but it is not reachable from the keyboard and
/// invisible to VoiceOver, so every reorderable list also carries these.
struct ReorderControls: View {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let itemLabel: String
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: Design.Space.xxs) {
            RowIconButton(systemName: "chevron.up",
                          help: "Move \(itemLabel) up",
                          label: "Move \(itemLabel) up") { move(-1) }
                .disabled(!canMoveUp)
            RowIconButton(systemName: "chevron.down",
                          help: "Move \(itemLabel) down",
                          label: "Move \(itemLabel) down") { move(1) }
                .disabled(!canMoveDown)
        }
    }
}

/// A pull-down in a list row.
///
/// The highlight is drawn around the value the menu changes, not around its chevron.
/// AppKit's own menu button rings the indicator, which in a row that also carries
/// reorder and delete buttons made the one control that opens a menu look like the
/// two that do something immediately.
///
/// The width is fixed by the caller rather than by the title, so a column of these
/// puts every chevron at the same x. Sized to the longest label they can hold, since
/// a box that resized as the value changed would move the control out from under the
/// pointer that just used it.
struct RowMenu<Content: View>: View {
    let title: String
    let width: CGFloat
    let label: String
    @ViewBuilder var content: Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Menu { content } label: {
            HStack(spacing: Design.Space.xs) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Design.Space.xs)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isEnabled ? Design.Palette.tertiaryText
                                               : Design.Palette.quaternaryText)
            }
            .padding(.horizontal, Design.Space.xs)
            .padding(.vertical, 3)
            .frame(width: width, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .fill(isHovering && isEnabled
                          ? Design.Palette.primaryText.opacity(0.08)
                          : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: Design.Radius.control,
                                           style: .continuous))
        }
        // `.button` with a plain button style is the one combination that draws the
        // label exactly as written. `.borderlessButton` substitutes AppKit's own
        // pop-up chrome, which puts its indicator on the leading edge and ignores the
        // width, and `.fixedSize()` on top of that collapses the frame to the title.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering in
            withAnimation(Design.Motion.hover) { isHovering = hovering }
        }
        .accessibilityLabel(label)
    }
}

/// A glyph button in a list row, sized for the pointer rather than for the glyph.
///
/// A bare `Image` in a borderless `Button` is only as clickable as the strokes it
/// draws — a chevron at caption size is about 10pt across, well under the 24pt the
/// HIG asks for, and it gave no sign it was a button until it had already been hit.
/// The frame is the hit target, the fill is the sign, and neither is visible until
/// the pointer is over the row.
struct RowIconButton: View {
    let systemName: String
    let help: String
    let label: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private static let side: CGFloat = 22

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: Self.side, height: Self.side)
                .background {
                    RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                        .fill(isHovering && isEnabled
                              ? Design.Palette.primaryText.opacity(0.10)
                              : Color.clear)
                }
                // The frame alone is not a hit target: a Button's shape is its label's
                // drawn content, and an empty background draws nothing.
                .contentShape(RoundedRectangle(cornerRadius: Design.Radius.control,
                                               style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled
                         ? (isHovering ? Design.Palette.primaryText : Design.Palette.secondaryText)
                         : Design.Palette.quaternaryText)
        .onHover { hovering in
            withAnimation(Design.Motion.hover) { isHovering = hovering }
        }
        .help(help)
        .accessibilityLabel(label)
    }
}

// MARK: - Value formatting

/// Labels for the fixed option lists the settings model exposes. Kept here so the
/// same duration reads identically in every pane.
enum SettingsLabels {

    static func interval(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int(seconds * 1000)) ms" }
        if seconds == 1 { return "1 second" }
        return "\(Int(seconds)) seconds"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "Immediately" }
        if seconds < 60 { return "\(Int(seconds)) seconds" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = Int(seconds / 3600)
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    static func points(_ value: Double) -> String { "\(Int(value.rounded())) pt" }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
}

// MARK: - Live menu bar preview

/// The real status item view, hosted in the settings window.
///
/// Wrapping `MenuBarContentView` rather than reimplementing it is the whole point:
/// the preview is the same drawing code, the same measurement, and the same model
/// the menu bar itself uses, so it cannot drift away from what the user will see.
struct MenuBarPreview: NSViewRepresentable {
    let model: MenuBarRenderModel

    func makeNSView(context: Context) -> MenuBarContentView {
        let view = MenuBarContentView(frame: .zero)
        view.update(with: model)
        return view
    }

    func updateNSView(_ view: MenuBarContentView, context: Context) {
        view.update(with: model)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuBarContentView,
                      context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// Measures the readouts with the same view that draws them, so the strip can size a
/// slot for them and tell when the bar runs past its edge. A throwaway view rather
/// than a reimplementation of the layout, for the reason `MenuBarPreview` exists:
/// a second measurement would drift from the first.
@MainActor
private enum MenuBarPreviewMetrics {
    private static let prototype = MenuBarContentView(frame: .zero)

    static func size(of model: MenuBarRenderModel) -> CGSize {
        prototype.update(with: model)
        return prototype.intrinsicContentSize
    }
}

/// Presents the preview on a surface that reads as a menu bar, because contrast in
/// the menu bar is the thing being judged and a preview on a form background would
/// misrepresent it.
///
/// The strip is a viewport onto a bar wider than itself. A settings window 760 points
/// across cannot show a screen's worth of menu bar — all sixteen readouts measure more
/// than twice the room this row has — so they get a slot bounded by what is left
/// beside the clock and scroll inside it. Letting them take their natural width is
/// what pushed the sidebar and the pane out of the window frame; dropping the overflow
/// instead of scrolling it would be a lie, since those readouts do fit in a real bar.
struct MenuBarPreviewStrip: View {
    let model: MenuBarRenderModel
    let isEmpty: Bool

    /// Width the readouts were actually given. Held against their natural width it is
    /// the only thing that says whether the bar continues past the slot. Unbounded
    /// until the first measurement lands, because starting at zero means every open
    /// of the pane flashes the marker for a frame.
    @State private var slotWidth: CGFloat = .infinity

    private var naturalSize: CGSize { MenuBarPreviewMetrics.size(of: model) }

    private var isTruncated: Bool { naturalSize.width - slotWidth > 0.5 }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: Design.Space.xl)
            if isEmpty {
                Text("No readouts are enabled.")
                    .font(.callout)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
            } else {
                readouts
                if isTruncated {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Design.Palette.tertiaryText)
                        .padding(.leading, Design.Space.s)
                        .accessibilityHidden(true)
                }
            }
            Image(systemName: "wifi").foregroundStyle(Design.Palette.tertiaryText)
                .padding(.leading, Design.Space.l)
            Image(systemName: "battery.75").foregroundStyle(Design.Palette.tertiaryText)
                .padding(.leading, Design.Space.m)
            Text(Date(), format: .dateTime.weekday(.abbreviated).hour().minute())
                .foregroundStyle(Design.Palette.tertiaryText)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, Design.Space.l)
            Spacer(minLength: Design.Space.xl)
        }
        .font(.system(size: Design.MenuBar.valueFontSize))
        .padding(.vertical, Design.Space.m)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Design.Radius.card,
                                                                  style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Menu bar preview")
        .accessibilityValue(accessibilityValue)
    }

    /// The slot is capped at the readouts' natural width so a short bar still sits
    /// centred, and floors at nothing so the window's width always wins.
    private var readouts: some View {
        ScrollView(.horizontal) {
            MenuBarPreview(model: model)
        }
        .frame(maxWidth: naturalSize.width)
        .frame(height: naturalSize.height)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width, initial: true) { _, width in
                        slotWidth = width
                    }
            }
        }
    }

    private var accessibilityValue: String {
        if isEmpty { return "No readouts enabled" }
        guard isTruncated else { return model.accessibilityDescription }
        return model.accessibilityDescription + ". Scroll the preview to see the rest"
    }
}
