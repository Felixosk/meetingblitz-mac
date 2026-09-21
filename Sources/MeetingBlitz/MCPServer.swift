import Foundation

/// `MeetingBlitz --mcp`: ein duenner stdio-MCP-Server (Runde 78).
///
/// Läuft als eigener Prozess (von Claude gestartet), spricht JSON-RPC 2.0
/// ueber stdin/stdout, eine Nachricht pro Zeile. Fasst EventKit NIE selbst an
/// (siehe Begruendung in `MCPBridge.swift`), sondern reicht jeden `tools/call`
/// per HTTP an die laufende App weiter. Laeuft die App nicht, wird sie kurz
/// gestartet und auf ihre Bruecke gewartet.
///
/// Bewusst SYNCHRON (blockierendes `readLine`, blockierender HTTP-Aufruf per
/// Semaphore): dieser Prozess hat keine andere Aufgabe, ein Runloop/async
/// waere hier nur zusaetzliche Komplexitaet ohne Nutzen.
enum MCPServer {

    private static let bundleID = "app.meetingblitz.MeetingBlitz"

    static func run() -> Never {
        // stdout gehoert ausschliesslich dem Protokoll (Plan: „Logs nur nach
        // stderr"), deshalb ungepuffert, sonst haengt eine Antwort im Buffer,
        // bis der Prozess irgendwann von selbst spuelt.
        setbuf(stdout, nil)
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let response = handle(obj) else { continue }   // Notification: keine Antwort
            if let out = try? JSONSerialization.data(withJSONObject: response),
               let s = String(data: out, encoding: .utf8) {
                print(s)
            }
        }
        exit(0)
    }

    private static func handle(_ req: [String: Any]) -> [String: Any]? {
        let method = req["method"] as? String ?? ""
        let id = req["id"]   // kann String, Zahl oder fehlen (Notification)

        func result(_ r: Any) -> [String: Any] {
            var out: [String: Any] = ["jsonrpc": "2.0", "result": r]
            if let id { out["id"] = id }
            return out
        }
        func rpcError(_ code: Int, _ message: String) -> [String: Any] {
            var out: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
            if let id { out["id"] = id }
            return out
        }

        switch method {
        case "notifications/initialized":
            return nil   // Notification, keine Antwort erwartet
        case "initialize":
            let params = req["params"] as? [String: Any]
            let clientVersion = params?["protocolVersion"] as? String ?? "2024-11-05"
            return result([
                "protocolVersion": clientVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "meetingblitz", "version": Self.appVersion()],
            ])
        case "ping":
            return result([String: Any]())
        case "tools/list":
            return result(["tools": MCPTools.toolSchemas()])
        case "tools/call":
            guard let params = req["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                return rpcError(-32602, "params.name fehlt")
            }
            let arguments = (params["arguments"] as? [String: Any]) ?? [:]
            let (text, isError) = callApp(tool: name, arguments: arguments)
            return result(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            guard id != nil else { return nil }   // unbekannte Notification: still ignorieren
            return rpcError(-32601, "Methode nicht gefunden: \(method)")
        }
    }

    // MARK: - Weiterreichen an die laufende App

    private struct BridgeConfig: Decodable { let port: Int; let token: String }

    private static var configURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MeetingBlitz", isDirectory: true)
            .appendingPathComponent("mcp.json")
    }

    /// Liefert (Text fuers `content`-Feld, `isError`).
    private static func callApp(tool: String, arguments: [String: Any]) -> (String, Bool) {
        guard let config = loadOrWaitForConfig() else {
            let msg = L.t("MeetingBlitz läuft nicht oder der Claude-Zugang ist aus (Einstellungen).",
                          "MeetingBlitz is not running or Claude access is off (Settings).")
            return (msg, true)
        }
        guard let url = URL(string: "http://127.0.0.1:\(config.port)/rpc") else {
            return (L.t("Ungültige Bruecken-Adresse.", "Invalid bridge address."), true)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["tool": tool, "arguments": arguments])
        req.timeoutInterval = 15

        var answer = synchronousRequest(req)
        if answer == nil, let fresh = relaunchAndWait(stale: config),
           let freshURL = URL(string: "http://127.0.0.1:\(fresh.port)/rpc") {
            // Die Datei kann von einer App stammen, die inzwischen beendet oder
            // abgestuerzt ist: dann zeigt der Port ins Leere. Einmal neu starten
            // und mit der frischen Konfiguration wiederholen.
            req.url = freshURL
            req.setValue("Bearer \(fresh.token)", forHTTPHeaderField: "Authorization")
            answer = synchronousRequest(req)
        }
        guard let (data, _) = answer else {
            return (L.t("Bruecke antwortet nicht.", "Bridge did not respond."), true)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (L.t("Antwort der Bruecke war kein gueltiges JSON.", "Bridge response was not valid JSON."), true)
        }
        if let err = obj["error"] as? String {
            return (err, true)
        }
        let payload = obj["result"] ?? [String: Any]()
        guard let out = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: out, encoding: .utf8) else {
            return (L.t("Ergebnis konnte nicht kodiert werden.", "Could not encode the result."), true)
        }
        return (text, false)
    }

    private static func synchronousRequest(_ req: URLRequest) -> (Data, URLResponse)? {
        var result: (Data, URLResponse)?
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data, let resp { result = (data, resp) }
            sema.signal()
        }.resume()
        _ = sema.wait(timeout: .now() + req.timeoutInterval + 1)
        return result
    }

    /// Liest die Bruecken-Konfiguration. Existiert sie nicht, wird die App per
    /// `open -b` gestartet und bis zu 8 s auf die Datei gewartet. Steht sie
    /// dann immer noch nicht da, laeuft die App entweder nicht oder ihr
    /// Schalter „Claude-Zugang" ist aus.
    private static func loadOrWaitForConfig() -> BridgeConfig? {
        if let c = readConfig() { return c }

        launchApp()

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let c = readConfig() { return c }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return nil
    }

    /// Startet die App und wartet, bis eine ANDERE Konfiguration dasteht als die
    /// veraltete (neuer Start = neues Token).
    private static func relaunchAndWait(stale: BridgeConfig) -> BridgeConfig? {
        launchApp()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let c = readConfig(), c.token != stale.token { return c }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return nil
    }

    private static func launchApp() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // `-n` und der Pfad, nicht `-b`: dieser MCP-Prozess traegt dieselbe
        // Bundle-ID, `open -b` haelt die App deshalb fuer gestartet und tut nichts.
        open.arguments = ["-n", Bundle.main.bundlePath]
        try? open.run()
    }

    private static func readConfig() -> BridgeConfig? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(BridgeConfig.self, from: data)
    }

    private static func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
