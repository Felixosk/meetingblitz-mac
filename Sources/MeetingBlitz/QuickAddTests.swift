import Foundation

/// Selbsttest der Freitext-Eingabe (F8), Teil von `--selftest`.
///
/// Bezugszeitpunkt ist fest verdrahtet (Mittwoch, 19.08.2026, 11:00), sonst
/// wären „morgen" und „freitag" nicht reproduzierbar. Genau deshalb nimmt
/// `QuickAdd.parse` das „jetzt" als Parameter entgegen.
enum QuickAddTests {

    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }

    private static var now: Date {
        cal.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 11, minute: 0))!
    }

    /// (Eingabe, Titel, Tag, Stunde, Minute, Dauer). nil = darf NICHT erkannt werden.
    private static let cases: [(String, (title: String, day: Int, h: Int, m: Int, mins: Int)?)] = [
        // Wochentag + Zeitbereich
        ("fr 10-12 call mit chris", ("call mit chris", 21, 10, 0, 120)),
        ("freitag 9:30-11 review",  ("review", 21, 9, 30, 90)),
        // Gemeldet 19.08.: „16 uhr bis 17 uhr" muss ein ZEITRAUM sein. Vorher
        // blieb „bis 17 uhr" im Titel stehen und die Dauer fiel auf 30 zurück.
        ("fr 16 uhr bis 17 uhr call mit chris", ("call mit chris", 21, 16, 0, 60)),
        ("fr 16 uhr call mit chris", ("call mit chris", 21, 16, 0, 30)),
        ("morgen 10 uhr - 11 uhr sync", ("sync", 20, 10, 0, 60)),
        // Relative Tage
        ("morgen 14 uhr standup",   ("standup", 20, 14, 0, 30)),
        ("heute 16:00 kurzes gespräch", ("kurzes gespräch", 19, 16, 0, 30)),
        ("übermorgen 8 uhr frühstück", ("frühstück", 21, 8, 0, 30)),
        // Dauer in verschiedenen Schreibweisen
        ("morgen 9 uhr 1,5h workshop", ("workshop", 20, 9, 0, 90)),
        ("morgen 9 uhr 45min sync",    ("sync", 20, 9, 0, 45)),
        ("morgen 9 uhr 2 stunden klausur", ("klausur", 20, 9, 0, 120)),
        // Englisch
        ("tomorrow 3pm sync with anna", ("sync with anna", 20, 15, 0, 30)),
        ("fri 10-12 call with chris",   ("call with chris", 21, 10, 0, 120)),
        ("mon 9:30 1h review",          ("review", 24, 9, 30, 60)),
        // Ohne Tagesangabe: heute, wenn die Zeit noch kommt …
        ("14:30 kurzes gespräch", ("kurzes gespräch", 19, 14, 30, 30)),
        // … sonst morgen (09:00 ist um 11:00 schon vorbei)
        ("9:00 rückblick", ("rückblick", 20, 9, 0, 30)),
        // Wochentag, dessen Zeit heute vorbei ist → nächste Woche
        ("mittwoch 9:00 jour fixe", ("jour fixe", 26, 9, 0, 30)),
        // Über Mitternacht
        ("heute 22-1 nachtschicht", ("nachtschicht", 19, 22, 0, 180)),
        // Ohne jede Zeitangabe: ungültig, lieber gar nichts als geraten
        ("call mit anna", nil),
        ("", nil),
    ]

    static func failures() -> [String] {
        var out: [String] = []
        let c = cal
        for (input, want) in cases {
            let got = QuickAdd.parse(input, now: now, calendar: c)
            guard let want else {
                if got != nil { out.append("„\(input)" + "\" durfte NICHT erkannt werden, wurde aber zu \(describe(got!, c))") }
                continue
            }
            guard let got else { out.append("„\(input)\" wurde gar nicht erkannt"); continue }
            let d = c.dateComponents([.day, .hour, .minute], from: got.start)
            if got.title != want.title || d.day != want.day || d.hour != want.h
                || d.minute != want.m || got.minutes != want.mins {
                out.append("„\(input)\"\n   erwartet: \(want.title) · \(want.day). \(want.h):\(String(format: "%02d", want.m)) · \(want.mins)min"
                           + "\n   bekommen: \(describe(got, c))")
            }
        }
        // Nackte Zahl darf erkannt werden, aber NUR als unsicher — die Vorschau
        // färbt das ein, damit niemand blind Enter drückt.
        if let g = QuickAdd.parse("call 22", now: now, calendar: c), g.confident {
            out.append("„call 22" + "\" muss als unsicher gelten, wurde aber als sicher gemeldet")
        }
        return out
    }

    private static func describe(_ e: ParsedEvent, _ c: Calendar) -> String {
        let d = c.dateComponents([.day, .hour, .minute], from: e.start)
        return "\(e.title) · \(d.day ?? 0). \(d.hour ?? 0):\(String(format: "%02d", d.minute ?? 0)) · \(e.minutes)min"
            + (e.confident ? "" : " (unsicher)")
    }
}
