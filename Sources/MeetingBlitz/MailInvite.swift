import Foundation
import AppKit

/// Runde 109: Mail an den Gast. Alles hier ist reine Rechnerei (ohne Netz,
/// ohne UI), damit `--selftest` es prüfen kann: Adressen, Platzhalter, MIME,
/// Fehler-Zuordnung der Gmail-API. Das Senden selbst steht in `GoogleService`.
enum MailInvite {

    // MARK: Standard-Vorlagen (EN/DE)

    static let defaultSubject = "{title} · {date}, {time}"
    static let defaultBodyEN = "Hi,\n\nhere is the link for our call:\n{link}\n\n{date}\n{times}\n\nSee you then"
    static let defaultBodyDE = "Hallo,\n\nhier ist der Link für unseren Call:\n{link}\n\n{datum}\n{zeiten}\n\nBis dann"

    // MARK: Adressen

    /// Genau ein @, Punkt im Teil danach, keine Leerzeichen, nichts Leeres.
    static func isValidAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(where: { $0.isWhitespace || $0.isNewline }) else { return false }
        let p = t.split(separator: "@", omittingEmptySubsequences: false)
        guard p.count == 2, !p[0].isEmpty, !p[1].isEmpty else { return false }
        let domain = p[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else { return false }
        // Keine Steuerzeichen / Header-Einschleusung.
        return !t.contains(where: { $0 == "<" || $0 == ">" || $0 == "," || $0 == ";" || $0 == "\"" })
    }

    /// Mehrere Adressen mit Komma oder Leerzeichen getrennt, höchstens 5.
    /// `ok` ist nur dann true, wenn mindestens eine da ist und jede stimmt.
    static func parseAddresses(_ raw: String) -> (list: [String], ok: Bool, empty: Bool) {
        let parts = raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).map(String.init)
        if parts.isEmpty { return ([], false, true) }
        let ok = parts.count <= 5 && parts.allSatisfy(isValidAddress)
        return (parts, ok, false)
    }

    // MARK: Platzhalter

    struct Fields {
        var title: String
        var start: Date
        var end: Date
        var link: String
        var zoneIDs: [String]
        var labels: [String: String]
        var de: Bool
        /// Runde 119: nil = Standard-Trennung („ · “ bei zwei Zonen), Mail nimmt Zeilenumbruch.
        var timesSeparator: String? = "\n"
    }

    /// Ersetzt {title}/{titel}, {date}/{datum}, {time}/{zeit}, {times}/{zeiten},
    /// {duration}/{dauer}, {link}. Unbekannte Platzhalter bleiben stehen, damit man den Tippfehler sieht.
    @MainActor static func render(_ template: String, _ f: Fields) -> String {
        let local = TimeZone.current
        let day = DateFormatter()
        day.locale = f.de ? Locale(identifier: "de_DE") : Locale(identifier: "en_US")
        day.dateFormat = f.de ? "EE, dd.MM." : "EE, MMM d"
        day.timeZone = local
        let mins = max(1, Int((f.end.timeIntervalSince(f.start) / 60).rounded()))
        let time = GoogleService.timeRange(f.start, f.end, tz: local, de: f.de) + " "
            + ZoneBook.displayName(local.identifier, labels: f.labels)
        let times = GoogleService.inviteTimes(start: f.start, end: f.end, zoneIDs: f.zoneIDs,
                                              labels: f.labels, separator: f.timesSeparator)
        let map: [String: String] = [
            "title": f.title, "titel": f.title,
            "date": day.string(from: f.start), "datum": day.string(from: f.start),
            "time": time, "zeit": time,
            "times": times, "zeiten": times,
            "duration": "\(mins) min", "dauer": "\(mins) min",
            "link": f.link,
        ]
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), let v = map[after[..<close].lowercased()] {
                out += v
                rest = after[after.index(after: close)...]
            } else {
                out += "{"
                rest = after
            }
        }
        out += rest
        return out
    }

    // MARK: MIME

    /// RFC 2047 für Betreff mit Nicht-ASCII (sonst kaputte Umlaute).
    static func encodeHeader(_ s: String) -> String {
        let clean = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        if clean.allSatisfy({ $0.isASCII }) { return clean }
        return "=?UTF-8?B?" + Data(clean.utf8).base64EncodedString() + "?="
    }

    /// Quoted-Printable (RFC 2045) für den Textteil, Zeilen ≤ 76 Zeichen.
    static func quotedPrintable(_ s: String) -> String {
        var lines: [String] = []
        for rawLine in s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = ""
            for b in Array(rawLine.utf8) {
                let piece: String
                if (b >= 33 && b <= 126 && b != 61) || b == 32 { piece = String(UnicodeScalar(b)) }
                else { piece = String(format: "=%02X", b) }
                if line.count + piece.count > 75 { lines.append(line + "="); line = "" }
                line += piece
            }
            // Leerzeichen am Zeilenende müssen kodiert werden.
            if line.hasSuffix(" ") { line = String(line.dropLast()) + "=20" }
            lines.append(line)
        }
        return lines.joined(separator: "\r\n")
    }

    /// Base64 in 76er-Zeilen (Anhang).
    static func base64Lines(_ d: Data) -> String {
        d.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }

    /// Die ganze Mail als MIME-Text. `ics` nil = ohne Anhang. `boundary` für Tests festlegbar.
    static func mime(from: String, to: [String], subject: String, body: String, ics: String?,
                     boundary: String = "mb-" + UUID().uuidString) -> String {
        var h: [String] = []
        h.append("From: \(from)")
        h.append("To: \(to.joined(separator: ", "))")
        h.append("Subject: \(encodeHeader(subject))")
        h.append("MIME-Version: 1.0")
        var out = ""
        if let ics {
            h.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            out = h.joined(separator: "\r\n") + "\r\n\r\n"
            out += "--\(boundary)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
            out += quotedPrintable(body) + "\r\n"
            // Runde 109g: `application/ics` statt `text/calendar; method=PUBLISH`.
            // Gmail zeigte den text/calendar-Teil nicht als Anhang (Rückmeldung 19.11.:
            // „Datei war nicht dabei"); als normale Datei sieht man „invite.ics".
            out += "--\(boundary)\r\nContent-Type: application/ics; name=\"invite.ics\"\r\n"
            out += "Content-Disposition: attachment; filename=\"invite.ics\"\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            out += base64Lines(Data(ics.utf8)) + "\r\n"
            out += "--\(boundary)--\r\n"
        } else {
            h.append("Content-Type: text/plain; charset=utf-8")
            h.append("Content-Transfer-Encoding: quoted-printable")
            out = h.joined(separator: "\r\n") + "\r\n\r\n" + quotedPrintable(body) + "\r\n"
        }
        return out
    }

    /// base64url ohne Auffüllung, wie `messages.send` es im Feld `raw` verlangt.
    static func rawBase64URL(_ mime: String) -> String {
        Data(mime.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Fehler der Gmail-API

    enum Failure: Equatable {
        case needsScope            // 403, Scope fehlt: Google neu verbinden
        case apiDisabled           // 403, Gmail API im Projekt aus
        case expired               // 401
        case other(String)
    }

    /// Ordnet Status + Antwort-JSON einem Fall zu. Rein, deshalb testbar.
    static func classify(status: Int, json: [String: Any]) -> Failure {
        let err = json["error"] as? [String: Any]
        let msg = (err?["message"] as? String) ?? "HTTP \(status)"
        var reasons = ((err?["errors"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
        for d in (err?["details"] as? [[String: Any]]) ?? [] {
            if let r = d["reason"] as? String { reasons.append(r) }
        }
        let hay = (reasons + [msg]).joined(separator: " ").lowercased()
        if status == 401 { return .expired }
        if status == 403 {
            if hay.contains("accessnotconfigured") || hay.contains("has not been used in project")
                || hay.contains("service_disabled") || hay.contains("is disabled") { return .apiDisabled }
            if hay.contains("insufficientpermissions") || hay.contains("insufficient authentication scopes")
                || hay.contains("access_token_scope_insufficient") || hay.contains("scope") { return .needsScope }
        }
        return .other(msg)
    }
}

/// Selbsttest ohne Netz, Teil von `--selftest`.
@MainActor enum MailInviteTests {
    static func failures() -> [String] {
        var f: [String] = []
        f += pasteboardFailures()
        f += statsFailures()
        f += previewFailures()
        f += snapshotFailures()
        func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) { if a != b { f.append("Mail: \(what): \(a) ≠ \(b)") } }

        // Adressen
        for ok in ["a@b.co", "anna.m@kunde.com", " x@y.de "] { eq(MailInvite.isValidAddress(ok), true, "gültig \(ok)") }
        for bad in ["", "a", "a@b", "a@@b.co", "@b.co", "a@.co", "a@b..co", "a b@c.de", "a@b.co>", "a\r\nBcc: x@y.de@c.de"] {
            eq(MailInvite.isValidAddress(bad), false, "ungültig \(bad.debugDescription)")
        }
        let two = MailInvite.parseAddresses("a@b.co, c@d.de e@f.io")
        eq(two.list.count, 3, "drei Adressen"); eq(two.ok, true, "drei ok")
        eq(MailInvite.parseAddresses("a@b.co kaputt").ok, false, "eine kaputt")
        eq(MailInvite.parseAddresses("1@a.de 2@a.de 3@a.de 4@a.de 5@a.de 6@a.de").ok, false, "mehr als 5")
        eq(MailInvite.parseAddresses("  ").empty, true, "leer")

        // Platzhalter (feste Zeit, UTC-Zone des Rechners egal: wir prüfen nur Struktur)
        let s = Date(timeIntervalSince1970: 1_800_000_000)
        let fields = MailInvite.Fields(title: "Call mit Änna", start: s, end: s.addingTimeInterval(1800),
                                       link: "https://meet.google.com/abc-defg-hij", zoneIDs: [], labels: [:], de: true)
        let out = MailInvite.render("{Titel} | {link} | {dauer} | {foo} | {date}", fields)
        eq(out.hasPrefix("Call mit Änna | https://meet.google.com/abc-defg-hij | 30 min | {foo} | "), true, "Platzhalter: \(out)")
        eq(MailInvite.render("offen {", fields), "offen {", "lose Klammer")

        // MIME
        eq(MailInvite.encodeHeader("Call · Fr"), "=?UTF-8?B?" + Data("Call · Fr".utf8).base64EncodedString() + "?=", "Betreff UTF-8")
        eq(MailInvite.encodeHeader("Plain"), "Plain", "Betreff ASCII")
        eq(MailInvite.encodeHeader("A\r\nBcc: x"), "A  Bcc: x", "Betreff ohne Zeilenumbruch")
        let m = MailInvite.mime(from: "me@x.de", to: ["a@b.co"], subject: "Gruß Äö", body: "Hallo Äö=\n{x}", ics: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n", boundary: "BND")
        eq(m.contains("Subject: =?UTF-8?B?"), true, "MIME Betreff kodiert")
        eq(m.contains("multipart/mixed; boundary=\"BND\""), true, "MIME multipart")
        eq(m.contains("name=\"invite.ics\""), true, "MIME Anhang")
        eq(m.contains("Hallo =C3=84=C3=B6=3D"), true, "QP Umlaut + Gleichheitszeichen: \(m)")
        eq(m.hasSuffix("--BND--\r\n"), true, "MIME Ende")
        eq(MailInvite.mime(from: "a@b.co", to: ["c@d.de"], subject: "x", body: "y", ics: nil).contains("multipart"), false, "ohne Anhang kein multipart")
        let raw = MailInvite.rawBase64URL("???>>>~~~")
        eq(raw.contains("+") || raw.contains("/") || raw.contains("="), false, "base64url: \(raw)")
        eq(Data(base64Encoded: raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=").flatMap { String(data: $0, encoding: .utf8) }, "???>>>~~~", "base64url Rückweg")

        // Fehler-Zuordnung
        func j(_ msg: String, reason: String? = nil) -> [String: Any] {
            var e: [String: Any] = ["message": msg]
            if let reason { e["errors"] = [["reason": reason]] }
            return ["error": e]
        }
        eq(MailInvite.classify(status: 403, json: j("Request had insufficient authentication scopes.", reason: "insufficientPermissions")), .needsScope, "403 Scope")
        eq(MailInvite.classify(status: 403, json: j("Gmail API has not been used in project 123 before or it is disabled.", reason: "accessNotConfigured")), .apiDisabled, "403 API aus")
        eq(MailInvite.classify(status: 401, json: j("Invalid Credentials")), .expired, "401")
        eq(MailInvite.classify(status: 500, json: j("Backend Error")), .other("Backend Error"), "500")
        eq(MailInvite.classify(status: 429, json: [:]), .other("HTTP 429"), "429 ohne JSON")

        // Standardvorlagen: nur bekannte Platzhalter
        for t in [MailInvite.defaultSubject, MailInvite.defaultBodyEN, MailInvite.defaultBodyDE] {
            let r = MailInvite.render(t, fields)
            eq(r.contains("{"), false, "Vorlage ohne Rest-Platzhalter")
        }
        return f
    }
}


extension MailInviteTests {
    /// Runde 110: Zwischenablage = EIN Eintrag mit genau den Typen Datei-URL + Text; ein Textfeld fügt den TEXT ein.
    /// Sichert und stellt die echte Zwischenablage wieder her.
    @MainActor static func pasteboardFailures() -> [String] {
        var f: [String] = []
        let pb = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        defer {
            pb.clearContents()
            let items = saved.map { entries -> NSPasteboardItem in
                let i = NSPasteboardItem(); for (t, d) in entries { i.setData(d, forType: t) }; return i
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mb_selftest.ics")
        try? "BEGIN:VCALENDAR\nEND:VCALENDAR\n".write(to: url, atomically: true, encoding: .utf8)
        let text = "Titel\nDo, Nov 19\n10:00–10:30 London"
        ICSExport.copyToPasteboard(url, text: text)
        let items = pb.pasteboardItems ?? []
        if items.count != 1 { f.append("Zwischenablage: \(items.count) Einträge statt 1") }
        let types = Set(items.first?.types.map(\.rawValue) ?? [])
        if types != ["public.file-url", "public.utf8-plain-text"] { f.append("Zwischenablage: Typen \(types.sorted())") }
        if pb.string(forType: .string) != text { f.append("Zwischenablage: Text weicht ab") }
        if let s = pb.string(forType: .fileURL), let u = URL(string: s) {
            if !FileManager.default.fileExists(atPath: u.path) { f.append("Zwischenablage: Datei fehlt") }
        } else { f.append("Zwischenablage: kein fileURL") }
        // Ein reines Textfeld bekommt per paste(_:) den TEXT, nicht den Pfad.
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        field.isRichText = false
        field.paste(nil)
        if field.string != text { f.append("Zwischenablage: Textfeld bekam \"\(field.string)\"") }
        try? FileManager.default.removeItem(at: url)
        return f
    }
}


extension MailInviteTests {
    /// Runde 111: Tagesminuten = vereinigte Intervalle (kein 25,7-h-Tag).
    @MainActor static func statsFailures() -> [String] {
        var f: [String] = []
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        func at(_ m: Int) -> Date { t0.addingTimeInterval(Double(m) * 60) }
        let a = CalendarService.unionMinutes([(at(0), at(60)), (at(30), at(120)), (at(300), at(330))])
        if a != 150 { f.append("Stats: Union \(a) statt 150") }
        if CalendarService.unionMinutes([]) != 0 { f.append("Stats: leer ≠ 0") }
        if CalendarService.unionMinutes([(at(0), at(1440)), (at(0), at(600))]) != 1440 { f.append("Stats: Tag > 24 h") }
        let b = Meeting(id: "x", title: "Robin ( Alice Mom )'s 52nd Birthday", start: t0, end: t0, isAllDay: true, isBirthday: true,
                        calendarTitle: "", calendarID: nil, color: .blue, joinURL: nil, contactID: nil, calendarItemID: nil)
        if !b.displayTitle.hasSuffix("Robin (Alice Mom), 52") { f.append("Geburtstag: \(b.displayTitle)") }
        return f
    }
}


extension MailInviteTests {
    /// Runde 111b: "Kopierter Text" im Formular = derselbe Text, den `shareText` beim Erstellen kopiert (nur der Link wird ersetzt).
    @MainActor static func previewFailures() -> [String] {
        let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let a = GoogleService.shareText(title: "Demo", start: t0, end: t0.addingTimeInterval(1800), link: "https://meet.google.com/…")
        let b = GoogleService.shareText(title: "Demo", start: t0, end: t0.addingTimeInterval(1800), link: "https://meet.google.com/abc")
        var f: [String] = []
        if !a.hasSuffix("https://meet.google.com/…") { f.append("Vorschau: Platzhalter-Link fehlt") }
        if a.replacingOccurrences(of: "https://meet.google.com/…", with: "") != b.replacingOccurrences(of: "https://meet.google.com/abc", with: "") {
            f.append("Vorschau weicht vom echten Text ab")
        }
        return f
    }
}


extension MailInviteTests {
    /// Runde 111b: Rückgängig stellt die Zwischenablage wieder her (Typen + Daten).
    @MainActor static func snapshotFailures() -> [String] {
        var f: [String] = []
        let pb = NSPasteboard.general
        let outer = PasteboardSnapshot.capture(pb)
        defer { outer.restore(pb) }
        pb.clearContents(); pb.setString("vorher", forType: .string)
        let snap = PasteboardSnapshot.capture(pb)
        pb.clearContents(); pb.setString("nachher", forType: .string)
        snap.restore(pb)
        if pb.string(forType: .string) != "vorher" { f.append("Rückgängig: Zwischenablage nicht wiederhergestellt") }
        if (pb.pasteboardItems?.count ?? 0) != 1 { f.append("Rückgängig: Zahl der Einträge") }
        return f
    }
}
