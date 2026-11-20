import SwiftUI
import AppKit

/// The main dropdown ("widget") as a self-managed floating panel (Runde 4).
///
/// Why not MenuBarExtra: its window closes the instant another window becomes
/// key, so opening the settings panel or Apple Calendar made the widget vanish.
///
/// Runde 6: the body is a real `NSVisualEffectView` pinned to `.active`.
/// SwiftUI's `.regularMaterial` inside a borderless panel of an accessory app
/// renders as a flat dark slab, the app is never "active", so the material
/// falls back to its inactive look, and text over a transparent window loses
/// subpixel smoothing ("unschwach"). The native, always-active material fixes
/// both, the panel gets a native window shadow, and it drops centred directly
/// under the menu-bar icon like the old MenuBarExtra window did.
@MainActor
final class WidgetPanelController {
    static let shared = WidgetPanelController()
    private var panel: NSPanel?
    /// Die Inhaltsansicht, um sie nachmessen zu können. Nötig, weil sie per
    /// `autoresizingMask` an die Panelgröße geheftet ist: der GeometryReader
    /// darin meldet dadurch IMMER die alte Höhe, kann also nie sagen „ich
    /// brauche mehr Platz". Beim Aufklappen des Kalenders wurde der Inhalt so
    /// oben abgeschnitten (die Kopfzeile mit dem Datum verschwand).
    private var hostingView: NSView?
    private var anchorX: CGFloat = 0    // menu-bar icon centre (screen coords)
    private var topY: CGFloat = 0       // fixed top edge, just below the menu bar
    private var dismissMonitors: [Any] = []
    private weak var statusWindow: NSWindow?

    /// Letzte bekannte Position, auch wenn das Widget gerade zu ist (Runde 47i).
    /// Die Begleit-Panels docken daran an; ohne diesen Fallback fiel die
    /// Positionierung auf „unter der Maus" zurück, und die steht beim Klick auf
    /// „Neues Meeting" mitten auf dem Widget, weshalb das Panel es überdeckte.
    private var lastFrame: CGRect?

    var frame: CGRect? { panel?.frame ?? lastFrame }
    /// Runde 110: Glas-Rahmen (Andockmaß). Ab Schritt 2 mit Bühnenrand.
    var glassFrame: CGRect? { frame?.insetBy(dx: Self.stage, dy: Self.stage) }
    static var stage: CGFloat { Theme.stageInset }
    var isOpen: Bool { panel?.isVisible ?? false }
    /// Runde 111b: Mitte des Menüleisten-Symbols (für den Rückgängig-Hinweis darunter), nil = unbekannt.
    var anchorCenterX: CGFloat? { anchorX == 0 ? nil : anchorX }

    func toggle(state: AppState, statusButton: NSStatusBarButton?, anchorToMouseScreen: Bool = false) {
        if isOpen { close(); return }
        if DryCreate.isOn { print("widget toggle open \(Date().timeIntervalSince1970)\n" + Thread.callStackSymbols.prefix(8).joined(separator: "\n")); fflush(stdout) }
        if let u = noReopenUntil, Date() < u, ProcessInfo.processInfo.environment["MB_DRY_NOGUARD"] == nil {
            if DryCreate.isOn { print("widget reopen blocked"); fflush(stdout) }
            return
        }
        noReopenUntil = nil

        state.showToday()        // always open on today
        state.gridDisplay = nil       // ...and with the calendar folded away
        let host = FirstMouseHostingView(rootView: MenuPanel(state: state, onSize: { size in
            DispatchQueue.main.async { MainActor.assumeIsolated { WidgetPanelController.shared.resize(to: size) } }
        }))
        host.safeAreaRegions = []   // Runde 110b: die Bühne ragt über die Menüleiste, kein Sicherheitsabstand oben
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        hostingView = host

        // Runde 90: Liquid Glass als HINTERGRUND-Geschwister der Inhaltsansicht
        // (Fallstrick 7: die Hosting-View liegt obenauf und bekommt die Klicks).
        let effect = NSView(frame: CGRect(origin: .zero, size: size))
        effect.autoresizesSubviews = true
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)

        let p = StagePanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = Theme.systemShadow  // Runde 118: weicher Systemschatten
        p.isFloatingPanel = true
        p.level = .floating               // Runde 111b (A1): NACH isFloatingPanel (das setzte die Ebene still zurück)
        // Runde 115: Aussehen kommt von NSApp.appearance (Look.apply).
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = effect

        // Anchor: centred under the status-bar button, flush below the menu bar.
        // Hotkey open (Runde 44): the status icon may be on another display or
        // hidden behind the notch, so drop from the top-right of the screen the
        // MOUSE is on instead, the widget always appears where you are looking.
        if anchorToMouseScreen {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            let vf = screen?.visibleFrame ?? .zero
            anchorX = vf.maxX - 140
            topY = vf.maxY - 5
        } else if let bf = statusButton?.window?.frame {
            anchorX = bf.midX
            topY = bf.minY - 5
        } else {
            let vf = NSScreen.main?.visibleFrame ?? .zero
            anchorX = vf.maxX - 220
            topY = vf.maxY - 5
        }
        statusWindow = statusButton?.window
        panel = p
        place(size: size)
        // Runde 111 (Fund 12): 0,12 s Einblenden statt Aufspringen in einem Bild.
        p.alphaValue = 0
        p.orderFrontRegardless()
        installDismissMonitors()
        // Runde 111c: die Animation erst starten, wenn der Inhalt zum ersten Mal GEZEICHNET ist (sonst lief sie
        // ab, bevor das Fenster sichtbar war: ein Bild). Layout + Zeichnen erzwingen, dann im nächsten Runloop.
        p.contentView?.layoutSubtreeIfNeeded()
        p.displayIfNeeded()
        DispatchQueue.main.async { [weak p] in
            guard let p else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .linear)
                p.animator().alphaValue = 1
            }
        }
    }

    /// Close the widget when the user clicks anywhere outside it, like a real
    /// menu (Rückmeldung: "wenn ich daneben klicke geht sie nicht zu"). Clicks inside
    /// the widget, inside the settings panel, or on the menu-bar icon are kept
    /// open: the icon has its own toggle, and the settings panel must survive so
    /// opening it doesn't dismiss the widget (the whole reason it isn't a
    /// MenuBarExtra). A global monitor covers clicks in other apps; a local one
    /// covers clicks in our own windows.
    private func installDismissMonitors() {
        removeDismissMonitors()
        // Beim Vermessen (--demo-day) NUR die Schließen-Monitore auslassen,
        // sonst schließt der erste beliebige Klick das Widget, bevor der
        // Screenshot es erwischt. Die Bewegungs-Monitore weiter unten müssen
        // laufen, sie speisen die Erklärboxen; ein früheres `return` an dieser
        // Stelle hat sie mit abgeschaltet und die Erklärungen verstummten.
        let measuring = CommandLine.arguments.contains { $0.hasPrefix("--demo-day=") }
        let g = measuring ? nil : NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                // Runde 114 (Punkt 4): ein Klick, der in EINEM UNSERER Fenster liegt (z. B. Reiter in den Einstellungen),
                // darf nie schließen, auch wenn das Ereignis hier statt im lokalen Monitor ankommt.
                let m = NSEvent.mouseLocation
                let own = [WidgetPanelController.shared.panel?.frame, SettingsPanelController.shared.frame, CreatePanelController.shared.frame]
                if own.contains(where: { $0.map { $0.insetBy(dx: Theme.stageInset, dy: Theme.stageInset).contains(m) } ?? false }) { return }
                WidgetPanelController.shared.close()
            }
        }
        let l = measuring ? nil : NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                let w = event.window
                let keepOpen = w === WidgetPanelController.shared.panel
                    || SettingsPanelController.shared.owns(w)
                    || CreatePanelController.shared.owns(w)
                    || UndoToast.owns(w)
                    || w === WidgetPanelController.shared.statusWindow
                if !keepOpen { WidgetPanelController.shared.close() }
            }
            return event
        }
        // Runde 56: Bewegungen fürs selbstgebaute Hover der Symbol-Erklärungen.
        // Dieselbe Monitor-Technik wie beim Schließen, weil sie in dieser App
        // nachweislich zuverlässig ist, im Gegensatz zu SwiftUIs Hover-Tracking
        // (Begründung in Hints.swift). Nur solange das Widget offen ist.
        let gm = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in
            Task { @MainActor in HintWindow.shared.mouseMoved() }
        }
        let lm = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            MainActor.assumeIsolated { HintWindow.shared.mouseMoved() }
            return event
        }
        // Runde 98: Esc schließt das Widget (macOS 5.3). Lokal reicht, solange das
        // Widget die Tasten bekommt; Tasten anderer Apps sehen wir nicht.
        let esc = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            var hit = false
            MainActor.assumeIsolated {
                if event.keyCode == 53, event.window === WidgetPanelController.shared.panel {
                    WidgetPanelController.shared.close()
                    hit = true
                }
            }
            return hit ? nil : event
        }
        dismissMonitors = [g, l, gm, lm, esc].compactMap { $0 }
    }

    private func removeDismissMonitors() {
        for m in dismissMonitors { NSEvent.removeMonitor(m) }
        dismissMonitors = []
    }

    /// Content size changed (day switch, agenda length): keep the top edge and
    /// icon-centre anchor, grow downward. Integral origin keeps text on pixel
    /// boundaries (fractional offsets blur it).
    func resize(to size: CGSize) {
        guard let p = panel, p.isVisible else { return }
        lastNatural = size
        if ProcessInfo.processInfo.environment["MB_FIT_LOG"] != nil { print("widget natural \(size) panel \(p.frame.height)"); fflush(stdout) }
        place(size: size)
    }

    /// Inhalt neu vermessen und das Panel darauf setzen. Für Umschalter, die
    /// die Höhe ändern (Kalender auf/zu): der GeometryReader im Inneren kann
    /// das nicht melden, weil die Inhaltsansicht an der Panelgröße klebt.
    /// IMMER einen Runloop später aufrufen, vorher hat SwiftUI den neuen
    /// Inhalt noch nicht gelayoutet und `fittingSize` liefert den alten Wert.
    /// Dauer des Auf- und Zuklappens. Fenster UND SwiftUI-Inhalt müssen
    /// denselben Wert benutzen, sonst springt das Fenster und der Inhalt
    /// zieht hinterher — genau das wirkte „nervig".
    ///
    /// 🚨 Drei Anläufe brauchte es, bis die Kopfzeile beim Klappen wirklich
    /// stillstand. Alle drei Ursachen sind derselbe Denkfehler in Varianten —
    /// **beim Umschalten eines Zustands darf sich die GEOMETRIE nie ändern:**
    /// 1. Padding schaltete 0 → 5pt um (Runde 63c)
    /// 2. Zwei verschieden breite Pfeil-Glyphen getauscht (Runde 63d)
    /// 3. Der Inhalt wurde vom noch kleineren Fenster gestaucht (Runde 63e)
    /// Nur Farbe, Füllung, Deckkraft und Drehung sind gefahrlos.
    static let foldDuration = 0.20

    /// Runde 110: misst die Zielhöhe und setzt das Fenster (Bühne): Wachsen sofort, Schrumpfen erst nach
    /// der Klapp-Feder. Das Glas ist der SwiftUI-Hintergrund und läuft im selben Bild mit dem Inhalt.
    func refreshSize(animated: Bool = false) {
        // Runde 110b: der Inhalt meldet seine natürliche Größe selbst (`resize(to:)` per onSize, am Glas vor der
        // festen Höhe gemessen); hier nur noch nachsetzen.
        guard let p = panel, p.isVisible, let s = lastNatural else { return }
        place(size: s)
    }
    private var lastNatural: CGSize?

    /// Höhe, auf die das Fenster nach dem Schrumpf-Warten gesetzt wird (nil = nichts offen).
    private var pendingHeight: CGFloat?
    private var pendingShrink: DispatchWorkItem?

    private func place(size: CGSize) {
        guard let p = panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchorX, y: topY - 1)) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchorX - size.width / 2
        x = min(max(x, vf.minX + 4 - Self.stage), vf.maxX - size.width - 4 + Self.stage)
        // Die OBERKANTE des Glases bleibt fest, gewachsen wird nach unten: das Datum im
        // Kopf darf beim Aufklappen nicht wandern.
        let y = topY + Self.stage - size.height
        let rect = CGRect(x: x.rounded(), y: y.rounded(),
                          width: size.width.rounded(.up), height: size.height.rounded(.up))
        pendingShrink?.cancel(); pendingShrink = nil; pendingHeight = nil
        if rect.height < p.frame.height - 0.5, rect.width == p.frame.width {
            pendingHeight = rect.height
            let w = DispatchWorkItem { [weak self, weak p] in
                guard let self, let p else { return }
                p.setFrame(rect, display: true)
                WidgetLayout.shared.set(rect.height)
                self.pendingHeight = nil
            }
            pendingShrink = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.foldSettle, execute: w)
        } else {
            p.setFrame(rect, display: true)
            WidgetLayout.shared.set(rect.height)
        }
        let glass = rect.insetBy(dx: Self.stage, dy: Self.stage)
        CreatePanelController.shared.alignToWidget(glass)     // Reihenfolge: erst das Termin-Fenster, die Einstellungen docken daran
        SettingsPanelController.shared.alignToWidget(glass)
        HintWindow.log("widget place day=\(AppState.shared.dayOffset) grid=\(AppState.shared.showsToday ? "today" : "other") size=\(size) frame=\(rect) topY=\(topY)")
    }

    /// Runde 122: nach dem Schließen zusammen mit „New Meeting" darf das Widget kurz nicht wieder aufgehen
    /// (ein Nachzügler-Aufruf hätte es sonst sofort neu geöffnet).
    private var noReopenUntil: Date?
    /// Gemeinsames Ausblenden: Dauer 0,18 s, weich an- und auslaufend, im selben Bild wie das Termin-Fenster.
    static let jointFade = 0.18

    func close(fade: Double = 0.15, joint: Bool = false) {
        if joint { noReopenUntil = Date().addingTimeInterval(0.8) }
        WidgetLayout.shared.set(nil); lastNatural = nil; pendingShrink?.cancel(); pendingShrink = nil; pendingHeight = nil
        removeDismissMonitors()
        HintWindow.shared.hide()     // sonst bleibt eine Erklaerbox stehen
        SettingsPanelController.shared.close()   // don't orphan the settings panel
        // The "Neues Meeting" panel deliberately survives, it closes ONLY via
        // its own × (Runde 28: a stray click must not eat a half-typed
        // meeting).
        lastFrame = panel?.frame ?? lastFrame
        // Runde 111 (Fund 12): Inhalt und Glas gemeinsam ausblenden (Fenster-Alpha 0,15 s), dann erst abbauen.
        if let p = panel {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fade
                ctx.timingFunction = CAMediaTimingFunction(name: joint ? .easeInEaseOut : .linear)
                p.animator().alphaValue = 0
            } completionHandler: {
                p.orderOut(nil)
                p.contentView = nil
                // Runde 122c: erst jetzt (Widget weg) den eingefrorenen Kalender-Stand nachholen.
                if joint { Task { @MainActor in AppState.shared.monitor.unfreeze() } }
            }
        } else if joint {
            AppState.shared.monitor.unfreeze()
        }
        panel = nil
        hostingView = nil
    }
}


/// Runde 110b (F3): AppKit schob das Widget-Fenster unter die Menüleiste und damit das Glas 11 pt tiefer als die
/// Nachbarn. Die durchsichtige Bühne darf über die Menüleiste ragen.
final class StagePanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}


/// Runde 110b: Fensterhöhe des Widgets für die SwiftUI-Wurzel (oben verankert, ohne Animation gesetzt).
@MainActor
final class WidgetLayout: ObservableObject {
    static let shared = WidgetLayout()
    @Published var height: CGFloat?
    func set(_ h: CGFloat?) {
        guard height != h else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { height = h }
    }
}
