import SwiftUI
import AppKit
import Combine

@main
struct MeetingBlitzApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No visible scene: the whole UI is an NSStatusItem + self-managed panels
        // (Runde 4). A MenuBarExtra window closes as soon as another window becomes
        // key, which made the widget vanish when the settings/calendar opened.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var cancellable: AnyCancellable?
    private var splashDemoPanel: NSPanel?
    /// F9: URL, die vor dem fertigen Aufbau eintraf (Start PER URL).
    private var pendingURL: URL?

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor,
                                      reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: s) else { return }
        guard statusItem != nil else { pendingURL = url; return }
        URLScheme.handle(url, statusButton: statusItem?.button)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // F7: Selbsttest der Link-Erkennung. MUSS vor dem Einzelinstanz-Schutz
        // stehen — sonst beendet sich der Testlauf neben der laufenden App
        // sofort und meldet Erfolg, ohne einen einzigen Fall geprüft zu haben.
        // Genau das ist beim ersten Anlauf passiert. Braucht keine App-Umgebung,
        // nur reine Rechnerei, deshalb ganz nach vorn.
        if CommandLine.arguments.contains("--selftest") {
            let fails = JoinLinkTests.failures() + CalendarStageTests.failures()
                + QuickAddTests.failures()
            if fails.isEmpty {
                print("selftest ok: \(JoinLinkTests.cases.count) Link-Fälle, \(JoinLink.services.count) Dienste, Klick-Stufen, Freitext")
                exit(0)
            }
            print("SELFTEST FEHLGESCHLAGEN (\(fails.count)):")
            fails.forEach { print(" - \($0)") }
            exit(1)
        }
        // F8-Diagnose: `--parse "fr 16 uhr call mit chris"` zeigt, was die
        // Freitext-Erkennung daraus macht. Ebenfalls VOR dem Einzelinstanz-
        // Schutz, sonst beendet sich der Aufruf neben der laufenden App.
        if let i = CommandLine.arguments.firstIndex(of: "--parse"),
           i + 1 < CommandLine.arguments.count {
            let input = CommandLine.arguments[i + 1]
            if let p = QuickAdd.parse(input, now: Date()) {
                let f = DateFormatter()
                f.locale = Locale(identifier: "de_DE")
                f.dateFormat = "EEEE, d. MMMM yyyy, HH:mm"
                print("Eingabe : \(input)")
                print("Titel   : \(p.title.isEmpty ? "(leer → „Meeting\")" : p.title)")
                print("Start   : \(f.string(from: p.start))")
                print("Dauer   : \(p.minutes) min")
                print("Sicher  : \(p.confident ? "ja" : "NEIN (nackte Zahl geraten)")")
            } else {
                print("Eingabe : \(input)")
                print("Ergebnis: NICHT ERKANNT (keine Zeit gefunden)")
            }
            exit(0)
        }
        // Single instance (Runde 46). Eine zweite Kopie der App (gemeldet wurde:te eine
        // Alt-Kopie in ~/Downloads, die zusätzlich in den Login Items stand) läuft
        // unter DERSELBEN Bundle-ID, macOS wirft dann das kollidierende
        // NSStatusItem raus und das Menüleisten-Icon verschwindet kommentarlos.
        // Die ältere Instanz gewinnt, die neue beendet sich sofort.
        // Diese Prüf-Aufrufe brauchen den Kalender, aber keine Menüleiste, und
        // laufen deshalb absichtlich neben der App.
        let readOnlyChecks = ["--diagnose", "--conflicts", "--stats", "--test-notice", "--check-panels"]
        if !CommandLine.arguments.contains(where: readOnlyChecks.contains),
           let bid = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bid)
               .contains(where: { $0.processIdentifier != NSRunningApplication.current.processIdentifier }) {
            NSLog("MeetingBlitz läuft bereits, diese Instanz beendet sich (Status-Item-Kollision).")
            exit(0)
        }

        NSApp.setActivationPolicy(.accessory)   // menu-bar only, no dock icon

        // Selbsttest für die Schreibtisch-Falle (22.08.2026).
        //
        // Warum als Schalter und nicht per Screenshot: Ob ein Fenster über
        // einer fremden Vollbild-App erscheint, lässt sich von außen nur
        // prüfen, indem man eine App per Klick in den Vollbildmodus schickt,
        // und dieser Klick ist ohne Bedienungshilfen-Rechte nicht auslösbar.
        // Die Ursache selbst ist dagegen eine Zahl im Fenster, und die kann
        // die App über sich selbst ausgeben. Läuft absichtlich VOR `start()`:
        // die Panels brauchen keinen Kalender, und so fragt der Selbsttest
        // keine Rechte an.
        if CommandLine.arguments.contains("--check-panels") {
            // Einstieg ZUERST: sein `show` räumt das Einstellungsfenster aus
            // dem Weg, in der anderen Reihenfolge wäre es beim Ablesen zu.
            OnboardingPanelController.shared.show(state: .shared)
            WidgetPanelController.shared.toggle(state: .shared, statusButton: nil)
            AppState.shared.toggleSettingsPanel()
            AppState.shared.toggleCreatePanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                var bad = 0
                print("Fenster sichtbar: \(NSApp.windows.filter(\.isVisible).count)")
                for w in NSApp.windows where w.isVisible {
                    let b = w.collectionBehavior
                    let all = b.contains(.canJoinAllSpaces)
                    let aux = b.contains(.fullScreenAuxiliary)
                    let name = w.title.isEmpty ? "(ohne Titel: Widget)" : w.title
                    if !all { bad += 1 }
                    print("\(all && aux ? "ok  " : "FEHLT")  \(name): canJoinAllSpaces=\(all) fullScreenAuxiliary=\(aux)")
                }
                print(bad == 0
                      ? "check-panels ok: alle sichtbaren Fenster dürfen auf jeden Schreibtisch"
                      : "CHECK-PANELS FEHLGESCHLAGEN: \(bad) Fenster bleiben bei Vollbild-Apps unsichtbar")
                exit(bad == 0 ? 0 : 1)
            }
            return
        }

        AppState.shared.start()

        // `meetingblitz://restart` landet hier (siehe URLScheme).
        NotificationCenter.default.addObserver(self, selector: #selector(restartApp),
                                               name: .meetingBlitzRestart, object: nil)

        // F9: meetingblitz://… entgegennehmen. Wird die App PER URL gestartet,
        // trifft das Ereignis ein, bevor das Statusitem steht — deshalb wird
        // die URL gepuffert und erst nach dem Aufbau ausgeführt.
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))

        // Kollisions-Prüfung von außen: `--conflicts "fr 16 uhr call"` zeigt,
        // was die Warnung im Erstellen-Formular anzeigen würde. Panels sind bei
        // laufender Arbeit kaum zuverlässig zu fotografieren, das hier ist
        // belastbar.
        if let i = CommandLine.arguments.firstIndex(of: "--conflicts"),
           i + 1 < CommandLine.arguments.count {
            let input = CommandLine.arguments[i + 1]
            Task { @MainActor in
                for _ in 0..<20 where !AppState.shared.calendarAuthorized {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                let s = AppState.shared
                guard let p = QuickAdd.parse(input, now: Date()) else {
                    print("„\(input)" + "\" ergibt keine Zeit"); exit(1)
                }
                let f = DateFormatter(); f.locale = Locale(identifier: "de_DE")
                f.dateFormat = "EEEE, d. MMMM, HH:mm"
                let hits = s.calendar.conflicts(start: p.start, minutes: p.minutes,
                                                selected: s.selectedCalendarIDs)
                var out = ["Geplant : \(p.title) · \(f.string(from: p.start)) · \(p.minutes) min"]
                print(out[0])
                if hits.isEmpty { out.append("Konflikt: keiner") }
                else {
                    out.append("Konflikt: \(hits.count)")
                    for h in hits { out.append("  - \(h.rangeLabel)  \(h.title)") }
                }
                out.dropFirst().forEach { print($0) }
                try? out.joined(separator: "\n").write(toFile: "/tmp/mb_check.txt", atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        // P1-Prüfung: `--test-notice` schickt eine Beispielmeldung und schreibt
        // das Ergebnis nach /tmp/mb_check.txt. Ohne das ist von außen nicht zu
        // sehen, ob die Meldung wirklich rausgeht — sie greift sonst nur, wenn
        // Ruhe aktiv IST und gleichzeitig ein Termin ansteht.
        if CommandLine.arguments.contains("--test-notice") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                QuietNotice.test()
                try? "Hinweis gezeigt (eigenes Fenster oben rechts)"
                    .write(toFile: "/tmp/mb_check.txt", atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { exit(0) }
            return
        }
        // Auswertung von außen: `--stats` gibt Woche und Monat aus.
        if CommandLine.arguments.contains("--stats") {
            Task { @MainActor in
                for _ in 0..<20 where !AppState.shared.calendarAuthorized {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                let s = AppState.shared, cal = Calendar.current, now = Date()
                var out: [String] = []
                for (label, from) in [("Diese Woche", cal.dateInterval(of: .weekOfYear, for: now)?.start),
                                      ("Dieser Monat", cal.dateInterval(of: .month, for: now)?.start)] {
                    guard let from else { continue }
                    let st = s.calendar.stats(from: from, to: now, selected: s.selectedCalendarIDs)
                    out.append("\(label): \(st.count) Termine · \(st.hoursLabel) gesamt · "
                          + "\(st.callCount) Calls · \(st.callHoursLabel) in Calls"
                          + (st.busiestDay.map { " · vollster Tag \($0.label) (\(MeetingStats.hm($0.minutes)))" } ?? ""))
                }
                out.forEach { print($0) }
                try? out.joined(separator: "\n").write(toFile: "/tmp/mb_check.txt", atomically: true, encoding: .utf8)
                exit(0)
            }
            return
        }
        // Runde 48: Diagnose auch ohne Klick, damit sie sich prüfen und aus
        // Skripten holen lässt. Läuft kurz mit, wartet auf den ersten
        // Kalender-Tick und beendet sich dann wieder.
        if CommandLine.arguments.contains("--diagnose") {
            Task { @MainActor in
                // Auf die Kalenderfreigabe warten, sonst berichtet ein frischer
                // Prozess „0 Kalender", weil die Abfrage noch läuft.
                for _ in 0..<20 where !AppState.shared.calendarAuthorized {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                AppState.shared.monitor.tickNow()
                try? await Task.sleep(nanoseconds: 400_000_000)
                if CommandLine.arguments.contains("--stdout") {
                    print(Diagnostics.report())
                } else {
                    Diagnostics.writeAndReveal()
                }
                exit(0)
            }
            return
        }

        // Status-bar item. Its title/icon mirror AppState; clicking toggles the
        // widget panel.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.imagePosition = .imageLeading
        // Rechtsklick öffnet das Aktionsmenü, Linksklick das Widget.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        refreshStatusTitle()

        // Re-render the status title whenever relevant state changes.
        cancellable = AppState.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshStatusTitle()
            }
        }

        // Global hotkey (Runde 44): opens the widget on whichever display the
        // mouse is on, the menu-bar icon isn't reliable across screens / the
        // notch. AppState flips this hook when the settings toggle changes.
        // F5: zwei Kürzel, beide umbelegbar. `register` meldet zurück, ob die
        // Kombination frei war — ein still totes Kürzel wäre das Schlimmste.
        AppState.shared.onHotkeyToggle = { [weak self] on in
            guard let self else { return }
            let s = AppState.shared
            HotKeyManager.shared.unregister(.showWidget)
            HotKeyManager.shared.unregister(.joinNext)
            guard on else { s.hotkeyConflict = nil; return }

            let okWidget = HotKeyManager.shared.register(
                .showWidget, keyCode: UInt32(s.hotkeyWidgetKey),
                modifiers: UInt32(s.hotkeyWidgetMods)) {
                    WidgetPanelController.shared.toggle(state: .shared,
                                                        statusButton: self.statusItem?.button,
                                                        anchorToMouseScreen: true)
                }
            let okJoin = HotKeyManager.shared.register(
                .joinNext, keyCode: UInt32(s.hotkeyJoinKey),
                modifiers: UInt32(s.hotkeyJoinMods)) {
                    AppState.shared.joinCurrentOrNext()
                }
            // Sichtbar machen, was nicht griff, statt es zu verschlucken.
            var dead: [String] = []
            if !okWidget { dead.append(s.hotkeyWidgetLabel) }
            if !okJoin { dead.append(s.hotkeyJoinLabel) }
            s.hotkeyConflict = dead.isEmpty ? nil : dead.joined(separator: ", ")
        }
        AppState.shared.onHotkeyToggle?(AppState.shared.hotkeyEnabled)

        // F9: nachholen, was vor dem Aufbau eintraf.
        if let u = pendingURL {
            pendingURL = nil
            DispatchQueue.main.async { [weak self] in
                URLScheme.handle(u, statusButton: self?.statusItem?.button)
            }
        }

        // Einstieg beim ersten Start (Runde 56). Ohne ihn passiert für einen
        // neuen Nutzer sichtbar NICHTS: keine Fenster, kein Dock-Symbol, und
        // das Menüleisten-Icon findet man nur, wenn man weiß, dass es da ist.
        // Erst nach einem Runloop, damit das Statusitem schon steht, dann
        // zeigt die Menüleiste beim ersten Blick bereits das U-Boot.
        OnboardingPanelController.shared.onFinished = { [weak self] in
            WidgetPanelController.shared.toggle(state: .shared,
                                                statusButton: self?.statusItem?.button,
                                                anchorToMouseScreen: true)
        }
        if !AppState.shared.onboardingDone || CommandLine.arguments.contains("--demo-onboarding"),
           !CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.async {
                OnboardingPanelController.shared.show(state: .shared)
            }
        }

        // Demo mode for verification: repeatedly fire the test banner.
        if CommandLine.arguments.contains("--demo") {
            let s = AppState.shared
            s.showTestBanner()
            Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { _ in
                Task { @MainActor in s.showTestBanner() }
            }
        }
        // Verification aid: show a single banner pinned in the docked pose so the
        // docked look can be screenshotted without hovering.
        if CommandLine.arguments.contains("--demo-dock") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                AppState.shared.showTestBanner(pinnedDocked: true)
            }
        }
        // Verification aid: loop the Metal splash centred on screen so its look
        // can be tuned without chasing the jump timing.
        if CommandLine.arguments.contains("--demo-splash") {
            let vf = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let w: CGFloat = 620, h: CGFloat = 500
            let panel = NSPanel(contentRect: CGRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true
            let view = SplashMetalView(frame: CGRect(x: 0, y: 0, width: w, height: h),
                                       origin: SIMD2<Float>(0.5, 0.82), amount: 120)
            panel.contentView = view
            panel.orderFrontRegardless()
            view.start()
            Timer.scheduledTimer(withTimeInterval: 2.2, repeats: true) { _ in
                Task { @MainActor in view.restart() }
            }
            self.splashDemoPanel = panel   // retain
        }
        // Verification aid: open the widget (and settings) programmatically so
        // their look/position can be screenshotted without clicking.
        if CommandLine.arguments.contains("--demo-widget") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                WidgetPanelController.shared.toggle(state: .shared, statusButton: self.statusItem?.button)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    AppState.shared.toggleSettingsPanel()
                }
            }
        }
        // Verification aid (Runde 56): open the widget on a specific day, so the
        // layout of "today" and "a day with only all-day events" can be measured
        // against each other without clicking.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-day=") }),
           let day = Int(arg.dropFirst("--demo-day=".count)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                WidgetPanelController.shared.toggle(state: .shared, statusButton: self.statusItem?.button)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    AppState.shared.stepDay(day)
                    AppState.shared.advanceGrid()
                }
            }
        }
        // Verification aid (Runde 56): show the hint box programmatically at a
        // registered spot, no mouse needed. Pairs with --demo-widget.
        if CommandLine.arguments.contains("--demo-hint") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                HintWindow.shared.debugShowAtFirstSpot()
            }
        }
        // Verification aid: widget + "Neues Meeting" panel for screenshots.
        if CommandLine.arguments.contains("--demo-create") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                WidgetPanelController.shared.toggle(state: .shared, statusButton: self.statusItem?.button)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    AppState.shared.toggleCreatePanel()
                }
            }
        }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showActionsMenu() }
        else { toggleWidget() }
    }

    @objc private func toggleWidget() {
        WidgetPanelController.shared.toggle(state: .shared, statusButton: statusItem?.button)
    }

    // MARK: - Aktionsmenü (Rechtsklick)

    /// Kurzes NSMenu am Icon. Die Aufnahme-Einträge sind in Runde 48 entfallen:
    /// Meetings mitschneiden macht RecBlitz, MeetingBlitz braucht das nicht
    /// doppelt (Rückmeldung: „macht ja keinen Sinn").
    private func showActionsMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()

        let widget = NSMenuItem(title: L.t("Termine anzeigen", "Show agenda"),
                                action: #selector(toggleWidget), keyEquivalent: "")
        widget.target = self
        menu.addItem(widget)
        let settings = NSMenuItem(title: L.t("Einstellungen …", "Settings …"),
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        // Runde 48: Statusbericht auf Knopfdruck. Siehe Diagnostics.swift,
        // Panel- und Menüleistenprobleme lassen sich aus Screenshots nicht
        // zuverlässig lesen, aus diesen Zahlen schon.
        let diag = NSMenuItem(title: L.t("Diagnose speichern", "Save diagnostics"),
                              action: #selector(saveDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)

        menu.addItem(.separator())
        // Die zwei Selbsthilfe-Knöpfe. Sie stehen HIER und nicht in den
        // Einstellungen: Wer sein Einstellungsfenster nicht findet, kann darin
        // auch nichts anklicken, und hängt die eigene Oberfläche, geht dieses
        // Menü trotzdem noch auf (es zeichnet das System).
        let rescue = NSMenuItem(title: L.t("Fenster zurückholen", "Bring windows back"),
                                action: #selector(rescuePanels), keyEquivalent: "")
        rescue.target = self
        rescue.toolTip = L.t("Holt Widget und Panels auf den Bildschirm, auf dem die Maus steht, und vergisst gemerkte Fensterpositionen.",
                             "Brings the widget and panels to the screen the mouse is on and forgets remembered window positions.")
        menu.addItem(rescue)
        let restart = NSMenuItem(title: L.t("MeetingBlitz neu starten", "Restart MeetingBlitz"),
                                 action: #selector(restartApp), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L.t("MeetingBlitz beenden", "Quit MeetingBlitz"),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
    }

    @objc private func openSettings() { AppState.shared.toggleSettingsPanel() }

    /// Widget und Panels zurück auf den Bildschirm holen, auf dem gearbeitet
    /// wird (Begründung in `PanelRescue`).
    @objc private func rescuePanels() {
        PanelRescue.bringBack(state: .shared, statusButton: statusItem?.button)
    }

    /// App beenden und sofort wieder starten.
    ///
    /// **Die Falle dabei:** Diese App lässt absichtlich nur EINE Kopie von sich
    /// laufen (Runde 46, sonst wirft macOS das Menüleisten-Symbol raus). Eine
    /// zweite Kopie beendet sich beim Start sofort selbst, solange die erste
    /// noch lebt. Ein naiver Neustart („starten, dann beenden") würde also
    /// schlicht die App schließen und nichts wieder öffnen.
    ///
    /// Deshalb übernimmt eine kleine Shell den Neustart von außen: Sie wartet,
    /// bis dieser Prozess wirklich weg ist, und startet erst dann. Sie überlebt
    /// das Beenden der App, weil ein weiterlaufendes Kindprozess-Skript nicht
    /// mit dem Elternprozess stirbt.
    @objc private func restartApp() {
        let bundle = Bundle.main.bundleURL
        // Aus der Shell heraus gestartet (nacktes Binary statt .app) gibt es
        // kein Bundle zum Öffnen; dann lieber gar nicht neu starten als ein
        // Finder-Fenster aufmachen und die App weg.
        guard bundle.pathExtension == "app" else {
            NSLog("Neustart übersprungen: läuft nicht als .app (\(bundle.path))")
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/sleep 0.4
        /usr/bin/open -n '\(bundle.path.replacingOccurrences(of: "'", with: "'\\''"))'
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        do {
            try task.run()
        } catch {
            // Lieber weiterlaufen als beenden ohne Wiederkehr.
            NSLog("Neustart fehlgeschlagen: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    /// Schreibt den Statusbericht nach ~/Downloads, legt ihn in die
    /// Zwischenablage und zeigt ihn im Finder.
    @objc private func saveDiagnostics() { Diagnostics.writeAndReveal() }

    // MARK: - Menüleisten-Breite (Runde 46b)

    /// Harte Obergrenze für die Breite des Status-Items.
    ///
    /// **Warum das existiert (teuer erkauft):** macOS KÜRZT ein zu breites
    /// NSStatusItem nicht, es wirft die am weitesten links liegenden Items
    /// **kommentarlos komplett raus**, ohne Log, ohne Crash, ohne dass das Item
    /// im Code verschwindet (`isVisible` bleibt `true`, die Scene lebt weiter).
    /// Auf dem Entwicklungs-MacBook ist die nutzbare Menüleiste rechts vom Notch nur
    /// `auxiliaryTopRightArea.width` = **790pt für ALLE Apps zusammen**. Das
    /// Item mit vollem Meetingtitel war **289pt** breit → sobald irgendein
    /// weiteres Icon dazukam (z.B. die orange Mikrofon-Pille), flog MeetingBlitz
    /// raus. Gemessen: ein 289pt-Item killt drei Nachbar-Icons gleich mit.
    ///
    /// **Wert 260 (31.07. 15:30, nach einem Menüleisten-Aufräumen):** Notion,
    /// Claude und Telegram sind raus, damit belegen die übrigen Items noch ~408pt
    /// von 790pt. 260pt für uns lässt ~120pt Reserve, genug für die orange
    /// Mikrofon-Pille (~45pt, taucht bei JEDER Aufnahme auf) plus ein weiteres
    /// Icon. **Wenn wieder Icons dazukommen, muss dieser Wert runter**,
    /// sonst verschwindet MeetingBlitz erneut. Faustregel:
    /// `260 - (Breite der neu dazugekommenen Icons)`.
    private static let maxMenuBarWidth: CGFloat = 260

    /// Obergrenze WÄHREND eines laufenden Meetings (Runde 47/47b).
    ///
    /// **Warum enger als sonst:** genau während eines Meetings ist die Menüleiste
    /// am vollsten, RecBlitz zeigt bei laufender Aufnahme Punkt + mitlaufende
    /// Zeit (~60pt, wird mit jeder Minute breiter) und macOS blendet die orange
    /// Mikrofon-Pille ein (~45pt), die beim Stummschalten kommt und geht. Mit den
    /// normalen 260pt kippt das Budget (790pt) hin und her → macOS wirft unser
    /// Item raus und wieder rein: **das Flackern, das im Meeting zu sehen war
    /// hat.**
    ///
    /// **Warum 180 und nicht 90 (47b, Rückmeldung: „es sollte schon der ganze
    /// Meetingname dastehen"):** der Name MUSS mit. Platz dafür kommt nicht vom
    /// Kürzen, sondern aus `Meeting.menuBarTitle`, das Calendly-Suffix
    /// „- Confirmed" fällt weg und spart 77pt. Gemessen: „Maximilian S Call -
    /// Confirmed · noch 32m" = 250pt (Flacker-Zone), ohne Suffix 173pt. 180pt
    /// lässt also den vollen Namen stehen und hält ~107pt Reserve
    /// (408 fremde Icons + 180 + 105 Aufnahme/Mikro = 693 von 790).
    private static let inMeetingMenuBarWidth: CGFloat = 180

    private static let menuBarFont = NSFont.menuBarFont(ofSize: 0)

    private static func width(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: menuBarFont]).width
    }

    /// Kürzt den TITEL so weit, dass das Item unter `maxMenuBarWidth` bleibt,
    /// der Teil hinter dem letzten " · " (Countdown) überlebt IMMER, der ist die
    /// eigentliche Information.
    static func fitToMenuBar(_ text: String, max cap: CGFloat = maxMenuBarWidth) -> String {
        guard width(text) > cap else { return text }

        let sep = " · "
        guard let r = text.range(of: sep, options: .backwards) else {
            // Kein Countdown-Teil: stumpf von hinten kürzen.
            var head = text
            while !head.isEmpty, width(head + "…") > cap { head.removeLast() }
            return head.isEmpty ? text : head + "…"
        }

        let title = String(text[text.startIndex..<r.lowerBound])
        let tail  = String(text[r.upperBound...])          // z.B. "1h 3m"
        var head  = title
        while !head.isEmpty, width(head + "…" + sep + tail) > cap {
            head.removeLast()
        }
        // Selbst ein leerer Titel zu breit → nur den Countdown zeigen.
        return head.isEmpty ? tail : head + "…" + sep + tail
    }

    private func refreshStatusTitle() {
        guard let button = statusItem?.button else { return }
        let s = AppState.shared
        button.contentTintColor = nil
        if s.blinkActive {
            // Runde 5: the whole item blinks like a bright green button so it's
            // impossible to miss (toggling filled ↔ hollow every ~0.45s).
            button.image = nil
            let bright = NSColor(calibratedRed: 0.24, green: 0.86, blue: 0.45, alpha: 1)
            let attrs: [NSAttributedString.Key: Any] = s.blinkOn
                ? [.backgroundColor: bright, .foregroundColor: NSColor.black,
                   .font: NSFont.systemFont(ofSize: 12, weight: .bold)]
                : [.foregroundColor: bright,
                   .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
            button.attributedTitle = NSAttributedString(string: "  \(s.blinkText)  ", attributes: attrs)
        } else if let text = s.menuBarText {
            // Text only, the submarine appears once the day's calls are done
            // (Runde 27c: "nur sehen wenn keine Termine mehr da sind").
            // Runde 46b: durch `fitToMenuBar`, sonst wirft macOS das ganze Item
            // aus der Menüleiste (siehe maxMenuBarWidth). Voller Titel steht
            // weiterhin im Widget.
            // Runde 47b: läuft ein Termin, gilt die engere Grenze, dann ist die
            // Leiste durch Aufnahme- und Mikrofon-Pille am vollsten und ein
            // breites Item flackert (siehe inMeetingMenuBarWidth). Der Titel
            // bleibt drin, nur das Buchungs-Suffix ist vorher weggefallen.
            let inMeeting = s.compactMenuBarInMeeting && s.currentMeeting != nil
            let shown = Self.fitToMenuBar(text, max: inMeeting ? Self.inMeetingMenuBarWidth
                                                              : Self.maxMenuBarWidth)
            // Runde 56: Im Zustand „Zugriff nötig" BLEIBT das U-Boot stehen.
            // Sonst zeigt die Menüleiste beim allerersten Start nur ein nacktes
            // Textfragment ohne App-Bezug, während der Einstieg und die
            // Anleitung den Nutzer genau dann zum U-Boot schicken. Er sucht ein
            // Symbol, das es in seinem Zustand per Definition nicht gibt.
            // Nur in diesem kurzen Zustand, weil `fitToMenuBar` ausschließlich
            // Textbreite misst und ein Bild ~24pt unverbucht dazuaddiert.
            button.image = s.calendarAuthorized ? nil : MenuBarIcon.submarine
            button.attributedTitle = NSAttributedString(string: shown)
            button.title = shown
            button.toolTip = text
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
            button.image = MenuBarIcon.submarine
            // Sonst klebt hier der Titel des letzten Termins als Tooltip fest.
            // F6: im Stil „Nur Symbol" ist der Tooltip die EINZIGE Stelle, an
            // der der Termin noch steht, deshalb hat er dort Vorrang.
            button.toolTip = s.menuBarTooltip
                ?? L.t("MeetingBlitz, Tagesübersicht öffnen",
                       "MeetingBlitz, open today's agenda")
        }
    }
}
