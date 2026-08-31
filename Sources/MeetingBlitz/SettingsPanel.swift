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

    /// Wie bei den anderen Panels, damit `PanelRescue` weiß, was es nach dem
    /// Zurückholen wieder öffnen muss.
    var isOpen: Bool { panel?.isVisible ?? false }

    /// Für die Diagnose: wo das Fenster steht und wie groß es ist. Beides sind
    /// die Zahlen, die „ich sehe nichts" beantworten (außerhalb der Schirme?
    /// Phantomgröße?), und aus einem Screenshot sind sie nicht zu bekommen.
    var frame: CGRect? { panel?.frame }

    /// Ist-Höhe des Inhaltsbereichs. Ist sie kleiner als die Höhe, die der
    /// Inhalt meldet, schneidet das Fenster oben UND unten etwas ab: ein
    /// VStack, der nicht in sein Fenster passt, steht an beiden Enden über.
    /// Genau das meldete ein Nutzer am 26.08.2026 („sehe nur das").
    ///
    /// Als Soll-Wert NICHT `fittingSize` nehmen: die liefert bei diesem
    /// Hosting-View 0 (Phantomgröße, Runde 56c). Verlässlich ist nur, was der
    /// Inhalt selbst über `onSize` meldet.
    var contentHeight: CGFloat? { panel?.contentView?.frame.height }

    /// Alle drei Größenquellen nebeneinander, für `--squeeze-settings`.
    var sizeSources: String {
        guard let v = panel?.contentView else { return "kein Inhalt" }
        return String(format: "frame %.0f, fittingSize %.0f, intrinsic %.0f, gemeldet %@",
                      v.frame.height, v.fittingSize.height, v.intrinsicContentSize.height,
                      lastReportedSize.map { String(format: "%.0f", $0.height) } ?? "nie")
    }

    /// Zuletzt vom Inhalt gemeldete Größe, siehe `contentHeight`. Nur noch
    /// Rückfallebene: dieser Rückkanal feuert bei diesem Panel nicht (gemessen
    /// 26.08.2026), Maßstab ist `neededHeight`.
    private(set) var lastReportedSize: CGSize?

    /// Höhe, die der Inhalt braucht. Unabhängig davon, wie groß das Fenster
    /// gerade ist, siehe `fitToContent()`.
    var neededHeight: CGFloat? {
        guard let v = panel?.contentView else { return nil }
        return v.fittingSize.height > 1 ? v.fittingSize.height : lastReportedSize?.height
    }

    /// NUR für `--squeeze-settings`: klemmt das Panel absichtlich auf die
    /// Notbremsen-Höhe. Das ist der Zustand, den ein zu kleines
    /// Einstellungsfenster beim Nutzer hat, und ohne diesen Schalter wäre er
    /// auf einem gesunden Rechner gar nicht herstellbar (dasselbe Muster wie
    /// `--demo-hint` und `--demo-skin-detail=`).
    func squeezeForTest(height: CGFloat) {
        guard let p = panel else { return }
        moveRecorder?.suspended = true
        p.setFrame(CGRect(x: p.frame.minX, y: p.frame.maxY - height,
                          width: p.frame.width, height: height), display: true)
        DispatchQueue.main.async { self.moveRecorder?.suspended = false }
    }

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
        // BEIDE Optionen, und das ist der Kern der Sache (26.08.2026).
        //
        // Mit `.preferredContentSize` allein bekommt der Hosting-View KEINE
        // eigene Größe, die man abfragen könnte: `fittingSize` meldet 0,
        // `intrinsicContentSize` meldet -1, und der SwiftUI-Rückkanal unten
        // (`onSize`) feuert genau einmal mit (0,0) und danach nie wieder. Die
        // Fensterhöhe entsteht dann allein aus AppKits eigener Verrechnung, und
        // die fällt nicht auf jedem Rechner gleich aus: hier zieht sie ein zu
        // klein gesetztes Fenster von selbst wieder gerade, bei einem Nutzer
        // (Intel-MacBook) blieb es auf der Notbremsen-Höhe stehen und schnitt
        // den Reiter oben und unten ab.
        //
        // `.intrinsicContentSize` macht daraus eine echte Auto-Layout-Größe:
        // gemessen meldet der View danach 633 statt 0, auch während das Fenster
        // geklemmt ist. Erst damit hat `fitToContent()` unten überhaupt einen
        // Maßstab, auf den es das Fenster ziehen kann.
        hosting.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
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
        // Muss dasselbe Verhalten haben wie das Widget, sonst öffnet sich das
        // Panel bei laufender Vollbild-App auf dem Schreibtisch daneben und der
        // Klick sieht wirkungslos aus (22.08.2026, Begründung in PanelDock).
        p.collectionBehavior = PanelDock.companionBehavior
        p.contentView = hosting

        // Runde 47g/47h/47i: gemerkte Position gewinnt, sonst neben das Widget.
        // Grobplatzierung, die endgültige macht das erste resize() mit der
        // echten Größe (fittingSize kann hier noch ~0 sein, siehe CreatePanel).
        anchorRect = anchor
        let panelSize = p.frame.size
        p.setFrameOrigin(PanelDock.savedOrigin(panelSize: panelSize, id: "settings")
                         ?? PanelDock.origin(panelSize: panelSize, anchor: anchor))
        p.makeKeyAndOrderFront(nil)   // key immediately → blue accents from the start
        // Prüf-Schalter für die Notbremse: schiebt das Panel absichtlich winzig
        // ins Nirgendwo, genau der Zustand, den ein Nutzer als „ich klicke und
        // sehe nichts" meldet. Ohne so einen Schalter liesse sich der Fall nur
        // durch Warten auf den nächsten kaputten Rechner prüfen.
        // Position protokollieren wie beim Widget: sonst ist das Panel für eine
        // Sichtprüfung praktisch nicht auffindbar, es dockt je nach gemerkter
        // Position irgendwo an.
        HintWindow.log("settings place frame=\(p.frame)")
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
        // Notbremse eine halbe Sekunde später, wenn ALLE Platzierungswege durch
        // sind (Auto-Resize, onSize-Callback, finishInitialPlacement). Vorher
        // gemessen wäre die Phantomgröße ein Fehlalarm.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let p = self.panel, p.isVisible else { return }
            // Den Positions-Merker STUMMSCHALTEN, solange wir selbst schieben.
            // Sonst meldet `windowDidMove` unsere Notplatzierung als „vom Nutzer
            // hingezogen", und das Panel öffnet ab dann für immer dort statt
            // neben dem Widget. Genau das ist am 23.08. passiert (gemerkt
            // wurde 532|1130, quer über den Bildschirm). Dieselbe Falle wie in
            // `resize()`, dort steht die Stummschaltung seit Runde 47i.
            self.moveRecorder?.suspended = true
            self.lastRescueReason = PanelDock.enforceVisible(p)
            // Die Notbremse kennt nur eine Mindestgröße (300×420), nicht den
            // Inhalt. Bleibt das Fenster darunter, steht der Reiter oben UND
            // unten über und der Nutzer sieht nur einen Streifen aus der Mitte.
            // Auf diesem Rechner zieht AppKit die Höhe von sich aus nach, das
            // ist aber nicht überall so (Meldung vom 26.08.2026). Also hier
            // verbindlich nachziehen, statt darauf zu bauen.
            self.fitToContent()
            DispatchQueue.main.async { self.moveRecorder?.suspended = false }
        }
    }

    /// Warum die Notbremse greifen musste, für den Diagnosebericht. `nil` =
    /// alles normal platziert.
    private(set) var lastRescueReason: String?

    /// Grow/shrink the panel when the content size changes (Kalender expand),
    /// keeping the top edge fixed and clamping into the visible screen.
    func resize(to contentSize: CGSize) {
        // Die Meldung ZUERST festhalten, erst danach prüfen, ob das Panel schon
        // steht. Die erste und oft einzige Meldung kommt aus dem
        // `layoutSubtreeIfNeeded()` beim Aufbau, also bevor es ein Fenster gibt.
        // Sie hinter die guard-Zeile zu schreiben hieß: die einzige verlässliche
        // Größenangabe wandert in den Papierkorb (gefunden 26.08.2026).
        guard contentSize.width > 1 else { return }
        lastReportedSize = contentSize
        guard let p = panel, p.isVisible else { return }
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
        HintWindow.log("settings resize h=\(Int(frameSize.height)) w=\(Int(frameSize.width))")
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

    /// Zieht das Fenster auf die Höhe, die der Inhalt braucht, falls es kleiner
    /// ist. Oberkante bleibt stehen, das Ergebnis wird in den sichtbaren
    /// Bildschirm geklemmt.
    ///
    /// Der Maßstab ist `fittingSize` des Hosting-Views, und der ist NUR
    /// belastbar, weil oben `.intrinsicContentSize` gesetzt ist. Der
    /// SwiftUI-Rückkanal dient nur noch als Rückfallebene.
    ///
    /// Passt der Inhalt nicht auf den Bildschirm, gewinnt der Bildschirm: ein
    /// Fenster, das unten aus dem Bild läuft, ist auch unschön, aber die
    /// Titelleiste bleibt greifbar und die Reiterleiste sichtbar. Beides ist
    /// besser als ein Streifen aus der Mitte, in dem der Nutzer die Reiter gar
    /// nicht erst findet.
    func fitToContent() {
        guard let p = panel, p.isVisible, let v = p.contentView else { return }
        let want = v.fittingSize.height > 1 ? v.fittingSize : (lastReportedSize ?? .zero)
        guard want.height > 1 else { return }
        let old = p.frame
        var size = p.frameRect(forContentRect: CGRect(origin: .zero, size: want)).size
        size.width = max(size.width, old.width)
        guard size.height > old.height + 1 else { return }
        if let vf = PanelDock.visibleFrame(containing: old) {
            size.height = min(size.height, vf.height - 16)
        }
        var y = old.maxY - size.height
        if let vf = PanelDock.visibleFrame(containing: old) {
            y = PanelDock.clampY(y, height: size.height, vf: vf)
        }
        p.setFrame(CGRect(x: old.minX, y: y.rounded(), width: size.width, height: size.height),
                   display: true)
        HintWindow.log(String(format: "settings fitToContent %.0f→%.0f", old.height, size.height))
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
        // Sofort auf Inhaltshöhe, nicht erst mit der Notbremse eine halbe
        // Sekunde später: sonst blitzt das Fenster in falscher Größe auf.
        fitToContent()
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
    /// Gemerkt statt @State: beim erneuten Öffnen landet man dort, wo man
    /// zuletzt war, und für eine Sichtprüfung lässt sich der Reiter von außen
    /// vorwählen.
    @AppStorage("settingsTab") private var tab = 0
    /// F11: inline lists open, one per target side (both can show at once).
    @State private var gcalListOpen = false
    @State private var acalListOpen = false
    /// F5: which hotkey row is currently recording, plus its key monitor.
    /// Reiter unter der Maus, für die Hover-Rückmeldung der eigenen Leiste.
    @State private var hoveredTab: Int?
    /// Motiv unter der Maus, blendet dort den ⓘ-Knopf ein.
    @State private var hoveredSkin: String?
    /// Rückmeldung des Melde-Tests (P1).
    @State private var noticeTest: String?
    /// Auswertung einmal berechnet (Woche/Monat/Jahr), nicht bei jedem Bildaufbau.
    @State private var statsCache: (week: MeetingStats, month: MeetingStats, year: MeetingStats)?
    @State private var recording: HotKeyManager.Action?
    @State private var keyMonitor: Any?
    /// F1: inline list open + custom IANA field state for the second zone.
    @State private var zoneListOpen = false
    /// Motiv, das gerade groß mit seiner Geschichte gezeigt wird (Doppelklick
    /// im Raster). `nil` = Raster sichtbar.
    ///
    /// Startwert aus `--demo-skin-detail=<slug>`, damit sich die Detailansicht
    /// für einen Screenshot öffnen lässt. Ein Doppelklick ist von außen nicht
    /// auslösbar, ohne der Shell Bedienungshilfen-Rechte zu geben, und ohne
    /// diesen Schalter wäre die Ansicht gar nicht prüfbar (dasselbe Muster wie
    /// `--demo-hint` und `--onboarding-step=N`).
    @State private var detailSkin: Skin? = SettingsPane.initialDetailSkin

    static var initialDetailSkin: Skin? {
        for a in CommandLine.arguments where a.hasPrefix("--demo-skin-detail=") {
            return Skin.byID[String(a.dropFirst("--demo-skin-detail=".count))]
        }
        return nil
    }
    @State private var zoneCustom = ""
    @State private var zoneCustomBad = false

    /// F1: short list covering the household cases; anything else goes through
    /// the free-text field below it.
    private static let zoneChoices = ["Europe/Berlin", "Europe/Nicosia", "Europe/London",
                                      "America/New_York", "America/Los_Angeles",
                                      "Asia/Dubai", "Asia/Manila", "Australia/Sydney"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Fünf Reiter passen bei 300pt nur mit kurzen Namen, deshalb
            // „Kalender" → „Kal." und die Auswertung als Symbol.
            tabBar
            Text(tabTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            switch tab {
            case 1: alertsTab
            case 2: calendarsTab
            case 3 where google.hasConfig: googleTab
            case 4: statsTab
            case 5: widgetTab
            case 6: skinTab
            case 7: quietTab
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
        // F5: Ein laufender Tastatur-Monitor, der das Schließen des Panels
        // überlebt, würde jeden weiteren Tastendruck der App schlucken.
        .onDisappear { stopRecording() }
    }

    // MARK: - Tab: Allgemein

    /// App-Grundlagen. Bewusst KURZ: Der Reiter war über die Runden auf über
    /// 200 Zeilen gewachsen und füllte den halben Bildschirm („die
    /// Einstellungen sind zu groß"). Alles Widget-Nahe steckt jetzt in
    /// `widgetTab`, alles zum Erstellen im Google-Reiter.
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L.t("Beim Login starten", "Launch at login"), isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            )).font(.system(size: 12))

            Toggle(L.t("Tastenkürzel verwenden", "Use hotkeys"),
                   isOn: $state.hotkeyEnabled).font(.system(size: 12))
            if state.hotkeyEnabled {
                hotkeyRow(L.t("Widget öffnen", "Open widget"), action: .showWidget)
                hotkeyRow(L.t("Meeting beitreten", "Join meeting"), action: .joinNext)
                if let dead = state.hotkeyConflict {
                    Text(L.t("Schon vom System belegt: \(dead).", "Already taken by the system: \(dead)."))
                        .font(.system(size: 10)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L.t("Beitreten nimmt den laufenden Call, sonst den nächsten.",
                         "Join takes the running call, otherwise the next one."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            HStack(spacing: 6) {
                Text(L.t("Panel-Position", "Panel position")).font(.system(size: 12))
                Spacer()
                Button(L.t("Zurücksetzen", "Reset")) { PanelDock.forgetPositions() }
                    .font(.system(size: 12)).buttonStyle(.borderless)
            }
            HStack(spacing: 6) {
                Text(L.t("Einführung", "Walkthrough")).font(.system(size: 12))
                Spacer()
                Button(L.t("Nochmal zeigen", "Show again")) {
                    OnboardingPanelController.shared.show(state: state)
                }
                .font(.system(size: 12)).buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Tab: Widget (was das Fenster und die Menüleiste zeigen)

    private var widgetTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Beschriftung ÜBER den Picker: mit drei Wörtern („Titel / Nur Zeit
            // / Nur Symbol") ist er breiter als die halbe Zeile, in einem HStack
            // quetscht er die Beschriftung auf Breite 0 und reißt dabei
            // riesige Lücken ins Layout.
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("Menüleiste zeigt", "Menu bar shows")).font(.system(size: 12))
                Picker("", selection: $state.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            Toggle(L.t("Im Meeting schmal halten", "Keep it narrow during meetings"),
                   isOn: $state.compactMenuBarInMeeting).font(.system(size: 12))

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("Datumswahl zeigt", "Date picker shows")).font(.system(size: 12))
                Picker("", selection: $state.calendarViewMode) {
                    ForEach(CalendarViewMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            Text(calendarModeHint)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(L.t("Woche beginnt am", "Week starts on")).font(.system(size: 12))
                Spacer()
                Picker("", selection: $state.firstWeekday) {
                    Text(L.t("Mo", "Mon")).tag(2)
                    Text(L.t("So", "Sun")).tag(1)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }

            Divider()

            Toggle(L.t("Apple Erinnerungen zeigen", "Show Apple Reminders"), isOn: Binding(
                get: { state.showReminders },
                set: { on in
                    state.showReminders = on
                    if on { Task { await state.requestRemindersAccess() } }
                    else { state.reminders = [] }
                }
            )).font(.system(size: 12))
            Toggle(L.t("Nur Termine mit Link zeigen", "Only show events with a link"),
                   isOn: $state.onlyWithLink).font(.system(size: 12))
            Toggle(L.t("Vergangene Termine ausblenden", "Hide past events"),
                   isOn: $state.hidePastEvents).font(.system(size: 12))
            Toggle(L.t("Abgesagte Termine ausblenden", "Hide declined events"),
                   isOn: $state.hideDeclined).font(.system(size: 12))

            Divider()

            Toggle(L.t("Zweite Zeitzone", "Second time zone"),
                   isOn: $state.secondZoneEnabled).font(.system(size: 12))
            if state.secondZoneEnabled {
                zoneRow
                if zoneCustomBad {
                    Text(L.t("Unbekannte Zone. IANA-Name wie „Europe/Berlin“ verwenden.",
                             "Unknown zone. Use an IANA name like “Europe/Berlin”."))
                        .font(.system(size: 10)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Tab: Banner (alert behaviour)

    private var alertsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Vorlauf, Flugdauer, Ton und Sprung standen im Allgemein-Reiter,
            // gehören aber zum Banner — mit dem Umzug wird dort Platz frei.
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
            // 24.08.: Der Balken war seit dem 20.08. fest 1.35-fach, weil ein
            // Faktor Balken UND Tier zugleich vergrößert hat. Gemeint war nur
            // das Tier. Hier steht jetzt NUR die Balkengröße; das Flugobjekt
            // behält seine Wucht unabhängig davon (BannerContentView.motifScale).
            HStack {
                Text(L.t("Balkengröße", "Bar size")).font(.system(size: 12))
                Spacer()
                Picker("", selection: $state.bannerScale) {
                    Text(L.t("Klein", "Small")).tag(1.0)
                    Text(L.t("Mittel", "Medium")).tag(1.18)
                    Text(L.t("Groß", "Large")).tag(1.35)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            Text(L.t("Betrifft nur den Balken mit Titel und Knöpfen. Das Flugobjekt bleibt gleich groß.",
                     "Affects only the bar with the title and buttons. The flying object keeps its size."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(L.t("Ton abspielen", "Play sound"), isOn: $state.soundEnabled).font(.system(size: 12))
            // Runde 72: wirkt jetzt für BEIDE Elemente gleichwertig — Wasser
            // springt aus dem Meer, Luft bricht aus einer Wolke hervor — daher
            // nicht mehr ausgegraut für Luft-Motive (war 20.08.: dort wirkungslos).
            Toggle(L.t("Dramatischer Auftritt", "Dramatic entrance"), isOn: $state.dramaticEntrance)
                .font(.system(size: 12))
            Text(state.currentSkinElement == .air
                 ? L.t("Luft-Motiv: bricht aus einer Wolke hervor. Aus lässt es schlicht level hereinfliegen.",
                       "Air motif: bursts out of a cloud. Off, and it just flies in level.")
                 : L.t("Wasser-Motiv: springt aus dem Meer. Aus lässt es schlicht level hereinfliegen.",
                       "Water motif: jumps out of the sea. Off, and it just flies in level."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // F4: war fest auf 2 Minuten verdrahtet. Beschriftung ÜBER dem
            // Picker, in einer Zeile wurde sie zu „Später erin…" gequetscht.
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("Später erinnern um", "Snooze by")).font(.system(size: 12))
                Picker("", selection: $state.snoozeMinutes) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("\($0)m").tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }

            // Multi-monitor: only with more than one screen.
            if NSScreen.screens.count > 1 {
                Divider()
                multiScreenRows
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

    // MARK: - Tab: Flugobjekt (23.08.2026)

    /// Eigener Reiter statt eines Blocks im Banner-Reiter. Mit dem Motivwechsel
    /// und dem 27er-Raster war der Banner-Reiter höher als der Bildschirm
    /// („sehe die hälfte nicht"), und Motivwahl ist ohnehin ein eigenes Thema:
    /// wie das Ding aussieht, nicht wann es fliegt.
    private var skinTab: some View {
        skinSection
    }

    // MARK: - Tab: Ruhe (23.08.2026, aus dem Banner-Reiter ausgezogen)

    private var quietTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L.t("Ruhe-Modus (keine Banner)", "Quiet mode (no banners)"), isOn: $state.quietMode).font(.system(size: 12))
            // Befristet einschalten: Ruhe „für heute Nachmittag" schaltet man
            // sonst ein und vergisst sie, und wundert sich tagelang über
            // ausbleibende Banner.
            // Als sichtbare Knöpfe, nicht als borderless-Text: so sahen sie aus
            // wie Fließtext und wurden schlicht übersehen („sehe das nicht").
            HStack(spacing: 5) {
                Text(L.t("für", "for")).font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach([(1.0, "1h"), (5.0, "5h"), (24.0, L.t("1 Tag", "1 day")),
                         (168.0, L.t("1 Woche", "1 week"))], id: \.1) { h, label in
                    Button { state.startQuiet(hours: h) } label: {
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.11)))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(L.t("Ruhe für \(label) einschalten", "Turn on quiet for \(label)"))
                }
                Spacer(minLength: 0)
            }
            if let rest = state.quietRemainingLabel {
                HStack(spacing: 6) {
                    Text(L.t("Ruhe endet in \(rest)", "Quiet ends in \(rest)"))
                        .font(.system(size: 10)).foregroundStyle(Color.accentColor)
                    Spacer(minLength: 0)
                    Button(L.t("Jetzt beenden", "End now")) { state.quietMode = false }
                        .font(.system(size: 10)).buttonStyle(.borderless)
                }
            }
            // P1: ohne das verpasst man Termine genau dann, wenn man nicht
            // gestört werden will.
            Toggle(L.t("Bei Ruhe still benachrichtigen", "Notify silently while quiet"),
                   isOn: $state.quietNotifications).font(.system(size: 12))
            if state.quietNotifications {
                HStack(spacing: 6) {
                    Text(L.t("Statt Banner eine lautlose Mitteilung, damit ein Termin bei Ruhe oder Bildschirmfreigabe nicht untergeht.",
                             "A silent notification instead of the banner, so a meeting isn't missed during quiet mode or screen sharing."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    // Sonst sieht man das Feature nie: es greift nur, wenn Ruhe
                    // aktiv IST und gleichzeitig ein Termin ansteht.
                    Button {
                        QuietNotice.test()
                        noticeTest = L.t("Hinweis erscheint oben rechts.",
                                         "The notice appears in the top right.")
                    } label: {
                        Text(L.t("Testen", "Test"))
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.11)))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                if let t = noticeTest {
                    Text(t).font(.system(size: 10))
                        .foregroundStyle(t.hasPrefix("Gesendet") || t.hasPrefix("Sent")
                                         ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(L.t("Ruhe bei Bildschirmfreigabe", "Quiet while screen sharing"), isOn: $state.quietDuringScreenShare).font(.system(size: 12))
            Toggle(L.t("Auto-Beitreten (10s vorher)", "Auto-join (10s before)"), isOn: $state.autoJoin).font(.system(size: 12))
            Toggle(L.t("Warnung vor Meeting-Ende", "End-of-meeting warning"), isOn: $state.endWarning).font(.system(size: 12))
        }
    }

    /// Startbildschirm und Flugrichtung, nur bei mehr als einem Monitor.
    /// Ausgelagert, weil der Banner-Reiter sonst wieder zu lang wird.
    @ViewBuilder
    private var multiScreenRows: some View {
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
            .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Flugobjekt (Skin-Auswahl, 20.08.2026)

    /// Style-Umschalter + Motivraster + Test-Knopf. Eigener Block, damit der
    /// lange Banner-Reiter nicht noch unübersichtlicher wird.
    private var skinSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Kein eigener Titel mehr: seit 23.08. ist das ein eigener Reiter,
            // dessen Überschrift schon „Flugobjekt" heißt, und zweimal
            // dasselbe Wort untereinander sieht nach Versehen aus.
            Text(L.t("Stil", "Style")).font(.system(size: 12))
            Picker("", selection: $state.skinStyle) {
                ForEach(SkinStyle.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented)

            if state.skinStyle != .classic {
                // Wechsel-Schalter direkt unter der Stil-Wahl: er entscheidet,
                // was ein Tipp im Raster darunter bedeutet (auswählen oder in
                // den Wechsel aufnehmen), deshalb steht er davor.
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("Motivwechsel", "Motif changes")).font(.system(size: 12))
                    Picker("", selection: $state.skinRotation) {
                        ForEach(SkinRotation.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
                Text(state.skinRotation == .off
                     ? L.t("Immer dasselbe Motiv. Tippen wählt es aus.",
                           "Always the same motif. Tap one to pick it.")
                     : L.t("Jedes Banner nimmt ein anderes Motiv. Tippen nimmt eins in den Wechsel auf oder heraus.",
                           "Every banner uses a different motif. Tap one to add or remove it from the rotation."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.skinRotation != .off {
                    HStack(spacing: 6) {
                        Text(L.t("Im Wechsel: \(state.rotationSkins.count) von \(Skin.all.count)",
                                 "In rotation: \(state.rotationSkins.count) of \(Skin.all.count)"))
                            .font(.system(size: 10)).foregroundStyle(Color.accentColor)
                        Spacer(minLength: 0)
                        Button(L.t("Alle", "All")) { state.skinPool = [] }
                            .font(.system(size: 10)).buttonStyle(.borderless)
                            .help(L.t("Alle Motive teilnehmen lassen", "Let every motif take part"))
                    }
                }
            }

            if state.skinStyle == .classic {
                Text(L.t("Das klassische U-Boot, ohne Motivwahl.",
                         "The classic U-Boot, no motif to pick."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let skin = detailSkin {
                skinDetail(skin)
            } else {
                skinGrid
                Text(L.t("Das ⓘ am Motiv (oder ein Doppelklick) zeigt es groß, mit seiner Geschichte.",
                         "The ⓘ on a motif (or a double-click) shows it large, with its story."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Gilt für jeden Motiv-Stil, deshalb außerhalb der Fallunterscheidung
            // oben. Beim klassischen U-Boot gibt es kein Bild-Asset, das
            // herausragen könnte.
            if state.skinStyle != .classic {
                Toggle(L.t("Motiv ragt heraus", "Motif breaks out"), isOn: $state.skinOversize)
                    .font(.system(size: 12))
                Text(L.t("Das Objekt wird größer als die Kapsel und steht davor statt darin. Wirkt bei hohen Motiven wie Nessie oder der Ente, bei langen flachen U-Booten kaum.",
                         "The object grows taller than the capsule and stands in front of it. Works for tall motifs like Nessie or the duck, barely for long flat submarines."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(L.t("Vorschau fliegen lassen", "Preview it flying")) { state.showTestBanner() }
                .font(.system(size: 12)).buttonStyle(.borderless)
        }
    }

    /// Große Ansicht eines Motivs samt der Geschichte dahinter.
    ///
    /// BEWUSST INLINE statt Popover oder eigenem Fenster: Das Einstellungs-Panel
    /// ist nonactivating, und darin hängen modale Menüs (Runde 13), während
    /// frisch geordnete Kleinfenster sich nach dem Anzeigen selbst verschieben
    /// (Runde 56c). Die Detailansicht ersetzt deshalb einfach das Raster, das
    /// hält die Panelhöhe konstant und braucht keinerlei Fenster-Akrobatik.
    private func skinDetail(_ skin: Skin) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    detailSkin = nil
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text(L.t("Alle Motive", "All motifs")).font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                Spacer()
                // Beim Wechsel gibt es kein „Auswählen", sondern nur ein
                // Mitfliegen oder nicht: das Motiv, das als Nächstes fliegt,
                // bestimmt der Wechsel, nicht die Auswahl.
                if state.skinRotation != .off && state.skinStyle != .classic {
                    let inPool = state.skinPool.isEmpty || state.skinPool.contains(skin.id)
                    Button(inPool ? L.t("Nicht mitfliegen", "Sit this one out")
                                  : L.t("Mitfliegen lassen", "Let it fly")) {
                        state.toggleSkinInPool(skin.id)
                    }
                    .font(.system(size: 11)).buttonStyle(.borderless)
                } else if state.skinID != skin.id {
                    Button(L.t("Auswählen", "Select")) { state.skinID = skin.id }
                        .font(.system(size: 11)).buttonStyle(.borderless)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06))
                if let image = Skins.shared.image(for: skin, style: state.skinStyle) {
                    Image(nsImage: image)
                        .resizable().aspectRatio(contentMode: .fit).padding(10)
                } else {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.system(size: 20)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 104)

            Text(skin.name).font(.system(size: 12, weight: .semibold))

            if let text = skin.loreText {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Feste Höhe: ScrollView hat keine intrinsische (Runde 14) und
                // würde in diesem sich selbst messenden Panel auf 0 fallen.
                .frame(height: 92)

                if let url = skin.loreSource {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.right.square").font(.system(size: 9))
                            Text(L.t("Quelle", "Source")).font(.system(size: 10))
                        }
                    }
                    .buttonStyle(.link)
                }
            } else {
                Text(L.t("Zu diesem Motiv ist noch keine Geschichte hinterlegt.",
                         "No story recorded for this motif yet."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 92, alignment: .top)
            }
        }
    }

    /// 27 Motive in einem 3-spaltigen Raster, echte SVG-Vorschauen. Panelbreite
    /// ist 300 (272 nutzbar nach dem Padding), 3 Spalten passen knapp ohne die
    /// Seite zu sprengen. ScrollView mit fester Höhe (hat keine intrinsische,
    /// Runde 14) statt eines wachsenden VStack: bei 27 Kacheln würde das Panel
    /// sonst über den Bildschirm hinauswachsen.
    private var skinGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 8) {
                ForEach(Skin.all) { skin in
                    skinCell(skin)
                }
            }
            .padding(.top, 2)
            .padding(.trailing, 4)   // Platz für den Overlay-Scrollbalken (Runde 41 Muster)
        }
        .frame(height: 240)
    }

    private func skinCell(_ skin: Skin) -> some View {
        // Beim Wechsel zeigt die Markierung die TEILNAHME, nicht die Auswahl:
        // sonst wäre im Raster nur zu sehen, was zufällig zuletzt geflogen ist,
        // und nicht, worauf man sich festgelegt hat.
        let rotating = state.skinRotation != .off && state.skinStyle != .classic
        let inPool = state.skinPool.isEmpty || state.skinPool.contains(skin.id)
        let selected = rotating ? inPool : state.skinID == skin.id
        let image = Skins.shared.image(for: skin, style: state.skinStyle)
        // Kein Button: der würde den Doppelklick als zwei Einzelklicks
        // schlucken. Stattdessen eine normale View mit beiden Tap-Gesten,
        // Doppelklick zuerst registriert, sonst gewinnt immer der Einzelklick.
        return VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06))
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                    } else {
                        // Fällt die Datei aus (fehlt im Bundle), sauber ein
                        // Platzhalter statt Absturz oder leerer Kachel.
                        Image(systemName: "questionmark.square.dashed")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 44)
                Text(skin.name)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .padding(5)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                              lineWidth: selected ? 1.5 : 1))
            // Eigener Knopf für die Geschichte (23.08.2026). Beim Motivwechsel
            // bedeutet ein Tipp „nimmt teil", und wer dann doppelt tippt, um die
            // Geschichte zu sehen, wirft das Motiv im Zweifel aus dem Wechsel.
            // Der Doppelklick bleibt, aber es braucht einen Weg, der nichts
            // umstellt: das ⓘ erscheint beim Darüberfahren.
            .overlay(alignment: .topTrailing) {
                if hoveredSkin == skin.id {
                    Button { detailSkin = skin } label: {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 12))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help(L.t("Geschichte zu \(skin.name) zeigen", "Show the story behind \(skin.name)"))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onHover { hoveredSkin = $0 ? skin.id : (hoveredSkin == skin.id ? nil : hoveredSkin) }
            .onTapGesture(count: 2) { detailSkin = skin }
            .onTapGesture { rotating ? state.toggleSkinInPool(skin.id) : (state.skinID = skin.id) }
            .help(rotating
                  ? (inPool ? L.t("\(skin.name): fliegt mit", "\(skin.name): takes part")
                            : L.t("\(skin.name): fliegt nicht mit", "\(skin.name): sits this one out"))
                  : skin.name)
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
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Bis ~20 Kalender OHNE ScrollView: der bräuchte eine feste
                // Höhe (er hat keine intrinsische, Runde 14), und die war
                // geschätzt — bei 15 Kalendern blieben ~100pt Leere darunter
                // stehen. Ein reiner VStack wächst exakt mit dem Inhalt. Erst
                // darüber wird gescrollt, sonst sprengt die Liste den Schirm.
                Group {
                    let list = VStack(alignment: .leading, spacing: 5) {
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

                    if state.availableCalendars.count <= 20 {
                        list
                    } else {
                        ScrollView { list }.frame(height: 560)
                    }
                }
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
            Toggle(L.t("„Sofort-Meeting\"-Knopf anzeigen", "Show “Instant meeting” button"),
                   isOn: $state.showInstantMeeting).font(.system(size: 12))


            Divider()

            // F11, Rückmeldung 18.08. („Setting, wo das Meeting landen soll"):
            // Ziel als Entweder-Oder statt Toggle. Google = per EventKit DIREKT
            // in den eingebundenen CalDAV-Kalender (sofort lokal, synct von
            // allein hoch). Apple = wie früher (Formular-Wahl bzw. Standard).
            // BEWUSST kein „Beide": zwei Events hießen doppelte Banner und
            // Dubletten in der Kalender-App.
            // Getrennt je Erstellweg (Rückmeldung 18.08.): ein Ad-hoc-Call
            // gehört nicht in denselben Kalender wie ein geplanter Termin.
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("„Neues Meeting\" landet in", "“New Meeting” goes to")).font(.system(size: 12))
                Picker("", selection: $state.createTarget) {
                    Text("Google").tag(CreateTarget.google)
                    Text("Apple").tag(CreateTarget.apple)
                    Text(L.t("Beide", "Both")).tag(CreateTarget.both)
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L.t("„Sofort-Meeting\" landet in", "“Instant meeting” goes to")).font(.system(size: 12))
                Picker("", selection: $state.instantTarget) {
                    Text("Google").tag(CreateTarget.google)
                    Text("Apple").tag(CreateTarget.apple)
                    Text(L.t("Beide", "Both")).tag(CreateTarget.both)
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            // Die Kalender selbst sind für beide Wege dieselben, also eine
            // Auswahl je Seite, sichtbar sobald IRGENDEIN Weg sie braucht.
            if usesGoogleAnywhere { targetCalendarRow(google: true) }
            if usesAppleAnywhere { targetCalendarRow(google: false) }
            Text(targetHint)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    /// F11: target calendar for the SELECTED side. Both options are pickable
    /// (Rückmeldung 18.08.), the list simply shows the matching accounts:
    /// Google → the synced accounts, Apple → this Mac and iCloud.
    /// F5: eine Kürzel-Zeile mit Aufnahme-Knopf. Der Monitor läuft nur, solange
    /// genau diese Zeile aufnimmt (`recording`), und ausschließlich im
    /// Einstellungs-Panel — das darf key werden (Runde 14d), im Widget-Panel
    /// wäre ein Tastatur-Monitor unzuverlässig.
    private func hotkeyRow(_ title: String, action: HotKeyManager.Action) -> some View {
        let isRecording = recording == action
        let label = action == .showWidget ? state.hotkeyWidgetLabel : state.hotkeyJoinLabel
        return HStack(spacing: 6) {
            Text(title).font(.system(size: 12))
            Spacer()
            Text(isRecording ? L.t("Taste drücken…", "Press keys…") : label)
                .font(.system(size: 11, weight: .semibold).monospaced())
                .foregroundStyle(isRecording ? Color.accentColor : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(isRecording ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.08)))
            Button(isRecording ? L.t("Abbrechen", "Cancel") : L.t("Ändern", "Change")) {
                if isRecording { stopRecording() } else { startRecording(action) }
            }
            .font(.system(size: 11)).buttonStyle(.borderless)
        }
    }

    private func startRecording(_ action: HotKeyManager.Action) {
        stopRecording()
        recording = action
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            // Escape bricht ab, ohne etwas zu ändern.
            if ev.keyCode == 53 { stopRecording(); return nil }
            let mods = ev.modifierFlags.intersection([.command, .control, .option, .shift])
            // Ohne Zusatztaste wäre es kein globales Kürzel, sondern würde
            // jedem Tippen im System dazwischenfunken.
            guard !mods.isEmpty else { return nil }
            let key = ev.charactersIgnoringModifiers ?? ""
            guard !key.isEmpty else { return nil }
            let carbon = Int(HotKeyManager.carbonModifiers(mods))
            let text = HotKeyManager.label(modifiers: mods, key: key)
            if action == .showWidget {
                state.hotkeyWidgetKey = Int(ev.keyCode)
                state.hotkeyWidgetMods = carbon
                state.hotkeyWidgetLabel = text
            } else {
                state.hotkeyJoinKey = Int(ev.keyCode)
                state.hotkeyJoinMods = carbon
                state.hotkeyJoinLabel = text
            }
            // Beide neu registrieren, damit die Änderung sofort greift.
            state.onHotkeyToggle?(state.hotkeyEnabled)
            stopRecording()
            return nil   // Taste nicht ans Panel durchreichen
        }
    }

    private func stopRecording() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        recording = nil
    }

    /// Eigene Reiterleiste statt `Picker(.segmented)`. Sechs System-Symbole in
    /// einem Segmented rendern winzig und gedrängt („schaut nicht zu design
    /// schön aus"), und an ihrer Größe lässt sich dort nichts drehen. Hier:
    /// größere Zeichen, echte Klickflächen, Hover-Rückmeldung und ein Tooltip
    /// je Seite. Das Panel ist key (Runde 14d), also greifen die Farben.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Self.tabs, id: \.id) { t in
                if t.id != 3 || google.hasConfig {
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) { tab = t.id }
                    } label: {
                        Image(systemName: t.icon)
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .foregroundStyle(tab == t.id ? Color.white
                                             : hoveredTab == t.id ? Color.primary : Color.secondary)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(tab == t.id ? Color.accentColor
                                          : hoveredTab == t.id ? Color.primary.opacity(0.10) : .clear)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredTab = $0 ? t.id : (hoveredTab == t.id ? nil : hoveredTab) }
                    .help(title(for: t.id))
                }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
    }

    /// Reihenfolge der Reiter: erst die App, dann was sie zeigt, dann Daten.
    private static let tabs: [(id: Int, icon: String)] = [
        (0, "gearshape"), (1, "bell"), (6, "paperplane"), (7, "moon.zzz"),
        (5, "macwindow"), (2, "calendar"), (3, "video"), (4, "chart.bar"),
    ]

    private func title(for id: Int) -> String {
        switch id {
        case 1:  return L.t("Banner & Erinnern", "Alerts & reminders")
        case 2:  return L.t("Kalender", "Calendars")
        case 3:  return L.t("Meetings erstellen", "Creating meetings")
        case 4:  return L.t("Auswertung", "Stats")
        case 5:  return L.t("Widget & Menüleiste", "Widget & menu bar")
        case 6:  return L.t("Flugobjekt", "Flying object")
        case 7:  return L.t("Ruhe & Stille", "Quiet & silence")
        default: return L.t("Allgemein", "General")
        }
    }

    private var tabTitle: String {
        switch tab {
        case 1:  return L.t("Banner & Erinnern", "Alerts & reminders")
        case 2:  return L.t("Kalender", "Calendars")
        case 3:  return L.t("Meetings erstellen", "Creating meetings")
        case 4:  return L.t("Auswertung", "Stats")
        case 5:  return L.t("Widget & Menüleiste", "Widget & menu bar")
        case 6:  return L.t("Flugobjekt", "Flying object")
        case 7:  return L.t("Ruhe & Stille", "Quiet & silence")
        default: return L.t("Allgemein", "General")
        }
    }

    /// Erklärt die gewählte Stufung am Datum im Widget.
    private var calendarModeHint: String {
        switch state.calendarViewMode {
        case .stepped:
            return L.t("Ein Klick aufs Datum zeigt die Woche, ein zweiter den Monat, ein dritter schließt wieder.",
                       "One click on the date shows the week, a second the month, a third closes it again.")
        case .week:
            return L.t("Ein Klick aufs Datum zeigt die Woche, ein zweiter schließt wieder.",
                       "One click on the date shows the week, a second closes it again.")
        case .month:
            return L.t("Ein Klick aufs Datum zeigt den Monat, ein zweiter schließt wieder.",
                       "One click on the date shows the month, a second closes it again.")
        case .off:
            return L.t("Das Datum im Widget ist dann nur Text. Zum Blättern bleiben die Pfeile daneben.",
                       "The date in the widget is plain text then. The arrows next to it still page through days.")
        }
    }

    private var usesGoogleAnywhere: Bool {
        state.createTarget.usesGoogle || state.instantTarget.usesGoogle
    }
    private var usesAppleAnywhere: Bool {
        state.createTarget.usesApple || state.instantTarget.usesApple
    }

    /// Erklärtext unter der Zielwahl. „Beide" braucht die Warnung, alles andere
    /// nur eine Zeile dazu, wo der Termin liegt.
    private var targetHint: String {
        if state.createTarget == .both || state.instantTarget == .both {
            return L.t("„Beide\" legt den Termin ZWEIMAL an, einmal je Kalender, mit demselben Meet-Link. Gewarnt wird trotzdem nur einmal. In der Kalender-App stehen sie beide, und Verschieben musst du dann auch zweimal.",
                       "“Both” creates the event TWICE, once per calendar, sharing one Meet link. You are still warned only once. Both show in Calendar, and moving one means moving the other too.")
        }
        if usesGoogleAnywhere && !usesAppleAnywhere {
            return L.t("Der Termin liegt im Google-Kalender, ist sofort in der App und über den Sync auf allen Geräten.",
                       "The event lives in the Google calendar, shows in the app immediately and syncs everywhere.")
        }
        if usesAppleAnywhere && !usesGoogleAnywhere {
            return L.t("Der Termin bleibt auf diesem Mac bzw. in iCloud.",
                       "The event stays on this Mac or in iCloud.")
        }
        return L.t("Jeder Weg legt den Termin in seinen eigenen Kalender.",
                   "Each route files its event in its own calendar.")
    }

    /// F11: Ziel-Kalender einer Seite. Beide Seiten sind wählbar, die Liste
    /// zeigt jeweils die passenden Konten: Google → synchronisierte Konten,
    /// Apple → dieser Mac und iCloud.
    private func targetCalendarRow(google isGoogle: Bool) -> some View {
        let writable = state.calendar.writableCalendars()
            .filter { $0.isAppleAccount != isGoogle }
        let currentID = isGoogle ? state.googleTargetCalendarID : state.appleTargetCalendarID
        let current = writable.first { $0.id == currentID }
        let open = isGoogle ? gcalListOpen : acalListOpen
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if isGoogle { gcalListOpen.toggle() } else { acalListOpen.toggle() }
                }
            } label: {
                HStack(spacing: 6) {
                    // Stehen beide Zeilen untereinander, muss die Beschriftung
                    // sagen, welche welche ist.
                    Text(usesGoogleAnywhere && usesAppleAnywhere
                         ? (isGoogle ? "Google" : "Apple")
                         : L.t("Kalender", "Calendar"))
                        .font(.system(size: 12)).foregroundStyle(.primary)
                    Spacer()
                    Circle().fill(current?.color ?? .gray).frame(width: 8, height: 8)
                    // Auf der Apple-Seite ist "nichts gewählt" gültig (dann
                    // greift der Systemstandard), auf der Google-Seite nicht.
                    Text(current?.title
                         ?? (isGoogle ? L.t("Bitte wählen", "Pick one")
                                      : L.t("Standard", "Default")))
                        .font(.system(size: 12)).lineLimit(1)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            if open {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(writable) { c in
                            Button {
                                if isGoogle { state.googleTargetCalendarID = c.id }
                                else { state.appleTargetCalendarID = c.id }
                                // F11b: Wer hier ein Ziel wählt, meint es auch.
                                // Ohne dieses Zurücksetzen bliebe eine alte
                                // Handwahl aus dem Formular für immer davor
                                // stehen und die Einstellung wirkte nie.
                                UserDefaults.standard.set(false, forKey: "createCalendarPickedByHand")
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    if isGoogle { gcalListOpen = false } else { acalListOpen = false }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(c.color).frame(width: 8, height: 8)
                                    // Konto dazu: „Agency" kann es in iCloud UND
                                    // in Google geben, ohne Quelle wählt man blind.
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(c.title).font(.system(size: 12)).lineLimit(1)
                                        if !c.sourceTitle.isEmpty {
                                            Text(c.sourceTitle)
                                                .font(.system(size: 9)).foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if c.id == currentID {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 3).padding(.horizontal, 6)
                                .background(RoundedRectangle(cornerRadius: 5)
                                    .fill(c.id == currentID
                                          ? Color.accentColor.opacity(0.14) : .clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 96)   // fixed: ScrollView has no intrinsic height (Runde 14)
            }
        }
    }

    /// F1: zone picker, short list plus validated free text. No .menu picker,
    /// that hangs in nonactivating panels (Runde 13).
    private var zoneRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { zoneListOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(L.t("Zone", "Zone")).font(.system(size: 12)).foregroundStyle(.primary)
                    Spacer()
                    Text(MenuPanel.zoneCity(state.secondZoneID)).font(.system(size: 12)).lineLimit(1)
                    Image(systemName: zoneListOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            if zoneListOpen {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Self.zoneChoices, id: \.self) { id in
                        Button {
                            state.secondZoneID = id
                            zoneCustomBad = false
                            withAnimation(.easeInOut(duration: 0.16)) { zoneListOpen = false }
                        } label: {
                            HStack {
                                Text(MenuPanel.zoneCity(id)).font(.system(size: 12))
                                Spacer()
                                if id == state.secondZoneID {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(id == state.secondZoneID
                                      ? Color.accentColor.opacity(0.14) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                    TextField(L.t("Eigene, z. B. Europe/Paris", "Custom, e.g. Europe/Paris"),
                              text: $zoneCustom)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        .onSubmit {
                            let t = zoneCustom.trimmingCharacters(in: .whitespaces)
                            if TimeZone(identifier: t) != nil {
                                state.secondZoneID = t
                                zoneCustomBad = false
                                withAnimation(.easeInOut(duration: 0.16)) { zoneListOpen = false }
                            } else {
                                zoneCustomBad = true
                            }
                        }
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Tab: Auswertung

    /// Wie viel Zeit ging in Termine? Eigener Reiter, damit die anderen Seiten
    /// nicht weiter zuwachsen. Bewusst schlicht — die App ist eine Erinnerung,
    /// keine Auswertungs-Suite.
    private var statsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = statsCache {
                statsBlock(L.t("Diese Woche", "This week"), s.week)
                Divider()
                statsBlock(L.t("Dieser Monat", "This month"), s.month)
                Divider()
                statsBlock(L.t("Dieses Jahr", "This year"), s.year)
                Divider()
            } else {
                Text(L.t("Wird berechnet…", "Calculating…"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack(spacing: 8) {
                legendDot(Color.accentColor, L.t("Calls", "calls"))
                legendDot(Color.accentColor.opacity(0.28), L.t("andere Termine", "other events"))
                Spacer()
            }
            Text(L.t("Getimte Termine der angezeigten Kalender. Ganztägige und Geburtstage bleiben außen vor.",
                     "Timed events from the shown calendars. All-day events and birthdays are excluded."))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // EINMAL rechnen, nicht bei jedem Bildaufbau: das Jahr sind bei ihm
        // ~600 Termine, und SwiftUI ruft den Body oft auf.
        .onAppear { if statsCache == nil { statsCache = computeStats() } }
    }

    private func computeStats() -> (week: MeetingStats, month: MeetingStats, year: MeetingStats) {
        let cal = Calendar.current, now = Date()
        let ids = state.selectedCalendarIDs
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? now
        let yearStart = cal.dateInterval(of: .year, for: now)?.start ?? now
        return (state.calendar.stats(from: weekStart, to: now, selected: ids, groupBy: .day),
                state.calendar.stats(from: monthStart, to: now, selected: ids, groupBy: .weekOfYear),
                state.calendar.stats(from: yearStart, to: now, selected: ids, groupBy: .month))
    }

    private func legendDot(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func statsBlock(_ title: String, _ s: MeetingStats) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(s.count) · \(s.hoursLabel)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            barChart(s.bars)
            HStack(spacing: 0) {
                statCell("\(s.callCount)", L.t("Calls", "calls"))
                statCell(s.callHoursLabel, L.t("in Calls", "in calls"))
                statCell(s.count > 0 ? MeetingStats.hm(s.minutes / max(1, s.count)) : "–",
                         L.t("pro Termin", "per event"))
            }
            if let b = s.busiestDay {
                Text(L.t("Vollster Tag: \(b.label) · \(MeetingStats.hm(b.minutes))",
                         "Busiest day: \(b.label) · \(MeetingStats.hm(b.minutes))"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Selbst gezeichnete Balken statt Swift Charts: dessen System-Styling
    /// rendert im nie aktiven Panel genauso blass wie andere System-Controls
    /// (Runde 6/31), und hier zählt jeder Punkt Breite.
    /// Heller Anteil = alle Termine, satter Anteil = davon Videocalls.
    private func barChart(_ bars: [StatBar]) -> some View {
        let peak = max(bars.map(\.minutes).max() ?? 0, 60)   // mind. 1 h, sonst wirken Kleinigkeiten riesig
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(bars) { b in
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(0.07))          // Grundfläche = Maßstab
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.28))
                            .frame(height: barHeight(b.minutes, peak))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor)
                            .frame(height: barHeight(b.callMinutes, peak))
                    }
                    .frame(height: 46, alignment: .bottom)
                    Text(b.label)
                        .font(.system(size: 9, weight: b.isNow ? .bold : .regular))
                        .foregroundStyle(b.isNow ? Color.accentColor : Color.secondary)
                }
            }
        }
    }

    private func barHeight(_ minutes: Int, _ peak: Int) -> CGFloat {
        guard minutes > 0 else { return 0 }
        // Mindesthöhe, damit ein 15-Minuten-Termin nicht unsichtbar wird.
        return max(3, CGFloat(minutes) / CGFloat(peak) * 46)
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
