import Foundation

/// Translates a string. The key is the Norwegian source text; English lives in
/// Resources/en.lproj/Localizable.strings. If a translation is missing, the key is shown.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Translates a string with placeholders (%@, %d).
func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}

/// The language the app is actually shown in (used for date formatting).
var appLocale: Locale {
    Locale(identifier: Bundle.main.preferredLocalizations.first ?? "nb")
}
