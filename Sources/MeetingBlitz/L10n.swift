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

    // MARK: - Runde 111: EINE Quelle für Zeit, Datum, Zahlen (App-Sprache, nie das Systemformat)

    /// Uhrzeit nach App-Sprache: EN 12 h ("8:45 PM"), DE 24 h ("20:45"). Alle Anzeigen nehmen diesen Formatter.
    static func timeFormatter(_ tz: TimeZone = .current) -> DateFormatter {
        let f = DateFormatter(); f.locale = locale; f.timeZone = tz
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale) ?? "HH:mm"
        return f
    }

    static func time(_ d: Date, _ tz: TimeZone = .current) -> String { timeFormatter(tz).string(from: d) }

    /// Datum nach Vorlage ("MMMd", "EEEMMMd", "LLLLyyyy"): immer lokalisiert, nie ein festes Muster.
    static func date(_ d: Date, _ template: String, _ tz: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = locale; f.timeZone = tz
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: d)
    }

    /// Zeitraum "Nov 16 – 22" / "16.–22. Nov.".
    static func dateRange(_ a: Date, _ b: Date, _ template: String = "MMMd") -> String {
        let f = DateIntervalFormatter(); f.locale = locale; f.dateTemplate = template
        return f.string(from: a, to: b)
    }

    /// Zahl mit Tausender-/Dezimalzeichen der App-Sprache.
    static func number(_ v: Double, fraction: Int = 0) -> String {
        v.formatted(.number.precision(.fractionLength(fraction)).locale(locale))
    }
    static func number(_ v: Int) -> String { v.formatted(.number.locale(locale)) }
}
