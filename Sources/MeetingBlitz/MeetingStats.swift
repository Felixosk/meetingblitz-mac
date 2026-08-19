import Foundation
import EventKit

/// Auswertung: wie viel Zeit ging in Termine? (Wunsch 19.08.)
///
/// Bewusst in einem EIGENEN Einstellungs-Reiter statt irgendwo dazwischen —
/// sonst wächst die Seite immer weiter zu. Und bewusst schlicht: die App ist
/// eine Erinnerung, keine Auswertungs-Suite. Zwei Zeiträume, drei Zahlen.
/// Ein Balken der Auswertung: ein Tag (Wochenansicht) oder eine Woche
/// (Monatsansicht).
struct StatBar: Identifiable {
    let id: Int
    let label: String       // „Mo", „17."
    let minutes: Int
    let callMinutes: Int
    let isNow: Bool         // heute bzw. laufende Woche → hervorheben
}

struct MeetingStats {
    var count: Int          // Termine gesamt
    var callCount: Int      // davon mit Videolink
    var minutes: Int        // Gesamtdauer
    var callMinutes: Int    // davon in Videocalls
    var busiestDay: (label: String, minutes: Int)?
    var bars: [StatBar] = []

    var hoursLabel: String { Self.hm(minutes) }
    var callHoursLabel: String { Self.hm(callMinutes) }

    static func hm(_ m: Int) -> String {
        m < 60 ? "\(m) min" : String(format: "%.1f", Double(m) / 60.0) + " h"
    }
}
