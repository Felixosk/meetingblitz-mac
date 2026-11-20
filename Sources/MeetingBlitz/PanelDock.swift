import AppKit

/// Wo die Begleit-Panels (Einstellungen, „Neues Meeting") landen (Runde 47g).
///
/// **Vorher:** mittig UNTER dem Widget. Das Widget hängt an der Menüleiste und
/// ist mit Timeline, Agenda und Erinnerungen selbst schnell ~500pt hoch,
/// darunter bleiben von ~1140pt sichtbarer Höhe nur noch ~600pt. Sobald im
/// „Neues Meeting"-Panel ein Abschnitt aufklappte (benutzerdefinierte
/// Wiederholung, Kalenderliste), rutschte der Erstellen-Button unter den
/// Bildschirmrand. Genau das wurde dreimal gemeldet, die Höhe des Formulars
/// war nie das eigentliche Problem, sondern der Platz, den wir ihm gegeben haben.
///
/// **Jetzt:** NEBEN dem Widget, oben bündig, dort steht die volle
/// Bildschirmhöhe zur Verfügung. Links zuerst (das Widget klebt oben rechts),
/// sonst rechts daneben, sonst wie früher mittig darunter. Zusätzlich klemmt
/// `clampY` das Panel immer vollständig in den sichtbaren Bereich, auch beim
/// Wachsen.
enum PanelDock {

    /// Fenster-Verhalten für die Begleit-Panels (Einstellungen, „Neues
    /// Meeting", Einführung). **Muss dasselbe sein wie beim Widget**
    /// (`WidgetPanel.swift`), sonst passiert Folgendes:
    ///
    /// Ein Fenster ohne `.canJoinAllSpaces` gehört zu genau EINEM Schreibtisch.
    /// Sitzt der Nutzer gerade in einer Vollbild-App, hat macOS dafür einen
    /// eigenen Schreibtisch angelegt. Das Widget darf dort hinein (es hat die
    /// Eigenschaft), die Panels durften es nicht: sie öffneten sich brav, aber
    /// auf dem Schreibtisch daneben. Auf dem Bildschirm passierte sichtbar
    /// NICHTS, kein Fehler, kein Absturz, kein Log. Gemeldet wurde das als
    /// „ich klicke auf Einstellungen und es passiert nichts" (22.08.2026).
    ///
    /// `.fullScreenAuxiliary` allein reicht nicht: das erlaubt nur den Auftritt
    /// über einer Vollbild-App der EIGENEN App, und MeetingBlitz hat keine.
    ///
    /// Der Duplizier-Fehler aus Runde 13 (`.canJoinAllSpaces` zeigt ein Panel
    /// auf JEDEM Bildschirm gleichzeitig) trifft nur WANDERNDE Fenster, also
    /// die Banner. Für stehende Fenster wie Widget und Panels ist es richtig.
    static let companionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    /// Ursprung (unten links, AppKit-Koordinaten) für ein Panel dieser Größe.
    /// Runde 110: `stage` = durchsichtiger Bühnenrand des Fensters, `anchor` = GLAS-Rahmen
    /// des Nachbarn. Gerechnet wird mit dem Glas, der Rückgabewert ist der Fensterursprung.
    /// `rightAnchor`: reicht links vom `anchor` der Platz nicht, steht das Fenster RECHTS von diesem Rahmen
    /// (statt rechts vom `anchor`; z. B. Einstellungen links vom Termin-Fenster, sonst rechts vom Widget).
    static func origin(panelSize full: CGSize, anchor: CGRect?, gap: CGFloat = Theme.s8, stage: CGFloat = 0,
                       rightAnchor: CGRect? = nil) -> NSPoint {
        let panelSize = CGSize(width: full.width - 2 * stage, height: full.height - 2 * stage)
        let o = glassOrigin(panelSize: panelSize, anchor: anchor, gap: gap, rightAnchor: rightAnchor)
        return NSPoint(x: o.x - stage, y: o.y - stage)
    }

    private static func glassOrigin(panelSize: CGSize, anchor: CGRect?, gap: CGFloat, rightAnchor: CGRect? = nil) -> NSPoint {
        guard let a = anchor else {
            let m = NSEvent.mouseLocation
            return NSPoint(x: (m.x - panelSize.width / 2).rounded(),
                           y: (m.y - panelSize.height - 24).rounded())
        }
        let vf = visibleFrame(containing: a) ?? a

        var x = a.minX - panelSize.width - gap                 // links daneben
        if x < vf.minX + 8 {
            let right = (rightAnchor ?? a).maxX + gap           // sonst rechts daneben
            x = (right + panelSize.width <= vf.maxX - 8) ? right : a.midX - panelSize.width / 2
        }
        x = min(max(x, vf.minX + 8), vf.maxX - panelSize.width - 8)

        // Oben bündig mit dem Widget, dann in den sichtbaren Bereich klemmen.
        // Runde 99: Das Widget hängt nur ~5 pt unter der Menüleiste. Mit dem
        // normalen 8-pt-Rand säße das Panel dann 3 pt TIEFER als das Widget.
        // Deshalb darf der Rand oben so klein sein wie der des Widgets.
        let topMargin = max(0, min(8, vf.maxY - a.maxY))
        let y = clampY(a.maxY - panelSize.height, height: panelSize.height, vf: vf, topMargin: topMargin)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    /// Hält das Panel vollständig im sichtbaren Bereich. Ist es höher als der
    /// Bildschirm (Notfall), gewinnt die Unterkante, dort sitzt der Button.
    static func clampY(_ y: CGFloat, height: CGFloat, vf: CGRect, topMargin: CGFloat = 8) -> CGFloat {
        let lo = vf.minY + 8
        let hi = vf.maxY - height - topMargin
        return hi < lo ? lo : min(max(y, lo), hi)
    }

    /// Runde 114 (Punkt 4): Liegen beide Rechtecke (Mittelpunkt) auf demselben Bildschirm? Ein Fenster, das der Nutzer
    /// auf einen anderen Bildschirm gestellt hat, dockt nicht mehr ans Widget zurück.
    static func sameScreen(_ a: CGRect, _ b: CGRect) -> Bool {
        func scr(_ r: CGRect) -> NSScreen? { NSScreen.screens.first { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) } }
        guard let sa = scr(a), let sb = scr(b) else { return true }
        return sa == sb
    }

    static func visibleFrame(containing rect: CGRect) -> CGRect? {
        (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.visibleFrame
    }

    // MARK: - Gemerkte Position (Runde 47h)

    /// gemeldet wurde: zwei Screenshots geschickt: „so ist es" (neben dem Widget) und
    /// „so sollte es sein" (weiter links, tiefer). Die zweite Position war von
    /// Hand hingezogen, die kann keine Formel raten. Also merkt sich die App
    /// jetzt, wohin er ein Panel schiebt: einmal ziehen, danach öffnet es immer
    /// dort. Der Automatik-Platz neben dem Widget bleibt nur die Vorgabe fürs
    /// erste Mal.
    ///
    /// Gespeichert wird die OBERE linke Ecke, nicht der AppKit-Ursprung: die
    /// Panelhöhe ändert sich beim Auf- und Zuklappen, die Oberkante ist das,
    /// was optisch stehen bleiben soll.
    /// Runde 110: Schlüssel V2 = Ecke des GLASES (nicht des Fensters mit Bühne).
    /// Der alte Wert (Glas = Fenster) wird einmal übernommen und gelöscht.
    private static func key(_ id: String) -> String {
        let v2 = "panelTopLeftV2_\(id)", old = "panelTopLeft_\(id)"
        let ud = UserDefaults.standard
        if ud.object(forKey: v2) == nil, let o = ud.dictionary(forKey: old) { ud.set(o, forKey: v2) }
        ud.removeObject(forKey: old)
        return v2
    }

    /// Nur Fensterhöhe/-ursprung → Glas-Y klemmen (Bühnenrand zählt nicht zum sichtbaren Bereich).
    static func clampedWindowY(frame f: CGRect, newHeight h: CGFloat? = nil, vf: CGRect, stage: CGFloat) -> CGFloat {
        let height = h ?? f.height
        let glassH = height - 2 * stage
        let glassTop = f.maxY - stage
        let top = max(0, min(8, vf.maxY - glassTop))
        let y = clampY(glassTop - glassH, height: glassH, vf: vf, topMargin: top)
        return y - stage
    }

    static func storeTopLeft(_ p: NSPoint, id: String) {
        UserDefaults.standard.set(["x": Double(p.x), "y": Double(p.y)], forKey: key(id))
    }

    /// Gemerkter Ursprung für diese Panelgröße, oder nil, wenn es nichts
    /// Gemerktes gibt oder die Position auf keinem angeschlossenen Bildschirm
    /// mehr liegt (Monitor abgesteckt, Auflösung geändert).
    static func savedOrigin(panelSize full: CGSize, id: String, anchor: CGRect? = nil, stage: CGFloat = 0) -> NSPoint? {
        let panelSize = CGSize(width: full.width - 2 * stage, height: full.height - 2 * stage)
        // Runde 99: Ist das Widget offen, gilt IMMER der Platz neben dem Widget
        // (Oberkante exakt gleich, Abstand s8). Die gemerkte Position greift nur
        // noch, wenn das Widget zu ist.
        if anchor != nil { return nil }
        guard let d = UserDefaults.standard.dictionary(forKey: key(id)),
              let storedX = d["x"] as? Double, let storedTop = d["y"] as? Double
        else { return nil }
        let x = CGFloat(storedX), top = CGFloat(storedTop)

        // Die Titelleiste muss sichtbar bleiben, sonst ist das Panel nicht mehr
        // greifbar, deshalb gegen die Oberkante prüfen, nicht gegen den Rahmen.
        let probe = CGRect(x: x, y: top - 20, width: min(panelSize.width, 120), height: 20)
        guard let vf = visibleFrame(containing: probe), vf.intersects(probe) else { return nil }

        let clampedX = min(max(x, vf.minX + 8), vf.maxX - panelSize.width - 8)
        let y = clampY(top - panelSize.height, height: panelSize.height, vf: vf)
        return NSPoint(x: clampedX.rounded() - stage, y: y.rounded() - stage)
    }

    /// Letzte Instanz kurz nach dem Öffnen: Liegt das Panel trotz aller
    /// Platzierungslogik nirgends Sichtbares, wird es mittig auf den Bildschirm
    /// der Maus gezwungen.
    ///
    /// **Warum das sein muss (23.08.2026):** Ein Nutzer sah sein
    /// Einstellungsfenster auf KEINEM seiner zwei Bildschirme, obwohl die App
    /// aktuell war und das Widget reagierte. Ein Fenster kann aus zwei Gründen
    /// offen und trotzdem unsichtbar sein: es liegt außerhalb aller Bildschirme,
    /// oder es ist in seiner Phantomgröße steckengeblieben (`fittingSize` meldet
    /// beim Erstellen gern ~0×24, siehe Runde 47i/56c) und nie gewachsen. Beide
    /// Fälle sehen für den Nutzer gleich aus: er klickt, nichts passiert.
    ///
    /// Rückgabe = Grund, falls eingegriffen wurde. Der landet im Diagnosebericht,
    /// damit aus der Notbremse eine Messung wird und nicht bloß ein Pflaster,
    /// das die Ursache zudeckt.
    @MainActor
    @discardableResult
    static func enforceVisible(_ p: NSPanel, minSize: CGSize = CGSize(width: 300, height: 420)) -> String? {
        let f = p.frame
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(f) }
        let bigEnough = f.width >= 80 && f.height >= 80
        if onScreen && bigEnough { return nil }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return nil }
        let size = CGSize(width: max(f.width, minSize.width), height: max(f.height, minSize.height))
        let origin = NSPoint(x: (vf.midX - size.width / 2).rounded(),
                             y: (vf.midY - size.height / 2).rounded())
        p.setFrame(CGRect(origin: origin, size: size), display: true)
        p.orderFrontRegardless()

        let reason = !onScreen && !bigEnough ? "außerhalb aller Bildschirme UND zu klein"
                   : !onScreen ? "außerhalb aller Bildschirme"
                   : "zu klein (Phantomgröße)"
        let before = String(format: "(%.0f | %.0f) %.0f×%.0f", f.minX, f.minY, f.width, f.height)
        HintWindow.log("enforceVisible: \(reason), vorher \(before)")
        return "\(reason), vorher \(before)"
    }

    /// Notausgang, falls ein Panel doch mal unerreichbar liegt: nächstes Öffnen
    /// nimmt wieder den Automatik-Platz neben dem Widget.
    static func forgetPositions() {
        for id in ["create", "settings"] { UserDefaults.standard.removeObject(forKey: key(id)) }
        for id in ["create", "settings"] { UserDefaults.standard.removeObject(forKey: "panelTopLeft_\(id)") }
    }
}

/// „Fenster zurückholen": ein Rettungsknopf für den Fall, dass ein Fenster
/// dieser App zwar offen ist, der Nutzer es aber nicht sieht.
///
/// Dafür gibt es drei Wege, und alle drei enden im selben Bild: man klickt, und
/// scheinbar passiert nichts.
///   1. Das Fenster liegt auf einem anderen Schreibtisch (Vollbild-App).
///   2. Die gemerkte Position zeigt auf einen Monitor, der nicht mehr dran ist.
///   3. Das Widget selbst hängt an einem Bildschirm, auf den keiner schaut.
///
/// Deshalb reicht Verschieben hier NICHT: Ein bereits geöffnetes Fenster
/// wechselt den Schreibtisch nicht, nur weil man seinen Rahmen ändert. Der
/// einzige verlässliche Weg ist zu, Position vergessen, neu auf.
///
/// BEWUSST kein Eintrag in den Einstellungen: Wer sein Einstellungsfenster
/// nicht sieht, kann dort nichts anklicken. Der Platz dafür ist das Menü am
/// Menüleisten-Symbol, das kommt vom System und geht immer auf.
@MainActor
enum PanelRescue {

    /// Holt alles zurück, was gerade offen sein sollte, auf den Bildschirm, auf
    /// dem die Maus steht.
    static func bringBack(state: AppState, statusButton: NSStatusBarButton?) {
        let hadSettings = SettingsPanelController.shared.isOpen
        let hadCreate = CreatePanelController.shared.isOpen

        PanelDock.forgetPositions()
        SettingsPanelController.shared.close()
        CreatePanelController.shared.close()
        if WidgetPanelController.shared.isOpen { WidgetPanelController.shared.close() }

        // Zuerst das Widget: die Begleit-Panels docken an seinen Rahmen an.
        // Läge der noch auf dem abgesteckten Monitor, wären sie sofort wieder
        // weg. `anchorToMouseScreen` setzt es dorthin, wo gerade gearbeitet wird.
        WidgetPanelController.shared.toggle(state: state, statusButton: statusButton,
                                            anchorToMouseScreen: true)

        // Einen Durchlauf später, dann steht der echte Widget-Rahmen (dieselbe
        // Phantomgrößen-Falle wie bei der Erstplatzierung der Panels, 47i).
        DispatchQueue.main.async {
            if hadSettings { state.toggleSettingsPanel() }
            if hadCreate { state.toggleCreatePanel() }
        }
    }
}

/// Schreibt die Position weg, sobald das Panel bewegt wurde.
///
/// Als NSWindowDelegate statt NotificationCenter-Observer: Delegate-Methoden
/// laufen garantiert auf dem Main-Actor, ein `@Sendable` Observer-Closure dagegen
/// darf das `Notification`-Objekt nicht über die Actor-Grenze mitnehmen (Swift-6-
/// Concurrency lehnt das ab). `window.delegate` ist WEAK, der Controller muss
/// die Instanz festhalten.
@MainActor
final class PanelMoveRecorder: NSObject, NSWindowDelegate {
    private let id: String
    /// Runde 110: Bühnenrand; gespeichert wird die Ecke des Glases.
    private let stage: CGFloat
    /// Während wir das Fenster SELBST verschieben (Panel wächst beim Aufklappen)
    /// darf nichts gespeichert werden, sonst wandert die gemerkte Position mit
    /// jedem Auf- und Zuklappen davon (Runde 47i).
    var suspended = false
    /// Runde 111 (Fund 11): vom Nutzer gezogen → der Controller dockt nicht mehr automatisch an.
    var onUserMove: (() -> Void)?

    init(id: String, stage: CGFloat = 0) { self.id = id; self.stage = stage }

    func windowDidMove(_ notification: Notification) {
        guard !suspended, let w = notification.object as? NSWindow else { return }
        onUserMove?()
        PanelDock.storeTopLeft(NSPoint(x: w.frame.minX + stage, y: w.frame.maxY - stage), id: id)
    }
}
