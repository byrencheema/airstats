import Foundation

/// User-selected display language.
public enum AppLanguage: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case system, english, vietnamese

    public var resolved: ResolvedLanguage {
        switch self {
        case .english: return .english
        case .vietnamese: return .vietnamese
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.lowercased().hasPrefix("vi") ? .vietnamese : .english
        }
    }

    public var label: String {
        switch self {
        case .system: return L10n.tr("Match System", "Theo hệ thống")
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        }
    }
}

public enum ResolvedLanguage: Sendable, Equatable {
    case english, vietnamese
}

/// Lightweight bilingual helper shared across `AirStatKit`, `AirStatUI`, and `AirStats`.
///
/// Direct lookup keeps localization working identically inside SwiftPM test binaries,
/// the `--probe` / `--render` CLI, and assembled `.app` bundles without bundle-lookup
/// mismatches, and lets the user switch language live without restarting the app.
public enum L10n {
    public static func tr(_ en: String, _ vi: String,
                          language: ResolvedLanguage = SettingsStore.currentLanguage.resolved) -> String {
        language == .vietnamese ? vi : en
    }

    public static func tr(_ en: String, _ vi: String, language: AppLanguage) -> String {
        tr(en, vi, language: language.resolved)
    }
}
