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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance (Runde 46). Eine zweite Kopie der App (gemeldet wurde:te eine
        // Alt-Kopie in ~/Downloads, die zusätzlich in den Login Items stand) läuft
        // unter DERSELBEN Bundle-ID, macOS wirft dann das kollidierende
        // NSStatusItem raus und das Menüleisten-Icon verschwindet kommentarlos.
        // Die ältere Instanz gewinnt, die neue beendet sich sofort.
        if !CommandLine.arguments.contains("--diagnose"),
           let bid = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bid)
               .contains(where: { $0.processIdentifier != NSRunningApplication.current.processIdentifier }) {
            NSLog("MeetingBlitz läuft bereits, diese Instanz beendet sich (Status-Item-Kollision).")
            exit(0)
        }

        NSApp.setActivationPolicy(.accessory)   // menu-bar only, no dock icon
        AppState.shared.start()

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
        AppState.shared.onHotkeyToggle = { [weak self] on in
            guard let self else { return }
            if on {
                HotKeyManager.shared.register(keyCode: HotKeyManager.defaultKeyCode,
                                              modifiers: HotKeyManager.defaultModifiers) {
                    WidgetPanelController.shared.toggle(state: .shared,
                                                        statusButton: self.statusItem?.button,
                                                        anchorToMouseScreen: true)
                }
            } else {
                HotKeyManager.shared.unregister()
            }
        }
        AppState.shared.onHotkeyToggle?(AppState.shared.hotkeyEnabled)

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
                    AppState.shared.dayOffset = max(0, min(7, day))
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
        menu.addItem(NSMenuItem(title: L.t("MeetingBlitz beenden", "Quit MeetingBlitz"),
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
    }

    @objc private func openSettings() { AppState.shared.toggleSettingsPanel() }

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
            button.toolTip = L.t("MeetingBlitz, Tagesübersicht öffnen",
                                 "MeetingBlitz, open today's agenda")
        }
    }
}
