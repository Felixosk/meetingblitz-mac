import Foundation
import Network
import AppKit
import Combine

/// Lokale HTTP-Bruecke fuer den MCP-Zugang (Runde 78).
///
/// **Warum das ueberhaupt existiert:** `MeetingBlitz --mcp` (siehe
/// `MCPServer.swift`) ist ein eigener Prozess, den Claude aus dem Terminal
/// startet. Ein Terminal-Prozess hat KEINE Kalender-Freigabe, die TCC-Freigabe
/// haengt am signierten App-Bundle, das der Nutzer angeklickt hat, nicht am
/// nackten Binary. Deshalb fasst der `--mcp`-Prozess EventKit nie selbst an,
/// er reicht jede Anfrage per HTTP an GENAU DIESE laufende App weiter, die die
/// echte Freigabe hat.
///
/// Nur aktiv, wenn `AppState.mcpEnabled` an ist. Bindet ausschliesslich an
/// 127.0.0.1 (`requiredLocalEndpoint`), ein freier Port wird von `NWListener`
/// selbst gewaehlt. Port + ein 32-Byte-Zufallstoken stehen in
/// `~/Library/Application Support/MeetingBlitz/mcp.json`, Dateirechte 0600.
/// Jede Anfrage braucht `Authorization: Bearer <token>`, sonst 401.
@MainActor
final class MCPBridge: ObservableObject {
    static let shared = MCPBridge()

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = 0
    /// Diagnose: die letzten 5 Aufrufe, neueste zuerst.
    @Published private(set) var recentCalls: [String] = []

    private var listener: NWListener?
    private var token = ""

    private var configURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MeetingBlitz", isDirectory: true)
        return dir.appendingPathComponent("mcp.json")
    }

    func setEnabled(_ on: Bool) {
        if on { start() } else { stop() }
    }

    private func start() {
        guard listener == nil else { return }
        token = Self.randomToken()
        let params = NWParameters.tcp
        // NUR Loopback: eine Anfrage von einem anderen Rechner im selben Netz
        // darf diese Bruecke gar nicht erst erreichen.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else {
            NSLog("MCP-Bruecke: NWListener konnte nicht erstellt werden.")
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor in self?.didBecomeReady() }
            case .failed(let error):
                NSLog("MCP-Bruecke fehlgeschlagen: \(error)")
                Task { @MainActor in self?.stop() }
            default: break
            }
        }
        l.start(queue: .main)
    }

    private func didBecomeReady() {
        guard let p = listener?.port?.rawValue else { return }
        port = p
        isRunning = true
        writeConfig()
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        port = 0
        try? FileManager.default.removeItem(at: configURL)
    }

    private func writeConfig() {
        let dir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = ["port": Int(port), "token": token]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? data.write(to: configURL, options: .atomic)
        // 0600: nur der eigene Nutzer darf das Token lesen.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Minimaler HTTP-Server

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        var buffer = Data()

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { connection.cancel(); return }
                if let data, !data.isEmpty { buffer.append(data) }
                if let req = Self.parseHTTPRequest(buffer) {
                    Task { @MainActor in
                        await self.handle(req, on: connection)
                    }
                    return
                }
                if isComplete || error != nil { connection.cancel(); return }
                receiveMore()
            }
        }
        receiveMore()
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    /// Reicht fuer diesen einen Zweck (POST /rpc, ein JSON-Body): Kopfzeilen
    /// bis zur Leerzeile lesen, `Content-Length` daraus, dann warten, bis
    /// genau so viele Body-Bytes da sind. Kein echter HTTP-Parser, den braucht
    /// dieser rein lokale Zweck nicht.
    private static func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[data.startIndex..<sep.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= contentLength else { return nil }   // Body noch unvollstaendig
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)]
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body))
    }

    private func respond(_ connection: NWConnection, status: Int, statusText: String, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func handle(_ req: HTTPRequest, on connection: NWConnection) async {
        guard req.method == "POST", req.path == "/rpc" else {
            respond(connection, status: 404, statusText: "Not Found", json: ["error": "unbekannter Pfad"])
            return
        }
        let expected = "Bearer \(token)"
        guard req.headers["authorization"] == expected, !token.isEmpty else {
            respond(connection, status: 401, statusText: "Unauthorized", json: ["error": "fehlendes oder falsches Token"])
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let tool = obj["tool"] as? String else {
            respond(connection, status: 400, statusText: "Bad Request", json: ["error": "ungueltiger Aufruf"])
            return
        }
        let arguments = (obj["arguments"] as? [String: Any]) ?? [:]
        note(tool)
        let (result, error) = await execute(tool: tool, arguments: arguments)
        if let error {
            respond(connection, status: 200, statusText: "OK", json: ["error": error])
        } else {
            respond(connection, status: 200, statusText: "OK", json: ["result": result ?? [:]])
        }
    }

    private func note(_ tool: String) {
        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss"
        recentCalls.insert("\(stamp.string(from: Date())) \(tool)", at: 0)
        if recentCalls.count > 5 { recentCalls.removeLast(recentCalls.count - 5) }
    }

    // MARK: - Werkzeuge

    /// Fuehrt EIN Werkzeug aus. Laeuft komplett auf dem MainActor, weil jeder
    /// Zweig frueher oder spaeter `AppState`/`CalendarService` anfasst
    /// (EKEventStore ist nicht Sendable).
    func execute(tool: String, arguments: [String: Any]) async -> (result: Any?, error: String?) {
        let state = AppState.shared
        switch tool {
        case "get_context":
            return (getContext(), nil)
        case "list_calendars":
            return (listCalendars(state: state), nil)
        case "list_events":
            return listEvents(state: state, arguments: arguments)
        case "create_event":
            return await createEvent(state: state, arguments: arguments)
        case "move_event":
            return moveEvent(state: state, arguments: arguments)
        case "delete_event":
            return deleteEvent(state: state, arguments: arguments)
        default:
            return (nil, L.t("Unbekanntes Werkzeug: \(tool)", "Unknown tool: \(tool)"))
        }
    }

    private func getContext() -> [String: Any] {
        let tz = TimeZone.current
        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE"
        f.timeZone = tz
        let offsetSeconds = tz.secondsFromGMT(for: now)
        let sign = offsetSeconds >= 0 ? "+" : "-"
        let abs = Swift.abs(offsetSeconds)
        let offsetString = String(format: "%@%02d:%02d", sign, abs / 3600, (abs % 3600) / 60)
        return [
            "timezone": tz.identifier,
            "utcOffset": offsetString,
            "now": MCPTools.isoString(now, tz: tz),
            "weekday": f.string(from: now),
        ]
    }

    private func listCalendars(state: AppState) -> [String: Any] {
        let defaultID = state.calendar.defaultCalendarID
        let list = state.calendar.writableCalendars().map { c -> [String: Any] in
            [
                "id": c.id, "title": c.title,
                "account": c.sourceTitle.isEmpty ? (c.isAppleAccount ? "Apple" : "?") : c.sourceTitle,
                "isDefault": c.id == defaultID,
            ]
        }
        return ["calendars": list]
    }

    private func listEvents(state: AppState, arguments: [String: Any]) -> (result: Any?, error: String?) {
        guard let fromRaw = arguments["from"] as? String, let toRaw = arguments["to"] as? String else {
            return (nil, L.t("from und to sind Pflicht.", "from and to are required."))
        }
        let tzArg = arguments["timezone"] as? String
        let from: Date, to: Date
        do {
            // Ein nacktes Datum ist beim LESEN eindeutig (ganzer Tag), beim
            // Anlegen waere es ein Termin um Mitternacht, deshalb nur hier:
            // `from` ab 00:00, `to` bis zum Ende dieses Tages.
            let dateOnly = { (s: String) in s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }
            from = try MCPTools.parseTime(dateOnly(fromRaw) ? fromRaw + "T00:00" : fromRaw, timezone: tzArg)
            to = try MCPTools.parseTime(dateOnly(toRaw) ? toRaw + "T23:59:59" : toRaw, timezone: tzArg)
        } catch { return (nil, "\(error)") }
        guard to > from else { return (nil, L.t("to muss nach from liegen.", "to must be after from.")) }
        let tz = tzArg.flatMap(TimeZone.init(identifier:)) ?? .current
        let events = state.calendar.mcpEventsInRange(from: from, to: to).map { e -> [String: Any] in
            [
                "id": e.id, "title": e.title,
                "start": MCPTools.isoString(e.start, tz: tz),
                "end": MCPTools.isoString(e.end, tz: tz),
                "timezone": tz.identifier,
                "calendar": e.calendarTitle,
                "joinURL": (e.joinURL?.absoluteString).map { $0 as Any } ?? NSNull(),
                "isRecurring": e.isRecurring,
                "calendarWritable": e.calendarWritable,
                "hasAttendees": e.hasAttendees,
                "iAmOrganizer": e.iAmOrganizer,
            ]
        }
        return (["events": events, "timezone": tz.identifier], nil)
    }

    /// Kalender-Argument (id ODER Titel, ohne Gross/Klein) in eine echte
    /// Kennung aufloesen. `nil`/leer/unbekannt faellt auf den Formular-
    /// Standard zurueck (`effectiveCreateCalendarIDs`), NICHT auf den System-
    /// standard: das ist dieselbe Regel wie im „Neues Meeting"-Formular.
    private func resolveCalendarID(_ raw: String?, state: AppState) -> String? {
        guard let raw, !raw.isEmpty else { return state.effectiveCreateCalendarIDs.first ?? nil }
        let writable = state.calendar.writableCalendars()
        if let byID = writable.first(where: { $0.id == raw }) { return byID.id }
        if let byTitle = writable.first(where: { $0.title.caseInsensitiveCompare(raw) == .orderedSame }) { return byTitle.id }
        return state.effectiveCreateCalendarIDs.first ?? nil
    }

    private func calendarTitle(for id: String?, state: AppState) -> String {
        let target = id ?? state.calendar.defaultCalendarID
        return state.calendar.writableCalendars().first { $0.id == target }?.title ?? ""
    }

    private func createEvent(state: AppState, arguments: [String: Any]) async -> (result: Any?, error: String?) {
        guard let titleRaw = arguments["title"] as? String,
              !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, L.t("title fehlt.", "title is required."))
        }
        guard let startRaw = arguments["start"] as? String else {
            return (nil, L.t("start fehlt.", "start is required."))
        }
        let tzArg = arguments["timezone"] as? String
        let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let start: Date
        do { start = try MCPTools.parseTime(startRaw, timezone: tzArg) }
        catch { return (nil, "\(error)") }

        let end: Date
        if let endRaw = arguments["end"] as? String {
            do { end = try MCPTools.parseTime(endRaw, timezone: tzArg) }
            catch { return (nil, "\(error)") }
        } else {
            let minutes = (arguments["durationMinutes"] as? Int) ?? 30
            end = start.addingTimeInterval(Double(max(1, minutes)) * 60)
        }
        guard end > start else { return (nil, L.t("Ende muss nach dem Start liegen.", "End must be after start.")) }

        let calendarID = resolveCalendarID(arguments["calendar"] as? String, state: state)
        let meetLink = (arguments["meetLink"] as? Bool) ?? false
        let location = arguments["location"] as? String
        let notes = arguments["notes"] as? String
        let makeICS = (arguments["makeICS"] as? Bool) ?? state.createICSFile
        let copyInvite = (arguments["copyInvite"] as? Bool) ?? state.copyInviteOnCreate
        let timeZone = tzArg.flatMap(TimeZone.init(identifier:))

        var eventID = ""
        var meetLinkOut: String?
        var icsPath: String?
        var shareText: String?

        if meetLink {
            let minutes = Int(end.timeIntervalSince(start) / 60)
            let ok = await GoogleService.shared.createAppleMeeting(
                title: title, start: start, minutes: minutes, calendarIDs: [calendarID],
                autoTranscribe: false, makeICS: makeICS, copyInvite: copyInvite,
                calendarService: state.calendar)
            guard ok, let id = GoogleService.shared.lastCreatedEventIDs.first, !id.isEmpty else {
                return (nil, GoogleService.shared.lastError ?? L.t("Meet-Link konnte nicht erstellt werden.", "Could not create the Meet link."))
            }
            eventID = id
            meetLinkOut = GoogleService.shared.lastMeetLink
            icsPath = GoogleService.shared.lastICSURL?.path
            shareText = GoogleService.shared.lastShareText
        } else {
            do {
                eventID = try state.calendar.createEvent(title: title, start: start, end: end, url: nil,
                                                         calendarID: calendarID, timeZone: timeZone,
                                                         location: location, notes: notes)
            } catch { return (nil, error.localizedDescription) }
            let text = GoogleService.shareText(title: title, start: start, end: end, link: nil)
            shareText = text
            if copyInvite {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            if makeICS {
                icsPath = try? ICSExport.write(title: title, start: start, end: end, link: nil).path
            }
        }

        MCPCreatedStore.remember(eventID)
        state.monitor.tickNow()

        let outTZ = timeZone ?? .current
        return ([
            "eventID": eventID,
            "start": MCPTools.isoString(start, tz: outTZ),
            "end": MCPTools.isoString(end, tz: outTZ),
            "calendar": calendarTitle(for: calendarID, state: state),
            "meetLink": meetLinkOut.map { $0 as Any } ?? NSNull(),
            "icsPath": icsPath.map { $0 as Any } ?? NSNull(),
            "shareText": shareText.map { $0 as Any } ?? NSNull(),
            "copiedToClipboard": copyInvite,
        ], nil)
    }

    private func moveEvent(state: AppState, arguments: [String: Any]) -> (result: Any?, error: String?) {
        guard let eventID = arguments["eventID"] as? String, !eventID.isEmpty else {
            return (nil, L.t("eventID fehlt.", "eventID is required."))
        }
        guard let newStartRaw = arguments["newStart"] as? String else {
            return (nil, L.t("newStart fehlt.", "newStart is required."))
        }
        let tzArg = arguments["timezone"] as? String
        let newStart: Date
        do { newStart = try MCPTools.parseTime(newStartRaw, timezone: tzArg) }
        catch { return (nil, "\(error)") }

        var occurrenceStart: Date?
        if let raw = arguments["occurrenceStart"] as? String {
            do { occurrenceStart = try MCPTools.parseTime(raw, timezone: tzArg) }
            catch { return (nil, "\(error)") }
        }

        let timeZone = tzArg.flatMap(TimeZone.init(identifier:))
        do {
            // Explizit gegebenes Ende/Dauer schlaegt „Dauer bleibt gleich"
            // (nil an CalendarService.moveEvent, das haelt die alte Dauer).
            var newEnd: Date?
            if let newEndRaw = arguments["newEnd"] as? String {
                newEnd = try MCPTools.parseTime(newEndRaw, timezone: tzArg)
            } else if let minutes = arguments["durationMinutes"] as? Int {
                newEnd = newStart.addingTimeInterval(Double(minutes) * 60)
            }

            // KEIN MCPCreatedStore.remember hier: move_event gilt fuer JEDEN
            // Termin (siehe Plan), nicht nur fuer per MCP angelegte. Wer diesen
            // Termin loeschen darf, aendert sich durchs Verschieben nicht.
            let moved = try state.calendar.moveEvent(id: eventID, occurrenceStart: occurrenceStart,
                                                      newStart: newStart, newEnd: newEnd, timeZone: timeZone)
            state.monitor.tickNow()
            let outTZ = timeZone ?? .current

            let makeICS = (arguments["makeICS"] as? Bool) ?? false
            let copyInvite = (arguments["copyInvite"] as? Bool) ?? false
            var icsPath: String?
            if makeICS {
                icsPath = try? ICSExport.write(title: moved.title, start: newStart, end: moved.newEnd, link: nil).path
            }
            if copyInvite {
                let text = GoogleService.shareText(title: moved.title, start: newStart, end: moved.newEnd, link: nil)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return ([
                "eventID": eventID, "title": moved.title, "calendar": moved.calendarTitle,
                "oldStart": MCPTools.isoString(moved.oldStart, tz: outTZ),
                "oldEnd": MCPTools.isoString(moved.oldEnd, tz: outTZ),
                "newStart": MCPTools.isoString(newStart, tz: outTZ),
                "newEnd": MCPTools.isoString(moved.newEnd, tz: outTZ),
                "icsPath": icsPath.map { $0 as Any } ?? NSNull(),
            ], nil)
        } catch { return (nil, error.localizedDescription) }
    }

    private func deleteEvent(state: AppState, arguments: [String: Any]) -> (result: Any?, error: String?) {
        guard let eventID = arguments["eventID"] as? String, !eventID.isEmpty else {
            return (nil, L.t("eventID fehlt.", "eventID is required."))
        }
        guard MCPCreatedStore.contains(eventID) else {
            return (nil, L.t("Dieser Termin wurde nicht über Claude angelegt und kann hier nicht gelöscht werden.",
                             "This event was not created through Claude and cannot be deleted here."))
        }
        do {
            try state.calendar.deleteEvent(id: eventID)
            MCPCreatedStore.forget(eventID)
            state.monitor.tickNow()
            return (["deleted": true, "eventID": eventID], nil)
        } catch { return (nil, error.localizedDescription) }
    }
}
