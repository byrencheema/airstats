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
                Toggle("Open AirStats at login",
                       isOn: settings.binding(\.general.launchAtLogin, onChange: applyLoginItem))
                if let loginItemError {
                    SettingsCaution(loginItemError)
                }
                Toggle("Show icon in the Dock",
                       isOn: settings.binding(\.general.showsDockIcon, onChange: applyDockIcon))
            } header: {
                Text("Startup")
            }

            Section {
                Picker("Update interval", selection: settings.binding(\.general.updateInterval)) {
                    ForEach(GeneralSettings.allowedIntervals, id: \.self) { interval in
                        Text(SettingsLabels.interval(interval)).tag(interval)
                    }
                }
                Toggle("Slow down when the menu bar is hidden",
                       isOn: settings.binding(\.general.throttlesWhenOccluded))
                Toggle("Pause sampling on Low Power Mode",
                       isOn: settings.binding(\.general.pausesOnLowPower))
            } header: {
                Text("Sampling")
            }

            Section {
                Picker("Temperature", selection: settings.binding(\.general.temperatureUnit)) {
                    ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                Picker("Network rate", selection: settings.binding(\.general.networkRateUnit)) {
                    ForEach(NetworkRateUnit.allCases, id: \.self) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                Picker("Storage sizes", selection: settings.binding(\.general.byteUnitStyle)) {
                    ForEach(ByteUnitStyle.allCases, id: \.self) { style in
                        Text(style.label).tag(style)
                    }
                }
                Toggle("Show the percent sign", isOn: settings.binding(\.general.showsPercentSign))
            } header: {
                Text("Units")
            }

            // Every update control in one place. The two automatic-update toggles were
            // here and the button that performs a check was in About, so answering
            // "is this up to date, and will it stay that way" meant knowing to look in
            // two panes and finding no cross-reference in either.
            Section {
                HStack(spacing: Design.Space.l) {
                    // Everything past the press belongs to Sparkle: it reports up to
                    // date, an error, or an update with its release notes and an
                    // Install button, in its own window.
                    Button("Check Now…") { updater?.checkForUpdates() }
                        .disabled(updater?.canCheck != true)
                        .accessibilityHint("Asks airstats.app whether a newer version exists")
                    Spacer()
                }
                // Stored by Sparkle rather than in the settings file, so this reads and
                // writes the updater itself. Only the offscreen renderer has none.
                Toggle("Check for updates automatically", isOn: checksAutomatically)
                    .disabled(updater == nil)
                // Sparkle offers the same choice the first time it installs something,
                // and takes the answer as standing. Without this row the only way back
                // is to wait for another release and refuse it there.
                Toggle("Install updates automatically", isOn: installsAutomatically)
                    .disabled(updater == nil || !(updater?.checksAutomatically ?? false))
                if let checked = lastCheckedNote {
                    SettingsFootnote(checked)
                }
                // Sparkle stamps the check date on failure too, so without this line a
                // feed that has been unreachable for a month reads as checked just now.
                if let failure = updater?.lastCheckFailure {
                    SettingsFootnote("The last check failed: \(failure)")
                }
            } header: {
                Text("Updates")
            }

            Section {
                Toggle("Look up my public IP address",
                       isOn: settings.binding(\.general.fetchesPublicIP))
            } header: {
                Text("Privacy")
            } footer: {
                SettingsFootnote("Left off, the Network module shows your local "
                                 + "addresses only and AirStats contacts nothing.")
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

    /// Standing answer to "is this thing actually running?", which the button alone
    /// cannot give: the automatic check is silent when it finds nothing, so a user who
    /// has never pressed anything would otherwise see no sign of it at all.
    private var lastCheckedNote: String? {
        guard let checked = updater?.lastCheck else { return nil }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return "Last checked \(relative.localizedString(for: checked, relativeTo: Date()))."
    }

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
