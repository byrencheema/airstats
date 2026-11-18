import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AirStatKit

struct AboutPane: View {
    let settings: SettingsStore
    let engine: MetricsEngine?
    /// Absent in the offscreen renderer, which has no running app to update.
    var updater: SoftwareUpdater?

    @State private var transferResult: String?
    @State private var transferFailed = false
    @State private var isConfirmingFullReset = false

    /// Live identity when the app is running; the render harness has no engine, so
    /// it shows the same fixture machine every other rendered surface shows.
    private var systemState: MetricState<SystemInfoSnapshot> {
        engine?.system ?? .value(SnapshotFixtures.system())
    }

    private var formatter: MetricFormatter {
        MetricFormatter(settings: settings.settings.general)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: Design.Space.xl) {
                    LogoMark(size: 52)
                        .foregroundStyle(Design.Palette.primaryText)
                    VStack(alignment: .leading, spacing: Design.Space.xxs) {
                        Text("AirStats").font(.title2.weight(.medium))
                        Text(versionText).foregroundStyle(Design.Palette.secondaryText)
                    }
                    Spacer()
                }
                .padding(.vertical, Design.Space.xs)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("AirStats, \(versionText)")
            }

            Section {
                MetricContent(systemState) { system in
                    Group {
                        LabeledContent(L10n.tr("Computer", "Tên máy"), value: system.computerName)
                        LabeledContent(L10n.tr("Model", "Kiểu máy"), value: system.modelName)
                        LabeledContent("Chip", value: system.chipName)
                        LabeledContent(L10n.tr("Cores", "Số nhân"), value: coreText(system))
                        LabeledContent(L10n.tr("Memory", "Bộ nhớ"), value: formatter.memory(system.totalMemoryBytes))
                        LabeledContent(L10n.tr("System", "Hệ điều hành"), value: "\(system.osName) \(system.osVersion) (\(system.osBuild))")
                        LabeledContent(L10n.tr("Uptime", "Thời gian bật"), value: formatter.compactUptime(system.uptime))
                    }
                }
            } header: {
                Text(L10n.tr("This Mac", "Máy Mac này"))
            }

            Section {
                HStack(spacing: Design.Space.l) {
                    Button(L10n.tr("Export…", "Xuất…")) { export() }
                        .accessibilityHint(L10n.tr("Writes your settings to a JSON file", "Lưu cài đặt ra tệp JSON"))
                    Button(L10n.tr("Import…", "Nhập…")) { importSettings() }
                        .accessibilityHint(L10n.tr("Replaces your settings from a JSON file", "Khôi phục cài đặt từ tệp JSON"))
                    Spacer()
                }
                if let transferResult {
                    if transferFailed {
                        SettingsCaution(transferResult)
                    } else {
                        SettingsFootnote(transferResult)
                    }
                }
                LabeledContent(L10n.tr("Location", "Vị trí"), value: settings.settingsFileURL.path)
                    .font(.callout)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .textSelection(.enabled)
                Button(L10n.tr("Show in Finder", "Hiện trong Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([settings.settingsFileURL])
                }
            } header: {
                Text(L10n.tr("Settings File", "Tệp cài đặt"))
            }

            // One section's defaults are restored from the bar under that section's
            // own pane, where the user can see what is about to change. This is the
            // only reset that reaches settings you are not looking at, so it is the
            // only one that belongs here.
            Section {
                Button(L10n.tr("Restore All Settings…", "Đặt lại toàn bộ cài đặt…"), role: .destructive) { isConfirmingFullReset = true }
                    .confirmationDialog(L10n.tr("Restore every setting to its defaults?", "Đặt lại toàn bộ cài đặt về mặc định?"),
                                        isPresented: $isConfirmingFullReset) {
                        Button(L10n.tr("Restore All Settings", "Đặt lại toàn bộ"), role: .destructive) {
                            settings.resetToDefaults()
                        }
                        Button(L10n.tr("Cancel", "Huỷ"), role: .cancel) {}
                    } message: {
                        Text(L10n.tr(
                            "Your menu bar readouts, desktop widget, colours, notification rules and shortcuts all go back to how AirStats shipped.",
                            "Các chỉ số thanh Menu, Widget, màu sắc, quy tắc thông báo và phím tắt sẽ quay về mặc định ban đầu."))
                    }
            } header: {
                Text(L10n.tr("Reset", "Đặt lại"))
            } footer: {
                if let diagnostic = settings.loadDiagnostic {
                    SettingsCaution(diagnostic)
                }
            }
        }
        .settingsFormStyle()
    }

    /// The marketing version alone. The build number beside it is what Sparkle
    /// compares releases by and means nothing to the person reading it.
    private var versionText: String {
        guard let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            // Running the bare SwiftPM binary rather than the assembled .app.
            return L10n.tr("Development build", "Bản dựng phát triển")
        }
        return L10n.tr("Version \(short)", "Phiên bản \(short)")
    }

    private func coreText(_ system: SystemInfoSnapshot) -> String {
        var text = "\(system.logicalCores)"
        if system.performanceCores > 0 || system.efficiencyCores > 0 {
            text += L10n.tr(" (\(system.performanceCores) performance, \(system.efficiencyCores) efficiency)",
                            " (\(system.performanceCores) hiệu năng cao, \(system.efficiencyCores) tiết kiệm)")
        }
        if let gpu = system.gpuCoreCount {
            text += " · \(gpu) GPU"
        }
        return text
    }

    // MARK: Import / export

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AirStats Settings.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.exportJSON().write(to: url, options: .atomic)
            transferFailed = false
            transferResult = "Exported to \(url.lastPathComponent)."
        } catch {
            transferFailed = true
            transferResult = "Could not export: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.importJSON(Data(contentsOf: url))
            transferFailed = false
            transferResult = "Imported from \(url.lastPathComponent)."
        } catch {
            transferFailed = true
            transferResult = "\(url.lastPathComponent) is not a settings file AirStats can read. Your settings are unchanged."
        }
    }
}
