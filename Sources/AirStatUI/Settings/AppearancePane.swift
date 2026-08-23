import SwiftUI
import AppKit
import AirStatKit

/// How AirStat looks: light or dark, what colour each metric is, and how its charts
/// are drawn.
///
/// One pane, because these are one decision. The colours were their own pane and the
/// charts another, and a user who wanted CPU to be orange had no reason to expect the
/// two to be filed apart.
struct AppearancePane: View {
    let settings: SettingsStore

    private var theme: ThemeSettings { settings.settings.theme }

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: settings.binding(\.general.appearance,
                                                            onChange: applyAppearance)) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                // Setting nine metrics to the same colour one row at a time is nine
                // trips through the colour wheel to express one decision — "I want
                // this app in my colour" — so that decision gets its own control.
                //
                // It belongs here rather than at the top of the list below it. This is
                // the same kind of choice as light-or-dark: one setting that decides
                // how the whole app looks. Filed among the nine per-metric rows it
                // read as a tenth metric called "All Metrics", and its reach over the
                // rows beneath it was something you had to discover by using it.
                ColorRow(label: "All Metrics",
                         symbol: "circle.hexagongrid.fill",
                         current: theme.uniformColor.map(Color.init(themeColor:))
                             ?? Design.Palette.primaryText,
                         // A row that stands for nine colours has no one colour to
                         // show until they agree, and drawing `labelColor` there
                         // claimed the app was set to black.
                         showsSpectrum: theme.uniformColor == nil,
                         // Any override at all, so this row can clear a set of nine
                         // different colours and not only nine matching ones.
                         isOverridden: !theme.metrics.isEmpty,
                         status: allMetricsStatus,
                         defaultTitle: "Use Defaults",
                         set: { color in
                             settings.update { $0.theme.setAllColors(color) }
                         })
            } footer: {
                SettingsFootnote("All Metrics sets every colour below at once. "
                                 + "Each metric can still be changed on its own.")
            }

            // A board rather than nine rows. One colour per metric is a palette, and a
            // palette is something you look at all at once — as a column it was a
            // 390pt scroll of near-identical rows that pushed the chart settings off
            // the pane entirely. Three across, every colour in the app is on screen
            // together, which is also the only way to see whether they still work as
            // a set after you have changed one.
            Section {
                // Equal columns rather than columns sized to their contents: three
                // widths set by whichever metric has the longest name is three
                // different distances between a name and its swatch, and the swatch
                // then reads as belonging to the label on its right.
                LazyVGrid(columns: Self.columns, alignment: .leading,
                          spacing: Design.Space.xs) {
                    ForEach(CollectorID.allCases, id: \.self) { id in colorChip(id) }
                }
            } header: {
                Text("Metric Colours")
            }

            Section {
                Picker("Chart style", selection: settings.binding(\.charts.style)) {
                    ForEach(ChartStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                Picker("Keep history for", selection: settings.binding(\.charts.historyDuration)) {
                    ForEach(ChartSettings.allowedDurations, id: \.self) { duration in
                        Text(SettingsLabels.duration(duration)).tag(duration)
                    }
                }
            } header: {
                Text("Charts")
            }

        }
        .settingsFormStyle()
    }

    private static let columns = Array(repeating: GridItem(.flexible(),
                                                          spacing: Design.Space.xl,
                                                          alignment: .leading),
                                       count: 3)

    private func colorChip(_ id: CollectorID) -> some View {
        HStack(spacing: Design.Space.s) {
            Image(systemName: id.symbolName)
                .frame(width: 18, alignment: .center)
                .foregroundStyle(Design.Palette.metric(id))
            Text(id.label)
                .lineLimit(1)
            Spacer(minLength: Design.Space.s)
            SwatchButton(current: Design.Palette.metric(id),
                         isOverridden: theme.color(for: id) != nil,
                         defaultTitle: "Use Default",
                         label: "\(id.label) colour",
                         value: theme.color(for: id) != nil ? "Custom" : "Default",
                         set: { color in
                             settings.update { $0.theme.setColor(color, for: id) }
                         })
        }
    }

    /// What the all-metrics row reports, when it has anything to report. "Custom" is
    /// not the only answer here: nine rows can disagree, and calling that "Custom"
    /// would claim the swatch beside it is the colour they are all on.
    private var allMetricsStatus: String? {
        theme.uniformColor == nil && !theme.metrics.isEmpty ? "Mixed" : nil
    }

    /// The theme is process state rather than a stored value, so the store alone would
    /// change nothing until the next launch.
    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// A full-width colour row: a label, what the colour is now, and a swatch that opens
/// the palette.
///
/// Every colour here is "the shipped one, unless you have picked one", and the
/// distinction is real: the shipped colours are Apple's semantic system colours and
/// re-resolve per appearance, so a colour left alone behaves differently in dark mode
/// from one the user has fixed to a triple. So it is worth a word beside the label
/// when it applies — and worth nothing at all when it does not, which is the usual
/// case. Every row captioned "Default" said nothing, repeatedly, and left no way to
/// spot the one that had been changed.
private struct ColorRow: View {
    let label: String
    let symbol: String
    let current: Color
    var showsSpectrum: Bool = false
    let isOverridden: Bool
    /// Overrides the "Custom" reading, for a row that stands for more than one stored
    /// colour and can therefore be neither.
    var status: String?
    /// "Use Default" for one metric, "Use Defaults" for the row that sets them all.
    var defaultTitle: String = "Use Default"
    let set: (ThemeColor?) -> Void

    var body: some View {
        LabeledContent {
            SwatchButton(current: current,
                         showsSpectrum: showsSpectrum,
                         isOverridden: isOverridden,
                         defaultTitle: defaultTitle,
                         label: "\(label) colour",
                         value: statusText ?? "Default",
                         set: set)
        } label: {
            HStack(spacing: Design.Space.s) {
                Image(systemName: symbol)
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(showsSpectrum ? Design.Palette.secondaryText : current)
                Text(label)
                if let statusText {
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(Design.Palette.tertiaryText)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
        }
    }

    private var statusText: String? { status ?? (isOverridden ? "Custom" : nil) }
}

/// The colour control itself: a swatch of what is drawn now, and a palette on click.
///
/// This replaces `ColorPicker`, whose macOS well is a 90pt pill. Nine of those down
/// the trailing edge of a form were the loudest thing in the window by some distance,
/// and every one of them opened the full colour wheel — a wheel, sliders, an
/// eyedropper and a spectrum for a decision that is nearly always "the blue one".
/// The presets answer that in one click, and the wheel is still one click further for
/// the user who actually wants a specific triple.
private struct SwatchButton: View {
    let current: Color
    var showsSpectrum: Bool = false
    let isOverridden: Bool
    let defaultTitle: String
    let label: String
    let value: String
    let set: (ThemeColor?) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isPresented = false
    @State private var isHovering = false

    private static let side: CGFloat = 20
    private static let radius: CGFloat = 5

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: Design.Space.xs) {
                swatch
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isEnabled ? Design.Palette.tertiaryText
                                               : Design.Palette.quaternaryText)
            }
            .padding(.horizontal, Design.Space.xs)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .fill(isHovering && isEnabled
                          ? Design.Palette.primaryText.opacity(0.08)
                          : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: Design.Radius.control,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Design.Motion.hover) { isHovering = hovering }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ColorPalette(current: current,
                         isOverridden: isOverridden,
                         defaultTitle: defaultTitle,
                         isPresented: $isPresented,
                         set: set)
        }
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    /// The colour as it will be drawn, over a chequerboard-free flat tile. Bordered,
    /// because a white swatch on a light form and a black one on a dark form are both
    /// otherwise a hole in the row.
    private var swatch: some View {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(fill)
            .frame(width: Self.side, height: Self.side)
            .overlay {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .strokeBorder(Design.Palette.primaryText.opacity(0.15))
            }
            .opacity(isEnabled ? 1 : 0.5)
    }

    private var fill: AnyShapeStyle {
        guard showsSpectrum else { return AnyShapeStyle(current) }
        return AnyShapeStyle(AngularGradient(colors: ColorPalette.spectrum,
                                             center: .center))
    }
}

/// The palette behind a swatch: the twelve system colours, a picker for everything
/// else, and the way back to the default.
///
/// Presets first because they answer the question nearly every time. They are the
/// colours the rest of the app is already drawn in, so picking one keeps an override
/// in the same family as everything left alone, which a hand-mixed triple rarely
/// does. The picker below them is one drag away rather than one window away.
private struct ColorPalette: View {
    let current: Color
    let isOverridden: Bool
    let defaultTitle: String
    @Binding var isPresented: Bool
    let set: (ThemeColor?) -> Void

    /// The picker's own state, seeded from the colour on screen.
    ///
    /// Local rather than read back out of the store on every frame, because hue and
    /// saturation do not survive the trip: an override is stored as a triple, and a
    /// triple has nothing to say about which hue a black or a grey came from.
    @State private var hsb = HSB(hue: 0, saturation: 0, brightness: 0)

    /// Apple's system palette, in spectrum order so the grid reads as a spectrum
    /// rather than as a list. Also the fill for a swatch standing in for nine
    /// disagreeing colours.
    static let presets: [(name: String, color: Color)] = [
        ("Red", Color(nsColor: .systemRed)),
        ("Orange", Color(nsColor: .systemOrange)),
        ("Yellow", Color(nsColor: .systemYellow)),
        ("Green", Color(nsColor: .systemGreen)),
        ("Mint", Color(nsColor: .systemMint)),
        ("Teal", Color(nsColor: .systemTeal)),
        ("Cyan", Color(nsColor: .systemCyan)),
        ("Blue", Color(nsColor: .systemBlue)),
        ("Indigo", Color(nsColor: .systemIndigo)),
        ("Purple", Color(nsColor: .systemPurple)),
        ("Pink", Color(nsColor: .systemPink)),
        ("Grey", Color(nsColor: .systemGray)),
    ]

    static var spectrum: [Color] { presets.map(\.color) + [presets[0].color] }

    private static let columns = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            ForEach(0..<(Self.presets.count / Self.columns), id: \.self) { row in
                HStack(spacing: Design.Space.m) {
                    ForEach(0..<Self.columns, id: \.self) { column in
                        preset(Self.presets[row * Self.columns + column])
                    }
                }
            }

            Divider()

            ColorEditor(hsb: $hsb) {
                // Sampling covers the screen, so the popover is put away first rather
                // than left to vanish underneath it.
                isPresented = false
            }

            if isOverridden {
                Divider()
                Button {
                    set(nil)
                    isPresented = false
                } label: {
                    Label(defaultTitle, systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.link)
            }
        }
        .font(.callout)
        .padding(Design.Space.l)
        .frame(width: Self.width)
        .onAppear { hsb = HSB(current.themeColor ?? ThemeColor(red: 0, green: 0, blue: 0)) }
        .onChange(of: hsb) { _, new in
            // The user's own drag, arriving back here as a store write. Guarded so a
            // colour that has not actually moved is not written down as an override:
            // opening a popover is not choosing anything.
            guard let stored = current.themeColor, !new.matches(stored) else { return }
            set(new.themeColor)
        }
        .onChange(of: current) { _, new in
            // A change from outside the picker — a preset, an All Metrics sweep, a
            // restore. Ignored when it is the one we just made, which would otherwise
            // round-trip through sRGB and drag the knob a hair on every frame.
            guard let stored = new.themeColor, !hsb.matches(stored) else { return }
            hsb = HSB(stored)
        }
    }

    /// Sized to the preset grid: six 20pt dots with their hit padding, which is also
    /// a comfortable width for the square below them.
    private static let width: CGFloat = 220

    private func preset(_ entry: (name: String, color: Color)) -> some View {
        Button {
            // A colour that will not resolve into sRGB cannot be stored, and storing a
            // wrong one is worse than declining the edit.
            guard let stored = entry.color.themeColor else { return }
            set(stored)
            isPresented = false
        } label: {
            Circle()
                .fill(entry.color)
                .frame(width: 20, height: 20)
                .overlay {
                    Circle().strokeBorder(Design.Palette.primaryText.opacity(0.15))
                }
                .padding(3)
                .overlay {
                    // The ring sits outside the dot rather than on it, so the colour
                    // the user is looking at is not the one with a line drawn through
                    // its edge.
                    Circle()
                        .strokeBorder(isSelected(entry.color)
                                      ? Design.Palette.accent : Color.clear,
                                      lineWidth: 2)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(entry.name)
        .accessibilityLabel(entry.name)
        .accessibilityAddTraits(isSelected(entry.color) ? [.isSelected] : [])
    }

    /// Compared as stored triples, because that is what a pick writes: both sides
    /// resolve in the appearance on screen, which is the one the user is choosing in.
    private func isSelected(_ color: Color) -> Bool {
        guard let a = color.themeColor, let b = current.themeColor else { return false }
        return a == b
    }
}
