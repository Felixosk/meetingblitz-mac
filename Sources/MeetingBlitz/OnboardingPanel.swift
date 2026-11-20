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

    /// ✕ in der Kopfzeile.
    func closeByUser() { panel?.close() }

    func show(state: AppState) {
        if let p = panel, p.isVisible {
            p.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingView(rootView: OnboardingPane(
            state: state,
            onFinish: { Task { @MainActor in OnboardingPanelController.shared.finish(state: state) } },
            onClose: { Task { @MainActor in OnboardingPanelController.shared.closeByUser() } },
            onHeight: { h in DispatchQueue.main.async { MainActor.assumeIsolated { OnboardingPanelController.shared.setGlassHeight(h) } } }))
        hosting.layoutSubtreeIfNeeded()

        // Feste Größe statt fittingSize: Der Inhalt wechselt pro Schritt, und
        // ein Panel, das bei jedem „Weiter" springt, wirkt kaputt. Die Höhe
        // fasst den längsten Schritt.
        let size = NSSize(width: Theme.welcomeWidth + 2 * Theme.stageInset, height: Theme.welcomeHeight + 2 * Theme.stageInset)
        let p = ThemePanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .utilityWindow, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = L.t("Willkommen bei MeetingBlitz", "Welcome to MeetingBlitz")
        // Runde 98: Glas wie die anderen Fenster; Esc schließt nur, wenn die
        // Einrichtung schon einmal fertig war (sonst würde man sie versehentlich überspringen).
        p.titlebarAppearsTransparent = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.onEscape = { [weak p] in if AppState.shared.onboardingDone { p?.close() } }
        p.isReleasedWhenClosed = false
        // Gleiche Ebene wie Widget und Einstellungen. Mit `.floating` lag der
        // Einstieg HINTER dem Einstellungs-Panel (`.popUpMenu`), ausgerechnet
        // beim „Nochmal zeigen", das ja von dort aus aufgerufen wird.
        p.level = .floating
        // Runde 115: Aussehen kommt von NSApp.appearance (Look.apply).
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        // Wie beim Widget: ohne das erscheint der Einstieg bei laufender
        // Vollbild-App auf dem Schreibtisch daneben, also für den Nutzer gar
        // nicht (22.08.2026, Begründung in PanelDock).
        p.collectionBehavior = PanelDock.companionBehavior
        p.contentView = hosting
        Theme.installStage(in: p)
        p.delegate = self
        self.state = state
        // Das Einstellungsfenster aus dem Weg räumen: Der Einstieg erklärt die
        // Einstellungen, da soll er nicht mit ihnen um den Platz streiten.
        // Runde 111b (B6): Widget und Einstellungen bleiben offen, das Willkommen liegt mittig darüber.
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

    private var pendingShrink: DispatchWorkItem?
    /// Runde 112 (Fund 9): Fensterhöhe folgt dem Schritt, Oberkante bleibt; Wachsen sofort, Schrumpfen nach der Feder.
    func setGlassHeight(_ h: CGFloat) {
        guard let p = panel else { return }
        let target = h + 2 * Theme.stageInset
        let old = p.frame
        guard abs(target - old.height) > 0.5 else { return }
        let apply = { [weak p] in
            guard let p else { return }
            let f = p.frame
            (p as? ThemePanel)?.setFrameFromController(NSRect(x: f.minX, y: f.maxY - target, width: f.width, height: target), display: true)
        }
        pendingShrink?.cancel()
        if target < old.height {
            let w = DispatchWorkItem(block: apply); pendingShrink = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.foldSettle, execute: w)
        } else { apply() }
    }

    func close() {
        pendingShrink?.cancel()
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
    var onClose: (() -> Void)? = nil

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
    /// Runde 111b (B6): vier Schritte (ohne Google-Konfiguration drei): Kalender, Google Meet, So planst du ein Meeting, Fertig.
    private enum Step { case calendar, google, plan, done }
    private var steps: [Step] { hasGoogleStep ? [.calendar, .google, .plan, .done] : [.calendar, .plan, .done] }
    private var lastStep: Int { steps.count - 1 }
    var onHeight: ((CGFloat) -> Void)? = nil

    /// Runde 116: gemessene Inhaltshöhe von Schritt 2/3 (statt fester Zahl); Rest = Rand + Teiler + Knopfzeile.
    @State private var measuredPlan: CGFloat = 0
    @State private var measuredGoogle: CGFloat = 0
    private var footerFixed: CGFloat { Theme.s16 * 2 + Theme.s8 * 2 + 1 + Theme.rowHeight }
    /// Runde 112 (Fund 9): Höhe je Schritt (Glas), keine leeren zwei Drittel.
    private var stepHeight: CGFloat {
        let footer: CGFloat = 70 + Theme.s16 * 2
        switch steps[min(step, lastStep)] {
        case .calendar:
            let base: CGFloat = state.calendarAuthorized ? 200 : 330
            let list: CGFloat = state.calendarAuthorized && !state.availableCalendars.isEmpty ? min(CGFloat(state.availableCalendars.count), 8) * 28 + 40 : 0
            return base + list + footer - 70
        case .google: return measuredGoogle > 0 ? measuredGoogle + footerFixed : 270 + footer - 70
        case .plan: return measuredPlan > 0 ? measuredPlan + footerFixed : 340 + footer - 70
        case .done: return 250 + footer - 70
        }
    }

    static var initialStep: Int {
        for a in CommandLine.arguments where a.hasPrefix("--onboarding-step=") {
            return min(4, max(0, Int(a.dropFirst("--onboarding-step=".count)) ?? 0))
        }
        return 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Runde 110b (U3): keine Platzhalter-Zeile mehr, die Überschrift steht auf Glas-y 16.
            Group {
                switch steps[min(step, lastStep)] {
                case .calendar: calendarStep
                case .google: googleStep
                case .plan: planStep
                case .done: finishStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            ThemeDivider().padding(.vertical, Theme.s8)

            // Fortschritt als Seitenzähler mittig zwischen Zurück und Weiter, auf deren Mittellinie.
            ZStack {
                HStack {
                    if step > 0 {
                        ThemeTextRow(title: L.t("Zurück", "Back"), fullWidth: false) {
                            withAnimation(.easeInOut(duration: 0.15)) { step -= 1 }
                        }
                    }
                    Spacer()
                    if step < lastStep {
                        ThemePrimaryButton(title: L.t("Weiter", "Continue")) {
                            withAnimation(.easeInOut(duration: 0.15)) { step += 1 }
                        }
                        .frame(width: 140)
                        .keyboardShortcut(.defaultAction)
                    } else {
                        ThemePrimaryButton(title: L.t("Fertig", "Done"), action: onFinish)
                            .frame(width: 140)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                HStack(spacing: Theme.s8) {
                    ForEach(0...lastStep, id: \.self) { i in
                        Capsule()
                            .fill(i == step ? Theme.blue : Theme.line)
                            .frame(width: i == step ? 18 : 6, height: 6)
                            .animation(.easeInOut(duration: 0.2), value: step)
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(height: Theme.rowHeight)   // gleich hoch mit und ohne "Zurück": der Weiter-Knopf springt nicht
        }
        .toggleStyle(ThemeToggleStyle())
        .padding(.horizontal, Theme.s16).padding(.bottom, Theme.s16).padding(.top, Theme.s16)
        .frame(width: Theme.welcomeWidth, height: stepHeight)
        .onChange(of: stepHeight, initial: true) { _, h in onHeight?(h) }
        .background(ThemeGlass())   // Runde 116: gleiches Glas wie alle Fenster
        .themeDragHeader()
        .themeCloseCorner { onClose?() }
        .padding(Theme.stageInset)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()   // Runde 103: Kopfzeile sitzt exakt 16 pt unter der Fensterkante
    }

    // MARK: Schritt 3, welche Kalender

    private var calendarStep: some View {
        VStack(alignment: .leading, spacing: Theme.s8) {
            HStack(alignment: .firstTextBaseline) {
                title(L.t("Dein Kalender", "Your calendar"))
                Spacer(minLength: Theme.s8)
                // Sprache klein oben rechts.
                SegPick(options: [("EN", "en"), ("DE", "de")], selection: $state.appLanguage, fill: false).fixedSize()
            }
            body(L.t("MeetingBlitz zeigt dir dein nächstes Meeting und legt neue mit einem Klick an. Termine bleiben auf deinem Mac, Meet-Links kommen von Google.",
                     "MeetingBlitz shows your next meeting and creates new ones with one click. Your events stay on your Mac, Meet links come from Google."))

            if !state.calendarAuthorized {
                ThemePrimaryButton(title: L.t("Zugriff erlauben", "Allow access")) {
                    Task { await state.requestCalendarAccess() }
                }
                statusRow(ok: false, text: L.t("Noch kein Zugriff", "No access yet"))
                // Nach einem versehentlichen „Nicht erlauben" fragt macOS NIE wieder von selbst.
                ThemeTextRow(title: L.t("Systemeinstellungen öffnen", "Open System Settings"),
                             accent: true, fullWidth: false) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .themeRowList()
                body(L.t("Falls du „Nicht erlauben“ geklickt hast: macOS fragt nicht noch einmal. Setz den Haken bei MeetingBlitz unter Datenschutz & Sicherheit → Kalender.",
                         "If you clicked “Don’t Allow”: macOS won’t ask again. Tick MeetingBlitz under Privacy & Security → Calendars."))
            } else {
                statusRow(ok: true, text: L.t("Zugriff erteilt", "Access granted"))
            }

            if state.calendarAuthorized, !state.availableCalendars.isEmpty {
                // Beschriftete Spalten: drei nackte Häkchen nebeneinander sind
                // sonst nicht zu erraten (dieselbe Kopfzeile wie in den
                // Einstellungen, damit man es nur einmal lernen muss).
                HStack(spacing: 0) {
                    Text(L.t("Kalender", "Calendar")).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach([("eye", L.t("Zeigen", "Show"), 46), ("bell", L.t("Banner", "Banner"), 40), ("gift", L.t("Geburtstage", "Birthdays"), 40)], id: \.0) { sym, name, w in
                        VStack(spacing: 1) {
                            Image(systemName: sym).font(.theme(.small, .semibold))
                            Text(name).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(width: CGFloat(w))
                    }
                }
                .font(.theme(.small))
                .foregroundStyle(Theme.muted)
                .padding(.trailing, 14)

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.s4) {
                        ForEach(state.availableCalendars) { c in
                            HStack(spacing: 0) {
                                HStack(spacing: Theme.s8) {
                                    Circle().fill(c.color).frame(width: 8, height: 8)
                                    Text(c.title).font(.theme(.normal)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Toggle("", isOn: Binding(
                                    get: { state.selectedCalendarIDs.contains(c.id) },
                                    set: { _ in state.toggleCalendar(c.id) }
                                )).labelsHidden().toggleStyle(ThemeCheckStyle()).frame(width: 46)
                                Toggle("", isOn: Binding(
                                    get: { state.isAlertCalendar(c.id) },
                                    set: { _ in state.toggleAlertCalendar(c.id) }
                                )).labelsHidden().toggleStyle(ThemeCheckStyle()).frame(width: 34)
                                Toggle("", isOn: Binding(
                                    get: { state.isBirthdayCalendar(c.id) },
                                    set: { _ in state.toggleBirthdayCalendar(c.id) }
                                )).labelsHidden().toggleStyle(ThemeCheckStyle()).frame(width: 34)
                            }
                        }
                    }
                    .padding(.trailing, 14)
                }
                // Feste Höhe: ScrollView hat keine intrinsische Höhe und würde
                // in einem sich selbst messenden Panel auf 0 kollabieren
                // (Lektion aus Runde 14). Hoch genug für ~10 Kalender am Stück.
                .frame(height: min(CGFloat(state.availableCalendars.count), 8) * 28 + 4)
            }
        }
    }

    // MARK: Google Meet (nur mit vorhandener Konfiguration)

    private var googleStep: some View {
        VStack(alignment: .leading, spacing: Theme.s16) {
            title(L.t("Google Meet", "Google Meet"))
            body(L.t("Damit jeder Termin automatisch einen Meet-Link bekommt.",
                     "So every meeting gets a Meet link automatically."))

            if google.isConnected {
                // Runde 116: verbunden = Haken + Konto; "Trennen" gibt es nur in den Einstellungen.
                statusRow(ok: true, text: L.t("Verbunden als \(google.accountEmail ?? "")",
                                              "Connected as \(google.accountEmail ?? "")"))
            } else {
                ThemePrimaryButton(title: L.t("Mit Google verbinden", "Connect with Google")) {
                    Task { await google.connect() }
                }
                statusRow(ok: false, text: L.t("Nicht verbunden", "Not connected"))
            }

            if !google.isConnected {
                // Später verbinden: geht weiter, ohne Google läuft alles andere normal.
                ThemeTextRow(title: L.t("Später verbinden", "Connect later"), accent: false, fullWidth: false) {
                    withAnimation(.easeInOut(duration: 0.15)) { step += 1 }
                }
                .themeRowList()
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measuredGoogle = $0 }
    }

    // MARK: Schritt 3, So planst du ein Meeting

    private var planStep: some View {
        VStack(alignment: .leading, spacing: Theme.s16) {
            title(L.t("So planst du ein Meeting", "Plan a meeting"))
            // Schein-Formular, nur Beispieldaten (keine echten Namen oder Termine).
            OnboardingMiniForm()
            VStack(alignment: .leading, spacing: Theme.s8) {
                tip("keyboard", L.t("\(state.hotkeyWidgetLabel) öffnet das Widget.", "\(state.hotkeyWidgetLabel) opens the widget."))
                tip("text.cursor", L.t("Tippen wie „fr 10-12 call mit chris“.", "Type like “fri 10-12 call with chris”."))
                tip("paperplane", L.t("Erstellen kopiert die Einladung oder schickt die Mail.", "Create copies the invite or sends the mail."))
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measuredPlan = $0 }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.s8) {
            Image(systemName: symbol).font(.theme(.normal)).foregroundStyle(Theme.blue).frame(width: 18)
            Text(text).font(.theme(.normal)).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Letzter Schritt, einrichten und ausprobieren

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: Theme.s16) {
            title(L.t("Fertig", "You’re set"))
            body(L.t("Kurz vor jedem Meeting fliegt ein Hinweis über den Bildschirm.",
                     "Shortly before every meeting a notice flies across the screen."))
            ThemeTextRow(title: L.t("Test-Banner zeigen", "Show test banner"), accent: true, fullWidth: false) { state.showTestBanner() }.themeRowList()
            Toggle(L.t("Bei der Anmeldung öffnen", "Open at login"), isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .font(.theme(.normal))
        }
    }

    // MARK: - Bausteine

    private func title(_ t: String) -> some View {
        Text(t).font(.theme(.title, .bold)).foregroundStyle(Theme.label).padding(.bottom, Theme.s4)
    }

    private func body(_ t: String) -> some View {
        Text(t)
            .font(.theme(.normal))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusRow(ok: Bool, text: String) -> some View {
        HStack(spacing: Theme.s8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? Theme.ok : Theme.muted)
            Text(text).font(.theme(.normal))
        }
    }

    private func calloutBox(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.s8) {
            Image(systemName: icon)
                .font(.theme(.normal))
                .foregroundStyle(Theme.blue)
            Text(text)
                .font(.theme(.normal))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)   // Runde 110b (U3): volle Breite
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.blue.opacity(0.18))
        )
    }
}


/// Runde 116: Schein-Termin-Fenster für Schritt 3, nur das Wesentliche (Eingabefeld, Uhrzeit, Knopf), in Originalgröße.
/// Texte wie im echten Termin-Fenster (CreateButtonTitle), nur Beispieldaten.
struct OnboardingMiniForm: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s8) {
            Text("Call with Anna").font(.theme(.normal)).foregroundStyle(Theme.label)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Theme.s8).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("10:30").font(.theme(.big, .bold)).foregroundStyle(Theme.blue)
                Text("AM").font(.theme(.title, .bold)).foregroundStyle(Theme.blue)
                Spacer()
                Text(L.t("Fr 20. Nov", "Fri, Nov 20")).font(.theme(.normal)).foregroundStyle(Theme.muted)
            }
            Text(CreateButtonTitle.make(mailTo: [], text: true, ics: false, de: L.isDE))
                .font(.theme(.normal, .semibold)).foregroundStyle(Theme.onBlue)
                .frame(maxWidth: .infinity).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.blue))
        }
        .padding(Theme.s16)
        .background(RoundedRectangle(cornerRadius: Theme.windowRadius, style: .continuous).fill(Theme.fill))
    }
}
