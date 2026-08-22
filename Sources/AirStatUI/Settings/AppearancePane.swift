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
                         // Any override at all, so this row can clear a set of nine
                         // different colours and not only nine matching ones.
                         isOverridden: !theme.metrics.isEmpty,
                         status: allMetricsStatus,
                         defaultTitle: "Use Defaults",
                         set: { color in
                             settings.update { $0.theme.setAllColors(color) }
                         })
            }

            Section {
                ForEach(CollectorID.allCases, id: \.self) { id in
                    ColorRow(label: id.label,
                             symbol: id.symbolName,
                             current: Design.Palette.metric(id),
                             isOverridden: theme.color(for: id) != nil,
                             set: { color in
                                 settings.update { $0.theme.setColor(color, for: id) }
                             })
                }
            } header: {
                Text("Metric Colours")
            }

            Section {
                Picker("Keep history for", selection: settings.binding(\.charts.historyDuration)) {
                    ForEach(ChartSettings.allowedDurations, id: \.self) { duration in
                        Text(SettingsLabels.duration(duration)).tag(duration)
                    }
                }
                Picker("Chart style", selection: settings.binding(\.charts.style)) {
                    ForEach(ChartStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
            } header: {
                Text("Charts")
            }

        }
        .settingsFormStyle()
    }

    /// What the all-metrics row reports. "Default" and "Custom" are not the only two
    /// answers here: nine rows can disagree, and calling that "Custom" would claim the
    /// swatch beside it is the colour they are all on.
    private var allMetricsStatus: String {
        if theme.uniformColor != nil { return "Custom" }
        return theme.metrics.isEmpty ? "Default" : "Mixed"
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

/// One editable colour: a swatch that opens the system picker, and — only once the
/// user has actually overridden it — a control to put it back.
///
/// Every row is "the shipped colour, unless you have picked one". The distinction is
/// visible because it is real: the shipped colours are Apple's semantic system colours
/// and re-resolve per appearance, so a row on its default behaves differently in dark
/// mode from one the user has fixed to a triple.
private struct ColorRow: View {
    let label: String
    let symbol: String
    let current: Color
    let isOverridden: Bool
    /// Overrides the "Custom"/"Default" reading, for a row that stands for more than
    /// one stored colour and can therefore be neither.
    var status: String?
    /// "Use Default" for one metric, "Use Defaults" for the row that sets them all.
    var defaultTitle: String = "Use Default"
    let set: (ThemeColor?) -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: Design.Space.m) {
                // Revert appears only when there is something to revert to, so a row
                // on its default does not carry a permanently disabled control.
                if isOverridden {
                    Button(defaultTitle) {
                        // Closing first: the wheel is still bound to this swatch, and
                        // leaving it open on a colour that just reverted invites the
                        // user to drag it straight back.
                        ColorPanel.close()
                        set(nil)
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .accessibilityHint("Returns \(label) to the colour AirStats ships with")
                }
                ColorPicker("", selection: binding, supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel("\(label) colour")
            }
        } label: {
            HStack(spacing: Design.Space.s) {
                Image(systemName: symbol)
                    .frame(width: 18, alignment: .center)
                    .foregroundStyle(current)
                Text(label)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(Design.Palette.tertiaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityValue("\(statusText) colour")
        }
    }

    private var statusText: String { status ?? (isOverridden ? "Custom" : "Default") }

    /// Reads through to whatever is being drawn — the override if there is one, the
    /// shipped colour if not — so opening the picker starts on the colour on screen
    /// rather than on black.
    private var binding: Binding<Color> {
        Binding(get: { current },
                set: { newValue in
                    // A colour that will not resolve into sRGB cannot be stored, and
                    // storing a wrong one is worse than declining the edit.
                    guard let stored = newValue.themeColor else { return }
                    set(stored)
                })
    }
}
