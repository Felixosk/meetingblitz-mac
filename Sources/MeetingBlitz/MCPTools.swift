import Foundation

/// Reine Bausteine fuer den MCP-Zugang (Runde 78): Zeit-/Zonen-Parsing und die
/// Werkzeug-Beschreibungen fuer `tools/list`. Bewusst OHNE EventKit, damit sie
/// sich in `--selftest` pruefen lassen wie `JoinLinkTests`/`QuickAddTests`.
enum MCPTimeError: Error, CustomStringConvertible {
    case invalidTimezone(String)
    case invalidTime(String)

    var description: String {
        switch self {
        case .invalidTimezone(let z): return L.t("Unbekannte Zeitzone: \(z)", "Unknown time zone: \(z)")
        case .invalidTime(let s):     return L.t("Zeit nicht lesbar: \(s)", "Could not read time: \(s)")
        }
    }
}

enum MCPTools {

    /// Liest `start`/`end`/`newStart` nach der Regel aus dem Plan: eine ISO-
    /// Zeit MIT Offset oder „Z" gewinnt immer (die Zone ist dann eindeutig),
    /// sonst ist es eine Wandzeit („15:00 heißt 15:00 IN dieser Zone"), gelesen
    /// in der uebergebenen IANA-Zone, oder wenn keine mitkommt, in der Zone
    /// des Macs. Eine ungueltige Zonen-Kennung wirft, sie wird NIE still
    /// ignoriert (sonst legt Claude einen Termin drei Stunden daneben an, ohne
    /// dass irgendwer es merkt).
    static func parseTime(_ raw: String, timezone: String?) throws -> Date {
        if let d = isoWithOffset(raw) { return d }
        let tz: TimeZone
        if let tzid = timezone, !tzid.isEmpty {
            guard let t = TimeZone(identifier: tzid) else { throw MCPTimeError.invalidTimezone(tzid) }
            tz = t
        } else {
            tz = TimeZone.current
        }
        guard let d = wallTime(raw, tz: tz) else { throw MCPTimeError.invalidTime(raw) }
        return d
    }

    /// ISO 8601 MIT Offset oder „Z" am Ende. Eine reine Wandzeit
    /// ("2026-10-02T15:00") hat weder das eine noch das andere und faellt
    /// bewusst durch, damit `parseTime` sie stattdessen in der Zielzone liest.
    private static func isoWithOffset(_ raw: String) -> Date? {
        guard raw.hasSuffix("Z")
            || raw.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: raw)
    }

    /// "YYYY-MM-DDTHH:MM[:SS]" (auch mit Leerzeichen statt „T"), gelesen in `tz`.
    private static func wallTime(_ raw: String, tz: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                    "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = fmt
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    /// ISO 8601 MIT Offset in der gegebenen Zone, fuer Antworten an Claude
    /// (`list_events`, `create_event`, `move_event`), nie „Z"/UTC: Claude soll
    /// die Zone sehen, in der der Nutzer tatsaechlich lebt bzw. gefragt hat.
    static func isoString(_ date: Date, tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return f.string(from: date)
    }

    /// Werkzeug-Schemas fuer `tools/list`. Rein statisch, JSON-Schema light
    /// (genug für einen MCP-Client, kein voller Validator).
    static func toolSchemas() -> [[String: Any]] {
        func schema(_ props: [String: Any], required: [String] = []) -> [String: Any] {
            var s: [String: Any] = ["type": "object", "properties": props]
            if !required.isEmpty { s["required"] = required }
            return s
        }
        let str: [String: Any] = ["type": "string"]
        let bool: [String: Any] = ["type": "boolean"]
        let int: [String: Any] = ["type": "integer"]

        return [
            ["name": "get_context",
             "description": "Zeitzone und aktuelle Uhrzeit dieses Macs. Vor jedem create_event/move_event "
                + "mit einer vom Nutzer genannten Uhrzeit OHNE ausdrückliche Zone zuerst hier nachsehen, "
                + "seine Uhrzeiten gelten in dieser Zone.",
             "inputSchema": schema([:])],
            ["name": "list_calendars",
             "description": "Beschreibbare Kalender: id, title, account, isDefault.",
             "inputSchema": schema([:])],
            ["name": "list_events",
             "description": "Termine zwischen from und to (ISO-Datum/Zeit, optional timezone).",
             "inputSchema": schema([
                "from": str, "to": str, "timezone": str,
             ], required: ["from", "to"])],
            ["name": "create_event",
             "description": "Legt einen neuen Termin an.",
             "inputSchema": schema([
                "title": str, "start": str, "timezone": str, "durationMinutes": int, "end": str,
                "calendar": str, "meetLink": bool, "location": str, "notes": str,
                "makeICS": bool, "copyInvite": bool,
             ], required: ["title", "start"])],
            ["name": "move_event",
             "description": "Verschiebt EIN Vorkommen eines bestehenden Termins (nie eine ganze Serie).",
             "inputSchema": schema([
                "eventID": str, "occurrenceStart": str, "newStart": str, "timezone": str,
                "newEnd": str, "durationMinutes": int, "makeICS": bool, "copyInvite": bool,
             ], required: ["eventID", "newStart"])],
            ["name": "delete_event",
             "description": "Löscht einen Termin, aber NUR wenn er selbst über Claude/MCP angelegt wurde.",
             "inputSchema": schema(["eventID": str], required: ["eventID"])],
        ]
    }
}

/// Verzeichnis der per MCP angelegten Termine (Runde 78): `delete_event` darf
/// AUSSCHLIESSLICH Termine löschen, die hier stehen. Datei statt In-Memory,
/// weil die App zwischen zwei MCP-Aufrufen neu gestartet werden kann.
///
/// Runde 80: gespeichert werden GRUPPEN, nicht einzelne Kennungen. Ein Ziel
/// „beide" legt denselben Termin in zwei Kalendern an, und für den Nutzer ist das
/// EIN Termin: löschen muss beide Hälften löschen, verschieben beide
/// verschieben, sonst bleibt im Apple-Kalender eine Leiche stehen bzw. die
/// zwei Hälften laufen zeitlich auseinander. Die alte flache Liste wird beim
/// Lesen weiter akzeptiert (jede Kennung ist dann ihre eigene Gruppe).
enum MCPCreatedStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MeetingBlitz", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mcp-created.json")
    }

    /// Eine Gruppe zusammengehöriger Termine merken (ein Aufruf = eine Gruppe).
    static func remember(_ eventIDs: [String]) {
        save(adding(eventIDs, to: load()))
    }

    /// Alle Kennungen derselben Gruppe, die gegebene eingeschlossen. Leer, wenn
    /// der Termin nicht über MCP angelegt wurde.
    static func siblings(of eventID: String) -> [String] { siblings(of: eventID, in: load()) }

    /// Die ganze Gruppe vergessen, zu der diese Kennung gehört.
    static func forget(_ eventID: String) { save(removing(eventID, from: load())) }

    static func contains(_ eventID: String) -> Bool { !siblings(of: eventID).isEmpty }

    // MARK: - Reine Logik (ohne Datei, damit `--selftest` sie pruefen kann)

    /// Neue Gruppe anhaengen. Kennungen, die schon in einer aelteren Gruppe
    /// stehen, werden dort herausgenommen: eine Kennung darf nie in zwei
    /// Gruppen haengen, sonst loescht `delete_event` ueber die falsche Gruppe
    /// einen fremden Termin mit.
    static func adding(_ eventIDs: [String], to groups: [[String]]) -> [[String]] {
        let clean = eventIDs.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return groups }
        var out = groups.compactMap { group -> [String]? in
            let rest = group.filter { !clean.contains($0) }
            return rest.isEmpty ? nil : rest
        }
        out.append(clean)
        return out
    }

    static func siblings(of eventID: String, in groups: [[String]]) -> [String] {
        groups.first { $0.contains(eventID) } ?? []
    }

    static func removing(_ eventID: String, from groups: [[String]]) -> [[String]] {
        groups.filter { !$0.contains(eventID) }
    }

    /// Altbestand vor Runde 80 ist eine flache Liste einzelner Kennungen;
    /// jede wird dann ihre eigene Gruppe.
    static func decodeGroups(_ data: Data) -> [[String]] {
        if let groups = try? JSONDecoder().decode([[String]].self, from: data) { return groups }
        if let flat = try? JSONDecoder().decode([String].self, from: data) { return flat.map { [$0] } }
        return []
    }

    private static func load() -> [[String]] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return decodeGroups(data)
    }

    private static func save(_ groups: [[String]]) {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Prueft die Gruppenlogik von `MCPCreatedStore` ohne Dateizugriff (Runde 80).
/// Haengt in `--selftest`, damit die echte `mcp-created.json` dabei nie
/// angefasst wird.
enum MCPCreatedStoreTests {
    static func run() -> [String] {
        var fails: [String] = []
        func check(_ ok: Bool, _ what: String) { if !ok { fails.append(what) } }

        // Eine Anlage mit Ziel „beide" = eine Gruppe aus zwei Kennungen.
        var g = MCPCreatedStore.adding(["A", "B"], to: [])
        check(MCPCreatedStore.siblings(of: "A", in: g) == ["A", "B"], "Geschwister von A")
        check(MCPCreatedStore.siblings(of: "B", in: g) == ["A", "B"], "Geschwister von B")
        check(MCPCreatedStore.siblings(of: "C", in: g).isEmpty, "Fremder Termin hat keine Geschwister")

        // Loeschen nimmt die ganze Gruppe mit, nicht nur die eine Haelfte.
        g = MCPCreatedStore.adding(["C"], to: g)
        check(MCPCreatedStore.removing("A", from: g).count == 1, "Loeschen entfernt die ganze Gruppe")
        check(MCPCreatedStore.siblings(of: "B", in: MCPCreatedStore.removing("A", from: g)).isEmpty,
              "Nach dem Loeschen ist auch die zweite Haelfte vergessen")

        // Dieselbe Kennung neu vergeben: sie darf nicht in zwei Gruppen haengen.
        let reused = MCPCreatedStore.adding(["B", "D"], to: g)
        check(reused.filter { $0.contains("B") }.count == 1, "B haengt in genau einer Gruppe")
        check(MCPCreatedStore.siblings(of: "A", in: reused) == ["A"], "A bleibt allein zurueck")

        // Leere Eingabe aendert nichts, leere Kennungen fliegen raus.
        check(MCPCreatedStore.adding([], to: g).count == g.count, "Leere Anlage aendert nichts")
        check(MCPCreatedStore.adding(["", ""], to: g).count == g.count, "Leere Kennungen zaehlen nicht")

        // Altbestand: flache Liste wird zu Ein-Element-Gruppen.
        let old = Data(#"["X","Y"]"#.utf8)
        check(MCPCreatedStore.decodeGroups(old) == [["X"], ["Y"]], "Alte flache Liste wird gelesen")
        let new = Data(#"[["X","Y"]]"#.utf8)
        check(MCPCreatedStore.decodeGroups(new) == [["X", "Y"]], "Neues Gruppenformat wird gelesen")
        check(MCPCreatedStore.decodeGroups(Data("kaputt".utf8)).isEmpty, "Kaputte Datei ergibt leer")

        return fails
    }
}
