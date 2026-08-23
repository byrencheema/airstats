import SwiftUI
import AppKit
import AirStatKit

/// The shortcut rows, as sections for a `Form`.
///
/// Separate from `ShortcutsPane` because the conflict detection below is the substance
/// of the feature and is worth reading on its own, without a pane's scaffolding
/// wrapped around it.
struct ShortcutsFormSections: View {
    let settings: SettingsStore

    private var bindings: [ShortcutAction: AirStatKit.KeyboardShortcut] {
        settings.settings.shortcuts.bindings
    }

    var body: some View {
        Group {
            // No header: it would repeat the pane's own name in the source list
            // beside it.
            Section {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    LabeledContent(action.label) {
                        ShortcutRecorderField(action: action, settings: settings)
                    }
                }
            } footer: {
                SettingsFootnote("These work anywhere in macOS, including while another "
                                 + "app is frontmost. AirStats stays in the background.")
            }

            if !conflicts.isEmpty {
                Section {
                    ForEach(conflicts, id: \.self) { conflict in
                        SettingsCaution(conflict)
                    }
                } header: {
                    Text("Conflicts")
                }
            }
        }
    }

    /// Two actions on the same key code and modifier set. Compared on the stored
    /// fields rather than the display string, so two different keys that happen to
    /// print the same glyph are not called a conflict.
    private var conflicts: [String] {
        var byCombination: [Combination: [ShortcutAction]] = [:]
        for action in ShortcutAction.allCases {
            guard let shortcut = bindings[action] else { continue }
            byCombination[Combination(shortcut), default: []].append(action)
        }
        return byCombination.compactMap { combination, actions in
            guard actions.count > 1 else { return nil }
            let names = actions.map(\.label).joined(separator: " and ")
            return "\(combination.display) is assigned to \(names)."
        }
        .sorted()
    }

    private struct Combination: Hashable {
        let keyCode: UInt16
        let modifierFlags: UInt
        let display: String

        init(_ shortcut: AirStatKit.KeyboardShortcut) {
            keyCode = shortcut.keyCode
            modifierFlags = shortcut.modifierFlags
            display = ShortcutDisplay.string(for: shortcut)
        }

        static func == (a: Self, b: Self) -> Bool {
            a.keyCode == b.keyCode && a.modifierFlags == b.modifierFlags
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(keyCode)
            hasher.combine(modifierFlags)
        }
    }
}
