import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ru, en

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return tr("Как в системе", "System")
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}

/// Picks the Russian or English string for the current interface language.
/// Views that observe `Preferences` re-render when the language changes.
func tr(_ ru: String, _ en: String) -> String { L10n.isEnglish ? en : ru }

enum L10n {
    static var isEnglish: Bool {
        switch Preferences.shared.language {
        case .ru: return false
        case .en: return true
        case .system: return !(Locale.preferredLanguages.first ?? "en").hasPrefix("ru")
        }
    }

    static var locale: Locale { Locale(identifier: isEnglish ? "en_US" : "ru_RU") }
}
