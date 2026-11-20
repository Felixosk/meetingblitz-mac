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
    /// Runde 86: „17:00 manila" → die Uhrzeit gilt in dieser Zone.
    var zoneID: String? = nil
}

/// Runde 113: Ergebnis von `QuickAdd.scan` (Teile mit Position im ORIGINALTEXT).
struct QuickScan {
    enum Kind { case day, time, duration, zone }
    var tokens: [(range: NSRange, kind: Kind)] = []
    /// Aufgelöster Tag (Beginn des Tages), wenn ein Tag oder eine Zeit genannt ist.
    var day: Date?
    var hour: Int?
    var minute: Int = 0
    /// Voller Beginn, nur wenn eine Uhrzeit erkannt wurde.
    var start: Date?
    var minutes: Int?
    var zoneID: String?
    var title: String
    var confident = false
    /// Es stand ein Tageswort ("fr", "morgen") da.
    var dayWord = false
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

    /// Runde 113 (B1): Erkennung MIT Positionen im Originaltext. Treffer werden durch gleich viele Leerzeichen ersetzt
    /// (nicht gelöscht), damit die Bereiche für die Markierung im Feld gültig bleiben.
    static func scan(_ raw: String, now: Date, calendar baseCal: Calendar = .current,
                     zones: [String: String]? = nil) -> QuickScan {
        var cal = baseCal
        var out = QuickScan(title: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        // 1 Zeichen Polster links, damit `(?<![\w])` am Anfang trifft; Position im Original = Position − 1.
        var text = " " + raw + " "
        guard text.count > 2 else { return out }

        func blank(_ r: Range<String.Index>, _ kind: QuickScan.Kind) {
            let ns = NSRange(r, in: text)
            // Leerraum am Rand nicht mitmarkieren.
            var loc = ns.location, len = ns.length
            let u = Array(text.utf16)
            while len > 0, u[loc] == 32 { loc += 1; len -= 1 }
            while len > 0, u[loc + len - 1] == 32 { len -= 1 }
            if len > 0 { out.tokens.append((NSRange(location: loc - 1, length: len), kind)) }
            text.replaceSubrange(r, with: String(repeating: " ", count: text[r].count))
        }

        // 1. Tag.
        var dayOffset: Int?
        var weekday: Int?
        for (word, off) in [("übermorgen", 2), ("uebermorgen", 2), ("day after tomorrow", 2),
                            ("morgen", 1), ("tomorrow", 1), ("heute", 0), ("today", 0)] {
            if let r = find(word, in: text) { blank(r, .day); dayOffset = off; break }
        }
        if dayOffset == nil {
            for (word, wd) in weekdays.sorted(by: { $0.0.count > $1.0.count }) {
                if let r = find(word, in: text) { blank(r, .day); weekday = wd; break }
            }
        }

        // 2. Zeit.
        var startH: Int?, startM = 0, endH: Int?, endM = 0
        var timePos: Int?
        if let m = firstMatch(#"(\d{1,2})(?::(\d{2}))?\s*(?:uhr|h|am|pm)?\s*(?:-|–|bis|to|until)\s*(\d{1,2})(?::(\d{2}))?\s*(?:uhr|h|am|pm)?"#, text) {
            startH = Int(m.groups[0] ?? ""); startM = Int(m.groups[1] ?? "") ?? 0
            endH = Int(m.groups[2] ?? ""); endM = Int(m.groups[3] ?? "") ?? 0
            timePos = text.distance(from: text.startIndex, to: m.range.lowerBound); blank(m.range, .time)
        } else if let m = firstMatch(#"(\d{1,2})(?::(\d{2}))\s*(uhr|h|am|pm)?"#, text) {
            startH = Int(m.groups[0] ?? ""); startM = Int(m.groups[1] ?? "") ?? 0
            // Runde 114: "7:30 pm" ist 19:30 (vorher las die Erkennung am/pm hinter Minuten nicht).
            let suffix = (m.groups[2] ?? "").lowercased()
            if suffix == "pm", let h = startH, h < 12 { startH = h + 12 }
            if suffix == "am", startH == 12 { startH = 0 }
            timePos = text.distance(from: text.startIndex, to: m.range.lowerBound); blank(m.range, .time)
        } else if let m = firstMatch(#"(\d{1,2})\s*(uhr|am|pm|a\.m\.|p\.m\.)"#, text) {
            startH = Int(m.groups[0] ?? "")
            let suffix = (m.groups[1] ?? "").lowercased()
            if suffix.hasPrefix("p"), let h = startH, h < 12 { startH = h + 12 }
            if suffix.hasPrefix("a"), startH == 12 { startH = 0 }
            timePos = text.distance(from: text.startIndex, to: m.range.lowerBound); blank(m.range, .time)
        } else if let m = firstMatch(#"(?<![\w:])(\d{1,2})(?![\w:])"#, text) {
            // Runde 113: eine nackte Zahl ist NUR eine Uhrzeit, wenn direkt davor ein Tag oder "um/at" steht
            // ("fr 10 call", "call at 3"). Sonst bleibt sie im Titel ("Call 2").
            let h = Int(m.groups[0] ?? "") ?? 99
            let before = String(text[text.startIndex..<m.range.lowerBound])
            let prevWord = before.split(whereSeparator: { $0 == " " }).last.map(String.init)?.lowercased()
            let L = NSRange(m.range, in: text).location
            let u = Array(text.utf16)
            let dayBefore = out.tokens.contains { t in
                guard t.kind == .day else { return false }
                let end = t.range.location + 1 + t.range.length
                return end <= L && (end..<L).allSatisfy { u[$0] == 32 }
            }
            if (0...23).contains(h), dayBefore || prevWord == "um" || prevWord == "at" {
                startH = h; timePos = text.distance(from: text.startIndex, to: m.range.lowerBound); blank(m.range, .time)
            }
        }
        // „um"/„at" direkt vor der Zeit gehören zum Zeit-Teil, nicht zum Titel (nur Titelrand-Bereinigung unten).

        // 2b. Zone direkt hinter der Zeit.
        var zoneID: String?
        if startH != nil, let pos = timePos, pos <= text.count {
            let table = zones ?? ZoneNames.quickAddTable()
            let rest = String(text[text.index(text.startIndex, offsetBy: pos)...])
            for key in table.keys.sorted(by: { $0.count > $1.count }) {
                let pattern = #"^\s*(?:in\s+)?\(?"# + NSRegularExpression.escapedPattern(for: key) + #"\)?(?![\wäöüß])"#
                if let m = firstMatch(pattern, rest), let id = table[key], let tz = TimeZone(identifier: id) {
                    let from = text.index(text.startIndex, offsetBy: pos)
                    let len = rest.distance(from: rest.startIndex, to: m.range.upperBound)
                    blank(from..<text.index(from, offsetBy: len), .zone)
                    zoneID = id
                    cal.timeZone = tz
                    break
                }
            }
        }

        // 3. Dauer.
        var minutes: Int?
        if let m = firstMatch(#"(\d+(?:[.,]\d+)?)\s*(stunden|stunde|std|hrs|hr|h)(?![\w])"#, text) {
            let v = Double((m.groups[0] ?? "0").replacingOccurrences(of: ",", with: ".")) ?? 0
            if v > 0 { minutes = Int(v * 60); blank(m.range, .duration) }
        } else if let m = firstMatch(#"(\d{1,3})\s*(minuten|minute|mins|min|m)(?![\w])"#, text) {
            if let v = Int(m.groups[0] ?? ""), v > 0 { minutes = v; blank(m.range, .duration) }
        }
        if minutes == nil, let eh = endH, let sh = startH {
            var diff = (eh * 60 + endM) - (sh * 60 + startM)
            if diff <= 0 { diff += 24 * 60 }
            minutes = diff
        }
        out.minutes = minutes
        out.zoneID = zoneID

        // 4. Datum (nur wenn Tag oder Zeit da sind).
        let today = cal.startOfDay(for: now)
        var day = today
        if let off = dayOffset {
            day = cal.date(byAdding: .day, value: off, to: today) ?? today
        } else if let wd = weekday {
            for i in 0..<7 {
                let d = cal.date(byAdding: .day, value: i, to: today) ?? today
                if cal.component(.weekday, from: d) == wd { day = d; break }
            }
        }
        if let hour = startH, (0...23).contains(hour), (0...59).contains(startM) {
            out.hour = hour; out.minute = startM
            var start = cal.date(bySettingHour: hour, minute: startM, second: 0, of: day) ?? day
            if dayOffset == nil, weekday == nil, start <= now { start = cal.date(byAdding: .day, value: 1, to: start) ?? start }
            if let wd = weekday, cal.component(.weekday, from: start) == wd, start <= now {
                start = cal.date(byAdding: .day, value: 7, to: start) ?? start
            }
            out.start = start
            out.day = cal.startOfDay(for: start)
        } else if dayOffset != nil || weekday != nil {
            // Nur ein Tag: Wochentag in der Vergangenheit von heute aus nach vorn.
            out.day = day
        }
        out.confident = out.hour != nil
        out.dayWord = dayOffset != nil || weekday != nil

        // 5. Titel.
        var title = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        for filler in ["um", "at", "von", "from", "ab"] {
            if title.lowercased().hasPrefix(filler + " ") { title = String(title.dropFirst(filler.count + 1)) }
            if title.lowercased().hasSuffix(" " + filler) { title = String(title.dropLast(filler.count + 1)) }
        }
        out.title = title.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–"))
        out.tokens.sort { $0.range.location < $1.range.location }
        return out
    }

    static func parse(_ raw: String, now: Date, calendar baseCal: Calendar = .current,
                      zones: [String: String]? = nil) -> ParsedEvent? {
        let sc = scan(raw, now: now, calendar: baseCal, zones: zones)
        guard let start = sc.start else { return nil }
        return ParsedEvent(title: sc.title, start: start, minutes: max(5, sc.minutes ?? defaultMinutes),
                           confident: true, zoneID: sc.zoneID)
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
