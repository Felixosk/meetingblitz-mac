import Foundation

/// Runde 79: Wem gehört die Menüleiste, solange ein Termin läuft?
///
/// Bis hierher galt „laufender Termin schlägt alles": die Leiste zeigte bis zur
/// letzten Minute „Titel · noch 54m". Sitzt man selbst in dem Gespräch, ist das
/// die eine Information, die man nicht braucht, und die einzige, die man
/// wirklich braucht, fehlt: wann das NÄCHSTE losgeht, also wie lange man
/// überziehen darf.
///
/// Reine Rechnerei ohne `AppState`, damit `--selftest` sie prüfen kann, ohne
/// die echten Nutzereinstellungen anzufassen (gleiche Bauart wie
/// `SkinRotationEngine`).
enum MenuBarFocus {

    /// Wählbare Schwellen für die Einstellung. 0 = aus, laufender Termin bleibt
    /// bis zum Ende stehen (das alte Verhalten).
    static let choices = [0, 5, 10, 15, 30]

    /// `true` = die Menüleiste zeigt weiter das LAUFENDE Meeting.
    /// `false` = sie tritt zurück und zeigt den nächsten Termin.
    ///
    /// - Parameter runningFor: wie lange das laufende Meeting schon läuft.
    /// - Parameter afterMinutes: die Einstellung, 0 heißt aus.
    /// - Parameter hasNext: gibt es überhaupt einen nächsten Termin? Ohne einen
    ///   wird nicht umgeschaltet, sonst tauscht man eine Information gegen ein
    ///   leeres Symbol.
    static func showsCurrent(runningFor seconds: TimeInterval,
                             afterMinutes: Int,
                             hasNext: Bool) -> Bool {
        guard afterMinutes > 0, hasNext else { return true }
        return seconds < Double(afterMinutes) * 60
    }
}
