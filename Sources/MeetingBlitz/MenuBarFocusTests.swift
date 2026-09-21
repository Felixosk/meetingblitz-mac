import Foundation

/// Selbsttest der Menüleisten-Umschaltung (21.09.2026), Teil von `--selftest`.
enum MenuBarFocusTests {

    static func failures() -> [String] {
        var out: [String] = []

        func check(_ label: String,
                   _ got: Bool,
                   _ want: Bool) {
            if got != want { out.append("MenuBarFocus: \(label) ergab \(got), erwartet \(want)") }
        }

        // Aus (0) heißt: der laufende Termin bleibt stehen, egal wie lange.
        check("aus, 3h gelaufen",
              MenuBarFocus.showsCurrent(runningFor: 3 * 3600, afterMinutes: 0, hasNext: true),
              true)

        // Genau auf der Schwelle wird schon umgeschaltet.
        check("10 Min, exakt 600s",
              MenuBarFocus.showsCurrent(runningFor: 600, afterMinutes: 10, hasNext: true),
              false)
        check("10 Min, 599s",
              MenuBarFocus.showsCurrent(runningFor: 599, afterMinutes: 10, hasNext: true),
              true)

        // Ohne nächsten Termin bleibt der laufende stehen, sonst wäre die
        // Leiste nach 10 Minuten leer.
        check("10 Min, 2h gelaufen, kein nächster",
              MenuBarFocus.showsCurrent(runningFor: 7200, afterMinutes: 10, hasNext: false),
              true)

        // Gerade erst begonnen: immer der laufende.
        check("10 Min, 5s gelaufen",
              MenuBarFocus.showsCurrent(runningFor: 5, afterMinutes: 10, hasNext: true),
              true)

        return out
    }
}
