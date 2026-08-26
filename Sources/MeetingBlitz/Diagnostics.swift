import AppKit
import EventKit

/// Statusbericht auf Knopfdruck (Runde 48).
///
/// **Warum das existiert:** Am 31.07. haben Panel-Layoutfehler fünf Rateschleifen
/// gekostet, weil aus Screenshots nicht hervorging, WO die Fenster wirklich
/// liegen. Ein einziges Log mit den echten Koordinaten hat den Fehler dann in
/// zwei Minuten gefunden (Phantomgröße 0×24, siehe Runde 47i). Die Panels sind
/// im Screenshot ohnehin oft unsichtbar (Vollbild-Space anderer Apps), also
/// schreibt die App ihren Zustand jetzt selbst auf.
///
/// Bewusst NUR lokale Fakten, keine Termininhalte außer Titel des laufenden und
/// nächsten Termins, der Bericht landet in ~/Downloads und wandert
/// erfahrungsgemäß in einen Chat.
///
/// ⚠️ **Nicht aus der Shell starten und dann über den Kalender wundern.** Wird
/// die Binary direkt im Terminal aufgerufen, hängt die TCC-Identität am
/// aufrufenden Prozess und der Bericht meldet „Zugriff Termine FEHLT", obwohl
/// die App selbst vollen Zugriff hat. Richtig ist
/// `open -n MeetingBlitz.app --args --diagnose` (oder der Menüpunkt).
@MainActor
enum Diagnostics {

    static func report() -> String {
        let s = AppState.shared
        var out: [String] = []

        func section(_ t: String) { out.append(""); out.append("## \(t)") }
        func line(_ k: String, _ v: Any) { out.append("\(k.padding(toLength: max(k.count, 26), withPad: " ", startingAt: 0)) \(v)") }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        out.append("# MeetingBlitz Diagnose \(f.string(from: Date()))")

        section("App")
        line("Version", "\(bundleValue("CFBundleShortVersionString")) (Build \(bundleValue("CFBundleVersion")))")
        line("Pfad", Bundle.main.bundlePath)
        line("Signatur", signingAuthority())
        line("Sprache", s.appLanguage)
        line("Beim Login starten", s.launchAtLogin)
        line("Tastenkürzel aktiv", s.hotkeyEnabled)

        section("Kalender")
        // Gegen die ECHTEN Enum-Fälle prüfen, nicht gegen rohe Zahlen: die
        // Rohwerte haben sich zwischen macOS-Versionen verschoben und der erste
        // Diagnoselauf meldete deshalb faelschlich „FEHLT (4)" (Runde 48).
        let evStatus = EKEventStore.authorizationStatus(for: .event)
        let remStatus = EKEventStore.authorizationStatus(for: .reminder)
        // Runde 56: Vorher stand hier stumpf „FEHLT (4)" für ALLES, was nicht
        // fullAccess ist. Das schickt Support in die falsche Richtung: 4 ist
        // write-only (darf schreiben, sieht aber nichts), und „noch nicht
        // gefragt" direkt nach dem Start ist überhaupt kein Fehler, sondern
        // die noch laufende EventKit-Abfrage.
        line("Zugriff Termine", describe(evStatus))
        line("Zugriff Erinnerungen", describe(remStatus))
        line("Kalender gesamt", s.availableCalendars.count)
        line("davon angezeigt", s.selectedCalendarIDs.isEmpty ? "alle" : "\(s.selectedCalendarIDs.count)")
        line("davon mit Banner", s.alertCalendarIDs.isEmpty ? "alle" : "\(s.alertCalendarIDs.count)")
        line("davon mit Geburtstagen", s.birthdayCalendarIDs.isEmpty ? "alle" : "\(s.birthdayCalendarIDs.count)")
        line("Termine heute", s.agenda.count)
        line("Läuft gerade", s.currentMeeting?.title ?? "-")
        line("Nächster", s.nextMeeting.map { "\($0.title) um \($0.timeLabel)" } ?? "-")
        line("Ausgeblendet", "\(s.hiddenCount) (davon dauerhaft \(s.hiddenTitleKeys.count))")
        // Runde 55: die Liste MIT Namen und Kennung. AppleScript gibt die uid
        // eines Kalenders nicht heraus, ohne diese Zeilen ist von außen also
        // nicht feststellbar, welche Kennung zu welchem Kalendernamen gehört.
        if !s.availableCalendars.isEmpty {
            out.append("")
            out.append("   Anzeigen/Banner/Geburtstage je Kalender:")
            for c in s.availableCalendars {
                let flags = [s.selectedCalendarIDs.isEmpty || s.selectedCalendarIDs.contains(c.id) ? "an" : "AUS",
                             s.isAlertCalendar(c.id) ? "an" : "AUS",
                             s.isBirthdayCalendar(c.id) ? "an" : "AUS"].joined(separator: "/")
                out.append("   \(flags.padding(toLength: 12, withPad: " ", startingAt: 0)) \(c.id)  \(c.title)")
            }
            // F11: Zielwahl für neue Meetings ist nur prüfbar, wenn man sieht,
            // welcher Kalender zu WELCHEM Konto gehört (derselbe Name kann in
            // iCloud und in Google liegen).
            out.append("   Beschreibbar (Ziel für neue Meetings), je Konto:")
            let formIDs = s.calendarIDs(for: s.createTarget)
            let instIDs = s.calendarIDs(for: s.instantTarget)
            for c in s.calendar.writableCalendars() {
                var marks: [String] = []
                if formIDs.contains(c.id) { marks.append("Neues Meeting") }
                if instIDs.contains(c.id) { marks.append("Sofort") }
                let mark = marks.isEmpty ? "" : "  ← \(marks.joined(separator: " + "))"
                out.append("     \(c.title)  [\(c.sourceTitle.isEmpty ? "?" : c.sourceTitle)]\(mark)")
            }
            func label(_ t: CreateTarget) -> String {
                switch t {
                case .google: "Google" case .apple: "Apple"
                case .both:   "BEIDE (zwei Termine, ein Meet-Link)"
                }
            }
            out.append("   „Neues Meeting\" → \(label(s.createTarget)) · Ziele: \(formIDs.count)")
            out.append("   „Sofort-Meeting\" → \(label(s.instantTarget)) · Ziele: \(instIDs.count)")
        }
        if !s.calendar.isAuthorized, ProcessInfo.processInfo.environment["TERM"] != nil {
            out.append("   ↑ Aus dem Terminal gestartet: die Kalenderfreigabe hängt dann am")
            out.append("     aufrufenden Prozess, nicht an der App. Für echte Werte:")
            out.append("     open -n MeetingBlitz.app --args --diagnose")
        }

        section("Menüleiste")
        let text = s.menuBarText ?? "(Icon, kein Text)"
        line("Text", text)
        line("Breite", String(format: "%.1fpt", menuBarWidth(text)))
        line("Im Meeting kompakt", s.compactMenuBarInMeeting)
        // Der häufigste Ausfall dieser App: zu breites Item → macOS wirft es raus.
        line("Budget rechts vom Notch", NSScreen.main.map { String(format: "%.0fpt", auxWidth($0)) } ?? "?")

        section("Bildschirme")
        for (i, sc) in NSScreen.screens.enumerated() {
            line("Screen \(i + 1)", "frame \(short(sc.frame)) sichtbar \(short(sc.visibleFrame))")
        }

        section("Fenster")
        line("Widget offen", WidgetPanelController.shared.isOpen)
        line("Widget-Frame", WidgetPanelController.shared.frame.map(short) ?? "-")
        // Die Panels selbst standen bis 23.08.2026 NICHT im Bericht, obwohl er
        // genau für Panel-Layoutfehler gebaut wurde. Bei einem Fall „ich klicke
        // Einstellungen und sehe nichts" fehlte damit die einzige Zahl, die die
        // Frage beantwortet: Ist das Fenster zu, ist es 0 Punkte groß, oder
        // steht es außerhalb aller Bildschirme?
        line("Einstellungen offen", SettingsPanelController.shared.isOpen)
        line("Einstellungen-Frame", SettingsPanelController.shared.frame.map(short) ?? "-")
        line("Einstellungen auf Bildschirm", screenIndex(SettingsPanelController.shared.frame))
        line("Einstellungen Notplatzierung",
             SettingsPanelController.shared.lastRescueReason ?? "nicht nötig")
        // Ist-Höhe gegen nötige Höhe (26.08.2026). Ein Fenster, das kleiner ist
        // als sein Inhalt, zeigt nur einen Streifen aus der Mitte: oben fehlt
        // die Reiterleiste, unten der Rest. Aus einem Screenshot ist das nicht
        // sicher abzulesen, aus diesen zwei Zahlen schon.
        line("Einstellungen Inhaltshöhe", {
            let c = SettingsPanelController.shared
            guard let ist = c.contentHeight, let soll = c.neededHeight else { return "-" }
            return String(format: "%.0f von nötigen %.0f%@", ist, soll,
                          ist >= soll - 1 ? "" : "  ← SCHNEIDET OBEN UND UNTEN AB")
        }())
        line("Neues-Meeting offen", CreatePanelController.shared.isOpen)
        line("Neues-Meeting-Frame", CreatePanelController.shared.frame.map(short) ?? "-")
        line("Neues-Meeting Notplatzierung",
             CreatePanelController.shared.lastRescueReason ?? "nicht nötig")
        for id in ["create", "settings"] {
            let d = UserDefaults.standard.dictionary(forKey: "panelTopLeft_\(id)")
            let v = d.flatMap { dict -> String? in
                guard let x = dict["x"] as? Double, let y = dict["y"] as? Double else { return nil }
                return String(format: "(%.0f | %.0f)", x, y)
            }
            line("Gemerkte Position \(id)", v ?? "keine (Automatik neben dem Widget)")
        }

        section("Google")
        let g = GoogleService.shared
        line("OAuth-Konfiguration", g.hasConfig ? "vorhanden" : "FEHLT")
        // ⚠️ Der Refresh-Token liegt im Schlüsselbund, und dessen Freigabe hängt
        // am Programm, das ihn angelegt hat. Eine ZWEITE, per `open -n`
        // gestartete Instanz (wie dieser Diagnoselauf) bekommt ihn nicht immer
        // zu lesen und meldete dann fälschlich „nicht verbunden" (Runde 53).
        // Deshalb zusätzlich der gespeicherte Kontoname, der ohne Schlüsselbund
        // auskommt, stimmen die beiden nicht überein, steht es als Hinweis da.
        let storedAccount = UserDefaults.standard.string(forKey: "googleAccountEmail")
        line("Verbunden", g.isConnected)
        line("Konto", g.accountEmail ?? storedAccount ?? "-")
        if !g.isConnected, storedAccount != nil {
            out.append("   ↑ Token im Schlüsselbund für DIESE Instanz nicht lesbar.")
            out.append("     Die laufende App ist davon nicht betroffen.")
        }
        line("Neu verbinden nötig", g.needsReconnect)
        line("Meet-Routing", s.meetRoutingEnabled ? s.effectiveMeetAccount : "aus")
        line("Letzter Fehler", g.lastError ?? "-")

        section("Banner")
        line("Ruhe-Modus", s.quietMode)
        line("Ruhe bei Bildschirmfreigabe", s.quietDuringScreenShare)
        line("Bildschirm wird geteilt", ScreenShareDetector.isSharing())
        line("Vorlaufzeit", "\(s.leadMinutes) min")
        line("Auto-Beitreten", s.autoJoin)
        line("End-Warnung", s.endWarning)

        out.append("")
        return out.joined(separator: "\n")
    }

    /// Schreibt den Bericht nach ~/Downloads, kopiert den Text gleich in die
    /// Zwischenablage (zum Einfügen in einen Chat) und zeigt die Datei im Finder.
    @discardableResult
    static func writeAndReveal() -> URL? {
        let text = report()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmm"
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("MeetingBlitz-Diagnose_\(stamp.string(from: Date())).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return url
        } catch {
            NSLog("Diagnose konnte nicht geschrieben werden: \(error)")
            return nil
        }
    }

    // MARK: - Bausteine

    /// Klartext statt Rohwert. Die Nummerierung von `EKAuthorizationStatus`
    /// hat sich zwischen macOS-Versionen verschoben, deshalb wird gegen die
    /// echten Enum-Fälle geprüft und der Rohwert nur als Beifang genannt.
    private static func describe(_ status: EKAuthorizationStatus) -> String {
        let text: String
        switch status {
        case .fullAccess:    text = "voll"
        case .writeOnly:     text = "NUR SCHREIBEN, die App darf Termine anlegen, sieht aber keine"
        case .denied:        text = "VERWEIGERT, in Systemeinstellungen → Datenschutz & Sicherheit → Kalender erlauben"
        case .restricted:    text = "GESPERRT (z. B. durch eine Geräteverwaltung)"
        case .notDetermined: text = "noch nicht gefragt (direkt nach dem Start normal, die Abfrage läuft noch)"
        @unknown default:    text = "unbekannt"
        }
        return "\(text) (\(status.rawValue))"
    }

    private static func bundleValue(_ key: String) -> String {
        Bundle.main.infoDictionary?[key] as? String ?? "?"
    }

    /// Auf welchem Bildschirm ein Fenster liegt, in derselben Zählung wie der
    /// Abschnitt „Bildschirme" oben. „außerhalb" ist die Antwort, auf die es
    /// ankommt: dann ist das Fenster offen und trotzdem nirgends zu sehen.
    private static func screenIndex(_ rect: CGRect?) -> String {
        guard let r = rect else { return "-" }
        for (i, sc) in NSScreen.screens.enumerated() where sc.frame.intersects(r) {
            return "Screen \(i + 1)"
        }
        return "außerhalb aller Bildschirme"
    }

    private static func short(_ r: CGRect) -> String {
        String(format: "(%.0f | %.0f) %.0f×%.0f", r.minX, r.minY, r.width, r.height)
    }

    private static func menuBarWidth(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.menuBarFont(ofSize: 0)]).width
    }

    /// Nutzbare Menüleistenbreite rechts vom Notch, das Budget, an dem sich
    /// ALLE Apps bedienen (Runde 46b).
    private static func auxWidth(_ screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *), let aux = screen.auxiliaryTopRightArea { return aux.width }
        return screen.frame.width
    }

    /// Signierende Instanz der laufenden App. Ad-hoc heißt: Berechtigungen gehen
    /// bei jedem Rebuild verloren (Runde 48).
    private static func signingAuthority() -> String {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else { return "unbekannt" }
        var staticRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess, let stat = staticRef else { return "unbekannt" }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return "unbekannt" }
        if let chain = info["certificates"] as? [SecCertificate], let leaf = chain.first {
            return (SecCertificateCopySubjectSummary(leaf) as String?) ?? "signiert"
        }
        return "ad-hoc (Berechtigungen überleben Rebuilds NICHT)"
    }
}
