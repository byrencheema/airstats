import SwiftUI
import AppKit
import AirStatKit

struct GeneralPane: View {
    let settings: SettingsStore
    /// Absent in the offscreen renderer, which has no running app to update.
    var updater: SoftwareUpdater?

    /// `LoginItem.synchronize` reports a real failure — a missing bundle, a
    /// revoked approval — and the toggle is worthless if that is swallowed.
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Picker(L10n.tr("Language", "Ngôn ngữ"), selection: settings.binding(\.general.language)) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.label).tag(lang)
                    }
                }
                Toggle(L10n.tr("Open AirStats at login", "Mở AirStats khi đăng nhập"),
                       isOn: settings.binding(\.general.launchAtLogin, onChange: applyLoginItem))
                if let loginItemError {
                    SettingsCaution(loginItemError)
                }
                Toggle(L10n.tr("Show icon in the Dock", "Hiện biểu tượng trên Dock"),
                       isOn: settings.binding(\.general.showsDockIcon, onChange: applyDockIcon))
            } header: {
                Text(L10n.tr("Startup", "Khởi động & Ngôn ngữ"))
            }

            Section {
                Picker(L10n.tr("Update interval", "Chu kỳ cập nhật"), selection: settings.binding(\.general.updateInterval)) {
                    ForEach(GeneralSettings.allowedIntervals, id: \.self) { interval in
                        Text(SettingsLabels.interval(interval)).tag(interval)
                    }
                }
                Toggle(L10n.tr("Slow down when the menu bar is hidden", "Giảm tần suất khi thanh Menu bị ẩn"),
                       isOn: settings.binding(\.general.throttlesWhenOccluded))
                Toggle(L10n.tr("Pause sampling on Low Power Mode", "Tạm dừng khi bật Chế độ nguồn điện thấp"),
                       isOn: settings.binding(\.general.pausesOnLowPower))
            } header: {
                Text(L10n.tr("Sampling", "Lấy mẫu"))
            }

            Section {
                Picker(L10n.tr("Temperature", "Nhiệt độ"), selection: settings.binding(\.general.temperatureUnit)) {
                    ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                Picker(L10n.tr("Network rate", "Tốc độ mạng"), selection: settings.binding(\.general.networkRateUnit)) {
                    ForEach(NetworkRateUnit.allCases, id: \.self) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                Picker(L10n.tr("Storage sizes", "Dung lượng lưu trữ"), selection: settings.binding(\.general.byteUnitStyle)) {
                    ForEach(ByteUnitStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                Toggle(L10n.tr("Show the percent sign", "Hiển thị dấu phần trăm (%)"), isOn: settings.binding(\.general.showsPercentSign))
            } header: {
                Text(L10n.tr("Units", "Đơn vị"))
            }

            // Every update control in one place. The two automatic-update toggles were
            // here and the button that performs a check was in About, so answering
            // "is this up to date, and will it stay that way" meant knowing to look in
            // two panes and finding no cross-reference in either.
            Section {
                // The answer to a check is drawn beside the button rather than in
                // Sparkle's alert. Only an update opens a window, and only when the
                // user asks to install it, because that window carries the release
                // notes and the Install button.
                HStack(spacing: Design.Space.l) {
                    if let pending = updater?.pending {
                        Button(pending.isReadyToInstall ? L10n.tr("Restart", "Khởi động lại") : L10n.tr("Install…", "Cài đặt…")) {
                            updater?.installPending()
                        }
                        .accessibilityHint(pending.isReadyToInstall
                                           ? L10n.tr("Relaunches AirStats into the new version", "Khởi động lại AirStats vào phiên bản mới")
                                           : L10n.tr("Opens the updater to install it", "Mở trình cập nhật để cài đặt"))
                    } else {
                        Button(L10n.tr("Check Now", "Kiểm tra ngay")) { updater?.checkQuietly() }
                            .disabled(updater?.canCheck != true)
                            .accessibilityHint(L10n.tr("Asks airstats.app whether a newer version exists", "Kiểm tra phiên bản mới từ airstats.app"))
                    }
                    Spacer()
                    updateStatus
                }
                // Stored by Sparkle rather than in the settings file, so this reads and
                // writes the updater itself. Only the offscreen renderer has none.
                Toggle(L10n.tr("Check for updates automatically", "Tự động kiểm tra cập nhật"), isOn: checksAutomatically)
                    .disabled(updater == nil)
                // Sparkle offers the same choice the first time it installs something,
                // and takes the answer as standing. Without this row the only way back
                // is to wait for another release and refuse it there.
                Toggle(L10n.tr("Install updates automatically", "Tự động cài đặt cập nhật"), isOn: installsAutomatically)
                    .disabled(updater == nil || !(updater?.checksAutomatically ?? false))
            } header: {
                Text(L10n.tr("Updates", "Cập nhật"))
            }

            Section {
                Toggle(L10n.tr("Look up my public IP address", "Tra cứu địa chỉ IP công khai"),
                       isOn: settings.binding(\.general.fetchesPublicIP))
            } header: {
                Text(L10n.tr("Privacy", "Quyền riêng tư"))
            } footer: {
                SettingsFootnote(L10n.tr(
                    "Left off, the Network module shows your local addresses only and AirStats contacts nothing.",
                    "Khi tắt, mục Mạng chỉ hiển thị IP nội bộ và AirStats không gửi bất kỳ yêu cầu mạng nào."))
            }
        }
        .settingsFormStyle()
    }

    // MARK: Side effects

    private var checksAutomatically: Binding<Bool> {
        Binding(get: { updater?.checksAutomatically ?? true },
                set: { updater?.setChecksAutomatically($0) })
    }

    private var installsAutomatically: Binding<Bool> {
        Binding(get: { updater?.installsAutomatically ?? false },
                set: { updater?.setInstallsAutomatically($0) })
    }

    /// The state of updates, beside the button that changes it. It also answers "is
    /// this thing actually running?": the automatic check is silent when it finds
    /// nothing, so without the checked time a user who never pressed anything would see
    /// no sign of it at all. A failure is named, because Sparkle stamps the check date
    /// on failure too and a feed unreachable for a month would otherwise read as fine.
    @ViewBuilder
    private var updateStatus: some View {
        if updater?.isChecking == true {
            HStack(spacing: Design.Space.s) {
                ProgressView().controlSize(.small)
                Text(L10n.tr("Checking…", "Đang kiểm tra…"))
            }
            .foregroundStyle(.secondary)
        } else if let failure = updater?.lastCheckFailure {
            Text(L10n.tr("Couldn't check", "Không thể kiểm tra"))
                .foregroundStyle(.secondary)
                .help(failure)
                .accessibilityValue(failure)
        } else if updater?.pending != nil || updater?.lastCheck != nil {
            VStack(alignment: .trailing, spacing: Design.Space.xxs) {
                if let pending = updater?.pending {
                    Text(pending.isReadyToInstall
                         ? L10n.tr("AirStats \(pending.version) is ready", "AirStats \(pending.version) đã sẵn sàng")
                         : L10n.tr("AirStats \(pending.version) is available", "Đã có AirStats \(pending.version)"))
                } else {
                    Text(L10n.tr("Up to date", "Đã mới nhất"))
                }
                if let checked = updater?.lastCheck {
                    Text(L10n.tr("Checked \(Self.checkedPhrase(checked))", "Đã kiểm tra \(Self.checkedPhrase(checked))"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
    }

    /// A check that has just finished is stamped a moment after the `Date()` it is
    /// drawn against, and the formatter reads that as "in 0 seconds".
    private static func checkedPhrase(_ checked: Date) -> String {
        let now = Date()
        guard now.timeIntervalSince(checked) >= 60 else { return "just now" }
        return relative.localizedString(for: checked, relativeTo: now)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Process-level state rather than a stored preference, so the store's value alone
    /// would change nothing until the next launch.
    private func applyDockIcon(_ shows: Bool) {
        NSApp.setActivationPolicy(shows ? .regular : .accessory)
        // Switching policy drops key window status; take it back so the settings
        // window the user is standing in does not slide behind everything.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyLoginItem(_ enabled: Bool) {
        if let error = LoginItem.synchronize(enabled: enabled) {
            loginItemError = "macOS refused to \(enabled ? "register" : "remove") the login item: \(error.localizedDescription)"
            // The stored preference must not claim something the system rejected.
            settings.update { $0.general.launchAtLogin = LoginItem.isEnabled }
        } else {
            loginItemError = nil
        }
    }
}
