import SwiftUI
import AppKit
import AirStatKit

/// Renders a stored key combination the way macOS writes them in menus.
///
/// Modifiers appear in Apple's canonical order (⌃⌥⇧⌘) regardless of the order the
/// user happened to press them, so two recordings of the same chord always read
/// identically.
enum ShortcutDisplay {

    static func string(for shortcut: AirStatKit.KeyboardShortcut) -> String {
        modifierGlyphs(shortcut.modifierFlags) + keyName(for: shortcut)
    }

    static func modifierGlyphs(_ rawFlags: UInt) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
        var glyphs = ""
        if flags.contains(.control) { glyphs += "⌃" }
        if flags.contains(.option) { glyphs += "⌥" }
        if flags.contains(.shift) { glyphs += "⇧" }
        if flags.contains(.command) { glyphs += "⌘" }
        return glyphs
    }

    /// Spoken form for VoiceOver — the glyphs alone are announced as unrelated
    /// symbols, which makes a recorded shortcut unverifiable without sight.
    static func accessibleString(for shortcut: AirStatKit.KeyboardShortcut) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
        var parts: [String] = []
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Option") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Command") }
        parts.append(keyName(for: shortcut))
        return parts.joined(separator: " ")
    }

    /// Named keys come from the key code, which is layout-independent. Everything
    /// else falls back to the characters recorded at capture time.
    static func keyName(for shortcut: AirStatKit.KeyboardShortcut) -> String {
        if let named = namedKeys[shortcut.keyCode] { return named }
        let characters = shortcut.characters.trimmingCharacters(in: .whitespacesAndNewlines)
        if characters.isEmpty { return "Key \(shortcut.keyCode)" }
        return characters.uppercased()
    }

    /// Virtual key codes for keys with no printable character. Values are the
    /// stable `kVK_` constants from Carbon's Events.h.
    private static let namedKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        115: "↖", 116: "⇞", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

/// Records a key combination.
///
/// Capture goes through a local event monitor rather than a custom first-responder
/// view: the monitor sees the key down before any menu equivalent or text field
/// consumes it, which is the only way to record combinations like ⌘Q that the app
/// would otherwise act on. The button itself stays a plain SwiftUI control, so it
/// keeps standard focus, focus ring and Space-to-activate behaviour for free.
struct ShortcutRecorderField: View {
    let action: ShortcutAction
    let settings: SettingsStore

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejection: String?

    private var shortcut: AirStatKit.KeyboardShortcut? {
        settings.settings.shortcuts.bindings[action]
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.m) {
                Button(action: toggleRecording) {
                    Text(fieldTitle)
                        .font(.body.monospacedDigit())
                        .frame(minWidth: 96)
                }
                .accessibilityLabel("\(action.label) shortcut")
                .accessibilityValue(accessibleValue)
                .accessibilityHint(isRecording
                    ? "Press the key combination to assign, or press Escape to cancel"
                    : "Activate, then press a key combination")
                .help(isRecording ? "Press a key combination. Escape cancels." : "Click to record a shortcut")

                Button {
                    clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Design.Palette.tertiaryText)
                .disabled(shortcut == nil)
                .help("Remove this shortcut")
                .accessibilityLabel("Remove the \(action.label) shortcut")
            }
            if let rejection {
                Text(rejection)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
            }
        }
        .onDisappear(perform: stopMonitor)
    }

    private var fieldTitle: String {
        if isRecording { return L10n.tr("Recording…", "Đang ghi…") }
        guard let shortcut else { return L10n.tr("Record Shortcut", "Đặt phím tắt") }
        return ShortcutDisplay.string(for: shortcut)
    }

    private var accessibleValue: String {
        if isRecording { return L10n.tr("Recording", "Đang ghi") }
        guard let shortcut else { return L10n.tr("None", "Không có") }
        return ShortcutDisplay.accessibleString(for: shortcut)
    }

    // MARK: Recording

    private func toggleRecording() {
        if isRecording { cancelRecording() } else { startRecording() }
    }

    private func startRecording() {
        rejection = nil
        isRecording = true
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            // Swallow the event: a chord being recorded must not also reach the app.
            return nil
        }
    }

    private func cancelRecording() {
        isRecording = false
        stopMonitor()
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        // Escape with no modifiers is how the user backs out; recording ⎋ itself
        // would leave no way to abandon a mis-press.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 && flags.isEmpty {
            cancelRecording()
            return
        }
        if event.keyCode == 51 && flags.isEmpty {
            clear()
            cancelRecording()
            return
        }

        let significant: NSEvent.ModifierFlags = [.command, .control, .option]
        guard !flags.intersection(significant).isEmpty else {
            // A bare key, or Shift plus a key, would fire while the user is typing
            // anywhere on the system.
            rejection = "Include ⌘, ⌃ or ⌥."
            return
        }

        let recorded = AirStatKit.KeyboardShortcut(keyCode: event.keyCode,
                                                  modifierFlags: flags.rawValue,
                                                  characters: event.charactersIgnoringModifiers ?? "")
        settings.update { $0.shortcuts.bindings[action] = recorded }
        rejection = nil
        cancelRecording()
    }

    private func clear() {
        settings.update { $0.shortcuts.bindings[action] = nil }
        rejection = nil
    }
}
