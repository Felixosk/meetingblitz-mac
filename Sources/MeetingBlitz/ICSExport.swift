import Foundation
import AppKit

/// Erzeugt eine .ics-Kalenderdatei zum Mitschicken (Runde 47, Rückmeldung: „wenn man
/// den Kalendereintrag bestellt, bekommt man ja Textnachrichten, ich würde auch
/// eine Apple-Kalenderdatei erstellen").
///
/// Warum eine Datei UND der Textblock: der Text ist für Chat lesbar, die .ics
/// landet mit einem Doppelklick als echter Termin im Kalender des Empfängers,
/// inklusive Meet-Link, Wiederholung und 10-Minuten-Erinnerung. Beides zusammen
/// deckt beide Empfängertypen ab (WhatsApp-Leser vs. „pack's mir in den Kalender").
///
/// Format: RFC 5545. Wichtig und leicht zu übersehen:
/// - Zeilenenden MÜSSEN CRLF sein, sonst schlucken manche Clients die Datei.
/// - Zeilen über 75 Oktetts müssen gefaltet werden (CRLF + genau ein Leerzeichen).
/// - `;` `,` `\` und Zeilenumbrüche im Text müssen escaped werden.
/// Alle Zeiten schreiben wir in UTC (`…Z`), dann braucht die Datei keine
/// VTIMEZONE-Definition und jeder Client rechnet korrekt in seine Zone um.
enum ICSExport {

    /// Baut den ICS-Text für einen Termin.
    static func build(title: String, start: Date, end: Date, link: String?,
                      recurrence: RepeatRule = .none,
                      custom: CustomRecurrence? = nil) -> String {
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//MeetingBlitz//DE",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "BEGIN:VEVENT",
            "UID:\(UUID().uuidString)@meetingblitz",
            "DTSTAMP:\(utc(Date()))",
            "DTSTART:\(utc(start))",
            "DTEND:\(utc(end))",
            "SUMMARY:\(esc(title))",
        ]
        if let rrule = rrule(for: recurrence, custom: custom) { lines.append("RRULE:\(rrule)") }
        // Runde 51: Der Meet-Link steht GENAU EINMAL in der Datei, im dafür
        // vorgesehenen URL-Feld. Vorher stand er zusätzlich in LOCATION und
        // DESCRIPTION, beim Import zeigte Apple Calendar ihn deshalb dreifach
        // (Ortszeile mit Join, URL-Feld, Notizfeld). Rückmeldung: „das sollte
        // professionell sein, also nicht dreimal." Der von MeetingBlitz selbst
        // erstellte Apple-Termin macht es genauso (nur `event.url`), und dort
        // erscheint er sauber einmal.
        if let link, !link.isEmpty {
            lines.append("URL:\(esc(link))")
        }
        lines += [
            "BEGIN:VALARM",
            "TRIGGER:-PT10M",
            "ACTION:DISPLAY",
            "DESCRIPTION:\(esc(title))",
            "END:VALARM",
            "END:VEVENT",
            "END:VCALENDAR",
        ]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    /// Schreibt die Datei nach ~/Downloads (üblicher Ablageort für solche Dateien) und
    /// gibt die URL zurück. Kollidierende Namen bekommen „-2", „-3" …
    @discardableResult
    static func write(title: String, start: Date, end: Date, link: String?,
                      recurrence: RepeatRule = .none,
                      custom: CustomRecurrence? = nil) throws -> URL {
        let text = build(title: title, start: start, end: end, link: link,
                         recurrence: recurrence, custom: custom)
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmm"
        let base = "\(slug(title))_\(stamp.string(from: start))"

        var url = dir.appendingPathComponent(base).appendingPathExtension("ics")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n)").appendingPathExtension("ics")
            n += 1
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Legt die Datei als DATEI in die Zwischenablage, eingefügt in WhatsApp,
    /// Mail oder Telegram wird daraus ein Anhang, kein Pfad-Text.
    static func copyToPasteboard(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Bausteine

    private static func utc(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: d)
    }

    /// RFC-5545-Escaping für Textwerte.
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Zeilenfaltung: max. 75 Oktetts pro Zeile, Fortsetzung beginnt mit einem
    /// Leerzeichen. Gezählt wird in BYTES (Umlaute sind 2), sonst reißt die
    /// Faltung mitten durch ein UTF-8-Zeichen.
    private static func fold(_ line: String) -> String {
        guard line.utf8.count > 75 else { return line }
        var out = "", current = 0, limit = 75
        for ch in line {
            let n = String(ch).utf8.count
            if current + n > limit {
                out += "\r\n "
                current = 1        // das führende Leerzeichen zählt mit
                limit = 75
            }
            out.append(ch)
            current += n
        }
        return out
    }

    /// Spiegelt `CalendarService.recurrenceRule(for:custom:)`, dieselbe Regel,
    /// nur in ICS-Syntax, damit Datei und Apple-Termin dieselbe Serie beschreiben.
    private static func rrule(for r: RepeatRule, custom: CustomRecurrence?) -> String? {
        switch r {
        case .none:     return nil
        case .daily:    return "FREQ=DAILY;INTERVAL=1"
        case .weekly:   return "FREQ=WEEKLY;INTERVAL=1"
        case .biweekly: return "FREQ=WEEKLY;INTERVAL=2"
        case .monthly:  return "FREQ=MONTHLY;INTERVAL=1"
        case .custom:
            let c = custom ?? CustomRecurrence()
            let every = max(1, c.interval)
            switch c.unit {
            case .days:   return "FREQ=DAILY;INTERVAL=\(every)"
            case .months: return "FREQ=MONTHLY;INTERVAL=\(every)"
            case .weeks:
                let days = c.weekdays.sorted().compactMap(icsWeekday)
                let base = "FREQ=WEEKLY;INTERVAL=\(every)"
                return days.isEmpty ? base : base + ";BYDAY=" + days.joined(separator: ",")
            }
        }
    }

    /// EKWeekday-Rohwert (1 = Sonntag … 7 = Samstag) → ICS-Kürzel.
    private static func icsWeekday(_ ek: Int) -> String? {
        ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][safe: ek - 1]
    }

    /// Dateinamen-tauglicher Titel: Schrägstriche/Doppelpunkte raus, Leerzeichen
    /// zu „-", maximal 40 Zeichen.
    private static func slug(_ title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        let short = String(cleaned.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return short.isEmpty ? "Meeting" : short
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
