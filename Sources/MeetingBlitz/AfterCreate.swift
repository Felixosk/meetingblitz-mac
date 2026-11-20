import Foundation

/// Runde 121: Schließt sich das Widget nach „New Meeting"? Nur bei Erfolg ohne Mail-Fehler und wenn
/// „Widget offen lassen" aus ist. Das Sofort-Meeting (Blitz) fragt das nie (5-s-Rückgängig bleibt sichtbar).
enum AfterCreate {
    static func closeWidget(keepOpen: Bool, success: Bool, mailFailed: Bool) -> Bool {
        success && !mailFailed && !keepOpen
    }

    static func failures() -> [String] {
        var out: [String] = []
        if !closeWidget(keepOpen: false, success: true, mailFailed: false) { out.append("Widget schließen: Standard (aus) + Erfolg muss schließen") }
        if closeWidget(keepOpen: true, success: true, mailFailed: false) { out.append("Widget schließen: offen lassen an darf nicht schließen") }
        if closeWidget(keepOpen: false, success: false, mailFailed: false) { out.append("Widget schließen: Fehler darf nicht schließen") }
        if closeWidget(keepOpen: false, success: true, mailFailed: true) { out.append("Widget schließen: Mail-Fehler darf nicht schließen") }
        return out
    }
}

/// Runde 122: Testschalter für „Erstellen" ohne echten Termin. Nur über die Umgebungsvariable MB_DRY_CREATE=1.
enum DryCreate {
    static let isOn = ProcessInfo.processInfo.environment["MB_DRY_CREATE"] == "1"
    static let fakeLink = "https://meet.google.com/dry-test-run"
    /// Runde 122b: der simulierte Termin, NUR im Speicher. Kalender-Abfragen der App hängen ihn an, als stünde er im
    /// Kalender (Agenda, Next up, Banner). Ohne Testmodus immer leer.
    @MainActor static var fakeMeetings: [Meeting] = []
    /// MB_DRY_START_MIN: Beginn des Fake-Termins in Minuten ab jetzt (z. B. 0.5 = sofort, 30). Fehlt er: Zeit aus dem Fenster.
    static var startOverrideMinutes: Double? { ProcessInfo.processInfo.environment["MB_DRY_START_MIN"].flatMap(Double.init) }
}
