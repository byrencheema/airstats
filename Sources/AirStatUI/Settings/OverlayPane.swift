import SwiftUI
import AirStatKit

struct OverlayPane: View {
    let settings: SettingsStore
    let engine: MetricsEngine?

    @State private var dropTarget: PanelModule?

    private var availability: MetricAvailability {
        MetricAvailability(snapshot: SettingsPreview.snapshot(engine))
    }

    private var overlay: OverlaySettings { settings.settings.overlay }

    var body: some View {
        Form {
            // No header: it would repeat the pane's own name in the source list
            // beside it, and this row is the pane's subject rather than a section of
            // it — everything below configures the thing this switch puts on screen.
            Section {
                Toggle("Show the overlay", isOn: settings.binding(\.overlay.isEnabled))
            } footer: {
                if !overlay.isEnabled {
                    SettingsFootnote("Turn this on to put the overlay on screen. "
                                     + "The settings below shape it once it is there.")
                }
            }

            Section {
                moduleList
                moduleControls
            } header: {
                Text("Modules")
            }
            .disabled(!overlay.isEnabled)

            Section {
                Picker("Position", selection: settings.binding(\.overlay.corner)) {
                    ForEach(OverlayCorner.allCases, id: \.self) { corner in
                        Text(corner.label).tag(corner)
                    }
                }
                if overlay.corner == .free {
                    LabeledContent("Saved position", value: savedPositionText)
                        .foregroundStyle(Design.Palette.secondaryText)
                    Button("Forget Saved Position") {
                        settings.update {
                            $0.overlay.originX = nil
                            $0.overlay.originY = nil
                        }
                    }
                    .disabled(overlay.originX == nil && overlay.originY == nil)
                }
                LabeledContent("Width") {
                    HStack(spacing: Design.Space.l) {
                        Slider(value: settings.quantized(\.overlay.width, step: 4), in: 160...480)
                            .frame(minWidth: 140)
                        Text(SettingsLabels.points(overlay.width))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(Design.Palette.secondaryText)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle("Use compact layout", isOn: settings.binding(\.overlay.isCompact))
            } header: {
                Text("Position & Size")
            }
            .disabled(!overlay.isEnabled)

            Section {
                LabeledContent("Opacity") {
                    HStack(spacing: Design.Space.l) {
                        Slider(value: settings.quantized(\.overlay.opacity, step: 0.05), in: 0.2...1)
                            .frame(minWidth: 140)
                        Text(SettingsLabels.percent(overlay.opacity))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(Design.Palette.secondaryText)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle("Fade when not in use", isOn: settings.binding(\.overlay.dimsWhenInactive))
                if overlay.dimsWhenInactive {
                    LabeledContent("Faded opacity") {
                        HStack(spacing: Design.Space.l) {
                            Slider(value: settings.quantized(\.overlay.inactiveOpacity, step: 0.05),
                                   in: 0.15...1)
                                .frame(minWidth: 140)
                            Text(SettingsLabels.percent(overlay.inactiveOpacity))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(Design.Palette.secondaryText)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            } header: {
                Text("Transparency")
            }
            .disabled(!overlay.isEnabled)

            Section {
                Picker("Layer", selection: settings.binding(\.overlay.depth)) {
                    ForEach(OverlayDepth.allCases, id: \.self) { depth in
                        Text(depth.label).tag(depth)
                    }
                }
                Toggle("Click through the overlay", isOn: settings.binding(\.overlay.isClickThrough))
                Toggle("Show on all spaces", isOn: settings.binding(\.overlay.showsOnAllSpaces))
            } header: {
                Text("Behaviour")
            } footer: {
                Text(overlay.depth.detail)
                    .font(.callout)
                    .foregroundStyle(Design.Palette.secondaryText)
            }
            // Restore Defaults below stays live: a pane the user has switched off is
            // still a pane they may want to put back the way it shipped.
            .disabled(!overlay.isEnabled)

        }
        .settingsFormStyle()
    }

    // MARK: Modules

    private var moduleList: some View {
        SettingsListBox {
            ForEach(Array(overlay.modules.enumerated()), id: \.element) { index, module in
                SettingsListRow(isFirst: index == 0, isDropTarget: module == dropTarget) {
                    HStack(spacing: Design.Space.m) {
                        ModuleLabel(module: module)
                        Spacer(minLength: Design.Space.m)
                        if let reason = availability.note(for: module) {
                            UnavailableBadge(reason: reason)
                        }
                        ReorderControls(canMoveUp: index > 0,
                                        canMoveDown: index < overlay.modules.count - 1,
                                        itemLabel: module.label) { offset in
                            move(module, by: offset)
                        }
                        RowIconButton(systemName: "trash",
                                      help: overlay.modules.count <= 1
                                          ? "The overlay needs at least one module."
                                          : "Remove \(module.label) from the overlay",
                                      label: "Remove \(module.label)") {
                            settings.update { $0.overlay.modules.removeAll { $0 == module } }
                        }
                        .disabled(overlay.modules.count <= 1)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(module.label)
                }
                .draggable(module.rawValue) {
                    Text(module.label).padding(Design.Space.xs)
                }
                .dropDestination(for: String.self) { payload, _ in
                    dropTarget = nil
                    guard let raw = payload.first, let dragged = PanelModule(rawValue: raw) else { return false }
                    return move(dragged, to: index)
                } isTargeted: { targeted in
                    dropTarget = targeted ? module : (dropTarget == module ? nil : dropTarget)
                }
            }
        }
        .accessibilityLabel("Overlay modules")
    }

    private var moduleControls: some View {
        HStack(spacing: Design.Space.m) {
            Menu {
                ForEach(availableModules, id: \.self) { module in
                    Button(module.label) {
                        settings.update { $0.overlay.modules.append(module) }
                    }
                }
            } label: {
                Label("Add Module", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(availableModules.isEmpty)
            .help(availableModules.isEmpty ? "Every module is already in the overlay." : "")
            .accessibilityLabel("Add a module to the overlay")

            Spacer()
        }
    }

    private var availableModules: [PanelModule] {
        PanelModule.allCases.filter { !overlay.modules.contains($0) }
    }

    private func move(_ module: PanelModule, by offset: Int) {
        settings.update { s in
            guard let index = s.overlay.modules.firstIndex(of: module) else { return }
            let target = index + offset
            guard s.overlay.modules.indices.contains(target) else { return }
            s.overlay.modules.swapAt(index, target)
        }
    }

    private func move(_ module: PanelModule, to destination: Int) -> Bool {
        guard let source = overlay.modules.firstIndex(of: module), source != destination,
              overlay.modules.indices.contains(destination) else { return false }
        settings.update { s in
            guard s.overlay.modules.indices.contains(source),
                  s.overlay.modules.indices.contains(destination) else { return }
            s.overlay.modules.insert(s.overlay.modules.remove(at: source), at: destination)
        }
        return true
    }

    private var savedPositionText: String {
        guard let x = overlay.originX, let y = overlay.originY else { return "Not set" }
        return "\(Int(x)), \(Int(y))"
    }
}
