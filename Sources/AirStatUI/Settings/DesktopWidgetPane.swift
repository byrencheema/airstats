import SwiftUI
import AirStatKit

struct DesktopWidgetPane: View {
    let settings: SettingsStore
    let engine: MetricsEngine?

    @State private var dropTarget: PanelModule?

    private var availability: MetricAvailability {
        MetricAvailability(snapshot: SettingsPreview.snapshot(engine))
    }

    private var desktopWidget: DesktopWidgetSettings { settings.settings.desktopWidget }

    var body: some View {
        Form {
            // No header: it would repeat the pane's own name in the source list
            // beside it, and this row is the pane's subject rather than a section of
            // it — everything below configures the thing this switch puts on screen.
            Section {
                Toggle(L10n.tr("Show the desktop widget", "Hiển thị widget trên màn hình"),
                       isOn: settings.binding(\.desktopWidget.isEnabled))
            }

            // The preview and the list that fills it, side by side. Stacked, the
            // thumbnail was a band across the pane and the modules were somewhere
            // below it; beside them, reordering one is watching the other.
            //
            // Below the switch rather than above it, so a pane opened with the desktop widget
            // off says it is off before it shows what it would look like. The preview
            // itself is never disabled: what the desktop widget would be is exactly what
            // someone deciding whether to switch it on wants to see.
            Section {
                HStack(alignment: .top, spacing: Design.Space.xl) {
                    if let engine {
                        DesktopWidgetPreview(engine: engine, settings: settings)
                    }
                    VStack(alignment: .leading, spacing: Design.Space.m) {
                        moduleList
                        moduleControls
                    }
                    .disabled(!desktopWidget.isEnabled)
                }
            } header: {
                Text(L10n.tr("Modules", "Các mục hiển thị"))
            }

            Section {
                SettingsSlider(title: L10n.tr("Width", "Chiều rộng"),
                               value: settings.quantized(\.desktopWidget.width, step: 4),
                               range: 160...480,
                               format: SettingsLabels.points)
                Toggle(L10n.tr("Use compact layout", "Dùng bố cục thu gọn"),
                       isOn: settings.binding(\.desktopWidget.isCompact))
                Toggle(L10n.tr("Show a 24-hour history", "Hiện lịch sử 24 giờ"),
                       isOn: settings.binding(\.desktopWidget.showsHistoryChart))
                SettingsSlider(title: L10n.tr("Opacity", "Độ mờ"),
                               value: settings.quantized(\.desktopWidget.opacity, step: 0.05),
                               range: 0.2...1,
                               format: SettingsLabels.percent)
                Toggle(L10n.tr("Fade when not in use", "Làm mờ khi không dùng"),
                       isOn: settings.binding(\.desktopWidget.dimsWhenInactive))
                if desktopWidget.dimsWhenInactive {
                    SettingsSlider(title: L10n.tr("Faded opacity", "Độ mờ khi ẩn"),
                                   value: settings.quantized(\.desktopWidget.inactiveOpacity, step: 0.05),
                                   range: 0.15...1,
                                   format: SettingsLabels.percent)
                }
            } header: {
                Text(L10n.tr("Size & Transparency", "Kích thước & Độ trong suốt"))
            }
            .disabled(!desktopWidget.isEnabled)

            Section {
                Picker(L10n.tr("Position", "Vị trí"), selection: settings.binding(\.desktopWidget.corner)) {
                    ForEach(DesktopWidgetCorner.allCases, id: \.self) { corner in
                        Text(corner.label).tag(corner)
                    }
                }
                if desktopWidget.corner == .free {
                    LabeledContent(L10n.tr("Saved position", "Vị trí đã lưu"), value: savedPositionText)
                        .foregroundStyle(Design.Palette.secondaryText)
                    Button(L10n.tr("Forget Saved Position", "Xoá vị trí đã lưu")) {
                        settings.update {
                            $0.desktopWidget.originX = nil
                            $0.desktopWidget.originY = nil
                        }
                    }
                    .disabled(desktopWidget.originX == nil && desktopWidget.originY == nil)
                }
            } header: {
                Text(L10n.tr("Position", "Vị trí"))
            }
            .disabled(!desktopWidget.isEnabled)

            Section {
                Picker(L10n.tr("Layer", "Lớp hiển thị"), selection: settings.binding(\.desktopWidget.depth)) {
                    ForEach(DesktopWidgetDepth.allCases, id: \.self) { depth in
                        Text(depth.label).tag(depth)
                    }
                }
                Toggle(L10n.tr("Click through the desktop widget", "Cho phép bấm xuyên qua widget"),
                       isOn: settings.binding(\.desktopWidget.isClickThrough))
                Toggle(L10n.tr("Show on all spaces", "Hiện trên mọi màn hình ảo"),
                       isOn: settings.binding(\.desktopWidget.showsOnAllSpaces))
            } header: {
                Text(L10n.tr("Behaviour", "Hành vi"))
            } footer: {
                Text(desktopWidget.depth.detail)
                    .font(.callout)
                    .foregroundStyle(Design.Palette.secondaryText)
            }
            // Restore Defaults below stays live: a pane the user has switched off is
            // still a pane they may want to put back the way it shipped.
            .disabled(!desktopWidget.isEnabled)

        }
        .settingsFormStyle()
    }

    // MARK: Modules

    private var moduleList: some View {
        SettingsListBox {
            ForEach(Array(desktopWidget.modules.enumerated()), id: \.element) { index, module in
                SettingsListRow(isFirst: index == 0, isDropTarget: module == dropTarget) {
                    HStack(spacing: Design.Space.m) {
                        ModuleLabel(module: module)
                        Spacer(minLength: Design.Space.m)
                        if let reason = availability.note(for: module) {
                            UnavailableBadge(reason: reason)
                        }
                        ReorderControls(canMoveUp: index > 0,
                                        canMoveDown: index < desktopWidget.modules.count - 1,
                                        itemLabel: module.label) { offset in
                            move(module, by: offset)
                        }
                        RowIconButton(systemName: "trash",
                                      help: desktopWidget.modules.count <= 1
                                          ? L10n.tr("The desktop widget needs at least one module.", "Widget cần tối thiểu một mục.")
                                          : L10n.tr("Remove \(module.label) from the desktop widget", "Xoá \(module.label) khỏi widget"),
                                      label: L10n.tr("Remove \(module.label)", "Xoá \(module.label)")) {
                            settings.update { $0.desktopWidget.modules.removeAll { $0 == module } }
                        }
                        .disabled(desktopWidget.modules.count <= 1)
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
        .accessibilityLabel("Desktop Widget modules")
    }

    private var moduleControls: some View {
        HStack(spacing: Design.Space.m) {
            Menu {
                ForEach(availableModules, id: \.self) { module in
                    Button(module.label) {
                        settings.update { $0.desktopWidget.modules.append(module) }
                    }
                }
            } label: {
                Label(L10n.tr("Add Module", "Thêm mục"), systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(availableModules.isEmpty)
            .help(availableModules.isEmpty ? L10n.tr("Every module is already in the desktop widget.", "Tất cả các mục đã có trong widget.") : "")
            .accessibilityLabel(L10n.tr("Add a module to the desktop widget", "Thêm mục vào widget"))

            Spacer()
        }
    }

    private var availableModules: [PanelModule] {
        PanelModule.allCases.filter { !desktopWidget.modules.contains($0) }
    }

    private func move(_ module: PanelModule, by offset: Int) {
        settings.update { s in
            guard let index = s.desktopWidget.modules.firstIndex(of: module) else { return }
            let target = index + offset
            guard s.desktopWidget.modules.indices.contains(target) else { return }
            s.desktopWidget.modules.swapAt(index, target)
        }
    }

    private func move(_ module: PanelModule, to destination: Int) -> Bool {
        guard let source = desktopWidget.modules.firstIndex(of: module), source != destination,
              desktopWidget.modules.indices.contains(destination) else { return false }
        settings.update { s in
            guard s.desktopWidget.modules.indices.contains(source),
                  s.desktopWidget.modules.indices.contains(destination) else { return }
            s.desktopWidget.modules.insert(s.desktopWidget.modules.remove(at: source), at: destination)
        }
        return true
    }

    private var savedPositionText: String {
        guard let x = desktopWidget.originX, let y = desktopWidget.originY else {
            return L10n.tr("Not set", "Chưa đặt")
        }
        return "\(Int(x)), \(Int(y))"
    }
}
