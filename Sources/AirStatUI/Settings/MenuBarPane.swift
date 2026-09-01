import SwiftUI
import AppKit
import AirStatKit

struct MenuBarPane: View {
    let settings: SettingsStore
    let engine: MetricsEngine?

    @State private var dropTarget: MenuBarItemConfig.ID?

    private var items: [MenuBarItemConfig] { settings.settings.menuBar.items }
    private var isVisible: Bool { settings.settings.menuBar.isVisible }

    private var availability: MetricAvailability {
        MetricAvailability(snapshot: SettingsPreview.snapshot(engine))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show in the menu bar", isOn: settings.binding(\.menuBar.isVisible))
            }

            Section {
                MenuBarPreviewStrip(model: previewModel, isEmpty: previewModel.items.isEmpty)
                    .listRowInsets(EdgeInsets())
            } header: {
                Text("Preview")
            }

            Section {
                readoutList
                readoutListControls
            } header: {
                Text("Readouts")
            }
            .disabled(!isVisible)

            Section {
                Toggle("Combine into one menu bar item",
                       isOn: settings.binding(\.menuBar.usesCombinedItem))
            } header: {
                Text("Layout")
            } footer: {
                Text("One item keeps the readouts together and in order. Separate items "
                     + "can be rearranged among your other menu bar icons, and macOS "
                     + "hides them one at a time when the bar runs out of room.")
                .font(.callout)
                .foregroundStyle(Design.Palette.secondaryText)
            }
            .disabled(!isVisible)

        }
        .settingsFormStyle()
    }

    // MARK: Readout list

    private var readoutList: some View {
        SettingsListBox {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                SettingsListRow(isFirst: index == 0,
                                isDropTarget: item.id == dropTarget) {
                    readoutRow(item, index: index)
                }
                .draggable(item.id.uuidString) {
                    Text(item.metric.label).padding(Design.Space.xs)
                }
                .dropDestination(for: String.self) { payload, _ in
                    dropTarget = nil
                    guard let dragged = payload.first else { return false }
                    return move(idString: dragged, to: index)
                } isTargeted: { targeted in
                    dropTarget = targeted ? item.id : (dropTarget == item.id ? nil : dropTarget)
                }
            }
        }
        .accessibilityLabel("Menu bar readouts")
    }

    /// Everything a readout has, on the readout's own row.
    ///
    /// The metric and style used to live in an "Editing …" section below the list,
    /// reached by selecting a row. That put the control you wanted somewhere other
    /// than the thing you wanted to change — and once the list ran past four readouts
    /// the section fell below the fold, so clicking a row appeared to do nothing at
    /// all. The style also sat in the row already, right-aligned exactly where a popup
    /// menu's value sits, as text that did not respond to a click.
    private func readoutRow(_ item: MenuBarItemConfig, index: Int) -> some View {
        HStack(spacing: Design.Space.m) {
            Toggle("", isOn: enabledBinding(for: item))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isLastEnabled(item))
                .help(isLastEnabled(item)
                      ? "At least one readout must stay visible so the menu bar item remains clickable."
                      : "Show \(item.metric.label) in the menu bar")
                .accessibilityLabel("Show \(item.metric.label)")

            RowMenu(title: item.metric.label,
                    width: Self.metricColumn,
                    label: "\(item.metric.label) metric") {
                Picker("Metric", selection: metricBinding(for: item)) {
                    ForEach(MenuBarMetric.allCases, id: \.self) { metric in
                        Text(metric.label).tag(metric)
                    }
                }
                .pickerStyle(.inline)
            }

            Spacer(minLength: Design.Space.s)

            // The badge stands in for the style control rather than joining it: a
            // readout this Mac cannot serve has no style worth choosing, and the two
            // together do not fit the row.
            if let reason = availability.note(for: item.metric) {
                UnavailableBadge(reason: reason)
            } else {
                styleMenu(item)
            }

            ReorderControls(canMoveUp: index > 0,
                            canMoveDown: index < items.count - 1,
                            itemLabel: item.metric.label) { offset in
                move(item, by: offset)
            }

            // Deleting belongs on the row it deletes. As a button under the list it
            // acted on "the selected readout", and the only thing naming that readout
            // was a tint on one row — a destructive control whose target you had to
            // infer. It also matches the desktop widget's module list, which is the same
            // list of the same metrics doing the same job.
            RowIconButton(systemName: "trash",
                          help: items.count <= 1
                              ? "The last readout cannot be removed."
                              : "Remove \(item.metric.label) from the menu bar",
                          label: "Remove \(item.metric.label)") {
                remove(item)
            }
            .disabled(items.count <= 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.metric.label)
        .accessibilityValue("\(item.isEnabled ? "Shown" : "Hidden"), \(item.style.label) style")
    }

    /// The style popup, carrying the caption toggle with it.
    ///
    /// The caption is a property of the style — only three of the five can show one —
    /// so it belongs behind the same control rather than as a second checkbox
    /// competing with the one that means "shown".
    private func styleMenu(_ item: MenuBarItemConfig) -> some View {
        RowMenu(title: item.style.label,
                label: "\(item.metric.label) display style") {
            Picker("Display as", selection: styleBinding(for: item)) {
                ForEach(item.metric.supportedStyles, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.inline)

            if item.style.supportsCaption {
                Divider()
                Toggle("Show \"\(caption(for: item.metric))\" above the value",
                       isOn: captionBinding(for: item))
            }
        }
    }

    /// Wide enough for "Battery Time Remaining", the longest metric name. The style
    /// beside it needs no column: it is the last thing in the row and sits against the
    /// trailing edge, where a fixed box would only add a gap.
    private static let metricColumn: CGFloat = 175

    private var readoutListControls: some View {
        HStack(spacing: Design.Space.m) {
            Menu {
                ForEach(MenuBarMetric.allCases, id: \.self) { metric in
                    Button {
                        add(metric)
                    } label: {
                        // Still selectable: a settings file travels between Macs, and
                        // a readout this machine cannot serve may work on the next.
                        Text(availability.note(for: metric) == nil
                             ? metric.label
                             : "\(metric.label) (unavailable here)")
                    }
                }
            } label: {
                Label("Add Readout", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Add a readout")

            Spacer()
        }
    }

    /// The label the menu bar would draw for this metric, quoted back so the toggle
    /// says what it will actually put on screen.
    private func caption(for metric: MenuBarMetric) -> String {
        MenuBarRenderModel.captionText(for: metric) ?? metric.label
    }

    // MARK: Model access

    /// Bindings carry the item's id rather than its position, so a rename or reorder
    /// cannot silently write to whichever readout now sits at that index.
    ///
    /// The getters answer from the captured item instead of going back to the array.
    /// SwiftUI reads a `Picker`'s selection during the same update pass that replaces
    /// the list, before the pane's body has had a chance to drop the editing section,
    /// so a getter that subscripted by index would trap on anything that shortens
    /// `menuBar.items` under the editor: Restore Defaults, or an import. The metric,
    /// style and caption factories are internal rather than private so the regression
    /// test can hold a binding across exactly that reset.
    private func mutate(_ item: MenuBarItemConfig,
                        _ body: @escaping (inout MenuBarItemConfig) -> Void) {
        settings.update { s in
            guard let index = s.menuBar.items.firstIndex(where: { $0.id == item.id }) else { return }
            body(&s.menuBar.items[index])
        }
    }

    private func enabledBinding(for item: MenuBarItemConfig) -> Binding<Bool> {
        Binding(get: { item.isEnabled },
                set: { isOn in mutate(item) { $0.isEnabled = isOn } })
    }

    func metricBinding(for item: MenuBarItemConfig) -> Binding<MenuBarMetric> {
        Binding(get: { item.metric },
                set: { metric in
                    mutate(item) { config in
                        config.metric = metric
                        // `sanitized()` in the store will clamp an unsupported style,
                        // but doing it here keeps the picker from flashing a value it
                        // is about to lose.
                        if !metric.supportedStyles.contains(config.style) {
                            config.style = metric.supportedStyles.first ?? .text
                        }
                    }
                })
    }

    func styleBinding(for item: MenuBarItemConfig) -> Binding<MenuBarDisplayStyle> {
        Binding(get: { item.style },
                set: { style in mutate(item) { $0.style = style } })
    }

    func captionBinding(for item: MenuBarItemConfig) -> Binding<Bool> {
        Binding(get: { item.showsCaption },
                set: { shows in mutate(item) { $0.showsCaption = shows } })
    }

    /// The item the store would refuse to disable, or nil when more than one is on.
    private var lastEnabledItem: MenuBarItemConfig? {
        let enabled = items.filter(\.isEnabled)
        return enabled.count == 1 ? enabled.first : nil
    }

    private func isLastEnabled(_ item: MenuBarItemConfig) -> Bool {
        lastEnabledItem?.id == item.id
    }

    /// Drop handler. Returns false for a payload that is not one of our rows, so a
    /// stray drag from another app is refused rather than silently ignored.
    private func move(idString: String, to destination: Int) -> Bool {
        guard let id = UUID(uuidString: idString),
              let source = items.firstIndex(where: { $0.id == id }),
              source != destination else { return false }
        settings.update { s in
            guard s.menuBar.items.indices.contains(source),
                  s.menuBar.items.indices.contains(destination) else { return }
            let moved = s.menuBar.items.remove(at: source)
            s.menuBar.items.insert(moved, at: destination)
        }
        return true
    }

    private func move(_ item: MenuBarItemConfig, by offset: Int) {
        settings.update { s in
            guard let index = s.menuBar.items.firstIndex(where: { $0.id == item.id }) else { return }
            let target = index + offset
            guard s.menuBar.items.indices.contains(target) else { return }
            s.menuBar.items.swapAt(index, target)
        }
    }

    private func add(_ metric: MenuBarMetric) {
        let config = MenuBarItemConfig(metric: metric,
                                       style: metric.supportedStyles.first ?? .text)
        settings.update { $0.menuBar.items.append(config) }
    }

    /// Removed by identity rather than by position, for the same reason the row's
    /// bindings are: the row a user pressed is the row that goes, whatever the array
    /// has done since.
    private func remove(_ item: MenuBarItemConfig) {
        settings.update { s in
            guard s.menuBar.items.count > 1 else { return }
            s.menuBar.items.removeAll { $0.id == item.id }
        }
    }

    // MARK: Preview

    /// Built from live data when the app is running and from fixtures when it is
    /// not, but through the same model either way — the preview never invents a
    /// value, it renders whatever the metric actually reports.
    private var previewModel: MenuBarRenderModel {
        MenuBarRenderModel(snapshot: SettingsPreview.snapshot(engine),
                           history: SettingsPreview.history(engine),
                           settings: settings.settings,
                           // Never stale-dimmed. This preview answers "what will my
                           // menu bar look like", and greying it because the last
                           // sample is a few seconds old would read as the setting
                           // being broken. The real menu bar still dims.
                           isStale: false)
    }
}
