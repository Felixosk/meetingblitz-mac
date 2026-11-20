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
        out += zoneFailures()
        return out
    }

    /// Runde 86: Zone direkt hinter der Uhrzeit. Erwartet wird die Zeit in
    /// BERLIN (Kalender der Tests), damit Versatz, Sommerzeit und Tageswechsel
    /// geprüft sind und nicht nur das Wiedererkennen des Wortes.
    private static func zoneFailures() -> [String] {
        var out: [String] = []
        let c = cal
        let table = ZoneNames.quickAddTable(saved: [])
        // (jetzt, Eingabe, Titel, Tag, Stunde, Minute, Zone)
        let lateOct = c.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 10, minute: 0))!
        let cases: [(Date, String, String, Int, Int, Int, String?)] = [
            // Manila +8, Berlin im August +2 → 6 h zurück
            (now, "morgen 17:00 manila call", "call", 20, 11, 0, "Asia/Manila"),
            // Tageswechsel rückwärts: 5 Uhr Manila am 20. = 23 Uhr Berlin am 19.
            (now, "morgen 5:00 manila frühcall", "frühcall", 19, 23, 0, "Asia/Manila"),
            // Kürzel meint die Zone: im August ist New York auf Sommerzeit (−4)
            (now, "tomorrow 3pm EST sync", "sync", 20, 21, 0, "America/New_York"),
            // Sommerzeit-Lücke: Europa ist am 25.10. umgestellt, die USA erst am
            // 1.11. → am 27.10. liegen Berlin und New York nur 5 h auseinander
            (lateOct, "tomorrow 3pm EST sync", "sync", 27, 20, 0, "America/New_York"),
            // „in london", Bereich mit Dauer
            (now, "fr 10-11 in london review", "review", 21, 11, 0, "Europe/London"),
            // Ortsname NICHT direkt hinter der Zeit: bleibt Titel, Zeit = Berlin
            (now, "call london team 10 uhr", "call london team", 20, 10, 0, nil),
            // „ist" ist kein Kürzel für Indien
            (now, "morgen 10 uhr ist wichtig", "ist wichtig", 20, 10, 0, nil),
        ]
        for (ref, input, title, day, h, m, zone) in cases {
            guard let got = QuickAdd.parse(input, now: ref, calendar: c, zones: table) else {
                out.append("Zone: „\(input)\" wurde gar nicht erkannt"); continue
            }
            let d = c.dateComponents([.day, .hour, .minute], from: got.start)
            if got.title != title || d.day != day || d.hour != h || d.minute != m || got.zoneID != zone {
                out.append("Zone: „\(input)\"\n   erwartet: \(title) · \(day). \(h):\(String(format: "%02d", m)) · \(zone ?? "-")"
                           + "\n   bekommen: \(describe(got, c)) · \(got.zoneID ?? "-")")
            }
        }
        // Schieber: Manila auf 17:00 ziehen → Nicosia 11:00, auch über Mitternacht
        let ln = TimeZone(identifier: "Asia/Nicosia")!, mn = TimeZone(identifier: "Asia/Manila")!
        var lc = Calendar(identifier: .gregorian); lc.timeZone = ln
        let s0 = lc.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 23, minute: 30))!
        let moved = ZoneMath.move(s0, toLocalMinutes: 17 * 60, in: mn)
        let mc = lc.dateComponents([.day, .hour], from: moved)
        if mc.day != 18 || mc.hour != 11 {
            out.append("Schieber Manila 17:00: erwartet 18. 11:00 Nicosia, bekommen \(mc.day ?? -1). \(mc.hour ?? -1):00")
        }
        out += round87Failures()
        return out
    }

    /// Runde 87: Befunde aus dem Review.
    private static func round87Failures() -> [String] {
        var out: [String] = []
        let ln = TimeZone(identifier: "Asia/Nicosia")!, mn = TimeZone(identifier: "Asia/Manila")!
        var lc = Calendar(identifier: .gregorian); lc.timeZone = ln
        func at(_ d: Int, _ m: Int, _ h: Int, _ mi: Int = 0) -> Date {
            lc.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: mi))!
        }
        // 1. Startliste hakt nichts an (sonst Manila in jeder Einladung).
        if !ZoneBook.invitedIDs(from: ZoneBook.seed).isEmpty {
            out.append("Startliste: es ist eine Zone vorab angehakt")
        }
        // 2. Schieber am Umstellungstag: Nicosia 25.10.2026 (04:00 → 03:00),
        //    02:00 auf 06:00 ziehen muss 06:00 ergeben, nicht 05:00.
        let moved = ZoneMath.move(at(25, 10, 2), toLocalMinutes: 6 * 60, in: ln)
        let mh = lc.dateComponents([.day, .hour], from: moved)
        if mh.day != 25 || mh.hour != 6 {
            out.append("Schieber Umstellungstag: erwartet 25. 06:00, bekommen \(mh.day ?? -1). \(mh.hour ?? -1):00")
        }
        // 3. Zweibuchstaben-Kürzel sind keine Zonen mehr.
        if let p = QuickAdd.parse("morgen 10 uhr et al review", now: now, calendar: cal,
                                  zones: ZoneNames.quickAddTable(saved: [])), p.zoneID != nil {
            out.append("„10 uhr et al" + "\" wurde als Zone gelesen: \(p.zoneID!)")
        }
        // 4. Eigener Name landet in der Einladung, Standard ist neutral.
        let labels = ZoneBook.labels(from: [SavedZone(id: "Europe/Lisbon", on: true, label: "Cascais")])
        if ZoneBook.displayName("Europe/Lisbon", labels: labels) != "Cascais"
            || ZoneBook.displayName("Europe/Lisbon", labels: [:]) != "Lisbon"
            || ZoneBook.displayName("Asia/Nicosia", labels: [:]) != "Nicosia" {
            out.append("Zonennamen: eigener Name oder neutraler Standard stimmt nicht")
        }
        let invite = MainActor.assumeIsolated {
            GoogleService.inviteTimes(start: at(17, 11, 11), end: at(17, 11, 12),
                                      zoneIDs: ["Europe/Lisbon"], labels: labels)
        }
        if !invite.contains("Cascais") { out.append("Einladung ohne eigenen Namen: \(invite)") }
        //    eigener Name auch im Freitext („17:00 porto")
        let t = ZoneNames.quickAddTable(saved: [SavedZone(id: "Europe/Lisbon", on: false, label: "Cascais")])
        if t["cascais"] != "Europe/Lisbon" { out.append("Freitext kennt den eigenen Namen „Cascais“ nicht") }
        return out
    }

    private static func describe(_ e: ParsedEvent, _ c: Calendar) -> String {
        let d = c.dateComponents([.day, .hour, .minute], from: e.start)
        return "\(e.title) · \(d.day ?? 0). \(d.hour ?? 0):\(String(format: "%02d", d.minute ?? 0)) · \(e.minutes)min"
            + (e.confident ? "" : " (unsicher)")
    }
}
