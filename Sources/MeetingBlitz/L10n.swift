import Foundation

/// App-wide language switch (Runde 35): every user-facing string goes through
/// `L.t(de, en)`. The language lives in UserDefaults ("appLanguage", set from
/// the settings panel via AppState.appLanguage, @Published, so every observing
/// view re-renders live on change and re-reads the fresh value here).
enum L {
    static var lang: String {
        UserDefaults.standard.string(forKey: "appLanguage")
            ?? UserDefaults.standard.string(forKey: "shareLanguage")   // pre-rename key
            ?? "en"
    }

    static var isDE: Bool { lang == "de" }

    static func t(_ de: String, _ en: String) -> String { isDE ? de : en }

    /// Locale for user-facing date text (weekday/month names).
    static var locale: Locale { Locale(identifier: isDE ? "de_DE" : "en_US") }

    // MARK: - Einladungssprache (Runde 50)

    /// Sprache des Einladungstextes, getrennt von der Oberfläche: bedient wird
    /// die App auf Deutsch, seine Empfänger lesen aber Englisch. „auto" folgt
    /// der App-Sprache, sonst gewinnt die Einstellung.
    static var inviteLang: String {
        let v = UserDefaults.standard.string(forKey: "inviteLanguage") ?? "en"
        return v == "auto" ? lang : v
    }

    static var inviteIsDE: Bool { inviteLang == "de" }

    /// Wie `t`, aber für Text, der an EMPFÄNGER geht (Einladungsblock).
    static func invite(_ de: String, _ en: String) -> String { inviteIsDE ? de : en }

    static var inviteLocale: Locale { Locale(identifier: inviteIsDE ? "de_DE" : "en_US") }
}
