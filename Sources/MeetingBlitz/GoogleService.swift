import EventKit
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
    /// Kennungen der zuletzt per `createAppleMeeting` angelegten Termine
    /// (Runde 78, MCP): ein Aufruf legt bei „Beide" zwei Termine an, deshalb
    /// eine Liste statt einer einzelnen Kennung.
    @Published private(set) var lastCreatedEventIDs: [String] = []
    /// Titel, Start und Ende des zuletzt angelegten Termins. Die Kennung allein
    /// reicht nicht: bei Google-Kalendern (CalDAV) ändert sie sich nach dem Sync,
    /// dann hielte die Kollisions-Warnung den eigenen Termin für fremd.
    @Published private(set) var lastCreatedSlot: (title: String, start: Date, end: Date)?

    // openid+email only to show "verbunden als …"; calendar.events is the real
    // ask. meetings.space.settings (Runde 43) is a NON-sensitive scope that lets
    // us switch on auto-transcription for the Meet space of a meeting we create
    // (spaces.get → spaces.patch). Added here means the grant is requested on the
    // next connect, an already-connected session must reconnect once to get it.
    /// Runde 109: der Mail-Scope (`gmail.send`, nur senden, nicht lesen) wird nur
    /// angefragt, wenn "Mail an Gast anbieten" an ist. Ein Fremdnutzer des
    /// öffentlichen Repos sieht "darf Mails senden" nie, wenn er es nicht nutzt.
    static let gmailSendScope = "https://www.googleapis.com/auth/gmail.send"
    private var scopes: String {
        var s = "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/meetings.space.settings openid email"
        if AppState.shared.mailInviteEnabled { s += " " + Self.gmailSendScope }
        return s
    }
    /// Gewährte Scopes aus der letzten Token-Antwort (Feld `scope`).
    var grantedScopes: String { UserDefaults.standard.string(forKey: "googleGrantedScopes") ?? "" }
    /// Nur Testschalter `MB_DEMO_GMAIL`: Demo tut so, als sei das Senden erlaubt (kein echter Versand ohne Anmeldung).
    private static let demoGmail = ProcessInfo.processInfo.environment["MB_DEMO_GMAIL"] != nil
    var canSendMail: Bool { Self.demoGmail || grantedScopes.contains("gmail.send") }
    /// Ergebnis des letzten Mail-Versands für die Ergebnisansicht.
    enum MailStatus: Equatable { case sent([String]); case failed(MailInvite.Failure) }
    @Published var lastMailStatus: MailStatus?
    @Published private(set) var mailBusy = false
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

    /// Läuft dieser Prozess als Zweitinstanz (der `--mcp`-Prozess, den Claude
    /// per `open -n` startet)? Die teilt sich Schlüsselbund und Einstellungen
    /// mit der echten App, hat aber kein Fenster, in dem ein Mensch etwas
    /// freigeben könnte. Sie darf deshalb nie im gemeinsamen Zustand aufräumen
    /// (Runde 81: drei solcher Prozesse standen verwaist herum).
    static var isSecondaryInstance: Bool { CommandLine.arguments.contains("--mcp") }

    /// Tote Sitzung wegräumen, damit das UI wieder „Verbinden" anbietet.
    private func dropExpiredSession() {
        guard !Self.isSecondaryInstance else {
            // Nur für sich selbst vergessen, Schlüsselbund und Kontoadresse
            // gehören der echten App.
            isConnected = false
            needsReconnect = true
            return
        }
        disconnect()
        needsReconnect = true
    }

    // MARK: - Connect (OAuth loopback + PKCE)

    func connect() async {
        guard !busy else { return }
        guard let config else {
            // Den Pfad nennen, den ein neuer Nutzer auch anlegen würde.
            lastError = L.t("OAuth-Konfiguration nicht gefunden. Erwartet in ~/Library/Application Support/MeetingBlitz/google-oauth.json (Anleitung in der README).",
                            "OAuth config not found. Expected at ~/Library/Application Support/MeetingBlitz/google-oauth.json (see the README).")
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
                .init(name: "include_granted_scopes", value: "true"),
                .init(name: "prompt", value: "consent"),   // force a refresh token every time
                .init(name: "state", value: state),
            ]
            NSWorkspace.shared.open(comps.url!)

            // Runde 88: Wer den Browser-Tab schließt, bekam nie eine Antwort,
            // `busy` blieb für immer an und JEDE Google-Funktion (auch Sofort-
            // Meeting) tat still nichts bis zum Neustart. Nach 3 Minuten aufgeben.
            catcher.timeout(after: Self.loginTimeoutSeconds)
            let (code, returnedState) = try await catcher.awaitCode()
            guard returnedState == state else { throw GError.msg(L.t("Sicherheitscheck fehlgeschlagen (state).", "Security check failed (state).")) }

            try await exchangeCode(code, verifier: verifier, redirect: redirect, config: config)
            isConnected = true
            needsReconnect = false
            lastMeetLink = nil
            // Runde 81: Der rote Satz unter „Sofort"/„Neues Meeting" lebt in
            // AppState, nicht hier. Ohne das blieb er nach einem erfolgreichen
            // Neuverbinden stehen, während die Einstellungen längst grün waren.
            AppState.shared.instantError = nil
        } catch {
            lastError = Self.human(error)
        }
    }

    nonisolated static let loginTimeoutSeconds: TimeInterval = 180
    nonisolated static var loginTimeoutMessage: String {
        L.t("Google-Login abgebrochen: keine Antwort aus dem Browser nach 3 Minuten. Einfach nochmal verbinden.",
            "Google login cancelled: no answer from the browser after 3 minutes. Just connect again.")
    }

    func disconnect() {
        keychain.refreshToken = nil
        accessToken = nil; accessExpiry = nil
        accountEmail = nil
        UserDefaults.standard.removeObject(forKey: "googleAccountEmail")
        UserDefaults.standard.removeObject(forKey: "googleGrantedScopes")
        isConnected = false
        lastMeetLink = nil
        lastError = nil
    }

    // MARK: - Create a meeting (Apple Calendar + auto Meet link)

    /// Reset the create-form feedback (called when the form opens).
    func resetCreateFeedback() {
        lastMeetLink = nil; lastShareText = nil; lastArtifactNote = nil; lastError = nil
        lastICSURL = nil; lastCreatedEventIDs = []; lastMailStatus = nil
    }

    /// Der Ablauf (Runde 27): the REAL event lives in the Apple calendar, not
    /// in Google. Google is only the Meet-link generator, we create a throwaway
    /// event with conferenceData, grab the link, delete the event again (Meet
    /// links stay valid after the source event is gone), then write an EventKit
    /// event carrying that link into the default Apple calendar. MeetingBlitz
    /// reads EventKit, so the new meeting immediately gets banner/timeline/join.
    /// Returns true on success (the link is also copied to the clipboard).
    /// `copyInvite` (Runde 78): steuert NUR die Zwischenablage. `lastShareText`
    /// wird immer gesetzt (der Kopier-Knopf in der Ergebnisansicht bleibt),
    /// aber ohne diesen Schalter fasst die Funktion die Zwischenablage selbst
    /// nicht an. Wichtig für den Schalter „Einladungstext kopieren" UND für
    /// MCP-Aufrufe mit `copyInvite: false`.
    @discardableResult
    func createAppleMeeting(title: String, start: Date, minutes: Int, calendarIDs: [String?],
                            recurrence: RepeatRule = .none, custom: CustomRecurrence? = nil,
                            autoTranscribe: Bool = false, autoSmartNotes: Bool = false, makeICS: Bool = false, copyInvite: Bool = true,
                            calendarService: CalendarService) async -> Bool {
        guard !busy else { return false }
        busy = true; lastError = nil; lastMeetLink = nil; lastArtifactNote = nil; lastICSURL = nil
        lastCreatedEventIDs = []
        defer { busy = false }
        // Runde 122: Testschalter MB_DRY_CREATE=1 (nur Umgebungsvariable): simulierter Erfolg mit Fake-Link,
        // KEIN Google-Aufruf, KEIN EventKit, keine Zwischenablage, keine .ics. Für Videos der Schließ-Animation.
        if DryCreate.isOn {
            // Wie echt: Google braucht ~1,5 s, danach meldet EventKit eine Änderung (hier nur die Meldung, kein Schreiben).
            try? await Task.sleep(nanoseconds: UInt64((Double(ProcessInfo.processInfo.environment["MB_DRY_DELAY"] ?? "1.5") ?? 1.5) * 1e9))
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let s0 = DryCreate.startOverrideMinutes.map { Date().addingTimeInterval($0 * 60) } ?? start
            let e0 = s0.addingTimeInterval(Double(minutes) * 60)
            lastCreatedSlot = (t.isEmpty ? "Meeting" : t, s0, e0)
            let fakeID = "dry-\(Int(Date().timeIntervalSince1970))"
            DryCreate.fakeMeetings.append(Meeting(id: fakeID, title: t.isEmpty ? "Meeting" : t, start: s0, end: e0,
                isAllDay: false, isBirthday: false, calendarTitle: "Dry", calendarID: calendarIDs.first ?? nil,
                color: .blue, joinURL: URL(string: DryCreate.fakeLink), contactID: nil, calendarItemID: nil))
            lastCreatedEventIDs = [fakeID]
            lastMeetLink = DryCreate.fakeLink
            // Wie EventKit nach einem echten Schreiben: Änderungs-Meldung sofort und noch einmal kurz danach.
            NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NotificationCenter.default.post(name: .EKEventStoreChanged, object: nil) }
            print("dry-create ok \(Date().timeIntervalSince1970)"); fflush(stdout)
            return true
        }
        do {
            let link = try await mintMeetLink()
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalTitle = cleanTitle.isEmpty ? "Meeting" : cleanTitle
            let end = start.addingTimeInterval(Double(minutes) * 60)
            // One Meet link, one event per chosen calendar ("beide" writes two).
            // The first failure aborts: a half-written state is worse than a
            // clear error, and the link is already minted either way.
            // Runde 88: scheitert die zweite Hälfte („beide"), wird die erste
            // wieder gelöscht, so wie es der MCP-Weg seit Runde 80 tut.
            // Vorher blieb ein halber Termin mit gültigem Meet-Link stehen.
            let wholeSeries = recurrence != .none
            let createdIDs = try Self.writeAll(
                calendarIDs.isEmpty ? [nil] : calendarIDs,
                create: { cid in
                    try calendarService.createEvent(title: finalTitle, start: start, end: end,
                                                    url: URL(string: link), calendarID: cid,
                                                    recurrence: recurrence, custom: custom)
                },
                rollback: { id in try? calendarService.deleteEvent(id: id, wholeSeries: wholeSeries) })
            lastCreatedEventIDs = createdIDs
            lastCreatedSlot = (finalTitle, start, end)
            // Best effort, never blocks creation: switch the Meet space to
            // auto-transcribe (Runde 43). Fails softly (licence/scope) into a note.
            if autoTranscribe || autoSmartNotes {
                await enableMeetArtifacts(meetLink: link, transcribe: autoTranscribe, smartNotes: autoSmartNotes)
            }
            lastMeetLink = link
            // Clipboard gets the full invite blurb, not just the bare link,
            // paste it into a chat and the receiver has everything.
            let share = Self.shareText(title: finalTitle, start: start, end: end, link: link)
            lastShareText = share
            if copyInvite {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(share, forType: .string)
            }
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

    /// Schreibt in alle Ziele; scheitert eines, werden die schon angelegten
    /// über `rollback` wieder entfernt und der Fehler weitergereicht (Runde 88).
    /// Rein, damit `--selftest` den Fehlerfall ohne Kalender prüfen kann.
    nonisolated static func writeAll(_ targets: [String?], create: (String?) throws -> String,
                                     rollback: (String) -> Void) throws -> [String] {
        var done: [String] = []
        do {
            for t in targets {
                let id = try create(t)
                if !id.isEmpty { done.append(id) }
            }
        } catch {
            for id in done.reversed() { rollback(id) }
            throw error
        }
        return done
    }

    /// Einladungsblock: Titel, Datum, Uhrzeit, Link.
    ///
    /// **Zeitzone folgt dem Rechner** (Runde 52, Rückmeldung: „dass das immer in der
    /// Zeitzone ist, wo gerade mein Rechner ist"). Vorher standen zwei Zonen
    /// FEST im Code, solange man in diesen Zonen sitzt stimmt
    /// das, unterwegs verschickt man damit falsche
    /// Zeiten. Jetzt ist die erste Zeitangabe immer `TimeZone.current`.
    ///
    /// Die zweite Zeitangabe (Deutschland) bleibt aus Runde 40 erhalten, dort
    /// hatte ein Empfänger die reine Ortszeit missverstanden, wird aber nur
    /// noch angehängt, wenn sie sich zum Termin-Zeitpunkt vom Rechner
    /// UNTERSCHEIDET. Sitzt man in Deutschland oder in einer Zone mit
    /// derselben Uhrzeit, steht die Zeit nur einmal da.
    ///
    /// DE: "Affen call\nDi, 22.07.\n18:30–19:00 Nikosia · 17:30–18:00 Berlin\n<link>"
    /// Sprache folgt der Einladungssprache (Runde 50), nicht der Oberfläche.
    ///
    /// `link` optional seit Runde 78 (MCP): ein per Claude ohne Meet-Link
    /// angelegter Termin bekommt denselben Einladungsblock, nur ohne die
    /// letzte Zeile.
    ///
    /// Runde 86: Statt Berlin fest im Code stehen jetzt die eigene Zone plus
    /// jede Zone mit Haken aus der Zeitzonen-Leiste des Termin-Fensters
    /// (`ZoneBook`). Liegt eine Zone an einem anderen Kalendertag, steht ihr
    /// Wochentag dabei („01:00–01:30 Manila (Mi)").
    /// Runde 119: nur während „Erstellen“ gesetzt, wenn die Text-Vorschau von Hand geändert wurde.
    nonisolated(unsafe) static var textTemplateOverride: String?

    /// Gespeicherte Text-Vorlage der Einladungssprache; leer = nil (alter Aufbau, Byte für Byte).
    static func storedInviteTextTemplate() -> String? {
        let v = UserDefaults.standard.string(forKey: L.inviteIsDE ? "inviteTextDE" : "inviteTextEN") ?? ""
        return v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : v
    }

    /// Vorlage → fertiger Einladungstext (gleiche Marken wie die Mail). Ohne Link entfällt die leere Schlusszeile.
    static func renderInviteText(_ template: String, title: String, start: Date, end: Date, link: String?,
                                 zoneIDs: [String]?) -> String {
        let list = ZoneBook.load()
        var f = MailInvite.Fields(title: title, start: start, end: end, link: link ?? "",
                                  zoneIDs: zoneIDs ?? ZoneBook.invitedIDs(from: list),
                                  labels: ZoneBook.labels(from: list), de: L.inviteIsDE)
        f.timesSeparator = nil
        var out = MailInvite.render(template, f)
        if (link ?? "").isEmpty { while out.hasSuffix("\n") { out.removeLast() } }
        return out
    }

    static func shareText(title: String, start: Date, end: Date, link: String?,
                          zoneIDs: [String]? = nil) -> String {
        // Runde 119: eigene Vorlage (Einstellungen „Invite text“ oder Änderung nur für dieses Meeting).
        if let tpl = Self.textTemplateOverride ?? Self.storedInviteTextTemplate() {
            let list0 = ZoneBook.load()
            return renderInviteText(tpl, title: title, start: start, end: end, link: link,
                                    zoneIDs: zoneIDs ?? ZoneBook.invitedIDs(from: list0))
        }
        let de = L.inviteIsDE
        let local = TimeZone.current
        let day = DateFormatter()
        day.locale = L.inviteLocale
        day.dateFormat = de ? "EE, dd.MM." : "EE, MMM d"
        day.timeZone = local

        let list = ZoneBook.load()
        let times = inviteTimes(start: start, end: end, zoneIDs: zoneIDs ?? ZoneBook.invitedIDs(from: list),
                                labels: ZoneBook.labels(from: list))
        var block = "\(title)\n\(day.string(from: start))\n\(times)"
        if let link, !link.isEmpty { block += "\n\(link)" }
        return block
    }

    /// Zeitzeile(n) des Einladungstexts: eigene Zone zuerst, dann die
    /// übergebenen. Bis zu zwei Zonen in einer Zeile mit „ · " (wie bisher),
    /// ab drei eine Zeile pro Zone, sonst wird die Zeile unlesbar lang.
    static func inviteTimes(start: Date, end: Date, zoneIDs: [String], labels: [String: String] = [:],
                            separator: String? = nil) -> String {
        let de = L.inviteIsDE
        let local = TimeZone.current
        let own = ZoneNames.canonical(local.identifier)
        var zones = [local]
        for id in zoneIDs where ZoneNames.canonical(id) != own {
            if let tz = TimeZone(identifier: id), !zones.contains(where: { $0.identifier == tz.identifier }) {
                zones.append(tz)
            }
        }
        var ownCal = Calendar(identifier: .gregorian); ownCal.timeZone = local
        let ownDay = ownCal.dateComponents([.year, .month, .day], from: start)
        let parts = zones.map { tz -> String in
            var s = "\(timeRange(start, end, tz: tz, de: de)) \(ZoneBook.displayName(tz.identifier, labels: labels))"
            var c = Calendar(identifier: .gregorian); c.timeZone = tz
            if c.dateComponents([.year, .month, .day], from: start) != ownDay {
                let f = DateFormatter(); f.locale = L.inviteLocale; f.timeZone = tz; f.dateFormat = "EE"
                s += " (\(f.string(from: start)))"
            }
            return s
        }
        return parts.joined(separator: separator ?? (parts.count <= 2 ? " · " : "\n"))
    }

    /// „18:30–19:00" (DE, 24h) oder „6:30–7:00 PM" (EN, 12h) in der Zone.
    static func timeRange(_ start: Date, _ end: Date, tz: TimeZone, de: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: de ? "de_DE" : "en_US")
        f.timeZone = tz
        f.dateFormat = de ? "HH:mm" : "h:mm a"
        return "\(f.string(from: start))–\(f.string(from: end))"
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
    /// actually produces a transcript if the Workspace edition/licence allows it
    /// (~Business Plus+); the API accepts ON regardless, so this never throws
    /// there, it just won't generate the file.
    private func enableMeetArtifacts(meetLink: String, transcribe: Bool, smartNotes: Bool) async {
        let kinds = MeetArtifacts.kinds(transcribe: transcribe, smartNotes: smartNotes)
        guard !kinds.isEmpty else { return }
        var results: [MeetArtifacts.Kind: (ok: Bool, note: String)] = [:]
        switch await resolveMeetSpace(meetLink: meetLink) {
        case .failure(let note):
            for k in kinds { results[k] = (false, Self.kindLabel(k) + ": " + note) }
        case .success(let spaceID, let token):
            // Getrennt (Runde 124): lehnt Google die Gemini-Notizen ab, bleibt das Transkript an.
            for k in kinds { results[k] = await patchArtifact(spaceID: spaceID, token: token, kind: k) }
        }
        // Runde 123/124: Ergebnis merken (Einstellungen › Meetings) und bei Misserfolg EIN stiller Hinweis.
        let d = UserDefaults.standard
        if let r = results[.transcript] {
            d.set(r.note, forKey: "lastTranscriptNote"); d.set(Date(), forKey: "lastTranscriptDate"); d.set(r.ok, forKey: "lastTranscriptOK")
        }
        if let r = results[.smartNotes] {
            d.set(r.note, forKey: "lastSmartNotesNote"); d.set(Date(), forKey: "lastSmartNotesDate"); d.set(r.ok, forKey: "lastSmartNotesOK")
        }
        lastArtifactNote = kinds.compactMap { results[$0]?.note }.joined(separator: " · ")
        let failed = kinds.filter { results[$0]?.ok != true }
        guard !failed.isEmpty else { return }
        let apiOff = failed.contains { (results[$0]?.note ?? "").contains("Meet-API") || (results[$0]?.note ?? "").contains("Meet API") }
        let title: String
        if failed.count == 2 {
            title = L.t("Transkript und Gemini-Notizen nicht aktiv", "Transcript and Gemini notes are not on")
        } else if failed.first == .transcript {
            title = L.t("Auto-Transkription nicht aktiv", "Auto-transcription is not on")
        } else {
            title = L.t("Gemini-Notizen nicht automatisch an", "Gemini notes did not switch on")
        }
        QuietNotice.showText(title: title,
                             subtitle: apiOff
                                ? L.t("Meet-API in Google einschalten (Link: Einstellungen › Meetings)", "Turn on the Meet API in Google (link: Settings › Meetings)")
                                : L.t("Bitte im Meeting von Hand starten. Details: Einstellungen › Meetings",
                                           "Start it by hand in the meeting. Details: Settings › Meetings"))
    }

    private enum SpaceLookup { case success(String, String), failure(String) }

    /// spaces.get nimmt den Meeting-Code als {name} und liefert die feste spaces/{id}.
    private func resolveMeetSpace(meetLink: String) async -> SpaceLookup {
        do {
            let token = try await validAccessToken()
            guard let code = Self.meetingCode(from: meetLink) else {
                return .failure(L.t("Meeting-Code nicht erkannt.", "could not read meeting code."))
            }
            var getReq = URLRequest(url: URL(string: "https://meet.googleapis.com/v2/spaces/\(code)")!)
            getReq.timeoutInterval = 20
            getReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (gData, gResp) = try await URLSession.shared.data(for: getReq)
            let gJson = (try? JSONSerialization.jsonObject(with: gData)) as? [String: Any] ?? [:]
            if let http = gResp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(Self.artifactNote(http.statusCode, gJson))
            }
            guard let name = gJson["name"] as? String else {
                return .failure(L.t("Space nicht gefunden.", "space not found."))
            }
            return .success(name.hasPrefix("spaces/") ? String(name.dropFirst("spaces/".count)) : name, token)
        } catch {
            return .failure(Self.human(error))
        }
    }

    private func patchArtifact(spaceID: String, token: String, kind: MeetArtifacts.Kind) async -> (ok: Bool, note: String) {
        let label = Self.kindLabel(kind)
        guard let req = MeetArtifacts.request(spaceID: spaceID, kind: kind, token: token) else {
            return (false, label + ": " + L.t("Anfrage nicht gebaut.", "could not build request."))
        }
        do {
            let (pData, pResp) = try await URLSession.shared.data(for: req)
            let pJson = (try? JSONSerialization.jsonObject(with: pData)) as? [String: Any] ?? [:]
            if let http = pResp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return (false, label + ": " + Self.artifactNote(http.statusCode, pJson))
            }
            // Runde 123: Googles Antwort prüfen statt blind „aktiviert" zu melden.
            let got = MeetArtifacts.answer(pJson, kind)
            if got == "ON" {
                switch kind {
                case .transcript:
                    return (true, L.t("Auto-Transkript bei Google eingeschaltet. Die Sprache wählt Google selbst.",
                                      "Auto-transcript switched on at Google. Google picks the language itself."))
                case .smartNotes:
                    return (true, L.t("Gemini-Notizen bei Google eingeschaltet. Sie starten, sobald du dem Meeting beitrittst.",
                                      "Gemini notes switched on at Google. They start when you join the meeting."))
                }
            }
            return (false, label + ": " + L.t("Google hat es nicht übernommen (Antwort: \(got ?? "leer")). Dein Google-Konto erlaubt es wohl nicht.",
                                              "Google did not accept it (answer: \(got ?? "empty")). Your Google account probably does not allow it."))
        } catch {
            return (false, label + ": " + Self.human(error))
        }
    }

    private static func kindLabel(_ k: MeetArtifacts.Kind) -> String {
        switch k {
        case .transcript: return L.t("Transkript nicht aktiviert", "Transcript not enabled")
        case .smartNotes: return L.t("Gemini-Notizen nicht aktiviert", "Gemini notes not enabled")
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
            return L.t("Die Google-Meet-API ist im Projekt nicht eingeschaltet. Einmal hier aktivieren: \(link)",
                       "the Google Meet API is off in your project. Enable it once: \(link)")
        }
        // (2) Wirklich eine fehlende Berechtigung.
        if lower.contains("scope") || status == 401 {
            return L.t("bitte Google einmal neu verbinden (neue Berechtigung nötig).",
                       "please reconnect Google once (new permission needed).")
        }
        // (3) Alles andere, typischerweise die Workspace-Lizenz: Googles eigenen
        //     Wortlaut zeigen statt zu raten.
        return msg
    }

    // MARK: - Mail an den Gast (Runde 109)

    /// Schickt die Einladung per Gmail-API (`messages.send`, Absender = verbundenes Konto).
    /// Fehler machen den Termin nie kaputt: das Ergebnis steht in `lastMailStatus`.
    /// Die Adresse bleibt nirgends gespeichert und kommt in kein Log.
    @discardableResult
    func sendInviteMail(to: [String], subject: String, body: String, ics: String?) async -> Bool {
        guard !to.isEmpty else { return false }
        mailBusy = true; defer { mailBusy = false }
        guard canSendMail else { lastMailStatus = .failed(.needsScope); return false }
        guard let from = accountEmail ?? UserDefaults.standard.string(forKey: "googleAccountEmail") else {
            lastMailStatus = .failed(.expired); return false
        }
        do {
            let token = try await validAccessToken()
            let raw = MailInvite.rawBase64URL(MailInvite.mime(from: from, to: to, subject: subject, body: body, ics: ics))
            var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["raw": raw])
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) { lastMailStatus = .sent(to); return true }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            lastMailStatus = .failed(MailInvite.classify(status: status, json: json))
            return false
        } catch let e as GError {
            if case .expiredSession = e { lastMailStatus = .failed(.expired) }
            else { lastMailStatus = .failed(.other(Self.human(e))) }
            return false
        } catch {
            lastMailStatus = .failed(.other(error.localizedDescription))
            return false
        }
    }

    /// Text für die Ergebnisansicht. `nil` bei Erfolg.
    static func mailFailureText(_ f: MailInvite.Failure) -> String {
        switch f {
        case .needsScope:
            return L.t("Mail nicht gesendet: MeetingBlitz darf noch keine Mails senden. Google neu verbinden.",
                       "Mail not sent: MeetingBlitz is not allowed to send mail yet. Reconnect Google.")
        case .apiDisabled:
            let project = Self.loadConfig()?.clientID.split(separator: "-").first.map(String.init) ?? ""
            let link = "https://console.cloud.google.com/apis/library/gmail.googleapis.com" + (project.isEmpty ? "" : "?project=\(project)")
            return L.t("Mail nicht gesendet: Gmail API im Google-Projekt einschalten. \(link)",
                       "Mail not sent: turn on the Gmail API in your Google project. \(link)")
        case .expired:
            return L.t("Mail nicht gesendet: Google-Verbindung abgelaufen. Neu verbinden.",
                       "Mail not sent: Google session expired. Reconnect.")
        case .other(let m):
            return L.t("Mail nicht gesendet (\(m))", "Mail not sent (\(m))")
        }
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
        if let sc = tok["scope"] as? String { UserDefaults.standard.set(sc, forKey: "googleGrantedScopes") }
        if let idToken = tok["id_token"] as? String, let email = Self.email(fromIDToken: idToken) {
            accountEmail = email
            UserDefaults.standard.set(email, forKey: "googleAccountEmail")
        }
    }

    /// A live access token, refreshing via the stored refresh token if needed.
    private func validAccessToken() async throws -> String {
        if let t = accessToken, let e = accessExpiry, e > Date() { return t }
        guard let config else {
            throw GError.msg(L.t("OAuth-Konfiguration nicht gefunden.", "OAuth config not found."))
        }
        // Runde 81: Den Grund auseinanderhalten. Ist der Eintrag WEG, war die
        // Sitzung echt zu Ende und der grüne Punkt muss mit ausgehen. Ist er nur
        // GESPERRT, liegt der Zugang noch da und darf auf keinen Fall gelöscht
        // werden, sonst kostet eine Signaturfrage eine funktionierende Sitzung.
        let refresh: String
        switch keychain.readToken() {
        case .token(let t):
            refresh = t
        case .missing:
            dropExpiredSession()
            throw GError.expiredSession
        case .blocked(let status):
            throw GError.keychainBlocked(status)
        }
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
        if let sc = tok["scope"] as? String { UserDefaults.standard.set(sc, forKey: "googleGrantedScopes") }
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
        // Zwei Orte, in dieser Reihenfolge: im App-Bundle mitgeliefert (wer die
        // App weitergibt, kann seine eigene Config einpacken), sonst der
        // uebliche Ort fuer Anwendungsdaten auf macOS. Frueher lag der zweite
        // Pfad in einem werkzeugspezifischen Ordner des Autors -- den haette in
        // einem oeffentlichen Repo nie jemand gefunden, und die README kann ihn
        // niemandem erklaeren.
        let candidates = [
            Bundle.main.url(forResource: "google-oauth", withExtension: "json"),
            URL(fileURLWithPath: ("~/Library/Application Support/MeetingBlitz/google-oauth.json" as NSString).expandingTildeInPath),
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
    /// Der Eintrag LIEGT im Schlüsselbund, macOS gibt ihn dieser Instanz nur
    /// nicht frei (Runde 81). Eigener Fall, weil hier nichts abgelaufen ist und
    /// „neu verbinden" das Problem nur für eine Stunde zudeckt.
    case keychainBlocked(OSStatus)
    var errorDescription: String? {
        switch self {
        case .msg(let m): return m
        case .expiredSession: return L.t("Google-Verbindung abgelaufen.", "Google session expired.")
        case .keychainBlocked(let st):
            return L.t("Der Schlüsselbund gibt den Google-Zugang gerade nicht frei (Fehler \(st)). Das passiert nach einem Neubau der App: einmal beenden und neu starten, beim Nachfragen „Immer erlauben“ wählen.",
                       "The keychain is not releasing the Google token right now (error \(st)). This happens after a rebuild: quit and relaunch the app, and pick “Always Allow” when asked.")
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

    /// Gibt nach `seconds` mit einem Fehler auf, falls bis dahin kein Code kam
    /// (Runde 88). `finish` ist idempotent, ein späterer Code wird ignoriert.
    func timeout(after seconds: TimeInterval) {
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.finish(with: .failure(GError.msg(GoogleService.loginTimeoutMessage)))
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

    /// Was beim Lesen herauskam. „Der Eintrag ist weg" und „macOS gibt ihn
    /// dieser Instanz gerade nicht frei" sind ZWEI verschiedene Dinge. Vorher
    /// wurde beides zu nil zusammengefaltet, und daraus wurde die Falschaussage
    /// „Nicht mit Google verbunden", während der Eintrag im Schlüsselbund lag
    /// und der Punkt daneben grün war (Runde 81, Rückmeldung: „Widerspruch in sich
    /// selber"). Häufigster Grund für den gesperrten Fall: ein Neubau ändert
    /// die Signatur, oder eine per `open -n` gestartete Zweitinstanz fragt.
    enum Read {
        case token(String)
        case missing
        case blocked(OSStatus)
    }

    private func read(service s: String) -> Read {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: s,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data,
                  let text = String(data: data, encoding: .utf8) else { return .blocked(errSecDecode) }
            return .token(text)
        case errSecItemNotFound:
            return .missing
        default:
            return .blocked(status)
        }
    }

    /// Wie `refreshToken`, nur mit dem Grund, falls nichts herauskam.
    func readToken() -> Read {
        var firstBlock: OSStatus?
        for s in [service] + legacyServices {
            switch read(service: s) {
            case .token(let t): return .token(t)
            case .blocked(let st): if firstBlock == nil { firstBlock = st }
            case .missing: continue
            }
        }
        if let st = firstBlock { return .blocked(st) }
        return .missing
    }

    var refreshToken: String? {
        get {
            if case .token(let t) = readToken() { return t }
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

/// Selbsttest (Runde 88): der echte Loopback-Empfänger gibt nach der Frist auf,
/// statt ewig zu warten. Läuft mit 0,3 s statt 3 Minuten.
enum GoogleLoginTests {
    static func failures() -> [String] {
        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var v: [String] = [] }   // nur nach sem.wait gelesen
        let box = Box()
        Task.detached {
            do {
                let c = try LoopbackCatcher()
                _ = try await c.start()
                c.timeout(after: 0.3)
                _ = try await c.awaitCode()
                box.v.append("Google-Login: awaitCode kam ohne Code zurück")
            } catch {
                if error.localizedDescription != GoogleService.loginTimeoutMessage {
                    box.v.append("Google-Login: falscher Fehler nach Frist: \(error.localizedDescription)")
                }
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + 5) == .timedOut { return ["Google-Login: Frist greift nicht (wartet > 5 s)"] }
        return box.v
    }
}
