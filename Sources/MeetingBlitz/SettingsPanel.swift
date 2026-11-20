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
    /// Runde 110b: Glas-Rahmen des Widgets (Ausweichplatz rechts davon).
    private var widgetAnchor: CGRect?

    /// Wie bei den anderen Panels, damit `PanelRescue` weiß, was es nach dem
    /// Zurückholen wieder öffnen muss.
    var isOpen: Bool { panel?.isVisible ?? false }

    /// Für die Diagnose: wo das Fenster steht und wie groß es ist. Beides sind
    /// die Zahlen, die „ich sehe nichts" beantworten (außerhalb der Schirme?
    /// Phantomgröße?), und aus einem Screenshot sind sie nicht zu bekommen.
    var frame: CGRect? { panel?.frame }
    /// Runde 110: Rahmen des sichtbaren Glases (ohne Bühne).
    var glassFrame: CGRect? { panel?.frame.insetBy(dx: Theme.stageInset, dy: Theme.stageInset) }

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
    /// Runde 111b: Reiter-Umbau (8 → 5). Alte Nummer → neue, einmal. 4 (Stats) → Allgemein, 5 (Widget) → Allgemein,
    /// 6 (Flugobjekt) → Erweitert, 7 (Ruhe) → Hinweise.
    static func migrateTabs() {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: "settingsTabMigrated") else { return }
        let map = [0: 0, 1: 1, 2: 2, 3: 3, 4: 0, 5: 0, 6: 4, 7: 1]
        ud.set(map[ud.integer(forKey: "settingsTab")] ?? 0, forKey: "settingsTab")
        ud.set(true, forKey: "settingsTabMigrated")
    }

    func toggle(state: AppState, anchor: CGRect?) {
        if let p = panel, p.isVisible { close(); return }
        Self.migrateTabs()

        // Runde 47j ZURÜCKGENOMMEN (siehe PROGRESS): der randlose Milchglas-Look
        // machte die Panels unklickbar. Wieder das bewährte titled Utility-Panel.
        let hosting = SettingsHostingView(rootView: SettingsPane(
            state: state,
            onClose: { Task { @MainActor in SettingsPanelController.shared.close() } },
            onSize: { size in
                // Runde 110b (F1): gemessen am GLAS vor dem Bühnen-Padding, ein Runloop-Hop (keine Layout-Rekursion).
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { SettingsPanelController.shared.resize(to: size) }
                }
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
        hosting.sizingOptions = []   // Runde 110b: Größe setzt allein der Controller (wie im Termin-Fenster)
        hosting.safeAreaRegions = []
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let p = ThemePanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = L.t("Einstellungen", "Settings")
        p.contentFillsFrame = true
        p.controllerOwnsSize = true
        p.setContentSize(size)
        // Runde 98: Glas bis unter die Titelleiste wie das Termin-Fenster, Esc schließt.
        p.titlebarAppearsTransparent = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.onEscape = { [weak p] in p?.close() }
        p.isReleasedWhenClosed = false
        p.level = .floating        // Runde 111b (A1): dieselbe Ebene wie alle MeetingBlitz-Fenster
        // Runde 115: Aussehen kommt von NSApp.appearance (Look.apply).
        p.hidesOnDeactivate = false
        // Key from the start: controls only render their active (blue) accent
        // in a key window, otherwise everything sits gray until first clicked.
        p.becomesKeyOnlyIfNeeded = false
        // Muss dasselbe Verhalten haben wie das Widget, sonst öffnet sich das
        // Panel bei laufender Vollbild-App auf dem Schreibtisch daneben und der
        // Klick sieht wirkungslos aus (22.08.2026, Begründung in PanelDock).
        p.collectionBehavior = PanelDock.companionBehavior
        p.contentView = hosting
        Theme.installStage(in: p)

        // Runde 47g/47h/47i: gemerkte Position gewinnt, sonst neben das Widget.
        // Grobplatzierung, die endgültige macht das erste resize() mit der
        // echten Größe (fittingSize kann hier noch ~0 sein, siehe CreatePanel).
        anchorRect = anchor
        widgetAnchor = WidgetPanelController.shared.glassFrame
        let panelSize = p.frame.size
        p.setFrameOrigin(PanelDock.savedOrigin(panelSize: panelSize, id: "settings", anchor: anchorRect, stage: Theme.stageInset)
                         ?? PanelDock.origin(panelSize: panelSize, anchor: anchor, stage: Theme.stageInset, rightAnchor: widgetAnchor))
        p.makeKeyAndOrderFront(nil)   // key immediately → blue accents from the start
        // Runde 109d (N2): kein Textfeld beim Öffnen fokussieren/markieren (ein
        // Tastendruck ersetzte sonst die Konto-Adresse). Zwei Hops, weil SwiftUI
        // den Fokus erst nach dem ersten Layout setzt.
        for delay in [0.0, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak p] in
                guard let p, p.isVisible, p.firstResponder is NSText else { return }
                // Nicht dem Mailtext-Betreff (Zahnrad) den Fokus wegnehmen.
                if UserDefaults.standard.string(forKey: "settingsScrollTo") == "mailText" { return }
                p.makeFirstResponder(nil)
            }
        }
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
        let recorder = PanelMoveRecorder(id: "settings", stage: Theme.stageInset)
        userMoved = false
        recorder.onUserMove = { [weak self] in
            self?.userMoved = true
            self?.restTop = self?.panel?.frame.maxY   // Runde 114: die Stelle, die der Nutzer gewählt hat
            self?.screenMaybeChanged()
        }
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

    /// Runde 114 (Punkt 4): Oberkante, an der das Fenster "wohnt". Beim Reiterwechsel wird immer von DIESER Kante
    /// aus geklemmt (nicht von der schon verschobenen), sonst bleibt das Fenster nach einem hohen Reiter oben hängen.
    private var restTop: CGFloat?

    /// Runde 114: Fenster wurde gezogen, evtl. auf einen anderen Bildschirm: Deckel neu, Höhe neu anpassen.
    private func screenMaybeChanged() {
        updateScreenHeight()   // ändert sich der Deckel, misst der Inhalt neu und meldet die neue Höhe von selbst
    }

    /// Warum die Notbremse greifen musste, für den Diagnosebericht. `nil` =
    /// alles normal platziert.
    private(set) var lastRescueReason: String?

    /// Grow/shrink the panel when the content size changes (Kalender expand),
    /// keeping the top edge fixed and clamping into the visible screen.
    private var pendingShrink: DispatchWorkItem?

    /// Runde 110b (F1): `glassSize` = Glas-Größe (vom Inhalt vor dem Bühnen-Padding gemessen). Das Fenster ist
    /// um die Bühne größer. Wachsen sofort (Oberkante bleibt), Schrumpfen erst nach der Klapp-Feder.
    func resize(to glassSize: CGSize) {
        // Die Meldung ZUERST festhalten (die erste kommt oft vor dem Fenster).
        guard glassSize.width > 1, glassSize.height > 100 else { return }
        let stage = 2 * Theme.stageInset
        let frameSize = CGSize(width: glassSize.width + stage, height: glassSize.height + stage)
        lastReportedSize = frameSize
        guard let p = panel, p.isVisible else { return }
        updateScreenHeight()
        let old = p.frame
        if moveRecorder?.suspended == true {
            restTop = nil
            (p as? ThemePanel)?.pinnedHeight = frameSize.height
            SettingsLayout.shared.set(frameSize.height)
            let origin = PanelDock.savedOrigin(panelSize: frameSize, id: "settings", anchor: anchorRect, stage: Theme.stageInset)
                ?? PanelDock.origin(panelSize: frameSize, anchor: anchorRect, stage: Theme.stageInset, rightAnchor: widgetAnchor)
            (p as? ThemePanel)?.setFrameFromController(CGRect(origin: origin, size: frameSize), display: true)
            moveRecorder?.suspended = false
            return
        }
        if abs(frameSize.height - old.height) < 1, abs(frameSize.width - old.width) < 1 {
            pendingShrink?.cancel(); pendingShrink = nil
            (p as? ThemePanel)?.pinnedHeight = frameSize.height
            return
        }
        if frameSize.height < old.height - 0.5, abs(frameSize.width - old.width) < 1 {
            pendingShrink?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.applyFrame(frameSize) }
            pendingShrink = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.foldSettle, execute: w)
            return
        }
        pendingShrink?.cancel(); pendingShrink = nil
        applyFrame(frameSize)
    }

    /// Runde 114 (Punkt 2): Deckel für den Reiter-Inhalt kommt vom Bildschirm unter dem Fenster.
    private func updateScreenHeight() {
        guard let p = panel else { return }
        let vf = PanelDock.visibleFrame(containing: p.frame) ?? (p.screen ?? NSScreen.main)?.visibleFrame
        SettingsLayout.shared.setScreen(CreatePanelController.simulatedScreenHeight ?? vf?.height)
    }

    private func applyFrame(_ frameSize: CGSize) {
        guard let p = panel, p.isVisible else { return }
        updateScreenHeight()
        let old = p.frame
        (p as? ThemePanel)?.pinnedHeight = frameSize.height
        SettingsLayout.shared.set(frameSize.height)
        HintWindow.log("settings resize h=\(Int(frameSize.height)) w=\(Int(frameSize.width))")
        moveRecorder?.suspended = true
        if restTop == nil { restTop = old.maxY }
        let homeFrame = CGRect(x: old.minX, y: restTop! - old.height, width: old.width, height: old.height)
        var y = restTop! - frameSize.height
        if let vf = PanelDock.visibleFrame(containing: old) {
            y = PanelDock.clampedWindowY(frame: homeFrame, newHeight: frameSize.height, vf: vf, stage: Theme.stageInset)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0; ctx.allowsImplicitAnimation = false
            CATransaction.begin(); CATransaction.setDisableActions(true)
            (p as? ThemePanel)?.setFrameFromController(CGRect(x: old.minX, y: y.rounded(), width: frameSize.width, height: frameSize.height), display: true)
            p.contentView?.layoutSubtreeIfNeeded()
            CATransaction.commit(); CATransaction.flush()
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
            size.height = min(size.height, vf.height - 16 + 2 * Theme.stageInset)
        }
        var y = old.maxY - size.height
        if let vf = PanelDock.visibleFrame(containing: old) {
            y = PanelDock.clampedWindowY(frame: old, newHeight: size.height, vf: vf, stage: Theme.stageInset)
        }
        (p as? ThemePanel)?.setFrameFromController(CGRect(x: old.minX, y: y.rounded(), width: size.width, height: size.height),
                   display: true)
        HintWindow.log(String(format: "settings fitToContent %.0f→%.0f", old.height, size.height))
    }

    /// Endgültige Erstplatzierung, sobald das Panel seine echte Größe hat
    /// (Runde 47i(2)). Läuft einen Runloop nach dem Öffnen; falls resize()
    /// schneller war (suspended schon false), tut sie nichts.
    private func finishInitialPlacement() {
        guard let p = panel, p.isVisible, moveRecorder?.suspended == true else { return }
        let size = p.frame.size
        updateScreenHeight()
        guard size.width > 50 else { return }   // immer noch Phantom → resize() übernimmt
        p.setFrameOrigin(PanelDock.savedOrigin(panelSize: size, id: "settings", anchor: anchorRect, stage: Theme.stageInset)
                         ?? PanelDock.origin(panelSize: size, anchor: anchorRect, stage: Theme.stageInset, rightAnchor: widgetAnchor))
        // Sofort auf Inhaltshöhe, nicht erst mit der Notbremse eine halbe
        // Sekunde später: sonst blitzt das Fenster in falscher Größe auf.
        fitToContent()
        moveRecorder?.suspended = false
    }

    /// Runde 99: Das Widget hat sich bewegt oder seine Höhe geändert → das Panel
    /// dockt neu an (Oberkante exakt gleich, Abstand s8, Seite mit Platz).
    /// Runde 111 (Fund 11): vom Nutzer gezogene Position gewinnt.
    private var userMoved = false

    func alignToWidget(_ a: CGRect) {
        guard let p = panel, p.isVisible, !userMoved else { return }
        guard PanelDock.sameScreen(p.frame, a) else { return }   // Runde 114: bleibt auf seinem Bildschirm
        // Runde 110b (F2): hängt das Termin-Fenster schon links am Widget, dockt dieses links NEBEN dem
        // Termin-Fenster (8 pt Glasabstand), sonst rechts vom Widget.
        widgetAnchor = a
        restTop = nil
        let target = CreatePanelController.shared.isOpen ? (CreatePanelController.shared.glassFrame ?? a) : a
        anchorRect = target
        moveRecorder?.suspended = true
        p.setFrameOrigin(PanelDock.origin(panelSize: p.frame.size, anchor: target, stage: Theme.stageInset, rightAnchor: a))
        moveRecorder?.suspended = false
    }

    func refreshTitle() { panel?.title = L.t("Einstellungen", "Settings") }

    func close() {
        SettingsLayout.shared.set(nil)
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
    @ObservedObject var mcp = MCPBridge.shared
    @ObservedObject private var layout = SettingsLayout.shared
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
    /// Runde 115: Aussehen + Glas.
    @AppStorage(Look.appearanceKey) private var lookAppearance = Look.Mode.dark.rawValue
    @AppStorage(Look.glassKey) private var lookGlass = Look.Glass.normal.rawValue
    /// Runde 110b: gemessene Höhe des Reiter-Inhalts, je Reiter gemerkt (kein Aufspringen beim Öffnen).
    nonisolated(unsafe) static var cachedHeights: [Int: CGFloat] = [:]
    @State private var contentH: CGFloat = 0
    /// F11: inline lists open, one per target side (both can show at once).
    @State private var gcalListOpen = CreatePane.demoCalendars != nil   // Demo (Fotos): Liste offen
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
        VStack(alignment: .leading, spacing: Theme.s16) {
            ThemeWindowHeader(title: tabTitle)   // Runde 110: Kopf = Name des Bereichs (wie Systemeinstellungen)
            // Fünf Reiter passen bei 300pt nur mit kurzen Namen, deshalb
            // „Kalender" → „Kal." und die Auswertung als Symbol.
            tabBar

            // Runde 104: passt der Reiter auf den Bildschirm, wächst das Fenster mit dem Inhalt;
            // sonst scrollt der Reiter und Kopf und Fuß bleiben stehen.
            // Runde 110b (F1): KEIN ViewThatFits mehr (es wählte je nach vorgeschlagener Fensterhöhe und
            // verklemmte sich: das Fenster wuchs nie). Die natürliche Höhe des Reiters wird im Inhalt gemessen,
            // der Bereich ist genau so hoch (Deckel Bildschirm), scrollt nur, wenn er den Deckel überschreitet.
            // Runde 114 (Punkt 2): Höhe des Bildschirms, auf dem das Fenster WIRKLICH steht (nicht NSScreen.main = Retina).
            let cap = max(300, (layout.screenHeight ?? NSScreen.main?.visibleFrame.height ?? 800) - 16 - 200)
            let shown = min(contentH, cap)
            ScrollViewReader { proxy in
                ScrollView {
                    tabContent
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                            let v = max(0, h)   // Runde 111 (Fund 9): nichts abziehen, sonst fehlen Unterlängen am letzten Knopf
                            contentH = v
                            Self.cachedHeights[tab] = v
                        }
                }
                .scrollIndicators(.automatic)
                .scrollDisabled(contentH <= cap)
                  .themeScrollFade(enabled: contentH > cap)
                .frame(height: shown, alignment: .top)
                .clipped()
                .animation(Theme.fold, value: shown)
                .onAppear {
                    // Runde 109: Zahnrad im Termin-Fenster springt hierher.
                    if let id = UserDefaults.standard.string(forKey: "settingsScrollTo") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(Theme.fold) { proxy.scrollTo(id, anchor: .top) }
                            UserDefaults.standard.removeObject(forKey: "settingsScrollTo")
                        }
                    }
                }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: ContentBottomKey.self, value: g.frame(in: .global).maxY)
            })

            // Fuß wie im Widget: Name + Version links, runde Knöpfe rechts.
            ThemeDivider()
                .background(GeometryReader { g in
                    Color.clear.preference(key: FootTopKey.self, value: g.frame(in: .global).minY)
                })
            HStack(spacing: Theme.s8) {
                Text("MeetingBlitz \(Self.appVersion)")
                    .font(.theme(.small)).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(ThemeToggleStyle())
        .padding(.horizontal, Theme.s16).padding(.bottom, Theme.s16).padding(.top, Theme.s16)
        .frame(width: 360)   // Runde 111b: wie das Widget, fünf beschriftete Reiter brauchen die Breite
        .background(ThemeGlass())
        .themeDragHeader()
        .themeCloseCorner { onClose?() }
        .onChange(of: state.appLanguage) { SettingsPanelController.shared.refreshTitle() }
        // Runde 110b (F1): HIER (am Glas, vor dem Bühnen-Padding) messen, dann oben festnageln auf Fensterhöhe.
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            if size.width > 1 { onSize?(size) }
        }
        .padding(Theme.stageInset)
        .frame(height: layout.height, alignment: .top)
        .ignoresSafeArea()   // Runde 103: Kopfzeile sitzt exakt 16 pt unter der Fensterkante
        .onPreferenceChange(RowFramesKey.self) { RowProbe.rows["settings"] = $0 }
        .onPreferenceChange(ContentBottomKey.self) { RowProbe.contentBottom = $0 }
        .onPreferenceChange(FootTopKey.self) { RowProbe.footTop = $0 }
        .onAppear { state.refreshLaunchAtLogin(); if contentH == 0 { contentH = Self.cachedHeights[tab] ?? 0 } }
        // F5: Ein laufender Tastatur-Monitor, der das Schließen des Panels
        // überlebt, würde jeden weiteren Tastendruck der App schlucken.
        .onDisappear { stopRecording() }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case 1: alertsTab
        case 2: calendarsTab
        case 3: meetingsTab
        case 4: advancedTab
        case 5: bannerTab
        default: generalTab
        }
    }

    // MARK: - Tab: Allgemein

    /// App-Grundlagen. Bewusst KURZ: Der Reiter war über die Runden auf über
    /// 200 Zeilen gewachsen und füllte den halben Bildschirm („die
    /// Einstellungen sind zu groß"). Alles Widget-Nahe steckt jetzt in
    /// `widgetTab`, alles zum Erstellen im Google-Reiter.
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            Toggle(L.t("Bei der Anmeldung öffnen", "Open at login"), isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            )).font(.theme(.normal))
            ThemeChoiceRow(title: L.t("Sprache", "Language"), options: [("English", "en")] + [("Deutsch", "de")], selection: $state.appLanguage)
            ThemeChoiceRow(title: L.t("Aussehen", "Appearance"),
                           options: [(L.t("System", "System"), Look.Mode.system.rawValue), (L.t("Hell", "Light"), Look.Mode.light.rawValue), (L.t("Dunkel", "Dark"), Look.Mode.dark.rawValue)],
                           selection: Binding(get: { lookAppearance }, set: { lookAppearance = $0; Look.apply() }))
            ThemeChoiceRow(title: L.t("Glas", "Glass"),
                           options: [(L.t("Normal", "Normal"), Look.Glass.normal.rawValue), (L.t("Klarer", "Clearer"), Look.Glass.clear.rawValue)],
                           selection: $lookGlass)

            ThemeSectionDivider()
            ThemeSectionTitle(L.t("Tastenkürzel", "Hotkeys"))
            Toggle(L.t("Tastenkürzel verwenden", "Use hotkeys"),
                   isOn: $state.hotkeyEnabled).font(.theme(.normal))
            if state.hotkeyEnabled {
                hotkeyRow(L.t("Widget öffnen", "Open widget"), action: .showWidget)
                hotkeyRow(L.t("Meeting beitreten", "Join meeting"), action: .joinNext)
                if let dead = state.hotkeyConflict {
                    Text(L.t("Schon vom System belegt: \(dead).", "Already taken by the system: \(dead)."))
                        .font(.theme(.small)).foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L.t("Beitreten nimmt den laufenden Call, sonst den nächsten.",
                         "Join takes the running call, otherwise the next one."))
                    .themeNote()
            }

            ThemeSectionDivider()
            ThemeSectionTitle(L.t("Menüleiste & Widget", "Menu bar & widget"))
            ThemeChoiceRow(title: L.t("Menüleiste zeigt", "Menu bar shows"), options: Array(MenuBarStyle.allCases).map { ($0.label, $0) }, selection: $state.menuBarStyle)
            Toggle(L.t("Im Meeting schmal halten", "Keep it narrow during meetings"),
                   isOn: $state.compactMenuBarInMeeting).font(.theme(.normal))
            ThemeChoiceRow(title: L.t("Im Meeting auf den nächsten Termin wechseln nach",
                                      "During a meeting, switch to the next one after"),
                           options: Array(MenuBarFocus.choices).map { m in (m == 0 ? L.t("Nie", "Never") : "\(m) min", m) },
                           selection: $state.switchToNextAfterMinutes)
            ThemeNote(L.t("Läuft ein Termin länger, zeigt die Menüleiste wieder, wann der nächste beginnt. Gibt es keinen nächsten, bleibt der laufende stehen.",
                          "Once a meeting has run that long, the menu bar goes back to showing when the next one starts. With no next meeting it keeps showing the running one."))
            ThemeChoiceRow(title: L.t("Datumswahl zeigt", "Date picker shows"), options: Array(CalendarViewMode.allCases).map { ($0.label, $0) }, selection: $state.calendarViewMode)
            Text(calendarModeHint).themeNote()
            ThemeChoiceRow(title: L.t("Woche beginnt am", "Week starts on"), options: [(L.t("Mo", "Mon"), 2)] + [(L.t("So", "Sun"), 1)], selection: $state.firstWeekday)
            Toggle(L.t("Apple Erinnerungen zeigen", "Show Apple Reminders"), isOn: Binding(
                get: { state.showReminders },
                set: { on in
                    state.showReminders = on
                    if on { Task { await state.requestRemindersAccess() } }
                    else { state.reminders = [] }
                }
            )).font(.theme(.normal))
            Toggle(L.t("Zweite Zeitzone", "Second time zone"),
                   isOn: $state.secondZoneEnabled).font(.theme(.normal))
            if state.secondZoneEnabled {
                zoneRow
                if zoneCustomBad {
                    Text(L.t("Unbekannte Zone. IANA-Name wie „Europe/Berlin“ verwenden.",
                             "Unknown zone. Use an IANA name like “Europe/Berlin”."))
                        .font(.theme(.small)).foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(L.t("Knopf „Neues Meeting“ anzeigen", "Show “New Meeting” button"),
                   isOn: $state.showMeetingCreator).font(.theme(.normal))
            Toggle(L.t("Knopf „Sofort-Meeting“ anzeigen", "Show “Instant meeting” button"),
                   isOn: $state.showInstantMeeting).font(.theme(.normal))
        }
    }

    // MARK: - Claude-Zugang (MCP, Runde 78)

    /// Eigener kleiner Abschnitt: Schalter, ein Satz Erklärung, Status, und
    /// der Knopf, der den fertigen `claude mcp add …`-Befehl in die
    /// Zwischenablage legt. Standard AUS (siehe `AppState.mcpEnabled`), eine
    /// lokale Bruecke, die ohne Klick Termine anlegen kann, ist bewusster Opt-in.
    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: Theme.s8) {
            ThemeSectionTitle(L.t("Claude-Zugang (MCP)", "Claude access (MCP)"))
            Toggle(L.t("Claude darf Termine über MeetingBlitz verwalten", "Claude may manage events through MeetingBlitz"),
                   isOn: $state.mcpEnabled).font(.theme(.normal))
            Text(L.t("Öffnet eine lokale, mit einem Zugangscode geschützte Brücke auf diesem Rechner (127.0.0.1). Nur Claude auf diesem Mac kann sie erreichen, kein Fernzugriff.",
                     "Opens a local, token-protected bridge on this Mac (127.0.0.1). Only Claude on this machine can reach it, no remote access."))
                .themeNote()
            if state.mcpEnabled {
                Text(mcp.isRunning
                     ? L.t("Läuft auf Port \(mcp.port)", "Running on port \(mcp.port)")
                     : L.t("Wird gestartet …", "Starting …"))
                    .font(.theme(.small)).foregroundStyle(Theme.muted)
                Button(L.t("Befehl kopieren", "Copy command")) {
                    let path = Bundle.main.executablePath ?? Bundle.main.bundlePath
                    let cmd = "claude mcp add -s user meetingblitz -- \"\(path)\" --mcp"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                }
                .font(.theme(.normal)).buttonStyle(ThemeLinkStyle()).themeRowList()
                Text(L.t("Fügt MeetingBlitz einmalig in Claude Code als MCP-Server ein. In ein Terminal einfügen und ausführen.",
                         "Adds MeetingBlitz to Claude Code as an MCP server, once. Paste into a terminal and run it."))
                    .themeNote()
            }
        }
    }

    // MARK: - Tab: Hinweise (Banner, Erinnern, Ruhe)

    private var alertsTab: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            ThemeChoiceRow(title: L.t("Vorlaufzeit", "Lead time"), options: Array(leadOptions).map { ("\($0)m", $0) }, selection: $state.leadMinutes)
            ThemeChoiceRow(title: L.t("Flugdauer", "Flight time"), options: Array(flightOptions).map { ("\(Int($0))s", $0) }, selection: $state.animationSeconds)
            Toggle(L.t("Ton abspielen", "Play sound"), isOn: $state.soundEnabled).font(.theme(.normal))
            ThemeChoiceRow(title: L.t("Später erinnern um", "Snooze by"), options: Array([1, 2, 5, 10]).map { ("\($0)m", $0) }, selection: $state.snoozeMinutes)
            Toggle(L.t("Warnung vor Meeting-Ende", "End-of-meeting warning"), isOn: $state.endWarning).font(.theme(.normal))
            Button(L.t("Test-Banner zeigen", "Show test banner")) { state.showTestBanner() }
                .font(.theme(.normal)).buttonStyle(ThemeLinkStyle()).themeRowList()

            ThemeSectionDivider()
            ThemeSectionTitle(L.t("Ruhe", "Quiet"))
            quietSection
        }
    }

    // MARK: - Ruhe (Abschnitt im Reiter Hinweise)

    private var quietSection: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            Toggle(L.t("Ruhe-Modus (keine Banner)", "Quiet mode (no banners)"), isOn: $state.quietMode).font(.theme(.normal))
            // Befristet einschalten: Ruhe „für heute Nachmittag" schaltet man
            // sonst ein und vergisst sie, und wundert sich tagelang über
            // ausbleibende Banner.
            // Als sichtbare Knöpfe, nicht als borderless-Text: so sahen sie aus
            // wie Fließtext und wurden schlicht übersehen („sehe das nicht").
            HStack(spacing: Theme.s8) {
                Text(L.t("für", "for")).font(.theme(.small)).foregroundStyle(Theme.muted)
                ForEach([(1.0, "1h"), (5.0, "5h"), (24.0, L.t("1 Tag", "1 day")),
                         (168.0, L.t("1 Woche", "1 week"))], id: \.1) { h, label in
                    ThemeTextRow(title: label, accent: true, fullWidth: false, compact: true) { state.startQuiet(hours: h) }
                        .help(L.t("Ruhe für \(label) einschalten", "Turn on quiet for \(label)"))
                }
                Spacer(minLength: 0)
            }
            if let rest = state.quietRemainingLabel {
                HStack(spacing: Theme.s8) {
                    Text(L.t("Ruhe endet in \(rest)", "Quiet ends in \(rest)"))
                        .font(.theme(.small)).foregroundStyle(Theme.blue)
                    Spacer(minLength: 0)
                    Button(L.t("Jetzt beenden", "End now")) { state.quietMode = false }
                        .font(.theme(.small)).buttonStyle(ThemeLinkStyle())
                }
            }
            // P1: ohne das verpasst man Termine genau dann, wenn man nicht
            // gestört werden will.
            Toggle(L.t("Bei Ruhe still benachrichtigen", "Notify silently while quiet"),
                   isOn: $state.quietNotifications).font(.theme(.normal))
            if state.quietNotifications {
                VStack(alignment: .leading, spacing: Theme.rowGap) {
                    ThemeNote(L.t("Statt Banner eine lautlose Mitteilung, damit ein Termin bei Ruhe oder Bildschirmfreigabe nicht untergeht.",
                                  "A silent notification instead of the banner, so a meeting isn't missed during quiet mode or screen sharing."))
                    ThemeTextRow(title: L.t("Testen", "Test"), accent: true, fullWidth: false, compact: true) {
                        QuietNotice.test()
                        noticeTest = L.t("Hinweis erscheint oben rechts.",
                                         "The notice appears in the top right.")
                    }
                    .themeRowList()
                }
                if let t = noticeTest {
                    Text(t).font(.theme(.small))
                        .foregroundStyle(t.hasPrefix("Gesendet") || t.hasPrefix("Sent")
                                         ? Theme.muted : Theme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(L.t("Ruhe bei Bildschirmfreigabe", "Quiet while screen sharing"), isOn: $state.quietDuringScreenShare).font(.theme(.normal))
        }
    }

    /// Startbildschirm und Flugrichtung, nur bei mehr als einem Monitor.
    /// Ausgelagert, weil der Banner-Reiter sonst wieder zu lang wird.
    @ViewBuilder
    private var multiScreenRows: some View {
        ThemeChoiceRow(title: L.t("Startbildschirm", "Start screen"), options: Array(0..<screenLabels().count).map { i in ("\(i + 1)", i) }, selection: $state.crossScreenStartIndex)
        // Segmented (NOT .menu): a menu picker opens a modal NSMenu
        // that hangs in this nonactivating panel and blocks all clicks.
        Text(screenLabels().indices.contains(state.crossScreenStartIndex)
             ? screenLabels()[state.crossScreenStartIndex] : "")
            .themeNote()
        ThemeChoiceRow(title: L.t("Richtung", "Direction"), options: [(L.t("→ rechts", "→ right"), true)] + [(L.t("← links", "← left"), false)], selection: $state.crossScreenToRight)
    }

    // MARK: - Flugobjekt (Skin-Auswahl, 20.08.2026)

    /// Style-Umschalter + Motivraster + Test-Knopf. Eigener Block, damit der
    /// lange Banner-Reiter nicht noch unübersichtlicher wird.
    private var skinSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Kein eigener Titel mehr: seit 23.08. ist das ein eigener Reiter,
            // dessen Überschrift schon „Flugobjekt" heißt, und zweimal
            // dasselbe Wort untereinander sieht nach Versehen aus.
            ThemeChoiceRow(title: L.t("Stil", "Style"), options: Array(SkinStyle.allCases).map { ($0.label, $0) }, selection: $state.skinStyle)

            if state.skinStyle != .classic {
                // Wechsel-Schalter direkt unter der Stil-Wahl: er entscheidet,
                // was ein Tipp im Raster darunter bedeutet (auswählen oder in
                // den Wechsel aufnehmen), deshalb steht er davor.
                ThemeChoiceRow(title: L.t("Motivwechsel", "Motif changes"),
                               options: Array(SkinRotation.allCases).map { ($0.label, $0) }, selection: $state.skinRotation)
                Text(state.skinRotation == .off
                     ? L.t("Immer dasselbe Motiv. Tippen wählt es aus.",
                           "Always the same motif. Tap one to pick it.")
                     : L.t("Jedes Banner nimmt ein anderes Motiv. Tippen nimmt eins in den Wechsel auf oder heraus.",
                           "Every banner uses a different motif. Tap one to add or remove it from the rotation."))
                    .themeNote()
                if state.skinRotation != .off {
                    HStack(spacing: Theme.s8) {
                        Text(L.t("Im Wechsel: \(state.rotationSkins.count) von \(Skin.all.count)",
                                 "In rotation: \(state.rotationSkins.count) of \(Skin.all.count)"))
                            .font(.theme(.small)).foregroundStyle(Theme.blue)
                        Spacer(minLength: 0)
                        Button(L.t("Alle", "All")) { state.skinPool = [] }
                            .font(.theme(.small)).buttonStyle(ThemeLinkStyle())
                            .help(L.t("Alle Motive teilnehmen lassen", "Let every motif take part"))
                    }
                }
            }

            if state.skinStyle == .classic {
                Text(L.t("Das klassische U-Boot, ohne Motivwahl.",
                         "The classic U-Boot, no motif to pick."))
                    .themeNote()
            } else if let skin = detailSkin {
                skinDetail(skin)
            } else {
                skinGrid
                Text(L.t("Das ⓘ am Motiv (oder ein Doppelklick) zeigt es groß, mit seiner Geschichte.",
                         "The ⓘ on a motif (or a double-click) shows it large, with its story."))
                    .themeNote()
            }

            Button(L.t("Vorschau fliegen lassen", "Preview it flying")) { state.showTestBanner() }
                .font(.theme(.normal)).buttonStyle(ThemeLinkStyle()).themeRowList()
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
                    HStack(spacing: Theme.s4) {
                        Image(systemName: "chevron.left").font(.theme(.small, .semibold))
                        Text(L.t("Alle Motive", "All motifs")).font(.theme(.small))
                    }
                }
                .buttonStyle(ThemeLinkStyle())
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
                    .font(.theme(.small)).buttonStyle(ThemeLinkStyle())
                } else if state.skinID != skin.id {
                    Button(L.t("Auswählen", "Select")) { state.skinID = skin.id }
                        .font(.theme(.small)).buttonStyle(ThemeLinkStyle())
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Color.primary.opacity(0.06))
                if let image = Skins.shared.image(for: skin, style: state.skinStyle) {
                    Image(nsImage: image)
                        .resizable().aspectRatio(contentMode: .fit).padding(10)
                } else {
                    Image(systemName: "questionmark.square.dashed")
                        .font(.theme(.normal)).foregroundStyle(Theme.muted)
                }
            }
            .frame(height: 104)

            Text(skin.name).font(.theme(.normal, .semibold))

            if let text = skin.loreText {
                ScrollView {
                    Text(text)
                        .font(.theme(.small))
                        .foregroundStyle(Theme.muted)
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
                        HStack(spacing: Theme.s4) {
                            Image(systemName: "arrow.up.right.square").font(.theme(.small))
                            Text(L.t("Quelle", "Source")).font(.theme(.small))
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.blue)
                }
            } else {
                Text(L.t("Zu diesem Motiv ist noch keine Geschichte hinterlegt.",
                         "No story recorded for this motif yet."))
                    .themeNote()
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
        return VStack(spacing: Theme.s4) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Color.primary.opacity(0.06))
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                    } else {
                        // Fällt die Datei aus (fehlt im Bundle), sauber ein
                        // Platzhalter statt Absturz oder leerer Kachel.
                        Image(systemName: "questionmark.square.dashed")
                            .font(.theme(.normal))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .frame(height: 44)
                Text(skin.name)
                    .font(.theme(.small))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(selected ? Theme.blue : .secondary)
            }
            .padding(5)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(selected ? Theme.blue.opacity(0.16) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(selected ? Theme.blue.opacity(0.7) : Color.primary.opacity(0.08),
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
                            .font(.theme(.normal))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Theme.onBlue, Theme.blue)
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help(L.t("Geschichte zu \(skin.name) zeigen", "Show the story behind \(skin.name)"))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
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
                    .font(.theme(.normal)).foregroundStyle(Theme.muted)
            } else {
                // Checkboxes left to right: show in widget (Runde 40),
                // 🔔 banner/blink (Runde 40), 🎂 birthdays (Runde 55).
                // Runde 111b: Spaltenköpfe ÜBER den Spalten (wie im Willkommen), nicht als Satz links.
                HStack(spacing: Theme.s8) {
                    Spacer(minLength: 0)
                    ForEach([("eye", L.t("Anzeigen", "Show")), ("bell", L.t("Banner", "Banner")), ("gift", L.t("Geburtstage", "Birthdays"))], id: \.0) { sym, name in
                        VStack(spacing: 1) {
                            Image(systemName: sym).font(.theme(.small, .semibold))
                            Text(name).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(Theme.muted).frame(width: 40)
                    }
                }
                .padding(.trailing, 14)
                // Bis ~20 Kalender OHNE ScrollView: der bräuchte eine feste
                // Höhe (er hat keine intrinsische, Runde 14), und die war
                // geschätzt — bei 15 Kalendern blieben ~100pt Leere darunter
                // stehen. Ein reiner VStack wächst exakt mit dem Inhalt. Erst
                // darüber wird gescrollt, sonst sprengt die Liste den Schirm.
                Group {
                    let list = VStack(alignment: .leading, spacing: Theme.s4) {
                        ForEach(state.availableCalendars) { c in
                            HStack(spacing: Theme.s8) {
                                Circle().fill(c.color).frame(width: 8, height: 8)
                                Text(c.title).font(.theme(.normal)).lineLimit(1)
                                Spacer(minLength: 8)
                                Toggle("", isOn: Binding(
                                    get: { state.selectedCalendarIDs.contains(c.id) },
                                    set: { _ in state.toggleCalendar(c.id) }
                                )).labelsHidden().toggleStyle(ThemeCheckStyle())
                                    .help(L.t("Im Widget anzeigen", "Show in widget"))
                                Toggle("", isOn: Binding(
                                    get: { state.isAlertCalendar(c.id) },
                                    set: { _ in state.toggleAlertCalendar(c.id) }
                                )).labelsHidden().toggleStyle(ThemeCheckStyle())
                                    .help(L.t("Banner & Blinken für diesen Kalender",
                                              "Banner & blink for this calendar"))
                                Toggle("", isOn: Binding(
                                    get: { state.isBirthdayCalendar(c.id) },
                                    set: { _ in state.toggleBirthdayCalendar(c.id) }
                                )).labelsHidden().toggleStyle(ThemeCheckStyle())
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
                    .font(.theme(.normal)).buttonStyle(ThemeLinkStyle()).themeRowList()
            }
            // Runde 55: the × was occurrence-scoped, so a yearly birthday came
            // back next year. This makes it permanent per title + calendar.
            Toggle(L.t("Ausgeblendete Termine bleiben weg", "Keep hidden events hidden"),
                   isOn: $state.hidePermanently).font(.theme(.normal))
            Text(L.t("Das × blendet dann jeden Termin mit diesem Titel in diesem Kalender aus, nicht nur den von heute.",
                     "The × then hides every event with this title in this calendar, not just today's."))
                .themeNote()
            if state.hiddenCount > 0 {
                Button(L.t("Ausgeblendete Termine wieder zeigen (\(state.hiddenCount))",
                           "Show hidden events again (\(state.hiddenCount))")) {
                    state.unhideAll()
                }
                .font(.theme(.small)).buttonStyle(ThemeLinkStyle())
            }

            ThemeSectionDivider()
            ThemeSectionTitle(L.t("Im Widget zeigen", "Show in widget"))
            Toggle(L.t("Nur Termine mit Link zeigen", "Only show events with a link"),
                   isOn: $state.onlyWithLink).font(.theme(.normal))
            Toggle(L.t("Vergangene Termine ausblenden", "Hide past events"),
                   isOn: $state.hidePastEvents).font(.theme(.normal))
            Toggle(L.t("Abgesagte Termine ausblenden", "Hide declined events"),
                   isOn: $state.hideDeclined).font(.theme(.normal))
        }
    }

    // MARK: - Mailtext (Runde 109)

    @FocusState private var mailSubjectFocused: Bool
    @State private var mailTextOpen = false
    @State private var focusMailSubject = false

    private func mailField(_ title: String, subject: Binding<String>, body: Binding<String>,
                           defaultBody: String, focus: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack {
                Text(title).font(.theme(.normal, .semibold))
                Spacer()
                Button(L.t("Standard", "Default")) { subject.wrappedValue = ""; body.wrappedValue = "" }
                    .font(.theme(.small)).buttonStyle(ThemeLinkStyle())
                    .help(L.t("Vorlage zurücksetzen", "Reset the template"))
            }
            Group {
                if focus {
                    TextField(MailInvite.defaultSubject, text: subject).focused($mailSubjectFocused)
                } else {
                    TextField(MailInvite.defaultSubject, text: subject)
                }
            }
            .textFieldStyle(ThemeFieldStyle())
            ZStack(alignment: .topLeading) {
                TextEditor(text: body)
                    .scrollContentBackground(.hidden)
                    .font(.theme(.normal))
                    .padding(Theme.s4)
                if body.wrappedValue.isEmpty {
                    Text(defaultBody).font(.theme(.normal)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, Theme.s8).padding(.vertical, Theme.s8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
        }
    }

    /// Runde 119: Vorlage für „Einladungstext kopieren“ (leer = fester Aufbau Titel, Datum, Zeiten, Link).
    private func inviteTextField(_ lang: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack {
                Text(L.t("Einladungstext \(lang)", "Invite text \(lang)")).font(.theme(.normal, .semibold))
                Spacer()
                Button(L.t("Standard", "Default")) { text.wrappedValue = "" }
                    .font(.theme(.small)).buttonStyle(ThemeLinkStyle())
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: text).scrollContentBackground(.hidden).font(.theme(.normal)).padding(Theme.s4)
                if text.wrappedValue.isEmpty {
                    Text(placeholder).font(.theme(.normal)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, Theme.s8).padding(.vertical, Theme.s8).allowsHitTesting(false)
                }
            }
            .frame(height: 76)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
        }
    }

    /// Betreff + Text je Sprache, Platzhalter-Liste, Vorschau mit Beispieldaten.
    private var mailTextEditor: some View {
        VStack(alignment: .leading, spacing: Theme.s8) {
            mailField("EN", subject: $state.mailSubjectEN, body: $state.mailBodyEN,
                      defaultBody: MailInvite.defaultBodyEN, focus: !L.inviteIsDE)
            mailField("DE", subject: $state.mailSubjectDE, body: $state.mailBodyDE,
                      defaultBody: MailInvite.defaultBodyDE, focus: L.inviteIsDE)
            inviteTextField("EN", text: $state.inviteTextEN, placeholder: MailInvite.defaultInviteTextEN)
            inviteTextField("DE", text: $state.inviteTextDE, placeholder: MailInvite.defaultInviteTextDE)
            Text(L.t("Platzhalter: {title} {date} {time} {times} {duration} {link} (auch deutsch: {titel} {datum} {zeit} {zeiten} {dauer}). Unbekannte bleiben stehen. Die Sprache folgt der Einladungssprache.",
                     "Placeholders: {title} {date} {time} {times} {duration} {link} (German also works: {titel} {datum} {zeit} {zeiten} {dauer}). Unknown ones stay as typed. The language follows the invite language."))
                .themeNote()
            mailPreview
        }
        .onAppear {
            // Zahnrad im Termin-Fenster: Betreff fokussieren.
            if focusMailSubject {
                focusMailSubject = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { mailSubjectFocused = true }
            }
        }
    }

    private var mailPreview: some View {
        let s = Date().addingTimeInterval(3600)
        let f = MailInvite.Fields(title: L.t("Call mit Anna", "Call with Anna"), start: s, end: s.addingTimeInterval(1800),
                                  link: "https://meet.google.com/abc-defg-hij", zoneIDs: ZoneBook.shared.invitedIDs, labels: ZoneBook.shared.labels, de: L.inviteIsDE)
        let de = L.inviteIsDE
        let subj = (de ? state.mailSubjectDE : state.mailSubjectEN)
        let body = (de ? state.mailBodyDE : state.mailBodyEN)
        let text = MailInvite.render(subj.isEmpty ? MailInvite.defaultSubject : subj, f) + "\n\n"
            + MailInvite.render(body.isEmpty ? (de ? MailInvite.defaultBodyDE : MailInvite.defaultBodyEN) : body, f)
        return VStack(alignment: .leading, spacing: Theme.s4) {
            Text(L.t("Vorschau", "Preview")).font(.theme(.small, .semibold)).foregroundStyle(Theme.muted)
            Text(text).font(.theme(.small)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    // MARK: - Tab: Meetings (Runde 111b: Google, Beitreten, Mail an Gäste)

    private var meetingsTab: some View {
        meetingsTabBody
            .onAppear {
                // Zahnrad / "Vorlage bearbeiten": Mailtext aufklappen (vor dem Löschen des Merkers).
                if UserDefaults.standard.string(forKey: "settingsScrollTo") == "mailText" {
                    mailTextOpen = true; focusMailSubject = true
                }
            }
    }

    private var meetingsTabBody: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            // Google ganz oben.
            if google.hasConfig {
                googleStatus
                ThemeSectionDivider()
            }

            ThemeSectionTitle(L.t("Beitreten", "Joining"))
            Toggle(L.t("Auto-Beitreten (10s vorher)", "Auto-join (10s before)"), isOn: $state.autoJoin).font(.theme(.normal))
            Toggle(L.t("Meet-Links im richtigen Account öffnen", "Open Meet links in the right account"),
                   isOn: $state.meetRoutingEnabled).font(.theme(.normal))
            if state.meetRoutingEnabled {
                HStack(spacing: Theme.s8) {
                    Text(L.t("Konto", "Account")).font(.theme(.normal)).foregroundStyle(Theme.label)
                    TextField("you@work-domain.example", text: Binding(
                        get: { state.effectiveMeetAccount },
                        set: { state.meetRoutingAccount = $0.trimmingCharacters(in: .whitespaces) }
                    ))
                    .textFieldStyle(ThemeFieldStyle())
                }
                Text(L.t("Öffnet Google Meet in Chrome direkt mit diesem Account (authuser). Muss in Chrome eingeloggt sein.",
                         "Opens Google Meet in Chrome as this account (authuser). It must be signed into Chrome."))
                    .themeNote()
            }

            ThemeSectionDivider()
            ThemeSectionTitle(L.t("Nach dem Erstellen", "After creating"))
            Toggle(L.t("Nach dem Erstellen Ergebnis anzeigen", "Show result after creating"),
                   isOn: $state.showResultAfterCreate).font(.theme(.normal))
            if !state.showResultAfterCreate {
                Text(L.t("Das Fenster schließt sich direkt nach dem Erstellen. Kalenderdatei und Zwischenablage laufen trotzdem wie eingestellt.",
                         "The window closes right after creating. Calendar file and clipboard still work as set."))
                    .themeNote()
            }
            Toggle(L.t("Widget nach dem Erstellen offen lassen", "Keep widget open after creating"),
                   isOn: $state.keepWidgetOpenAfterCreate).font(.theme(.normal))
            Text(L.t("Aus: Das Widget schließt sich nach einem erfolgreichen „New Meeting“. Gilt nicht fürs Sofort-Meeting.",
                     "Off: the widget closes after a successful New Meeting. Does not apply to the instant meeting."))
                .themeNote()
            Toggle(L.t("Meetings automatisch transkribieren", "Auto-transcribe meetings"),
                   isOn: $state.autoTranscribe).font(.theme(.normal))
            if state.autoTranscribe {
                Text(L.t("Nur für Meetings, die du hier erstellst. Braucht eine Workspace-Edition mit Auto-Transkript UND die aktivierte Meet-API im Google-Projekt. Greift das nicht, hier aus lassen und im Meeting manuell starten (drei Punkte → Transkript).",
                         "Only for meetings you create here. Needs a Workspace edition with auto-transcripts AND the Meet API enabled in your Google project. If that is not the case, leave this off and start it inside the meeting (three dots → Transcript)."))
                    .themeNote()
                Self.lastAttemptNote(prefix: "lastTranscript")
            }
            // Runde 124: Gemini-Notizen per Meet-API (smartNotesConfig), getrennt vom Transkript.
            Toggle(L.t("Gemini-Notizen automatisch starten", "Start Gemini notes automatically"),
                   isOn: $state.autoSmartNotes).font(.theme(.normal))
            if state.autoSmartNotes {
                Text(L.t("Gemini schreibt die Notizen, sobald du beitrittst. Braucht einen Google-Tarif mit Gemini.",
                         "Gemini takes notes as soon as you join. Needs a Google plan with Gemini."))
                    .themeNote()
                Self.lastAttemptNote(prefix: "lastSmartNotes")
            }
            if state.autoTranscribe || state.autoSmartNotes {
                Text(L.t("Sprache (Deutsch/Englisch) stellt Google selbst ein, die App kann sie nicht setzen. Ändern: im Meeting bei „Meeting language“ oder vorher in Google Kalender › Videoanruf-Optionen › Meeting records.",
                         "Google sets the language (German/English) itself, the app cannot set it. Change it in the meeting under “Meeting language” or beforehand in Google Calendar › Video call options › Meeting records."))
                    .themeNote()
            }

            ThemeSectionDivider()
            ThemeSectionTitle(L.t("Mail an Gäste", "Email to guests"))
            Toggle(L.t("Kalenderdatei (.ics) an die Mail hängen", "Attach the calendar file (.ics) to the mail"),
                   isOn: $state.mailAttachICS).font(.theme(.normal))
            if google.hasConfig {
                if google.canSendMail {
                    Text(L.t("Im Termin-Fenster erscheint ein Feld „Gast-E-Mail“. Die Mail geht von deinem verbundenen Google-Konto. Die Adresse wird nirgends gespeichert.",
                             "The New Meeting window shows a “Guest email” field. The mail is sent from your connected Google account. The address is never stored."))
                        .themeNote()
                } else {
                    Text(L.t("Google einmal neu verbinden, damit MeetingBlitz Mails senden darf (Häkchen bei „E-Mails senden“). Im Google-Projekt muss die Gmail API eingeschaltet sein.",
                             "Reconnect Google once so MeetingBlitz may send mail (tick “Send email”). The Gmail API must be turned on in your Google project."))
                        .themeNote()
                    ThemeTextRow(title: L.t("Google neu verbinden", "Reconnect Google"), accent: true) {
                        Task { await google.connect() }
                    }
                    .themeRowList()
                }
            }
            VStack(spacing: 0) {
                ThemeDisclosureRow(title: L.t("Mailtext bearbeiten", "Edit mail text"), isOpen: mailTextOpen) {
                    withAnimation(Theme.fold) { mailTextOpen.toggle() }
                }
                .id("mailText")
                ThemeFold(isOpen: mailTextOpen) { mailTextEditor }
            }
            if let err = google.lastError {
                ErrorLine(text: err)
            }
        }
    }

    /// Google-Verbindung (oben im Reiter Meetings).
    private var googleStatus: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            if google.isConnected {
                HStack(spacing: Theme.s8) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(L.t("Verbunden", "Connected")).font(.theme(.small)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button(L.t("Trennen", "Disconnect")) { google.disconnect() }
                        .font(.theme(.normal)).buttonStyle(ThemeLinkStyle())
                }
                // Runde 111c: volle Adresse in eigener Zeile.
                if let mail = google.accountEmail, !state.meetRoutingEnabled {   // Runde 112 (Fund 6): Konto nur einmal zeigen
                    Text(mail).font(.theme(.small)).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            } else {
                Button(google.busy ? L.t("Verbinde…", "Connecting…")
                       : google.needsReconnect ? L.t("Google neu verbinden", "Reconnect Google")
                                               : L.t("Mit Google verbinden", "Connect Google")) {
                    Task { await google.connect() }
                }
                .font(.theme(.normal)).buttonStyle(ThemeLinkStyle()).disabled(google.busy)
                if google.needsReconnect {
                    Text(L.t("Die Sitzung ist abgelaufen. Steht der OAuth-Client in der Google Cloud Console noch auf „Testing“, gelten Tokens nur 7 Tage. Einmal auf „In Produktion“ veröffentlichen beendet das dauerhaft.",
                             "The session expired. While the OAuth client sits in “Testing” in the Google Cloud Console, tokens only last 7 days. Publishing it to production ends this for good."))
                        .themeNote()
                }
            }
        }
    }

    // MARK: - Tab: Banner (Runde 115)

    private var bannerTab: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            ThemeSectionTitle(L.t("Flugobjekt", "Flying object"))
            ThemeChoiceRow(title: L.t("Balkengröße", "Bar size"), options: [(L.t("Klein", "Small"), 1.0)] + [(L.t("Mittel", "Medium"), 1.18)] + [(L.t("Groß", "Large"), 1.35)], selection: $state.bannerScale)
            Text(L.t("Betrifft nur den Balken mit Titel und Knöpfen. Das Flugobjekt bleibt gleich groß.",
                     "Affects only the bar with the title and buttons. The flying object keeps its size."))
                .themeNote()
            Text(state.currentSkinElement == .air
                 ? L.t("Luft-Motiv: sinkt beim Auftritt von oben herab, der Balken baut sich von links auf.",
                       "Air motif: drops in from above while the bar builds up from the left.")
                 : L.t("Wasser-Motiv: taucht beim Auftritt von unten auf, der Balken baut sich von links auf.",
                       "Water motif: surfaces from below while the bar builds up from the left."))
                .themeNote()
            if NSScreen.screens.count > 1 { multiScreenRows }
            Button(L.t("Test-Blinken", "Test blink")) { state.startMeetingBlink() }
                .font(.theme(.normal)).buttonStyle(ThemeLinkStyle()).themeRowList()
                .help(L.t("So blinkt die Menüleiste, wenn ein Meeting startet", "How the menu bar blinks when a meeting starts"))
            VStack(spacing: 0) {
                ThemeDisclosureRow(title: L.t("Motive", "Motifs"), value: L.t("Auswahl und Wechsel", "Choice and rotation"), isOpen: skinOpen) {
                    withAnimation(Theme.fold) { skinOpen.toggle() }
                }
                ThemeFold(isOpen: skinOpen) { skinSection }
            }
        }
    }

    // MARK: - Tab: Erweitert

    @State private var skinOpen = false
    @State private var statsOpen = false

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            ThemeSectionTitle(L.t("Menüleiste, Details", "Menu bar details"))
            VStack(alignment: .leading, spacing: Theme.s4) {
                ThemeChoiceRow(title: L.t("Titel-Länge", "Title length"), options: Array(MenuBarTitleLength.allCases).map { ($0.label, $0) }, selection: $state.menuBarTitleLength)
                Text(L.t("Verschwinden andere Symbole hinter der Kamera-Aussparung, eine Stufe kürzer wählen. Die Uhrzeit bleibt immer ganz stehen.",
                         "If other icons vanish behind the notch, pick a shorter step. The time always stays in full."))
                    .themeNote()
            }
            .disabled(state.menuBarStyle != .titleAndCountdown)
            .opacity(state.menuBarStyle == .titleAndCountdown ? 1 : 0.45)
            ThemeChoiceRow(title: L.t("Termine ohne Scrollen", "Events before scrolling"), options: Array([6, 8, 10, 15]).map { ("\($0)", $0) } + [(L.t("Alle", "All"), 0)], selection: $state.agendaMaxRows)
            Text(L.t("Hat ein Tag mehr Termine, lässt sich die Liste im Widget scrollen.",
                     "If a day has more events, the list in the widget scrolls."))
                .themeNote()

            ThemeSectionDivider()
            ThemeSectionTitle(L.t("Auswertung", "Stats"))
            VStack(spacing: 0) {
                ThemeDisclosureRow(title: L.t("Meetings pro Woche, Monat, Jahr", "Meetings per week, month, year"), isOpen: statsOpen) {
                    withAnimation(Theme.fold) { statsOpen.toggle() }
                }
                ThemeFold(isOpen: statsOpen) { statsTab }
            }

            ThemeSectionDivider()
            ThemeSectionTitle(L.t("Claude", "Claude"))
            mcpSection

            ThemeSectionDivider()
            ThemeSectionTitle(L.t("Fenster & Einführung", "Windows & walkthrough"))
            HStack(spacing: Theme.s8) {
                Text(L.t("Panel-Position", "Panel position")).font(.theme(.normal))
                Spacer()
                Button(L.t("Zurücksetzen", "Reset")) { PanelDock.forgetPositions() }
                    .font(.theme(.normal)).buttonStyle(ThemeLinkStyle())
            }
            .themeRow()
            HStack(spacing: Theme.s8) {
                Text(L.t("Einführung", "Walkthrough")).font(.theme(.normal))
                Spacer()
                Button(L.t("Nochmal zeigen", "Show again")) {
                    OnboardingPanelController.shared.show(state: state)
                }
                .font(.theme(.normal)).buttonStyle(ThemeLinkStyle())
            }
            .themeRow()

            ThemeSectionDivider()
            HStack(spacing: Theme.s16) {
                Button(L.t("MeetingBlitz neu starten", "Restart MeetingBlitz")) {
                    NotificationCenter.default.post(name: .meetingBlitzRestart, object: nil)
                }
                Button(L.t("MeetingBlitz beenden", "Quit MeetingBlitz")) { NSApp.terminate(nil) }
                Spacer(minLength: 0)
            }
            .font(.theme(.normal)).buttonStyle(ThemeLinkStyle()).themeRowList()
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
        return HStack(spacing: Theme.s8) {
            Text(title).font(.theme(.normal))
            Spacer()
            Text(isRecording ? L.t("Taste drücken…", "Press keys…") : label)
                .font(.theme(.small, .semibold).monospaced())
                .foregroundStyle(isRecording ? Theme.blue : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                    .fill(isRecording ? Theme.blue.opacity(0.15) : Color.primary.opacity(0.08)))
            Button(isRecording ? L.t("Abbrechen", "Cancel") : L.t("Ändern", "Change")) {
                if isRecording { stopRecording() } else { startRecording(action) }
            }
            .font(.theme(.small)).buttonStyle(ThemeLinkStyle())
        }
        .themeRow()
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

    /// Runde 111b: fünf beschriftete Reiter, Symbol über kurzem Wort (Apple-Muster der Einstellungsfenster).
    /// Das gewählte Feld ist blau hinterlegt; "Erweitert" steht abgesetzt.
    private var tabBar: some View {
        HStack(spacing: Theme.s4) {
            ForEach(Self.tabs, id: \.id) { t in
                if t.id == 4 {
                    // Runde 123: "Advanced" bewusst abgesetzt, jetzt mit feinem Trennstrich, damit es gewollt aussieht.
                    Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 1, height: 30)
                        .padding(.horizontal, Theme.s4)
                }
                SettingsTabButton(symbol: t.icon, label: title(for: t.id), selected: tab == t.id) { tab = t.id }
            }
        }
        .padding(Theme.s4)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
    }

    static func shortStamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "dd.MM. HH:mm"; return f.string(from: d)
    }

    /// Runde 124: „Letzter Versuch" für Transkript (lastTranscript…) oder Gemini-Notizen (lastSmartNotes…).
    @ViewBuilder static func lastAttemptNote(prefix: String) -> some View {
        if let n = UserDefaults.standard.string(forKey: prefix + "Note"), !n.isEmpty,
           let when = UserDefaults.standard.object(forKey: prefix + "Date") as? Date {
            Text(L.t("Letzter Versuch (\(shortStamp(when))): \(n)",
                     "Last attempt (\(shortStamp(when))): \(n)"))
                .themeNote()
        }
    }

    private static let tabs: [(id: Int, icon: String)] = [
        (0, "gearshape"), (1, "bell"), (2, "calendar"), (3, "video"), (5, "bolt.horizontal"), (4, "slider.horizontal.3"),
    ]

    private func title(for id: Int) -> String {
        switch id {
        case 1:  return L.t("Hinweise", "Alerts")
        case 2:  return L.t("Kalender", "Calendars")
        case 3:  return L.t("Meetings", "Meetings")
        case 4:  return L.t("Erweitert", "Advanced")
        case 5:  return L.t("Banner", "Banner")
        default: return L.t("Allgemein", "General")
        }
    }

    private var tabTitle: String { title(for: tab) }

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
    /// Zeile der Kalenderliste: Titel + Konto (2 Zeilen) + 2×3 pt + 1 pt Abstand.
    private static let calendarRowHeight: CGFloat = 37

    private func targetCalendarRow(google isGoogle: Bool) -> some View {
        let writable = (CreatePane.demoCalendars ?? state.calendar.writableCalendars())
            .filter { $0.isAppleAccount != isGoogle }
        let currentID = isGoogle ? state.googleTargetCalendarID : state.appleTargetCalendarID
        let current = writable.first { $0.id == currentID }
        let open = isGoogle ? gcalListOpen : acalListOpen
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.fold) {
                    if isGoogle { gcalListOpen.toggle() } else { acalListOpen.toggle() }
                }
            } label: {
                HStack(spacing: Theme.s8) {
                    // Stehen beide Zeilen untereinander, muss die Beschriftung
                    // sagen, welche welche ist.
                    Text(usesGoogleAnywhere && usesAppleAnywhere
                         ? (isGoogle ? "Google" : "Apple")
                         : L.t("Kalender", "Calendar"))
                        .font(.theme(.normal)).foregroundStyle(Theme.label)
                    Spacer()
                    Circle().fill(current?.color ?? .gray).frame(width: 8, height: 8)
                    // Auf der Apple-Seite ist "nichts gewählt" gültig (dann
                    // greift der Systemstandard), auf der Google-Seite nicht.
                    Text(current?.title
                         ?? (isGoogle ? L.t("Bitte wählen", "Pick one")
                                      : L.t("Standard", "Default")))
                        .font(.theme(.normal)).lineLimit(1)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.theme(.small, .semibold)).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ThemeLinkStyle())
            ThemeFold(isOpen: open) {
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
                                withAnimation(Theme.fold) {
                                    if isGoogle { gcalListOpen = false } else { acalListOpen = false }
                                }
                            } label: {
                                HStack(spacing: Theme.s8) {
                                    Circle().fill(c.color).frame(width: 8, height: 8)
                                    // Konto dazu: „Work" kann es in iCloud UND
                                    // in Google geben, ohne Quelle wählt man blind.
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(c.title).font(.theme(.normal)).lineLimit(1)
                                        if !c.sourceTitle.isEmpty {
                                            Text(c.sourceTitle)
                                                .font(.theme(.small)).foregroundStyle(Theme.muted)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if c.id == currentID {
                                        Image(systemName: "checkmark")
                                            .font(.theme(.small, .semibold))
                                            .foregroundStyle(Theme.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 3).padding(.horizontal, 6)
                                .background(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                                    .fill(c.id == currentID
                                          ? Theme.blue.opacity(0.14) : .clear))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                // Runde 109e: so hoch wie die Einträge (höchstens 5, Rest scrollt), kein Leerraum.
                // Feste Höhe nötig: ScrollView hat keine intrinsische (Runde 14).
                .frame(height: CGFloat(min(max(writable.count, 1), 5)) * Self.calendarRowHeight)
            }
        }
    }

    /// F1: zone picker, short list plus validated free text. No .menu picker,
    /// that hangs in nonactivating panels (Runde 13).
    private var zoneRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.fold) { zoneListOpen.toggle() }
            } label: {
                HStack(spacing: Theme.s8) {
                    Text(L.t("Zone", "Zone")).font(.theme(.normal)).foregroundStyle(.primary)
                    Spacer()
                    Text(MenuPanel.zoneCity(state.secondZoneID)).font(.theme(.normal)).lineLimit(1)
                    Image(systemName: zoneListOpen ? "chevron.up" : "chevron.down")
                        .font(.theme(.small, .semibold)).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ThemeLinkStyle())
            ThemeFold(isOpen: zoneListOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Self.zoneChoices, id: \.self) { id in
                        Button {
                            state.secondZoneID = id
                            zoneCustomBad = false
                            withAnimation(Theme.fold) { zoneListOpen = false }
                        } label: {
                            HStack {
                                Text(MenuPanel.zoneCity(id)).font(.theme(.normal))
                                Spacer()
                                if id == state.secondZoneID {
                                    Image(systemName: "checkmark")
                                        .font(.theme(.small, .semibold))
                                        .foregroundStyle(Theme.blue)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                                .fill(id == state.secondZoneID
                                      ? Theme.blue.opacity(0.14) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                    TextField(L.t("Eigene, z. B. Europe/Paris", "Custom, e.g. Europe/Paris"),
                              text: $zoneCustom)
                        .textFieldStyle(ThemeFieldStyle())
                        .onSubmit {
                            let t = zoneCustom.trimmingCharacters(in: .whitespaces)
                            if TimeZone(identifier: t) != nil {
                                state.secondZoneID = t
                                zoneCustomBad = false
                                withAnimation(Theme.fold) { zoneListOpen = false }
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
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            if let s = statsCache {
                statsBlock(L.t("Diese Woche", "This week"), s.week)
                ThemeSectionDivider()
                statsBlock(L.t("Dieser Monat", "This month"), s.month)
                ThemeSectionDivider()
                statsBlock(L.t("Dieses Jahr", "This year"), s.year)
                ThemeSectionDivider()
            } else {
                Text(L.t("Wird berechnet…", "Calculating…"))
                    .font(.theme(.small)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack(spacing: 8) {
                legendDot(Theme.blue, L.t("Calls", "calls"))
                legendDot(Theme.blue.opacity(0.28), L.t("andere Termine", "other events"))
                Spacer()
            }
            Text(L.t("Getimte Termine der angezeigten Kalender. Ganztägige und Geburtstage bleiben außen vor.",
                     "Timed events from the shown calendars. All-day events and birthdays are excluded."))
                .themeNote()
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
        HStack(spacing: Theme.s4) {
            RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous).fill(c).frame(width: 8, height: 8)
            Text(label).font(.theme(.small)).foregroundStyle(Theme.muted)
        }
    }

    private func statsBlock(_ title: String, _ s: MeetingStats) -> some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.theme(.normal, .semibold))
                Spacer()
                Text("\(L.number(s.count)) \(s.count == 1 ? L.t("Termin", "event") : L.t("Termine", "events")) · \(s.hoursLabel)")
                    .font(.theme(.small, .semibold).monospacedDigit())
                    .foregroundStyle(Theme.blue)
            }
            barChart(s.bars)
            HStack(spacing: 0) {
                statCell(L.number(s.callCount), L.t("Calls", "calls"))
                statCell(s.callHoursLabel, L.t("in Calls", "in calls"))
                statCell(s.count > 0 ? MeetingStats.hm(s.minutes / max(1, s.count)) : "–",
                         L.t("pro Termin", "per event"))
            }
            if let b = s.busiestDay {
                Text(L.t("Vollster Tag: \(b.label) · \(MeetingStats.hm(b.minutes))",
                         "Busiest day: \(b.label) · \(MeetingStats.hm(b.minutes))"))
                    .font(.theme(.small)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
    }

    /// Selbst gezeichnete Balken statt Swift Charts: dessen System-Styling
    /// rendert im nie aktiven Panel genauso blass wie andere System-Controls
    /// (Runde 6/31), und hier zählt jeder Punkt Breite.
    /// Heller Anteil = alle Termine, satter Anteil = davon Videocalls.
    private func barChart(_ bars: [StatBar]) -> some View {
        let peak = max(bars.map(\.minutes).max() ?? 0, 60)   // mind. 1 h, sonst wirken Kleinigkeiten riesig
        return HStack(alignment: .bottom, spacing: Theme.s4) {
            ForEach(bars) { b in
                VStack(spacing: Theme.s4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.07))          // Grundfläche = Maßstab
                        RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                            .fill(Theme.blue.opacity(0.28))
                            .frame(height: barHeight(b.minutes, peak))
                        RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                            .fill(Theme.blue)
                            .frame(height: barHeight(b.callMinutes, peak))
                    }
                    .frame(height: 46, alignment: .bottom)
                    Text(b.label)
                        .font(.theme(.small, b.isNow ? .bold : .regular))
                        .foregroundStyle(b.isNow ? Theme.blue : Color.secondary)
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
            Text(value).font(.theme(.normal, .semibold)).monospacedDigit()
            Text(label).font(.theme(.small)).foregroundStyle(Theme.muted)
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


/// Runde 110b: Höhe des Einstellungs-Fensters, damit die SwiftUI-Wurzel genau so hoch ist (oben verankert).
@MainActor
final class SettingsLayout: ObservableObject {
    static let shared = SettingsLayout()
    @Published var height: CGFloat?
    /// Runde 114: sichtbare Höhe des Bildschirms, auf dem das Einstellungs-Fenster steht.
    @Published var screenHeight: CGFloat?
    func setScreen(_ h: CGFloat?) {
        guard screenHeight != h else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { screenHeight = h }
    }
    func set(_ h: CGFloat?) {
        guard height != h else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { height = h }
    }
}
