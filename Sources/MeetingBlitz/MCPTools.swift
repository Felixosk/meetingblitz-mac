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
enum MCPCreatedStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MeetingBlitz", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mcp-created.json")
    }

    static func remember(_ eventID: String) {
        guard !eventID.isEmpty else { return }
        var ids = load()
        ids.insert(eventID)
        save(ids)
    }

    static func forget(_ eventID: String) {
        var ids = load()
        ids.remove(eventID)
        save(ids)
    }

    static func contains(_ eventID: String) -> Bool { load().contains(eventID) }

    private static func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    private static func save(_ ids: Set<String>) {
        guard let data = try? JSONEncoder().encode(Array(ids).sorted()) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
