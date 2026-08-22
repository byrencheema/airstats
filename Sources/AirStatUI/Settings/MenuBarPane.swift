import SwiftUI
import AppKit
import AirStatKit

struct MenuBarPane: View {
    let settings: SettingsStore
    let engine: MetricsEngine?

    @State private var selection: MenuBarItemConfig.ID?
    @State private var dropTarget: MenuBarItemConfig.ID?

    private var items: [MenuBarItemConfig] { settings.settings.menuBar.items }

    private var availability: MetricAvailability {
        MetricAvailability(snapshot: SettingsPreview.snapshot(engine))
    }

    private var selectedItem: MenuBarItemConfig? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    var body: some View {
        Form {
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

            if let item = selectedItem {
                itemDetail(item)
            }

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

        }
        .settingsFormStyle()
        // Opening on a selected readout means the configuration controls are visible
        // rather than hidden behind a click nothing hints at.
        .onAppear { if selection == nil { selection = items.first?.id } }
    }

    // MARK: Readout list

    private var readoutList: some View {
        SettingsListBox {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                SettingsListRow(isFirst: index == 0,
                                isSelected: item.id == selection,
                                isDropTarget: item.id == dropTarget) {
                    readoutRow(item, index: index)
                }
                .onTapGesture { selection = item.id }
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

    private func readoutRow(_ item: MenuBarItemConfig, index: Int) -> some View {
        HStack(spacing: Design.Space.m) {
            Toggle(isOn: enabledBinding(for: item)) {
                Text(item.metric.label)
            }
            .toggleStyle(.checkbox)
            .disabled(isLastEnabled(item))
            .help(isLastEnabled(item)
                  ? "At least one readout must stay visible so the menu bar item remains clickable."
                  : "Show \(item.metric.label) in the menu bar")

            Spacer(minLength: Design.Space.m)

            if let reason = availability.note(for: item.metric) {
                UnavailableBadge(reason: reason)
            } else {
                Text(item.style.label)
                    .font(.callout)
                    .foregroundStyle(Design.Palette.secondaryText)
            }

            ReorderControls(canMoveUp: index > 0,
                            canMoveDown: index < items.count - 1,
                            itemLabel: item.metric.label) { offset in
                move(item, by: offset)
            }

            // Deleting belongs on the row it deletes. As a button under the list it
            // acted on "the selected readout", and the only thing naming that readout
            // was a tint on one row — a destructive control whose target you had to
            // infer. It also matches the overlay's module list, which is the same
            // list of the same metrics doing the same job.
            Button {
                remove(item)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Design.Palette.tertiaryText)
            .disabled(items.count <= 1)
            .help(items.count <= 1
                  ? "The last readout cannot be removed."
                  : "Remove \(item.metric.label) from the menu bar")
            .accessibilityLabel("Remove \(item.metric.label)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.metric.label)
        .accessibilityValue("\(item.isEnabled ? "Shown" : "Hidden"), \(item.style.label) style")
    }

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

    // MARK: Selected readout

    /// The controls for the selected row.
    ///
    /// The header names the readout being edited rather than repeating the pane's own
    /// title. With nothing but "Metric" and "Display as" under a heading that said
    /// "CPU Usage", it read as a section of the pane, and changing the picker while
    /// looking at a list of four readouts was a guess about which one was moving.
    @ViewBuilder
    private func itemDetail(_ item: MenuBarItemConfig) -> some View {
        Section {
            Picker("Metric", selection: metricBinding(for: item)) {
                ForEach(MenuBarMetric.allCases, id: \.self) { metric in
                    Text(metric.label).tag(metric)
                }
            }

            Picker("Display as", selection: styleBinding(for: item)) {
                ForEach(item.metric.supportedStyles, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.menu)

            // The icon and battery styles name the metric with their glyph, so there is
            // nothing for a caption to add and the toggle would do nothing if shown.
            if item.style.supportsCaption {
                Toggle("Show \"\(caption(for: item.metric))\" above the value",
                       isOn: captionBinding(for: item))
            }
        } header: {
            Label("Editing \(item.metric.label)", systemImage: "slider.horizontal.3")
                .foregroundStyle(Design.Palette.accent)
        } footer: {
            if let reason = availability.note(for: item.metric) {
                SettingsCaution(reason)
            }
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
        selection = config.id
    }

    /// Removed by identity rather than by position, for the same reason the editing
    /// bindings are: the row a user pressed is the row that goes, whatever the array
    /// has done since.
    private func remove(_ item: MenuBarItemConfig) {
        settings.update { s in
            guard s.menuBar.items.count > 1 else { return }
            s.menuBar.items.removeAll { $0.id == item.id }
        }
        // Leave something selected, so the editor below does not vanish out from
        // under a user who was only trimming the list.
        if selection == item.id { selection = settings.settings.menuBar.items.first?.id }
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
