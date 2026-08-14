import SwiftUI
import AppKit
import ServiceManagement

/// The settings live in their own floating panel (point: "nicht im Widget
/// selber"). Runde 6: it opens directly BELOW the widget ("hier unten
/// aufgemacht"), never overlapping it; the window stays movable.
@MainActor
final class SettingsPanelController {
    static let shared = SettingsPanelController()
    private var panel: NSPanel?
    /// Merkt sich, wohin das Panel gezogen wird (Runde 47h). `window.delegate`
    /// ist weak, also muss der Controller den Recorder halten.
    private var moveRecorder: PanelMoveRecorder?
    /// Widget-Frame vom Öffnen, fürs Nach-Platzieren im ersten resize (47i).
    private var anchorRect: CGRect?

    /// Toggle the settings panel, opening it centred underneath the widget
    /// (`anchor`), clamped to the visible screen.
    func toggle(state: AppState, anchor: CGRect?) {
        if let p = panel, p.isVisible { close(); return }

        // Runde 47j ZURÜCKGENOMMEN (siehe PROGRESS): der randlose Milchglas-Look
        // machte die Panels unklickbar. Wieder das bewährte titled Utility-Panel.
        let hosting = SettingsHostingView(rootView: SettingsPane(
            state: state,
            onClose: { Task { @MainActor in SettingsPanelController.shared.close() } },
            onSize: { size in
                Task { @MainActor in SettingsPanelController.shared.resize(to: size) }
            }))
        hosting.sizingOptions = [.preferredContentSize]   // grow when Kalender expands
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = L.t("Einstellungen", "Settings")
        p.isReleasedWhenClosed = false
        p.level = .popUpMenu       // same tier as the widget, above other apps
        p.hidesOnDeactivate = false
        // Key from the start: controls only render their active (blue) accent
        // in a key window, otherwise everything sits gray until first clicked.
        p.becomesKeyOnlyIfNeeded = false
        p.contentView = hosting

        // Runde 47g/47h/47i: gemerkte Position gewinnt, sonst neben das Widget.
        // Grobplatzierung, die endgültige macht das erste resize() mit der
        // echten Größe (fittingSize kann hier noch ~0 sein, siehe CreatePanel).
        anchorRect = anchor
        let panelSize = p.frame.size
        p.setFrameOrigin(PanelDock.savedOrigin(panelSize: panelSize, id: "settings")
                         ?? PanelDock.origin(panelSize: panelSize, anchor: anchor))
        p.makeKeyAndOrderFront(nil)   // key immediately → blue accents from the start
        // Position merken, sobald das Panel gezogen wird (Runde 47h). Startet
        // SUSPENDIERT: bis die Erstplatzierung durch ist, ist jede Bewegung
        // programmatisch und darf nicht als „gezogen" gespeichert werden.
        let recorder = PanelMoveRecorder(id: "settings")
        recorder.suspended = true
        p.delegate = recorder
        moveRecorder = recorder
        panel = p
        // Runde 47i(2): Die endgültige Platzierung passiert im NÄCHSTEN
        // Runloop-Durchlauf. Grund: `fittingSize` ist beim Erstellen noch ~0
        // (Phantom), und die echte Größe kommt über ZWEI mögliche Wege,
        // AppKits preferredContentSize-Auto-Resize ODER unseren onSize-
        // Callback. Der „beim ersten resize neu platzieren"-Ansatz verfehlte
        // den ersten Weg: dort hat das Fenster schon echte Breite, bevor
        // resize() je läuft. Ein async-Hop deckt beide ab.
        DispatchQueue.main.async { [weak self] in self?.finishInitialPlacement() }
    }

    /// Grow/shrink the panel when the content size changes (Kalender expand),
    /// keeping the top edge fixed and clamping into the visible screen.
    func resize(to contentSize: CGSize) {
        guard let p = panel, p.isVisible, contentSize.width > 1 else { return }
        let frameSize = p.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)).size
        let old = p.frame
        // Erstplatzierung noch offen (Recorder suspendiert)? Dann mit der
        // frischen Größe direkt richtig platzieren, nicht warten.
        if moveRecorder?.suspended == true {
            let origin = PanelDock.savedOrigin(panelSize: frameSize, id: "settings")
                ?? PanelDock.origin(panelSize: frameSize, anchor: anchorRect)
            p.setFrame(CGRect(origin: origin, size: frameSize), display: true)
            moveRecorder?.suspended = false
            return
        }
        if abs(frameSize.height - old.height) < 1, abs(frameSize.width - old.width) < 1 { return }
        moveRecorder?.suspended = true
        do {
            var y = old.maxY - frameSize.height
            if let vf = PanelDock.visibleFrame(containing: old) {
                y = PanelDock.clampY(y, height: frameSize.height, vf: vf)
            }
            p.setFrame(CGRect(x: old.minX, y: y.rounded(), width: frameSize.width, height: frameSize.height),
                       display: true)
        }
        moveRecorder?.suspended = false
    }

    /// Endgültige Erstplatzierung, sobald das Panel seine echte Größe hat
    /// (Runde 47i(2)). Läuft einen Runloop nach dem Öffnen; falls resize()
    /// schneller war (suspended schon false), tut sie nichts.
    private func finishInitialPlacement() {
        guard let p = panel, p.isVisible, moveRecorder?.suspended == true else { return }
        let size = p.frame.size
        guard size.width > 50 else { return }   // immer noch Phantom → resize() übernimmt
        p.setFrameOrigin(PanelDock.savedOrigin(panelSize: size, id: "settings")
                         ?? PanelDock.origin(panelSize: size, anchor: anchorRect))
        moveRecorder?.suspended = false
    }

    func close() {
        panel?.delegate = nil
        moveRecorder = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// True if `window` is the settings panel, lets the widget's dismiss
    /// monitor keep both open when the user clicks into settings.
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === panel }
}

/// First click must land even though the accessory app is rarely "active".
private final class SettingsHostingView: NSHostingView<SettingsPane> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    required init(rootView: SettingsPane) { super.init(rootView: rootView) }
    @objc required dynamic init?(coder: NSCoder) { fatalError("not used") }
}

/// Reports the settings content's laid-out size so the panel can grow when the
/// calendar list expands (a fixed-size panel would clip it).
private struct SettingsSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// The settings content, moved out of MenuPanel.
struct SettingsPane: View {
    @ObservedObject var state: AppState
    @ObservedObject var google = GoogleService.shared
    /// Ersetzt den weggefallenen Schließen-Knopf der Titelleiste (Runde 47j).
    var onClose: (@Sendable () -> Void)? = nil
    var onSize: (@Sendable (CGSize) -> Void)? = nil

    private let leadOptions = [2, 5, 10, 15]
    private let flightOptions: [Double] = [6, 9, 14]
    /// Which settings tab is showing (Runde 41): splits the long page so only
    /// one short section is visible at a time.
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $tab) {
                Text(L.t("Allgemein", "General")).tag(0)
                Text(L.t("Banner", "Alerts")).tag(1)
                Text(L.t("Kalender", "Calendars")).tag(2)
                if google.hasConfig { Text("Google").tag(3) }
            }
            .labelsHidden().pickerStyle(.segmented)

            switch tab {
            case 1: alertsTab
            case 2: calendarsTab
            case 3 where google.hasConfig: googleTab
            default: generalTab
            }

            // App version (Runde 42), shown on every tab.
            Divider()
            Text("MeetingBlitz \(Self.appVersion)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
        .frame(width: 300)
        .background(GeometryReader { g in
            Color.clear.preference(key: SettingsSizeKey.self, value: g.size)
        })
        .onPreferenceChange(SettingsSizeKey.self) { size in
            if size != .zero { onSize?(size) }
        }
        .onAppear { state.refreshLaunchAtLogin() }
    }

    // MARK: - Tab: Allgemein

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L.t("Vorlaufzeit", "Lead time")).font(.system(size: 12))
                Spacer()
                Picker("", selection: $state.leadMinutes) {
                    ForEach(leadOptions, id: \.self) { Text("\($0)m").tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            HStack {
                Text(L.t("Flugdauer", "Flight time")).font(.system(size: 12))
                Spacer()
                Picker("", selection: $state.animationSeconds) {
                    ForEach(flightOptions, id: \.self) { Text("\(Int($0))s").tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            Toggle(L.t("Ton abspielen", "Play sound"), isOn: $state.soundEnabled).font(.system(size: 12))
            Toggle(L.t("Sprung aus dem Wasser", "Jump out of the water"), isOn: $state.waterEffect).font(.system(size: 12))
            Toggle(L.t("Beim Login starten", "Launch at login"), isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            )).font(.system(size: 12))
            Toggle(L.t("Apple Erinnerungen zeigen", "Show Apple Reminders"), isOn: Binding(
                get: { state.showReminders },
                set: { on in
                    state.showReminders = on
                    if on { Task { await state.requestRemindersAccess() } }
                    else { state.reminders = [] }
                }
            )).font(.system(size: 12))
            if state.showReminders && !state.remindersAuthorized {
                Text(L.t("Erinnerungen-Zugriff nötig, beim ersten Mal erlauben.",
                         "Reminders access needed, allow it once."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            // Runde 47: gegen das Flackern im laufenden Meeting (Aufnahme- und
            // Mikrofon-Pille sprengen sonst das Breitenbudget der Menüleiste).
            Toggle(L.t("Menüleiste im Meeting schmal halten", "Keep the menu bar narrow during meetings"),
                   isOn: $state.compactMenuBarInMeeting).font(.system(size: 12))
            if state.compactMenuBarInMeeting {
                Text(L.t("Name + Restzeit bleiben stehen, nur „- Confirmed\" und Ähnliches fällt weg. Sonst verdrängen Aufnahme- und Mikrofon-Symbol das Item und es flackert.",
                         "Name + time left stay; only booking noise like “- Confirmed” is dropped. Otherwise the recording and microphone indicators push the item out and it flickers."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Toggle(L.t("Öffnen per Tastenkürzel", "Open with a hotkey"),
                       isOn: $state.hotkeyEnabled).font(.system(size: 12))
                Spacer()
                Text(HotKeyManager.defaultLabel)
                    .font(.system(size: 11, weight: .semibold).monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                    .opacity(state.hotkeyEnabled ? 1 : 0.4)
            }
            Text(L.t("Öffnet das Widget auf dem Bildschirm, wo die Maus ist, unabhängig vom Menüleisten-Icon.",
                     "Opens the widget on the screen your mouse is on, independent of the menu-bar icon."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Runde 47h: Panels merken sich, wohin man sie zieht. Das hier holt
            // sie zurück, falls eine gemerkte Position mal unpraktisch liegt.
            HStack(spacing: 6) {
                Text(L.t("Panel-Position", "Panel position")).font(.system(size: 12))
                Spacer()
                Button(L.t("Zurücksetzen", "Reset")) { PanelDock.forgetPositions() }
                    .font(.system(size: 12)).buttonStyle(.borderless)
            }
            Text(L.t("Einstellungen und „Neues Meeting“ öffnen dort, wo du sie zuletzt hingezogen hast, sonst neben dem Widget.",
                     "Settings and “New Meeting” open where you last dragged them, otherwise next to the widget."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Runde 56: Der Einstieg läuft normalerweise genau einmal. Dieser
            // Knopf holt ihn zurück, zum Nachschlagen, oder wenn die App auf
            // einem neuen Rechner landet und man sie jemandem zeigen will.
            HStack(spacing: 6) {
                Text(L.t("Einführung", "Walkthrough")).font(.system(size: 12))
                Spacer()
                Button(L.t("Nochmal zeigen", "Show again")) {
                    OnboardingPanelController.shared.show(state: state)
                }
                .font(.system(size: 12)).buttonStyle(.borderless)
            }
            Text(L.t("Erklärt Menüleiste, Kalenderfreigabe und Autostart, so wie beim ersten Start.",
                     "Explains the menu bar, calendar access and launch at login, like on first run."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Text(L.t("Sprache", "Language")).font(.system(size: 12))
                Spacer()
                Picker("", selection: $state.appLanguage) {
                    Text("English").tag("en")
                    Text("Deutsch").tag("de")
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
        }
    }

    // MARK: - Tab: Banner (alert behaviour)

    private var alertsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L.t("Ruhe-Modus (keine Banner)", "Quiet mode (no banners)"), isOn: $state.quietMode).font(.system(size: 12))
            Toggle(L.t("Ruhe bei Bildschirmfreigabe", "Quiet while screen sharing"), isOn: $state.quietDuringScreenShare).font(.system(size: 12))
            Toggle(L.t("Auto-Beitreten (10s vorher)", "Auto-join (10s before)"), isOn: $state.autoJoin).font(.system(size: 12))
            Toggle(L.t("Warnung vor Meeting-Ende", "End-of-meeting warning"), isOn: $state.endWarning).font(.system(size: 12))

            // Multi-monitor: only with more than one screen.
            if NSScreen.screens.count > 1 {
                Divider()
                HStack {
                    Text(L.t("Startbildschirm", "Start screen")).font(.system(size: 12))
                    Spacer()
                    // Segmented (NOT .menu): a menu picker opens a modal NSMenu
                    // that hangs in this nonactivating panel and blocks all clicks.
                    Picker("", selection: $state.crossScreenStartIndex) {
                        ForEach(0..<screenLabels().count, id: \.self) { i in
                            Text("\(i + 1)").tag(i)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                Text(screenLabels().indices.contains(state.crossScreenStartIndex)
                     ? screenLabels()[state.crossScreenStartIndex] : "")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Text(L.t("Richtung", "Direction")).font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $state.crossScreenToRight) {
                        Text(L.t("→ rechts", "→ right")).tag(true)
                        Text(L.t("← links", "← left")).tag(false)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }

            Divider()

            HStack {
                Button(L.t("Test-Banner", "Test banner")) { state.showTestBanner() }
                Button(L.t("Test-Blinken", "Test blink")) { state.startMeetingBlink() }
                    .help(L.t("So blinkt die Menüleiste, wenn ein Meeting startet",
                              "How the menu bar blinks when a meeting starts"))
            }
            .font(.system(size: 12)).buttonStyle(.borderless)
        }
    }

    // MARK: - Tab: Kalender

    private var calendarsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.availableCalendars.isEmpty {
                Text(L.t("Kein Kalender-Zugriff.", "No calendar access."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                // Checkboxes left to right: show in widget (Runde 40),
                // 🔔 banner/blink (Runde 40), 🎂 birthdays (Runde 55).
                HStack(spacing: 6) {
                    Text(L.t("Anzeigen · 🔔 Banner · 🎂 Geburtstage",
                             "Show · 🔔 banner · 🎂 birthdays"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(state.availableCalendars) { c in
                            HStack(spacing: 6) {
                                Circle().fill(c.color).frame(width: 8, height: 8)
                                Text(c.title).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 8)
                                Toggle("", isOn: Binding(
                                    get: { state.selectedCalendarIDs.contains(c.id) },
                                    set: { _ in state.toggleCalendar(c.id) }
                                )).labelsHidden().toggleStyle(.checkbox)
                                    .help(L.t("Im Widget anzeigen", "Show in widget"))
                                Toggle("", isOn: Binding(
                                    get: { state.isAlertCalendar(c.id) },
                                    set: { _ in state.toggleAlertCalendar(c.id) }
                                )).labelsHidden().toggleStyle(.checkbox)
                                    .help(L.t("Banner & Blinken für diesen Kalender",
                                              "Banner & blink for this calendar"))
                                Toggle("", isOn: Binding(
                                    get: { state.isBirthdayCalendar(c.id) },
                                    set: { _ in state.toggleBirthdayCalendar(c.id) }
                                )).labelsHidden().toggleStyle(.checkbox)
                                    .help(L.t("Geburtstage aus diesem Kalender anzeigen (aus = fremde Geburtstage bleiben draußen, echte Termine nicht)",
                                              "Show birthdays from this calendar (off = other people's birthdays stay out, real events don't)"))
                            }
                        }
                    }
                    .padding(.top, 2)
                    // Trailing room so the overlay scrollbar never sits ON the
                    // checkboxes (Runde 41).
                    .padding(.trailing, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // FIXED height (a scroll view has no intrinsic height and would
                // collapse to zero in the panel's fitting size).
                .frame(height: min(CGFloat(state.availableCalendars.count) * 27 + 4, 260))
            }
            if state.calendarAuthorized {
                Button(L.t("Aktualisieren", "Refresh")) { state.monitor.tickNow() }
                    .font(.system(size: 12)).buttonStyle(.borderless)
            }
            // Runde 55: the × was occurrence-scoped, so a yearly birthday came
            // back next year. This makes it permanent per title + calendar.
            Toggle(L.t("Ausblenden gilt dauerhaft", "Hiding is permanent"),
                   isOn: $state.hidePermanently).font(.system(size: 12))
            Text(L.t("Das × blendet dann jeden Termin mit diesem Titel in diesem Kalender aus, nicht nur den von heute.",
                     "The × then hides every event with this title in this calendar, not just today's."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if state.hiddenCount > 0 {
                Button(L.t("Ausgeblendete Termine wieder zeigen (\(state.hiddenCount))",
                           "Show hidden events again (\(state.hiddenCount))")) {
                    state.unhideAll()
                }
                .font(.system(size: 11)).buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Tab: Google

    private var googleTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Meet account routing (Runde 43): open Meet links in Chrome as the
            // right signed-in account instead of the default one.
            Toggle(L.t("Meet-Links im richtigen Account öffnen", "Open Meet links in the right account"),
                   isOn: $state.meetRoutingEnabled).font(.system(size: 12))
            if state.meetRoutingEnabled {
                HStack(spacing: 6) {
                    Text(L.t("Konto", "Account")).font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("felix@…", text: Binding(
                        get: { state.effectiveMeetAccount },
                        set: { state.meetRoutingAccount = $0.trimmingCharacters(in: .whitespaces) }
                    ))
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                }
                Text(L.t("Öffnet Google Meet in Chrome direkt mit diesem Account (authuser). Muss in Chrome eingeloggt sein.",
                         "Opens Google Meet in Chrome as this account (authuser). It must be signed into Chrome."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Runde 50: Einladungstext getrennt von der Oberflächensprache.
            // Label ÜBER dem Picker statt daneben (Runde 51): in einer Zeile
            // blieb bei drei Optionen nur „Einlad…" übrig.
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("Sprache der Einladung", "Invite language")).font(.system(size: 12))
                Picker("", selection: $state.inviteLanguage) {
                    Text("EN").tag("en")
                    Text("DE").tag("de")
                    Text(L.t("Wie App", "App")).tag("auto")
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            Text(L.t("Gilt für den Textblock, der beim Erstellen in die Zwischenablage geht. Die Oberfläche bleibt davon unberührt.",
                     "Applies to the text block copied to the clipboard when creating a meeting. The interface is unaffected."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Kalenderdatei zum Mitschicken (Runde 47).
            Toggle(L.t("Kalenderdatei (.ics) mit erstellen", "Also create a calendar file (.ics)"),
                   isOn: $state.createICSFile).font(.system(size: 12))
            if state.createICSFile {
                Text(L.t("Landet beim Erstellen in ~/Downloads, mit Meet-Link, Wiederholung und Erinnerung. Der Textblock geht wie gehabt in die Zwischenablage.",
                         "Written to ~/Downloads on create, with Meet link, repeat rule and a reminder. The text block still goes to the clipboard."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // Auto-transcription (Runde 43).
            Toggle(L.t("Meetings automatisch transkribieren", "Auto-transcribe meetings"),
                   isOn: $state.autoTranscribe).font(.system(size: 12))
            if state.autoTranscribe {
                // Runde 53: ehrlicher Text statt Wunschdenken. Der Versuch
                // scheitert in der Praxis (Ursache noch offen: Meet-API im Projekt
                // aus, oder Lizenz), deshalb steht hier jetzt auch der Ausweg.
                Text(L.t("Nur für Meetings, die du hier erstellst. Braucht eine Workspace-Edition mit Auto-Transkript UND die aktivierte Meet-API im Google-Projekt. Greift das nicht, hier aus lassen und im Meeting manuell starten (drei Punkte → Transkript).",
                         "Only for meetings you create here. Needs a Workspace edition with auto-transcripts AND the Meet API enabled in your Google project. If that is not the case, leave this off and start it inside the meeting (three dots → Transcript)."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle(L.t("„Neues Meeting\"-Button anzeigen", "Show “New Meeting” button"),
                   isOn: $state.showMeetingCreator).font(.system(size: 12))
            Divider()
            if google.isConnected {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(L.t("Verbunden", "Connected") + (google.accountEmail.map { " · \($0)" } ?? ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button(L.t("Trennen", "Disconnect")) { google.disconnect() }
                        .font(.system(size: 12)).buttonStyle(.borderless)
                }
            } else {
                Button(google.busy ? L.t("Verbinde…", "Connecting…")
                       : google.needsReconnect ? L.t("Google neu verbinden", "Reconnect Google")
                                               : L.t("Mit Google verbinden", "Connect Google")) {
                    Task { await google.connect() }
                }
                .font(.system(size: 12)).buttonStyle(.borderless).disabled(google.busy)
                // Runde 48: die Ursache dazuschreiben, sonst wiederholt sich das
                // wöchentlich ohne dass klar ist warum.
                if google.needsReconnect {
                    Text(L.t("Die Sitzung ist abgelaufen. Steht der OAuth-Client in der Google Cloud Console noch auf „Testing“, gelten Tokens nur 7 Tage. Einmal auf „In Produktion“ veröffentlichen beendet das dauerhaft.",
                             "The session expired. While the OAuth client sits in “Testing” in the Google Cloud Console, tokens only last 7 days. Publishing it to production ends this for good."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let err = google.lastError {
                Text(err).font(.system(size: 10)).foregroundStyle(.red).lineLimit(3)
            }
        }
    }

    /// App version from the bundle (e.g. "1.1"), for the settings footer.
    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Screen names in left→right order, matching `crossScreenStartIndex`.
    private func screenLabels() -> [String] {
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        return screens.enumerated().map { i, s in
            let name = s.localizedName
            return name.isEmpty ? "Bildschirm \(i + 1)" : name
        }
    }
}
