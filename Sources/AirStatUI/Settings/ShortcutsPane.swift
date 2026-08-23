import SwiftUI
import AirStatKit

/// The global shortcut recorders.
///
/// A pane rather than a section of General: a shortcut is the one setting people open
/// this window already knowing they want, and it was previously the last thing in
/// General's scroll, below sampling intervals and unit pickers.
struct ShortcutsPane: View {
    let settings: SettingsStore

    var body: some View {
        Form {
            ShortcutsFormSections(settings: settings)
        }
        .settingsFormStyle()
    }
}
