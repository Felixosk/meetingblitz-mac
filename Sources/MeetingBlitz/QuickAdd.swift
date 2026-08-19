import Foundation

/// Ergebnis einer Freitext-Eingabe (F8).
struct ParsedEvent: Equatable {
    var title: String
    var start: Date
    var minutes: Int
    /// Wie sicher die Zeit erkannt wurde. Niedrig heißt: es stand nur eine
    /// nackte Zahl da („call 22"), das kann auch ein Namensbestandteil sein.
    /// Die Vorschau färbt das ein, statt es zu verschweigen.
    var confident: Bool
}

/// Freitext zu Termin (F8): „fr 10-12 call mit chris", „morgen 14 uhr standup".
///
/// Bewusst KEIN NSDataDetector als Hauptweg: der versteht deutsche
/// Wochentagskürzel nicht zuverlässig und deutet nackte Zahlen gern als
/// Uhrzeit. Hier wird stattdessen Schritt für Schritt erkannt und jeder
/// Treffer aus dem Text entfernt; was übrig bleibt, ist der Titel. Dadurch ist
/// jeder Schritt einzeln prüfbar (`--selftest`).
///
/// `now` ist ein Parameter, damit die Erkennung testbar ist — mit `Date()` im
/// Inneren wären die Fälle nicht reproduzierbar.
enum QuickAdd {

    static let defaultMinutes = 30

    /// Wochentage in beiden Sprachen → `Calendar`-Wochentag (1 = Sonntag).
    private static let weekdays: [(String, Int)] = [
        ("montag", 2), ("monday", 2), ("mo", 2), ("mon", 2),
        ("dienstag", 3), ("tuesday", 3), ("di", 3), ("tue", 3), ("tues", 3),
        ("mittwoch", 4), ("wednesday", 4), ("mi", 4), ("wed", 4),
        ("donnerstag", 5), ("thursday", 5), ("do", 5), ("thu", 5), ("thur", 5),
        ("freitag", 6), ("friday", 6), ("fr", 6), ("fri", 6),
        ("samstag", 7), ("saturday", 7), ("sa", 7), ("sat", 7), ("sonnabend", 7),
        ("sonntag", 1), ("sunday", 1), ("so", 1), ("sun", 1),
    ]

    static func parse(_ raw: String, now: Date, calendar cal: Calendar = .current) -> ParsedEvent? {
        var text = " " + raw.trimmingCharacters(in: .whitespacesAndNewlines) + " "
        guard text.count > 1 else { return nil }

        // 1. Tag. Ohne Angabe: heute (bzw. morgen, wenn die Zeit schon vorbei ist).
        var dayOffset: Int?
        var weekday: Int?
        for (word, off) in [("übermorgen", 2), ("uebermorgen", 2), ("day after tomorrow", 2),
                            ("morgen", 1), ("tomorrow", 1), ("heute", 0), ("today", 0)] {
            if let r = find(word, in: text) { text.removeSubrange(r); dayOffset = off; break }
        }
        if dayOffset == nil {
            for (word, wd) in weekdays.sorted(by: { $0.0.count > $1.0.count }) {
                if let r = find(word, in: text) { text.removeSubrange(r); weekday = wd; break }
            }
        }

        // 2. Zeit: erst Bereich („10-12", „9:30 – 11"), sonst Einzelzeit.
        var startH: Int?, startM = 0, endH: Int?, endM = 0
        var confident = false
        // „16-17", „9:30 – 11", aber AUCH „16 uhr bis 17 uhr": das Wort zwischen
        // Zahl und Trenner muss erlaubt sein, sonst bleibt „bis 17 uhr" im
        // Titel stehen und die Dauer fällt auf 30 Minuten zurück.
        if let m = firstMatch(#"(\d{1,2})(?::(\d{2}))?\s*(?:uhr|h|am|pm)?\s*(?:-|–|bis|to|until)\s*(\d{1,2})(?::(\d{2}))?\s*(?:uhr|h|am|pm)?"#, text) {
            startH = Int(m.groups[0] ?? ""); startM = Int(m.groups[1] ?? "") ?? 0
            endH = Int(m.groups[2] ?? ""); endM = Int(m.groups[3] ?? "") ?? 0
            text.removeSubrange(m.range); confident = true
        } else if let m = firstMatch(#"(\d{1,2})(?::(\d{2}))\s*(uhr|h)?"#, text) {
            // Mit Doppelpunkt ist es eindeutig eine Uhrzeit.
            startH = Int(m.groups[0] ?? ""); startM = Int(m.groups[1] ?? "") ?? 0
            text.removeSubrange(m.range); confident = true
        } else if let m = firstMatch(#"(\d{1,2})\s*(uhr|am|pm|a\.m\.|p\.m\.)"#, text) {
            // „14 uhr", „3pm" — das Wort macht es eindeutig.
            startH = Int(m.groups[0] ?? "")
            let suffix = (m.groups[1] ?? "").lowercased()
            if suffix.hasPrefix("p"), let h = startH, h < 12 { startH = h + 12 }
            if suffix.hasPrefix("a"), startH == 12 { startH = 0 }
            text.removeSubrange(m.range); confident = true
        } else if let m = firstMatch(#"(?<![\w:])(\d{1,2})(?![\w:])"#, text) {
            // Nackte Zahl: könnte die Uhrzeit sein, könnte auch zum Titel
            // gehören („Call 2"). Übernehmen, aber als unsicher markieren.
            let h = Int(m.groups[0] ?? "") ?? 99
            if (0...23).contains(h) { startH = h; text.removeSubrange(m.range); confident = false }
        }
        guard let hour = startH, (0...23).contains(hour), (0...59).contains(startM) else { return nil }

        // 3. Dauer („1,5h", „45min", „1 std"), sonst aus dem Bereich, sonst 30.
        var minutes: Int?
        if let m = firstMatch(#"(\d+(?:[.,]\d+)?)\s*(stunden|stunde|std|hrs|hr|h)(?![\w])"#, text) {
            let v = Double((m.groups[0] ?? "0").replacingOccurrences(of: ",", with: ".")) ?? 0
            if v > 0 { minutes = Int(v * 60); text.removeSubrange(m.range) }
        } else if let m = firstMatch(#"(\d{1,3})\s*(minuten|minute|mins|min|m)(?![\w])"#, text) {
            if let v = Int(m.groups[0] ?? ""), v > 0 { minutes = v; text.removeSubrange(m.range) }
        }
        if minutes == nil, let eh = endH {
            var diff = (eh * 60 + endM) - (hour * 60 + startM)
            if diff <= 0 { diff += 24 * 60 }        // „22-1" = über Mitternacht
            minutes = diff
        }

        // 4. Datum zusammensetzen.
        let today = cal.startOfDay(for: now)
        var day = today
        if let off = dayOffset {
            day = cal.date(byAdding: .day, value: off, to: today) ?? today
        } else if let wd = weekday {
            // Nächster Tag mit diesem Wochentag, heute eingeschlossen.
            for i in 0..<7 {
                let d = cal.date(byAdding: .day, value: i, to: today) ?? today
                if cal.component(.weekday, from: d) == wd { day = d; break }
            }
        }
        var start = cal.date(bySettingHour: hour, minute: startM, second: 0, of: day) ?? day
        // Ohne Tagesangabe und die Zeit ist heute schon vorbei: morgen meinen.
        if dayOffset == nil, weekday == nil, start <= now {
            start = cal.date(byAdding: .day, value: 1, to: start) ?? start
        }
        // Wochentag genannt, aber die Zeit heute schon vorbei: nächste Woche.
        if let wd = weekday, cal.component(.weekday, from: start) == wd, start <= now {
            start = cal.date(byAdding: .day, value: 7, to: start) ?? start
        }

        // 5. Rest ist der Titel: Füllwörter am Rand weg, Rest unverändert lassen.
        var title = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        for filler in ["um", "at", "von", "from", "ab"] {
            if title.lowercased().hasPrefix(filler + " ") { title = String(title.dropFirst(filler.count + 1)) }
            if title.lowercased().hasSuffix(" " + filler) { title = String(title.dropLast(filler.count + 1)) }
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–"))

        return ParsedEvent(title: title,
                           start: start,
                           minutes: max(5, minutes ?? defaultMinutes),
                           confident: confident)
    }

    // MARK: - Kleine Helfer

    /// Ganzes Wort suchen, ohne mitten in einem anderen zu treffen („so" darf
    /// nicht in „Sonne" anschlagen).
    private static func find(_ word: String, in text: String) -> Range<String.Index>? {
        firstMatch("(?<![\\wäöüß])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\wäöüß])", text)?.range
    }

    private struct Match {
        let range: Range<String.Index>
        let groups: [String?]
    }

    private static func firstMatch(_ pattern: String, _ text: String) -> Match? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: ns),
              let r = Range(m.range, in: text) else { return nil }
        var groups: [String?] = []
        for i in 1..<m.numberOfRanges {
            groups.append(Range(m.range(at: i), in: text).map { String(text[$0]) })
        }
        return Match(range: r, groups: groups)
    }
}
