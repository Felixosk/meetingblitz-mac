import Foundation

/// Runde 124: Aufbau der spaces.patch-Anfragen für Transkript und Gemini-Notizen.
///
/// Belegt in der Meet REST API v2 (Discovery-Dokument + Referenz spaces#SpaceConfig, gelesen 20.11.2026):
/// - `config.artifactConfig.transcriptionConfig.autoTranscriptionGeneration` = ON/OFF
/// - `config.artifactConfig.smartNotesConfig.autoSmartNotesGeneration` = ON/OFF ("Take notes for me")
/// - Beide brauchen beim PATCH nur `meetings.space.settings` (oder `meetings.space.created`), also keinen neuen Scope.
/// - Ein Sprachfeld gibt es NICHT (weder in SpaceConfig noch in Calendar conferenceData). Die Sprache
///   lässt sich nur im Meeting ("Meeting language") oder in Google Kalender (Videoanruf-Optionen › Meeting records) wählen.
///
/// Zwei getrennte PATCH-Aufrufe statt einem: lehnt Google die Gemini-Notizen ab (z. B. Tarif ohne Gemini),
/// bleibt das Transkript trotzdem an.
enum MeetArtifacts {
    enum Kind: String, CaseIterable { case transcript, smartNotes }

    static func mask(_ k: Kind) -> String {
        switch k {
        case .transcript: return "config.artifactConfig.transcriptionConfig.autoTranscriptionGeneration"
        case .smartNotes: return "config.artifactConfig.smartNotesConfig.autoSmartNotesGeneration"
        }
    }

    static func body(_ k: Kind) -> [String: Any] {
        switch k {
        case .transcript: return ["config": ["artifactConfig": ["transcriptionConfig": ["autoTranscriptionGeneration": "ON"]]]]
        case .smartNotes: return ["config": ["artifactConfig": ["smartNotesConfig": ["autoSmartNotesGeneration": "ON"]]]]
        }
    }

    /// Welche Teile beim Erstellen eingeschaltet werden.
    static func kinds(transcribe: Bool, smartNotes: Bool) -> [Kind] {
        (transcribe ? [Kind.transcript] : []) + (smartNotes ? [Kind.smartNotes] : [])
    }

    static func request(spaceID: String, kind: Kind, token: String) -> URLRequest? {
        guard var comps = URLComponents(string: "https://meet.googleapis.com/v2/spaces/\(spaceID)") else { return nil }
        comps.queryItems = [.init(name: "updateMask", value: mask(kind))]
        guard let url = comps.url, let data = try? JSONSerialization.data(withJSONObject: body(kind)) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "PATCH"
        r.timeoutInterval = 20
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = data
        return r
    }

    /// Wert, den Google nach dem PATCH zurückmeldet ("ON", "OFF" oder nil).
    static func answer(_ json: [String: Any], _ k: Kind) -> String? {
        let ac = (json["config"] as? [String: Any])?["artifactConfig"] as? [String: Any]
        switch k {
        case .transcript: return (ac?["transcriptionConfig"] as? [String: Any])?["autoTranscriptionGeneration"] as? String
        case .smartNotes: return (ac?["smartNotesConfig"] as? [String: Any])?["autoSmartNotesGeneration"] as? String
        }
    }

    // MARK: - Selbsttest (--selftest), ohne Netz

    static func failures() -> [String] {
        var f: [String] = []
        func json(_ r: URLRequest?) -> [String: Any] {
            guard let d = r?.httpBody else { return [:] }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        }
        if kinds(transcribe: true, smartNotes: true) != [.transcript, .smartNotes] { f.append("Artefakte: beide an") }
        if kinds(transcribe: false, smartNotes: true) != [.smartNotes] { f.append("Artefakte: nur Notizen") }
        if !kinds(transcribe: false, smartNotes: false).isEmpty { f.append("Artefakte: beide aus muss leer sein") }

        let t = request(spaceID: "abc123", kind: .transcript, token: "tok")
        let n = request(spaceID: "abc123", kind: .smartNotes, token: "tok")
        for (name, r, k) in [("Transkript", t, Kind.transcript), ("Notizen", n, Kind.smartNotes)] {
            guard let r else { f.append("Artefakte \(name): keine Anfrage"); continue }
            if r.httpMethod != "PATCH" { f.append("Artefakte \(name): Methode \(r.httpMethod ?? "-")") }
            let c = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)
            if c?.path != "/v2/spaces/abc123" { f.append("Artefakte \(name): Pfad \(c?.path ?? "-")") }
            if c?.queryItems?.first(where: { $0.name == "updateMask" })?.value != mask(k) { f.append("Artefakte \(name): updateMask") }
            if r.value(forHTTPHeaderField: "Authorization") != "Bearer tok" { f.append("Artefakte \(name): Token") }
            // Die Antwort-Prüfung muss den eigenen Body als "ON" lesen (gleicher Pfad wie Googles Antwort).
            if answer(json(r), k) != "ON" { f.append("Artefakte \(name): Body/Antwort-Pfad passt nicht") }
            // Kein Sprachfeld (gibt es in der API nicht) und nur der eine Zweig im Body.
            let ac = (json(r)["config"] as? [String: Any])?["artifactConfig"] as? [String: Any] ?? [:]
            if ac.count != 1 { f.append("Artefakte \(name): Body enthält mehr als einen Zweig") }
        }
        // Rotprobe: falscher Zweig darf nicht als ON gelesen werden.
        if answer(json(t), .smartNotes) != nil { f.append("Artefakte: Rotprobe Notizen aus Transkript-Body") }
        if answer(["config": ["artifactConfig": ["smartNotesConfig": ["autoSmartNotesGeneration": "OFF"]]]], .smartNotes) != "OFF" {
            f.append("Artefakte: OFF nicht erkannt")
        }
        return f
    }
}
