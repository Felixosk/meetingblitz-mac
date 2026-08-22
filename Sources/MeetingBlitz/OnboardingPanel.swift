import SwiftUI
import AppKit

/// Der Einstieg beim ersten Start (Runde 56).
///
/// WARUM ES DEN ÜBERHAUPT BRAUCHT: MeetingBlitz ist eine Accessory-App
/// (LSUIElement). Kein Dock-Icon, kein Fenster, kein Startbildschirm. Wer sie
/// zum ersten Mal öffnet, sieht buchstäblich nichts passieren und hält sie für
/// kaputt, besonders, wenn das Menüleisten-Icon rechts vom Notch keinen Platz
/// findet und macOS es kommentarlos wegwirft (Runde 46b).
///
/// BAUWEISE BEWUSST KONSERVATIV: gleiches `.titled`-Utility-Panel wie
/// Einstellungen und „Neues Meeting". Der randlose Milchglas-Look hat in
/// Runde 47j die ganze App unklickbar gemacht (siehe PROGRESS.md), hier wird
/// nicht experimentiert.
@MainActor
final class OnboardingPanelController: NSObject, NSWindowDelegate {
    static let shared = OnboardingPanelController()
    private var panel: NSPanel?
    private weak var state: AppState?

    /// Wegklicken zählt als erledigt. Ohne das setzt NUR „Fertig" das Flag,
    /// wer das Fenster mit dem roten Punkt schließt, bekommt es bei jedem
    /// Start wieder, mit Autostart also bei jedem Login, jedes Mal mit
    /// `NSApp.activate` mitten in der Arbeit. Aus einer netten App wird so
    /// binnen zwei Tagen etwas, das man deinstalliert.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            state?.onboardingDone = true
            panel = nil
        }
    }

    /// Setzt der AppDelegate: zeigt am Ende das Widget, damit der Nutzer einmal
    /// gesehen hat, wo die App wohnt. Als Hook, weil nur der AppDelegate den
    /// Menüleisten-Button als Anker kennt.
    var onFinished: (() -> Void)?

    var isOpen: Bool { panel?.isVisible == true }

    func show(state: AppState) {
        if let p = panel, p.isVisible {
            p.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingView(rootView: OnboardingPane(
            state: state,
            onFinish: { Task { @MainActor in OnboardingPanelController.shared.finish(state: state) } }))
        hosting.layoutSubtreeIfNeeded()

        // Feste Größe statt fittingSize: Der Inhalt wechselt pro Schritt, und
        // ein Panel, das bei jedem „Weiter" springt, wirkt kaputt. Die Höhe
        // fasst den längsten Schritt.
        let size = NSSize(width: 470, height: 560)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = L.t("Willkommen bei MeetingBlitz", "Welcome to MeetingBlitz")
        p.isReleasedWhenClosed = false
        // Gleiche Ebene wie Widget und Einstellungen. Mit `.floating` lag der
        // Einstieg HINTER dem Einstellungs-Panel (`.popUpMenu`), ausgerechnet
        // beim „Nochmal zeigen", das ja von dort aus aufgerufen wird.
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        // Wie beim Widget: ohne das erscheint der Einstieg bei laufender
        // Vollbild-App auf dem Schreibtisch daneben, also für den Nutzer gar
        // nicht (22.08.2026, Begründung in PanelDock).
        p.collectionBehavior = PanelDock.companionBehavior
        p.contentView = hosting
        p.delegate = self
        self.state = state
        // Das Einstellungsfenster aus dem Weg räumen: Der Einstieg erklärt die
        // Einstellungen, da soll er nicht mit ihnen um den Platz streiten.
        SettingsPanelController.shared.close()
        centerOnMouseScreen(p, size: size)
        // Eine Accessory-App steht nie im Vordergrund. Ohne dieses activate
        // erscheint der Einstieg hinter dem Fenster, in dem der Nutzer gerade
        // arbeitet, und wird schlicht übersehen.
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    /// Abschluss: merken, dass es gelaufen ist, und das Widget zeigen, damit
    /// der Nutzer einmal gesehen hat, wo die App wohnt.
    func finish(state: AppState) {
        state.onboardingDone = true
        // Holt nach, was start() beim Erstlauf ausgelassen hat (Erinnerungen).
        // Der Kalender ist zu diesem Zeitpunkt über den Knopf in Schritt 2
        // erledigt; hier fällt höchstens noch der Erinnerungen-Dialog an, und
        // zwar jetzt, wo der Nutzer weiß, wozu die App überhaupt existiert.
        state.startDeferredAccessRequests()
        close()
        onFinished?()
    }

    /// Mittig auf dem Bildschirm, auf dem die Maus steht. `NSWindow.center()`
    /// nimmt immer den Hauptbildschirm, bei zwei Monitoren landet das Fenster
    /// dann irgendwo links, weit weg vom Blick des Nutzers.
    private func centerOnMouseScreen(_ p: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { p.center(); return }
        p.setFrameOrigin(NSPoint(x: (vf.midX - size.width / 2).rounded(),
                                 y: (vf.midY - size.height / 2).rounded()))
    }

    func close() {
        panel?.delegate = nil          // sonst feuert windowWillClose beim Aufräumen
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

// MARK: - Inhalt

struct OnboardingPane: View {
    @ObservedObject var state: AppState
    let onFinish: () -> Void

    /// Startschritt, damit sich jeder Schritt einzeln prüfen lässt:
    /// `--demo-onboarding --onboarding-step=2`. Ohne das ist die Optik der
    /// späteren Schritte nur per Durchklicken zu sehen, und Tastendrücke von
    /// außen scheitern an den Bedienungshilfen.
    @State private var step = OnboardingPane.initialStep
    @ObservedObject private var google = GoogleService.shared

    /// Der Google-Schritt existiert NUR, wenn eine OAuth-Konfiguration vorliegt.
    /// Ohne sie blendet die App den ganzen Google-Bereich ohnehin aus, dann wäre
    /// ein Einstiegsschritt dafür eine Anleitung für einen Knopf, den es beim
    /// Empfänger gar nicht gibt.
    private var hasGoogleStep: Bool { google.hasConfig }
    private var lastStep: Int { hasGoogleStep ? 4 : 3 }

    static var initialStep: Int {
        for a in CommandLine.arguments where a.hasPrefix("--onboarding-step=") {
            return min(4, max(0, Int(a.dropFirst("--onboarding-step=".count)) ?? 0))
        }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fortschritt: vier Punkte, damit klar ist, wie lang das noch geht.
            HStack(spacing: 6) {
                ForEach(0...lastStep, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: i == step ? 18 : 6, height: 6)
                        .animation(.easeInOut(duration: 0.2), value: step)
                }
                Spacer()
                Picker("", selection: $state.appLanguage) {
                    Text("EN").tag("en")
                    Text("DE").tag("de")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 90)
            }
            .padding(.bottom, 14)

            Group {
                switch step {
                case 0: welcomeStep
                case 1: accessStep
                case 2: calendarStep
                case 3 where hasGoogleStep: googleStep
                default: finishStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().padding(.vertical, 10)

            HStack {
                if step > 0 {
                    Button(L.t("Zurück", "Back")) {
                        withAnimation(.easeInOut(duration: 0.15)) { step -= 1 }
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                if step < lastStep {
                    Button(L.t("Weiter", "Next")) {
                        withAnimation(.easeInOut(duration: 0.15)) { step += 1 }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(L.t("Fertig", "Done"), action: onFinish)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 470, height: 560)
    }

    // MARK: Schritt 1, was das ist und wo es wohnt

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(L.t("Ein U-Boot warnt dich vor jedem Termin",
                      "A submarine warns you before every meeting"))
            body(L.t("""
                Kurz bevor ein Termin aus deinem Apple-Kalender startet, fliegt ein \
                Banner über alle Bildschirme. Überschneidende Termine bekommen jeder \
                ihre eigene Warnung.
                """, """
                Shortly before an event from your Apple Calendar starts, a banner flies \
                across all your screens. Overlapping meetings each get their own warning.
                """))

            // Der wichtigste Satz des ganzen Einstiegs.
            calloutBox(icon: "menubar.arrow.up.rectangle",
                       text: L.t("""
                           Wichtig: Diese App hat kein Fenster und kein Dock-Symbol. \
                           Sie lebt oben rechts in der Menüleiste. Klicke dort auf das \
                           U-Boot, um deinen Tag zu sehen.
                           """, """
                           Important: this app has no window and no dock icon. It lives \
                           in the menu bar, top right. Click the submarine there to see \
                           your day.
                           """))
        }
    }

    // MARK: Schritt 2, Kalenderzugriff

    private var accessStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(L.t("Zugriff auf deinen Kalender", "Access to your calendar"))
            body(L.t("""
                Ohne Kalenderfreigabe sieht MeetingBlitz keine Termine und kann nichts \
                anzeigen. Die Daten bleiben auf deinem Mac, es wird nichts hochgeladen.
                """, """
                Without calendar access MeetingBlitz sees no events and can't show \
                anything. Your data stays on your Mac, nothing is uploaded.
                """))

            if state.calendarAuthorized {
                statusRow(ok: true, text: L.t("Zugriff erteilt", "Access granted"))
            } else {
                Button(L.t("Zugriff erlauben", "Allow access")) {
                    Task { await state.requestCalendarAccess() }
                }
                .buttonStyle(.borderedProminent)

                statusRow(ok: false, text: L.t("Noch kein Zugriff", "No access yet"))

                // Zweiter Weg: Nach einem versehentlichen „Nicht erlauben"
                // fragt macOS NIE wieder von selbst. Ohne diesen Knopf ist der
                // Nutzer an dieser Stelle gestrandet.
                Button(L.t("Systemeinstellungen öffnen", "Open System Settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                body(L.t("""
                    Falls du versehentlich „Nicht erlauben" geklickt hast: macOS fragt \
                    danach nicht noch einmal. Setz den Haken bei MeetingBlitz unter \
                    Datenschutz & Sicherheit → Kalender.
                    """, """
                    If you accidentally clicked "Don't Allow": macOS won't ask again. \
                    Tick MeetingBlitz under Privacy & Security → Calendars.
                    """))
            }

            // Wer die App selbst aus dem Quellcode baut: ohne eigenes Zertifikat ist
            // jeder Rebuild für macOS eine neue App, und genau diese Freigabe ist
            // danach wieder weg. Mit einem stabilen eigenen Zertifikat (siehe
            // signing.local.example) bleibt sie über Updates hinweg erhalten.
            Divider().padding(.vertical, 4)
            body(L.t("""
                Baust du die App selbst aus dem Quellcode: ein Rebuild ohne eigenes \
                Zertifikat setzt diese Freigabe bei jedem Update wieder zurück. \
                Anleitung dazu in signing.local.example im Repo.
                """, """
                Building the app yourself from source: a rebuild without your own \
                certificate resets this permission on every update. See \
                signing.local.example in the repo for setup.
                """))
        }
    }

    // MARK: Schritt 3, welche Kalender

    private var calendarStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            title(L.t("Deine Kalender", "Your calendars"))
            body(L.t("""
                Fremde Kalender lässt man oft sichtbar, will davon aber kein U-Boot und \
                keine Geburtstage. Alles hier ist später in den Einstellungen änderbar.
                """, """
                Shared calendars are often worth seeing without a submarine for every \
                entry. All of this is changeable later in settings.
                """))

            if state.availableCalendars.isEmpty {
                body(L.t("Noch keine Kalender sichtbar, erteile im Schritt davor den Zugriff.",
                         "No calendars yet, grant access in the previous step."))
            } else {
                // Beschriftete Spalten: drei nackte Häkchen nebeneinander sind
                // sonst nicht zu erraten (dieselbe Kopfzeile wie in den
                // Einstellungen, damit man es nur einmal lernen muss).
                HStack(spacing: 0) {
                    Text(L.t("Kalender", "Calendar"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(L.t("Zeigen", "Show")).frame(width: 46)
                    Text("🔔").frame(width: 34)
                    Text("🎂").frame(width: 34)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.trailing, 14)

                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(state.availableCalendars) { c in
                            HStack(spacing: 0) {
                                HStack(spacing: 6) {
                                    Circle().fill(c.color).frame(width: 8, height: 8)
                                    Text(c.title).font(.system(size: 12)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Toggle("", isOn: Binding(
                                    get: { state.selectedCalendarIDs.contains(c.id) },
                                    set: { _ in state.toggleCalendar(c.id) }
                                )).labelsHidden().toggleStyle(.checkbox).frame(width: 46)
                                Toggle("", isOn: Binding(
                                    get: { state.isAlertCalendar(c.id) },
                                    set: { _ in state.toggleAlertCalendar(c.id) }
                                )).labelsHidden().toggleStyle(.checkbox).frame(width: 34)
                                Toggle("", isOn: Binding(
                                    get: { state.isBirthdayCalendar(c.id) },
                                    set: { _ in state.toggleBirthdayCalendar(c.id) }
                                )).labelsHidden().toggleStyle(.checkbox).frame(width: 34)
                            }
                        }
                    }
                    .padding(.trailing, 14)
                }
                // Feste Höhe: ScrollView hat keine intrinsische Höhe und würde
                // in einem sich selbst messenden Panel auf 0 kollabieren
                // (Lektion aus Runde 14). Hoch genug für ~10 Kalender am Stück.
                .frame(height: 270)
            }
        }
    }

    // MARK: Google Meet (nur mit vorhandener Konfiguration)

    private var googleStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(L.t("Google Meet verbinden", "Connect Google Meet"))
            body(L.t("""
                Optional. Verbunden kannst du direkt aus der App einen Termin mit \
                fertigem Meet-Link anlegen. Der Einladungstext landet dabei gleich in \
                der Zwischenablage.
                """, """
                Optional. Once connected you can create an event with a ready Meet link \
                straight from the app. The invite text goes to your clipboard with it.
                """))

            if google.isConnected {
                statusRow(ok: true, text: L.t("Verbunden als \(google.accountEmail ?? "")",
                                              "Connected as \(google.accountEmail ?? "")"))
                Button(L.t("Trennen", "Disconnect")) { google.disconnect() }
                    .buttonStyle(.link).font(.system(size: 11))
            } else {
                Button(L.t("Mit Google verbinden", "Connect with Google")) {
                    Task { await google.connect() }
                }
                .buttonStyle(.borderedProminent)
                statusRow(ok: false, text: L.t("Nicht verbunden", "Not connected"))
            }

            Divider()

            body(L.t("""
                So läuft es ab: Es öffnet sich dein Browser mit der Google-Anmeldung. \
                Wähle das Konto, unter dem deine Termine laufen, und bestätige den \
                Zugriff auf Kalender. Danach kannst du das Browserfenster schließen.
                """, """
                What happens: your browser opens with the Google sign-in. Pick the \
                account your meetings run under and confirm calendar access. After that \
                you can close the browser window.
                """))
            body(L.t("""
                Ohne diesen Schritt funktioniert alles andere ganz normal. Du kannst ihn \
                jederzeit in den Einstellungen unter Google nachholen.
                """, """
                Everything else works normally without this step. You can do it later in \
                settings under Google.
                """))
        }
    }

    // MARK: Letzter Schritt, einrichten und ausprobieren

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            title(L.t("Fast fertig", "Almost done"))

            Toggle(L.t("Beim Login starten", "Launch at login"), isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .font(.system(size: 12))

            Toggle(L.t("Öffnen per Tastenkürzel (⌃⌥M)", "Open with keyboard shortcut (⌃⌥M)"),
                   isOn: $state.hotkeyEnabled)
                .font(.system(size: 12))
            body(L.t("""
                Nützlich, wenn das Menüleisten-Icon mal nicht zu sehen ist: Wenn rechts \
                oben zu viele Symbole liegen, wirft macOS einzelne kommentarlos raus. \
                Das Kürzel öffnet das Fenster trotzdem.
                """, """
                Useful when the menu bar icon isn't visible: when the top right gets \
                crowded, macOS silently drops icons. The shortcut opens the window anyway.
                """))

            Divider()

            Button(L.t("Test-Banner zeigen", "Show test banner")) { state.showTestBanner() }
            body(L.t("""
                So sieht die Warnung aus. Vorlaufzeit, Flugdauer und Ton stellst du in \
                den Einstellungen ein, Klick aufs U-Boot in der Menüleiste, dann unten \
                auf „Einstellungen".
                """, """
                That's what the warning looks like. Lead time, flight duration and sound \
                are in settings, click the submarine in the menu bar, then "Settings".
                """))
        }
    }

    // MARK: - Bausteine

    private func title(_ t: String) -> some View {
        Text(t).font(.system(size: 15, weight: .semibold))
    }

    private func body(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusRow(ok: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(text).font(.system(size: 12))
        }
    }

    private func calloutBox(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.12))
        )
    }
}
