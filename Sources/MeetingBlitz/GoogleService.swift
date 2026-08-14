import Foundation
import AppKit
import Network
import CryptoKit
import Security
import Combine

/// Google Calendar integration (M3): OAuth 2.0 loopback flow for desktop apps
/// (PKCE, system browser), refresh token kept in the Keychain, and event
/// creation that asks Google to attach a Meet link (conferenceData.createRequest).
///
/// Why loopback + PKCE: Google's recommended flow for "installed" apps. We open
/// the real browser to the consent page, run a throwaway HTTP listener on
/// 127.0.0.1:<random port> to catch the redirect, and exchange the code with a
/// PKCE verifier so no long-lived secret rides in a URL. The client_secret for a
/// desktop client is not actually secret (Google documents this), PKCE is what
/// protects the exchange.
@MainActor
final class GoogleService: ObservableObject {
    static let shared = GoogleService()

    @Published private(set) var isConnected = false
    @Published private(set) var accountEmail: String?
    @Published private(set) var busy = false
    @Published private(set) var lastMeetLink: String?
    /// Ready-to-send share blurb (title · time · link), what actually lands in
    /// the clipboard on create (Runde 32: "dann hat er direkt diese
    /// ganze Information").
    @Published private(set) var lastShareText: String?
    /// Die zuletzt geschriebene .ics-Datei (Runde 47), zum Anhängen an eine
    /// Nachricht statt/zusätzlich zum Textblock. nil = keine erstellt.
    @Published private(set) var lastICSURL: URL?
    /// Soft status from the auto-transcription attempt (Runde 43): "aktiviert",
    /// or a hint to reconnect / check the licence. Never blocks meeting creation.
    @Published private(set) var lastArtifactNote: String?
    @Published var lastError: String?
    /// Die gespeicherte Google-Sitzung ist abgelaufen und muss einmal neu
    /// verbunden werden (Runde 48). Steuert den Hinweis im UI, damit statt einer
    /// rohen Google-Fehlermeldung ein Knopf dasteht, der das Problem löst.
    @Published private(set) var needsReconnect = false

    // openid+email only to show "verbunden als …"; calendar.events is the real
    // ask. meetings.space.settings (Runde 43) is a NON-sensitive scope that lets
    // us switch on auto-transcription for the Meet space of a meeting we create
    // (spaces.get → spaces.patch). Added here means the grant is requested on the
    // next connect, an already-connected session must reconnect once to get it.
    private let scopes = "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/meetings.space.settings openid email"
    private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    private struct ClientConfig { let clientID: String; let clientSecret: String }
    private lazy var config: ClientConfig? = Self.loadConfig()

    /// Whether any OAuth client config is present (bundled google-oauth.json or
    /// a local secrets file). Absent on any machine without one, and then the
    /// Google UI hides itself instead of offering a button that only errors.
    var hasConfig: Bool { config != nil }

    private let keychain = Keychain(service: "app.meetingblitz.MeetingBlitz.google")
    private var accessToken: String?
    private var accessExpiry: Date?

    init() {
        // Runde 56: Beim Start NICHT in den Schlüsselbund fassen. Der Zugriff
        // hier hat nach jedem Rebuild bei JEDEM Start den Passwort-Dialog
        // ausgelöst und den kompletten Launch blockiert (Rückmeldung: „warum muss
        // ich das jedes Mal machen?"). Für die Anzeige „verbunden" reicht die
        // gemerkte Kontoadresse; der echte Token wird erst beim ersten
        // API-Aufruf gelesen, also in dem Moment, in dem der Nutzer bewusst
        // etwas mit Google tut. disconnect() räumt die Adresse mit weg, der
        // Marker kann also nicht veralten. Fehlt der Token dann doch, greift
        // der bestehende expiredSession-Pfad („Google neu verbinden").
        if let mail = UserDefaults.standard.string(forKey: "googleAccountEmail") {
            isConnected = true
            accountEmail = mail
        }
    }

    private func isExpired(_ e: GError) -> Bool { if case .expiredSession = e { return true }; return false }

    /// Tote Sitzung wegräumen, damit das UI wieder „Verbinden" anbietet.
    private func dropExpiredSession() {
        disconnect()
        needsReconnect = true
    }

    // MARK: - Connect (OAuth loopback + PKCE)

    func connect() async {
        guard !busy else { return }
        guard let config else {
            lastError = L.t("OAuth-Konfiguration nicht gefunden (~/.claude/secrets/meetingblitz-google-oauth.json).", "OAuth config not found (~/.claude/secrets/meetingblitz-google-oauth.json).")
            return
        }
        busy = true; lastError = nil
        defer { busy = false }
        do {
            let verifier = Self.randomURLSafe(64)
            let challenge = Self.codeChallenge(for: verifier)
            let state = Self.randomURLSafe(24)

            let catcher = try LoopbackCatcher()
            let port = try await catcher.start()
            let redirect = "http://127.0.0.1:\(port)"

            var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            comps.queryItems = [
                .init(name: "client_id", value: config.clientID),
                .init(name: "redirect_uri", value: redirect),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: scopes),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),   // force a refresh token every time
                .init(name: "state", value: state),
            ]
            NSWorkspace.shared.open(comps.url!)

            let (code, returnedState) = try await catcher.awaitCode()
            guard returnedState == state else { throw GError.msg(L.t("Sicherheitscheck fehlgeschlagen (state).", "Security check failed (state).")) }

            try await exchangeCode(code, verifier: verifier, redirect: redirect, config: config)
            isConnected = true
            needsReconnect = false
            lastMeetLink = nil
        } catch {
            lastError = Self.human(error)
        }
    }

    func disconnect() {
        keychain.refreshToken = nil
        accessToken = nil; accessExpiry = nil
        accountEmail = nil
        UserDefaults.standard.removeObject(forKey: "googleAccountEmail")
        isConnected = false
        lastMeetLink = nil
        lastError = nil
    }

    // MARK: - Create a meeting (Apple Calendar + auto Meet link)

    /// Reset the create-form feedback (called when the form opens).
    func resetCreateFeedback() {
        lastMeetLink = nil; lastShareText = nil; lastArtifactNote = nil; lastError = nil
        lastICSURL = nil
    }

    /// Der Ablauf (Runde 27): the REAL event lives in the Apple calendar, not
    /// in Google. Google is only the Meet-link generator, we create a throwaway
    /// event with conferenceData, grab the link, delete the event again (Meet
    /// links stay valid after the source event is gone), then write an EventKit
    /// event carrying that link into the default Apple calendar. MeetingBlitz
    /// reads EventKit, so the new meeting immediately gets banner/timeline/join.
    /// Returns true on success (the link is also copied to the clipboard).
    @discardableResult
    func createAppleMeeting(title: String, start: Date, minutes: Int, calendarID: String?,
                            recurrence: RepeatRule = .none, custom: CustomRecurrence? = nil,
                            autoTranscribe: Bool = false, makeICS: Bool = false,
                            calendarService: CalendarService) async -> Bool {
        guard !busy else { return false }
        busy = true; lastError = nil; lastMeetLink = nil; lastArtifactNote = nil; lastICSURL = nil
        defer { busy = false }
        do {
            let link = try await mintMeetLink()
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTitle = cleanTitle.isEmpty ? "Meeting" : cleanTitle
            let end = start.addingTimeInterval(Double(minutes) * 60)
            try calendarService.createEvent(title: finalTitle, start: start, end: end,
                                            url: URL(string: link),
                                            calendarID: calendarID,
                                            recurrence: recurrence, custom: custom)
            // Best effort, never blocks creation: switch the Meet space to
            // auto-transcribe (Runde 43). Fails softly (licence/scope) into a note.
            if autoTranscribe { await enableAutoTranscription(meetLink: link) }
            lastMeetLink = link
            // Clipboard gets the full invite blurb, not just the bare link,
            // paste it into a chat and the receiver has everything.
            let share = Self.shareText(title: finalTitle, start: start, end: end, link: link)
            lastShareText = share
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(share, forType: .string)
            // Zusätzlich eine .ics zum Mitschicken (Runde 47). Best effort: eine
            // fehlgeschlagene Datei darf den erstellten Termin nie kaputtmachen,
            // deshalb nur eine Notiz statt eines Fehlers.
            if makeICS {
                do {
                    // Runde 50: NUR der Link in die Notiz. Datum, Uhrzeit und
                    // Serienregel stehen bereits maschinenlesbar in DTSTART/
                    // DTEND/RRULE, als Text daneben wären sie Redundanz, die
                    // beim Verschieben des Termins auch noch falsch wird
                    // (Rückmeldung: „das brauchst nicht zusätzlich").
                    lastICSURL = try ICSExport.write(title: finalTitle, start: start, end: end,
                                                     link: link,
                                                     recurrence: recurrence, custom: custom)
                } catch {
                    let msg = L.t("Kalenderdatei konnte nicht geschrieben werden.",
                                  "Could not write the calendar file.")
                    // Nicht die Transkriptions-Notiz überschreiben.
                    lastArtifactNote = lastArtifactNote.map { "\($0) · \(msg)" } ?? msg
                }
            }
            return true
        } catch {
            lastError = Self.human(error)
            return false
        }
    }

    /// Einladungsblock: Titel, Datum, Uhrzeit, Link.
    ///
    /// **Zeitzone folgt dem Rechner** (Runde 52, Rückmeldung: „dass das immer in der
    /// Zeitzone ist, wo gerade mein Rechner ist"). Vorher standen Europe/Nicosia
    /// und Europe/Berlin FEST im Code, solange man in dieser Zone sitzt stimmt
    /// das, unterwegs (Bratislava, Deutschland) verschickt er damit falsche
    /// Zeiten. Jetzt ist die erste Zeitangabe immer `TimeZone.current`.
    ///
    /// Die zweite Zeitangabe (Deutschland) bleibt aus Runde 40 erhalten, dort
    /// hatte ein Empfänger die reine Zypernzeit missverstanden, wird aber nur
    /// noch angehängt, wenn sie sich zum Termin-Zeitpunkt vom Rechner
    /// UNTERSCHEIDET. Sitzt man in Deutschland oder in einer Zone mit
    /// derselben Uhrzeit, steht die Zeit nur einmal da.
    ///
    /// DE: "Affen call\nDi, 22.07.\n18:30–19:00 Nikosia · 17:30–18:00 Berlin\n<link>"
    /// Sprache folgt der Einladungssprache (Runde 50), nicht der Oberfläche.
    static func shareText(title: String, start: Date, end: Date, link: String) -> String {
        let de = L.inviteIsDE
        let local = TimeZone.current
        let day = DateFormatter()
        day.locale = L.inviteLocale
        day.dateFormat = de ? "EE, dd.MM." : "EE, MMM d"
        day.timeZone = local

        var times = "\(timeRange(start, end, tz: local, de: de)) \(zoneLabel(local))"
        if let second = TimeZone(identifier: "Europe/Berlin"),
           second.secondsFromGMT(for: start) != local.secondsFromGMT(for: start) {
            times += " · \(timeRange(start, end, tz: second, de: de)) \(zoneLabel(second))"
        }
        return "\(title)\n\(day.string(from: start))\n\(times)\n\(link)"
    }

    /// „18:30–19:00" (DE, 24h) oder „6:30–7:00 PM" (EN, 12h) in der Zone.
    private static func timeRange(_ start: Date, _ end: Date, tz: TimeZone, de: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: de ? "de_DE" : "en_US")
        f.timeZone = tz
        f.dateFormat = de ? "HH:mm" : "h:mm a"
        return "\(f.string(from: start))–\(f.string(from: end))"
    }

    /// Ortsname aus der Zeitzonen-Kennung: „Europe/Bratislava" → „Bratislava".
    /// Bewusst der Ort und nicht das Land, die Kennung nennt nur den Ort, und
    /// aufs Land zu schließen wäre geraten (Europe/Nicosia liegt auf Zypern,
    /// Europe/Zurich in der Schweiz, das steht nirgends in der Kennung).
    private static func zoneLabel(_ tz: TimeZone) -> String {
        let city = tz.identifier.split(separator: "/").last.map(String.init) ?? tz.identifier
        return city.replacingOccurrences(of: "_", with: " ")
    }

    /// Create a short throwaway Google event with a Meet conference, return its
    /// link, and delete the event again. Polls briefly if conference creation is
    /// still pending in the create response.
    private func mintMeetLink() async throws -> String {
        let token = try await validAccessToken()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone.current
        let tz = TimeZone.current.identifier
        let now = Date()

        let body: [String: Any] = [
            "summary": "MeetingBlitz Meet-Link",
            "start": ["dateTime": iso.string(from: now), "timeZone": tz],
            "end": ["dateTime": iso.string(from: now.addingTimeInterval(900)), "timeZone": tz],
            "conferenceData": ["createRequest": [
                "requestId": UUID().uuidString,
                "conferenceSolutionKey": ["type": "hangoutsMeet"],
            ]],
        ]
        var req = URLRequest(url: URL(string:
            "https://www.googleapis.com/calendar/v3/calendars/primary/events?conferenceDataVersion=1")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let m = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(http.statusCode)"
            throw GError.msg(m)
        }
        guard let eventID = json["id"] as? String else { throw GError.msg(L.t("Google: Termin ohne ID.", "Google: event without ID.")) }

        // Usually hangoutLink is in the create response; if conference creation
        // is still pending, re-fetch the event a few times.
        var link = Self.extractLink(json)
        var tries = 0
        while link == nil, tries < 3 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            var get = URLRequest(url: URL(string:
                "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(eventID)")!)
            get.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let (d, _) = try? await URLSession.shared.data(for: get),
               let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                json = j
                link = Self.extractLink(j)
            }
            tries += 1
        }

        // Delete the throwaway event, best effort: the link matters more, and
        // it stays valid even if the cleanup fails.
        var del = URLRequest(url: URL(string:
            "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(eventID)")!)
        del.httpMethod = "DELETE"
        del.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: del)

        guard let link else { throw GError.msg(L.t("Google hat keinen Meet-Link geliefert.", "Google did not return a Meet link.")) }
        return link
    }

    private static func extractLink(_ json: [String: Any]) -> String? {
        (json["hangoutLink"] as? String)
            ?? ((json["conferenceData"] as? [String: Any]).flatMap { cd in
                    (cd["entryPoints"] as? [[String: Any]])?
                        .first { ($0["entryPointType"] as? String) == "video" }?["uri"] as? String
                        ?? (cd["entryPoints"] as? [[String: Any]])?.first?["uri"] as? String })
    }

    // MARK: - Auto-transcription (Meet API v2, Runde 43)

    /// Switch on auto-transcription for the Meet space behind a freshly minted
    /// link. Flow (GA, no preview header): resolve the meeting code to a stable
    /// space via spaces.get, then spaces.patch config.artifactConfig. Requires the
    /// `meetings.space.settings` scope (added Runde 43), an old session that
    /// predates it gets a 401/403 and the note asks the user to reconnect once. Only
    /// actually produces a transcript if his Workspace edition/licence allows it
    /// (~Business Plus+); the API accepts ON regardless, so this never throws
    /// there, it just won't generate the file.
    private func enableAutoTranscription(meetLink: String) async {
        do {
            let token = try await validAccessToken()
            guard let code = Self.meetingCode(from: meetLink) else {
                lastArtifactNote = L.t("Transkript: Meeting-Code nicht erkannt.",
                                       "Transcript: could not read meeting code.")
                return
            }

            // spaces.get accepts the meeting code as the {name}, resolve the
            // stable spaces/{id} to patch.
            var getReq = URLRequest(url: URL(string: "https://meet.googleapis.com/v2/spaces/\(code)")!)
            getReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (gData, gResp) = try await URLSession.shared.data(for: getReq)
            let gJson = (try? JSONSerialization.jsonObject(with: gData)) as? [String: Any] ?? [:]
            if let http = gResp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lastArtifactNote = Self.artifactNote(http.statusCode, gJson); return
            }
            guard let name = gJson["name"] as? String else {
                lastArtifactNote = L.t("Transkript: Space nicht gefunden.", "Transcript: space not found."); return
            }
            let spaceID = name.hasPrefix("spaces/") ? String(name.dropFirst("spaces/".count)) : name

            // spaces.patch just the transcription leaf.
            let mask = "config.artifactConfig.transcriptionConfig.autoTranscriptionGeneration"
            var comps = URLComponents(string: "https://meet.googleapis.com/v2/spaces/\(spaceID)")!
            comps.queryItems = [.init(name: "updateMask", value: mask)]
            var patchReq = URLRequest(url: comps.url!)
            patchReq.httpMethod = "PATCH"
            patchReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            patchReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["config": ["artifactConfig":
                ["transcriptionConfig": ["autoTranscriptionGeneration": "ON"]]]]
            patchReq.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (pData, pResp) = try await URLSession.shared.data(for: patchReq)
            let pJson = (try? JSONSerialization.jsonObject(with: pData)) as? [String: Any] ?? [:]
            if let http = pResp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lastArtifactNote = Self.artifactNote(http.statusCode, pJson); return
            }
            lastArtifactNote = L.t("Auto-Transkript aktiviert (feuert nur mit passender Workspace-Lizenz).",
                                   "Auto-transcript on (only fires with a supporting Workspace licence).")
        } catch {
            lastArtifactNote = L.t("Transkript nicht aktiviert: \(Self.human(error))",
                                   "Transcript not enabled: \(Self.human(error))")
        }
    }

    /// The Meet meeting code (last path segment) from a hangout link.
    private static func meetingCode(from link: String) -> String? {
        guard let url = URL(string: link) else { return nil }
        let code = url.lastPathComponent
        return (code.isEmpty || code == "/") ? nil : code
    }

    /// Friendly note for a failed artifact call. 401/403 on an app-created
    /// meeting (the user is the organiser) almost always means the new scope is
    /// missing on an old session → reconnect.
    /// Übersetzt einen Fehler der Meet-API in einen Hinweis, der auch WEITERHILFT.
    ///
    /// Runde 53: Vorher wurde JEDER 401/403 als „bitte Google neu verbinden"
    /// ausgegeben. Das schickte auf die falsche Fährte, er hatte gerade
    /// frisch verbunden und die Meldung kam trotzdem. Ein 403 hat hier drei
    /// völlig verschiedene Ursachen, und Google nennt sie in der Fehlermeldung;
    /// wir haben sie bloß weggeworfen. Jetzt wird unterschieden.
    private static func artifactNote(_ status: Int, _ json: [String: Any]) -> String {
        let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
        let lower = msg.lowercased()

        // (1) Die Meet-API ist im Cloud-Projekt gar nicht eingeschaltet.
        if lower.contains("has not been used in project") || lower.contains("service_disabled")
            || lower.contains("is disabled") {
            let project = Self.loadConfig()?.clientID.split(separator: "-").first.map(String.init) ?? ""
            let link = "https://console.cloud.google.com/apis/library/meet.googleapis.com"
                + (project.isEmpty ? "" : "?project=\(project)")
            return L.t("Transkript nicht aktiviert: Die Google-Meet-API ist im Projekt nicht eingeschaltet. Einmal hier aktivieren: \(link)",
                       "Transcript not enabled: the Google Meet API is off in your project. Enable it once: \(link)")
        }
        // (2) Wirklich eine fehlende Berechtigung.
        if lower.contains("scope") || status == 401 {
            return L.t("Transkript nicht aktiviert, bitte Google einmal neu verbinden (neue Berechtigung nötig).",
                       "Transcript not enabled, please reconnect Google once (new permission needed).")
        }
        // (3) Alles andere, typischerweise die Workspace-Lizenz: Googles eigenen
        //     Wortlaut zeigen statt zu raten.
        return L.t("Transkript nicht aktiviert: \(msg)", "Transcript not enabled: \(msg)")
    }

    // MARK: - Tokens

    private func exchangeCode(_ code: String, verifier: String, redirect: String, config: ClientConfig) async throws {
        let tok = try await postForm(tokenURL, [
            "client_id": config.clientID,
            "client_secret": config.clientSecret,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirect,
        ])
        guard let access = tok["access_token"] as? String else { throw GError.msg(L.t("Kein Access-Token erhalten.", "No access token received.")) }
        accessToken = access
        accessExpiry = Date().addingTimeInterval(((tok["expires_in"] as? Double) ?? 3600) - 60)
        if let refresh = tok["refresh_token"] as? String { keychain.refreshToken = refresh }
        if let idToken = tok["id_token"] as? String, let email = Self.email(fromIDToken: idToken) {
            accountEmail = email
            UserDefaults.standard.set(email, forKey: "googleAccountEmail")
        }
    }

    /// A live access token, refreshing via the stored refresh token if needed.
    private func validAccessToken() async throws -> String {
        if let t = accessToken, let e = accessExpiry, e > Date() { return t }
        guard let refresh = keychain.refreshToken, let config else { throw GError.msg(L.t("Nicht mit Google verbunden.", "Not connected to Google.")) }
        let tok: [String: Any]
        do {
            tok = try await postForm(tokenURL, [
                "client_id": config.clientID,
                "client_secret": config.clientSecret,
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ])
        } catch let e as GError where isExpired(e) {
            dropExpiredSession()
            throw e
        }
        guard let access = tok["access_token"] as? String else {
            dropExpiredSession()
            throw GError.expiredSession
        }
        accessToken = access
        accessExpiry = Date().addingTimeInterval(((tok["expires_in"] as? Double) ?? 3600) - 60)
        return access
    }

    private func postForm(_ url: URL, _ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = fields.map { "\($0.key)=\(Self.formEscape($0.value))" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Abgelaufene/zurückgezogene Sitzung als EIGENEN Fall behandeln: sie
            // kam vorher als rohe englische Google-Meldung durch, die App blieb
            // auf „Verbunden" stehen und der nächste Klick scheiterte genauso
            // (Runde 48).
            if (json["error"] as? String) == "invalid_grant" { throw GError.expiredSession }
            let msg = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "HTTP \(http.statusCode)"
            throw GError.msg(msg)
        }
        return json
    }

    // MARK: - Config & helpers

    private static func loadConfig() -> ClientConfig? {
        // Prefer a copy bundled with the app (needed if it is ever shipped to a
        // colleague), then fall back to a local secrets file.
        let candidates = [
            Bundle.main.url(forResource: "google-oauth", withExtension: "json"),
            URL(fileURLWithPath: ("~/.claude/secrets/meetingblitz-google-oauth.json" as NSString).expandingTildeInPath),
        ].compactMap { $0 }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let node = (obj["installed"] as? [String: Any]) ?? (obj["web"] as? [String: Any]) ?? obj
            if let id = node["client_id"] as? String, let secret = node["client_secret"] as? String {
                return ClientConfig(clientID: id, clientSecret: secret)
            }
        }
        return nil
    }

    private static func email(fromIDToken jwt: String) -> String? {
        let segs = jwt.split(separator: ".")
        guard segs.count >= 2 else { return nil }
        var b64 = String(segs[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj["email"] as? String
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var d = Data(count: bytes)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64url(d)
    }

    private static func codeChallenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEscape(_ s: String) -> String {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
    }

    private static func human(_ e: Error) -> String {
        if let g = e as? GError, case .msg(let m) = g { return m }
        return e.localizedDescription
    }
}

private enum GError: LocalizedError {
    case msg(String)
    /// Google antwortet mit `invalid_grant`, wenn das Refresh-Token abgelaufen
    /// oder zurückgezogen wurde. Häufigster Grund hier: der OAuth-Client steht
    /// noch im Testing-Modus, da gelten Refresh-Tokens nur **7 Tage** (Runde 48).
    case expiredSession
    var errorDescription: String? {
        switch self {
        case .msg(let m): return m
        case .expiredSession: return L.t("Google-Verbindung abgelaufen.", "Google session expired.")
        }
    }
}

/// Silences Swift 6's Sendable check for Network types we deliberately confine
/// to one serial queue.
private struct Unchecked<T>: @unchecked Sendable { let v: T }

/// One-shot HTTP listener on 127.0.0.1:<random port> that captures the OAuth
/// redirect. All state is touched only on `queue` (a serial queue), so the
/// @unchecked Sendable conformance is sound.
private final class LoopbackCatcher: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.meetingblitz.MeetingBlitz.oauth")
    private var portResumed = false
    private var finished = false
    private var codeCont: CheckedContinuation<(String, String?), Error>?
    private var pending: Result<(String, String?), Error>?

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
    }

    /// Start listening; resolves to the OS-assigned port once bound.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.portResumed else { return }
                switch state {
                case .ready:
                    self.portResumed = true
                    if let p = self.listener.port?.rawValue { cont.resume(returning: p) }
                    else { cont.resume(throwing: GError.msg(L.t("Kein lokaler Port.", "No local port."))) }
                case .failed(let e):
                    self.portResumed = true
                    cont.resume(throwing: e)
                case .cancelled:
                    self.portResumed = true
                    cont.resume(throwing: GError.msg(L.t("Listener abgebrochen.", "Listener cancelled.")))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
        }
    }

    /// Wait for the browser redirect and return (code, state).
    func awaitCode() async throws -> (String, String?) {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let p = self.pending { self.pending = nil; cont.resume(with: p); return }
                self.codeCont = cont
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        let box = Unchecked(v: conn)
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let conn = box.v
            let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let (code, state, err) = Self.parse(req)
            if let code {
                self.send(conn, body: Self.okPage) { self.finish(with: .success((code, state))) }
            } else if let err {
                self.send(conn, body: Self.errPage(err)) { self.finish(with: .failure(GError.msg(L.t("Google-Login: \(err)", "Google login: \(err)")))) }
            } else {
                // Stray request (favicon etc.), answer and keep waiting.
                self.send(conn, body: Self.okPage) {}
            }
        }
    }

    private func send(_ conn: NWConnection, body: String, then: @escaping () -> Void) {
        let connBox = Unchecked(v: conn)
        let thenBox = Unchecked(v: then)
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
            connBox.v.cancel()
            thenBox.v()
        })
    }

    private func finish(with result: Result<(String, String?), Error>) {
        guard !finished else { return }
        finished = true
        listener.cancel()
        if let c = codeCont { codeCont = nil; c.resume(with: result) }
        else { pending = result }
    }

    private static func parse(_ req: String) -> (code: String?, state: String?, error: String?) {
        guard let line = req.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first else { return (nil, nil, nil) }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1\(parts[1])") else { return (nil, nil, nil) }
        let q = comps.queryItems ?? []
        return (q.first { $0.name == "code" }?.value,
                q.first { $0.name == "state" }?.value,
                q.first { $0.name == "error" }?.value)
    }

    private static let okPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>MeetingBlitz</title></head>
    <body style="font-family:-apple-system,system-ui;text-align:center;padding-top:90px;color:#1d1d1f">
    <div style="font-size:52px">🚀</div>
    <h2>MeetingBlitz is connected</h2>
    <p style="color:#6e6e73">You can close this window now.</p>
    </body></html>
    """

    private static func errPage(_ err: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>MeetingBlitz</title></head>
        <body style="font-family:-apple-system,system-ui;text-align:center;padding-top:90px;color:#1d1d1f">
        <div style="font-size:52px">⚠️</div>
        <h2>Login cancelled</h2>
        <p style="color:#6e6e73">\(err)</p>
        </body></html>
        """
    }
}

/// Minimal Keychain wrapper for a single generic-password item (the refresh
/// token). Ad-hoc-signed rebuilds change the code signature, so macOS may prompt
/// once to allow access after a rebuild, click "Allow".
private struct Keychain {
    let service: String
    /// Frühere Service-Namen, falls die Bundle-ID einmal wechselt: Der
    /// Schlüsselbund-Eintrag hängt am Service-Namen, ohne Rückfall wäre eine
    /// bestehende Sitzung nach einem Wechsel weg.
    var legacyServices: [String] = []
    private let account = "refresh_token"

    private func read(service s: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: s,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var refreshToken: String? {
        get {
            if let current = read(service: service) { return current }
            for legacy in legacyServices {
                if let old = read(service: legacy) { return old }
            }
            return nil
        }
        nonmutating set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(base as CFDictionary)
            guard let value = newValue else { return }
            var add = base
            add[kSecValueData as String] = Data(value.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
