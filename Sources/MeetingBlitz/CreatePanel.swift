import SwiftUI
import AppKit

/// "Neues Meeting" lives in its own floating panel (Runde 27c): the inline card
/// inside the widget pushed timeline + agenda down ("nimmt viel zu viel Platz
/// weg"), the widget stays untouched and the + button opens this panel instead,
/// same mechanics as the settings panel (titled utility, key from the start so
/// the text field has focus and accents render).
@MainActor
final class CreatePanelController {
    static let shared = CreatePanelController()
    private var panel: NSPanel?
    /// Merkt sich, wohin das Panel gezogen wird (Runde 47h). `window.delegate`
    /// ist weak, also muss der Controller den Recorder halten.
    private var moveRecorder: PanelMoveRecorder?
    /// Widget-Frame vom Öffnen, fürs Nach-Platzieren im ersten resize (47i).
    private var anchorRect: CGRect?
    private var resizeObserver: NSObjectProtocol?

    var isOpen: Bool { panel?.isVisible ?? false }

    /// Runde 121: nach erfolgreichem Erstellen soll das Widget mit zugehen, sobald dieses Fenster zugeht.
    var closeWidgetWithMe = false

    /// Für die Diagnose, wie beim Einstellungs-Panel.
    var frame: CGRect? { panel?.frame }
    /// Runde 110: Rahmen des sichtbaren Glases (ohne durchsichtige Bühne), Andockmaß für Nachbarn.
    var glassFrame: CGRect? { panel?.frame.insetBy(dx: Theme.stageInset, dy: Theme.stageInset) }

    /// Testschalter `--screen-height <pt>` (Runde 87): so tun, als wäre der
    /// Bildschirm so hoch (13-Zoll-MacBook ≈ 900 pt), ohne einen zu haben.
    static let simulatedScreenHeight: CGFloat? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--screen-height"), i + 1 < a.count, let v = Double(a[i + 1]) else { return nil }
        return CGFloat(v)
    }()

    /// Wie hoch das ganze Fenster (mit Titelleiste) höchstens werden darf:
    /// sichtbare Bildschirmhöhe minus die 2×8 pt Rand aus `PanelDock.clampY`.
    var availableFrameHeight: CGFloat {
        let screenH = Self.simulatedScreenHeight
            ?? (panel?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        // Runde 110: das GLAS muss passen (2×8 pt Rand), die Bühne (2×16) darf überstehen.
        return screenH - 16 + 2 * Theme.stageInset
    }

    /// Dasselbe für den Inhalt (ohne Titelleiste).
    var availableContentHeight: CGFloat {
        return availableFrameHeight - 2 * Theme.stageInset
    }

    func toggle(state: AppState, anchor: CGRect?) {
        if let p = panel, p.isVisible { close(); return }
        closeWidgetWithMe = false
        lastContentSize = nil   // Runde 109b: Maß gilt nur für dieses Fenster

        GoogleService.shared.resetCreateFeedback()

        // Runde 47j ZURÜCKGENOMMEN (siehe PROGRESS): der randlose Milchglas-Look
        // machte die Panels unklickbar. Wieder das bewährte titled Utility-Panel.
        let hosting = CreateHostingView(rootView: CreatePane(
            state: state,
            onClose: { Task { @MainActor in CreatePanelController.shared.close() } },
            onSize: { size in
                // Runde 109c (F1): NICHT synchron aus der SwiftUI-Animation heraus
                // (Layout-Rekursion beim Öffnen, Inhalt sprang beim Kalender 72 pt).
                // Ein Runloop-Hop reicht: der Inhalt ist oben verankert, ein Bild
                // lang fehlt höchstens unten ein Streifen.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { CreatePanelController.shared.resize(to: size) }
                }
            }))
        // Runde 108b: Größe NICHT mehr von SwiftUI/AppKit setzen lassen.
        // `NSHostingView.updateAnimatedWindowSize` rechnet die unsichtbare
        // Titelleiste (24 pt) auf die Inhaltshöhe drauf (gemessen: 445 → 469).
        // Folge: Inhalt 12 pt zu tief (✕ nicht oben), 12 pt Lücke unten.
        // Jetzt misst der Inhalt sich selbst (onGeometryChange) und resize()
        // setzt Fensterhöhe = Inhaltshöhe.
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let p = ThemePanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        // Runde 108b: Inhalt = ganzes Fenster. Sonst rechnet AppKit die
        // unsichtbare Titelleiste (24 pt) auf jede Wunschhöhe drauf, SwiftUI
        // zentriert den Inhalt darin: 12 pt zu tief, 12 pt Lücke unten.
        p.contentFillsFrame = true
        p.controllerOwnsSize = true
        p.setContentSize(size)
        p.title = L.t("Neues Meeting", "New Meeting")
        // Runde 98: Esc schließt (offene Felder fangen Esc vorher ab). Runde 110: bei offener Kalenderliste erst die Liste.
        p.onEscape = { [weak p] in
            if CreatePane.calendarListOpen { NotificationCenter.default.post(name: CreatePane.demoCommand, object: "calendar off") }
            else { p?.close() }
        }
        // Runde 90: Liquid Glass bis unter die Titelleiste. Bewusst weiter ein
        // TITLED Panel (Fallstrick 7): Titelleiste, Ziehen, Schließen und
        // Tastaturfokus bleiben die bewährten, nur der Hintergrund ist Glas.
        p.titlebarAppearsTransparent = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isReleasedWhenClosed = false
        p.level = .floating        // Runde 111b (A1): alle Fenster auf einer Ebene
        // Runde 115: Aussehen kommt von NSApp.appearance (Look.apply).
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false   // key from the start → focus + accents
        // Wie beim Widget, sonst liegt das Formular bei laufender Vollbild-App
        // auf dem Schreibtisch daneben (22.08.2026, Begründung in PanelDock).
        p.collectionBehavior = PanelDock.companionBehavior
        p.contentView = hosting
        Theme.installStage(in: p, movableByBackground: false)
        // Runde 87: Zonenliste deckeln, sobald das Fenster höher wird als der
        // Bildschirm. Über die ECHTE Fensterhöhe, weil der SwiftUI-Rückkanal
        // (onPreferenceChange) in diesem Panel nicht zuverlässig feuert
        // (gemessen: nie, vgl. Runde 75).
        ZoneListFit.shared.reset()
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { CreatePanelController.shared.fitZoneList() }
        }

        // Runde 47g/47h/47i: gemerkte Position gewinnt, sonst neben das Widget.
        // ⚠️ `fittingSize` ist hier oft noch (0, 24), SwiftUI hat den Inhalt
        // beim Erstellen noch nicht ausgelegt (gemessen, /tmp/mb_panel.log,
        // 47i). Mit Breite 0 rechnet „links daneben" die LINKE Kante dorthin,
        // wo das Panel nach dem Aufwachsen das Widget überdeckt. Deshalb: hier
        // nur grob platzieren, die endgültige Platzierung macht das erste
        // resize() mit der ECHTEN Größe.
        anchorRect = anchor
        let panelSize = p.frame.size
        p.setFrameOrigin(PanelDock.savedOrigin(panelSize: panelSize, id: "create", anchor: anchorRect, stage: Theme.stageInset)
                         ?? PanelDock.origin(panelSize: panelSize, anchor: anchor, stage: Theme.stageInset))
        // Runde 108b: unsichtbar öffnen, erst nach der endgültigen Platzierung
        // einblenden (`reveal()`). Vorher sah man das Fenster an der groben
        // Stelle aufgehen und dann nach links rutschen (Rückmeldung 19.11.).
        p.alphaValue = 0
        p.animationBehavior = .none   // keine System-Aufploppen-Animation, nur unser Einblenden
        p.makeKeyAndOrderFront(nil)
        // Position merken, sobald das Panel gezogen wird (Runde 47h). Startet
        // SUSPENDIERT: bis die Erstplatzierung durch ist, ist jede Bewegung
        // programmatisch und darf nicht als „gezogen" gespeichert werden.
        let recorder = PanelMoveRecorder(id: "create", stage: Theme.stageInset)
        userMoved = false
        recorder.onUserMove = { [weak self] in self?.userMoved = true }
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
        // Notbremse wie beim Einstellungs-Panel (Begründung in PanelDock).
        let opened = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // Runde 108c (Fable K4): nur DIESES Fenster, nicht ein schon neu geöffnetes.
            guard let self, let p = self.panel, p === opened, p.isVisible else { return }
            if p.frame.height < 100, let c = self.lastContentSize { self.resize(to: c) }   // Runde 109b
            if p.alphaValue < 1 { p.alphaValue = 1 }   // Runde 108b: nie unsichtbar hängen bleiben
            // Merker stummschalten, sonst gilt unsere Notplatzierung als
            // gezogene Position (Begründung im Einstellungs-Panel).
            self.moveRecorder?.suspended = true
            self.lastRescueReason = PanelDock.enforceVisible(p)
            DispatchQueue.main.async { self.moveRecorder?.suspended = false }
        }
    }

    /// Warum die Notbremse greifen musste, für den Diagnosebericht.
    private(set) var lastRescueReason: String?

    /// Fenstertitel nach einem Sprachwechsel nachziehen.
    func refreshTitle() { panel?.title = L.t("Neues Meeting", "New Meeting") }

    /// Runde 109: Wachsen sofort (Oberkante bleibt, der Inhalt ist oben angenagelt
    /// und fährt in den schon vorhandenen Platz), Schrumpfen erst nach der
    /// Klapp-Animation (0,2 s), unten verschwindet dann nur leeres Glas.
    private var pendingShrink: DispatchWorkItem?

    /// Runde 109b: letzte echte Inhaltsgröße. `onGeometryChange` meldet die
    /// Größe oft genau EINMAL, bevor das Fenster sichtbar ist; ohne diesen
    /// Merker blieb das Fenster dann 0 × 0 (gemessen 19.11., Öffnen per URL).
    private var lastContentSize: CGSize?

    /// Runde 110: `glassSize` = Größe des Glases (vom SwiftUI-Inhalt gemessen); das Fenster ist
    /// um die durchsichtige Bühne rundum größer.
    func resize(to glassSize: CGSize) {
        // Runde 108c (Fable K3): Phantom-Höhen beim Aufbau nie festhalten.
        guard glassSize.width > 1, glassSize.height > 100 else { return }
        lastContentSize = glassSize
        guard let p = panel, p.isVisible else { return }
        let contentSize = CGSize(width: glassSize.width + 2 * Theme.stageInset, height: glassSize.height + 2 * Theme.stageInset)
        let frameSize = contentSize
        let old = p.frame
        // Erstplatzierung noch offen (Recorder suspendiert)? Dann mit der
        // frischen Größe direkt richtig platzieren, nicht warten.
        if moveRecorder?.suspended == true {
            (p as? ThemePanel)?.pinnedHeight = contentSize.height
            CreateLayout.shared.set(frameSize.height)
            let origin = PanelDock.savedOrigin(panelSize: frameSize, id: "create", anchor: anchorRect, stage: Theme.stageInset)
                ?? PanelDock.origin(panelSize: frameSize, anchor: anchorRect, stage: Theme.stageInset)
            (p as? ThemePanel)?.setFrameFromController(CGRect(origin: origin, size: frameSize), display: true)
            moveRecorder?.suspended = false
            reveal()
            return
        }
        let pinned = (p as? ThemePanel)?.pinnedHeight
        if abs(frameSize.height - old.height) < 1, abs(frameSize.width - old.width) < 1 {
            pendingShrink?.cancel(); pendingShrink = nil
            if pinned == nil || abs((pinned ?? 0) - contentSize.height) > 0.5 { (p as? ThemePanel)?.pinnedHeight = contentSize.height }
            return
        }
        if frameSize.height < old.height - 0.5, abs(frameSize.width - old.width) < 1 {
            // Schrumpfen: warten, bis die Animation durch ist. Bis dahin hält
            // `pinnedHeight` die alte Höhe fest (AppKit setzt sonst zurück).
            pendingShrink?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.applyFrame(frameSize, contentHeight: contentSize.height) }
            pendingShrink = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Theme.foldSettle, execute: w)
            return
        }
        pendingShrink?.cancel(); pendingShrink = nil
        applyFrame(frameSize, contentHeight: contentSize.height)
    }

    private func applyFrame(_ frameSize: CGSize, contentHeight: CGFloat) {
        guard let p = panel, p.isVisible else { return }
        let old = p.frame
        (p as? ThemePanel)?.pinnedHeight = contentHeight
        CreateLayout.shared.set(frameSize.height)
        moveRecorder?.suspended = true
        // Normales Wachsen/Schrumpfen (Abschnitt klappt auf): Oberkante
        // bleibt stehen, clampY hält das Panel im sichtbaren Bereich
        // (Runde 47g).
        var y = old.maxY - frameSize.height
        if let vf = PanelDock.visibleFrame(containing: old) {
            y = PanelDock.clampedWindowY(frame: old, newHeight: frameSize.height, vf: vf, stage: Theme.stageInset)
        }
        // Runde 109c (F1): ohne jede Animation setzen. Lief das Wachsen in der
        // SwiftUI-Animation des Klicks mit, wuchs die Ebene um ihre Mitte und der
        // Inhalt saß ein Bild lang 72 pt zu tief (Kalender).
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0; ctx.allowsImplicitAnimation = false
            CATransaction.begin(); CATransaction.setDisableActions(true)
            (p as? ThemePanel)?.setFrameFromController(CGRect(x: old.minX, y: y.rounded(), width: frameSize.width, height: frameSize.height),
                                                       display: true)
            // Die Ebenen jetzt und ohne Animation nachziehen, sonst gleitet die
            // SwiftUI-Ebene mit der Klapp-Animation von alter zu neuer Größe.
            p.contentView?.layoutSubtreeIfNeeded()
            CATransaction.commit()
            CATransaction.flush()
        }
        moveRecorder?.suspended = false
        if let path = ProcessInfo.processInfo.environment["MB_FRAME_LOG"] {
            func dump(_ tag: String) {
                let line = "\(tag) win=\(p.frame) content=\(p.contentView?.frame ?? .zero) super=\(p.contentView?.superview?.frame ?? .zero)\n"
                if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
            }
            dump("apply \(contentHeight)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dump("  +0.4s") }
        }
    }

    /// Endgültige Erstplatzierung, sobald das Panel seine echte Größe hat
    /// (Runde 47i(2)). Läuft einen Runloop nach dem Öffnen; falls resize()
    /// schneller war (suspended schon false), tut sie nichts.
    private func finishInitialPlacement() {
        // Runde 109b: Größe kam schon vor dem Sichtbarwerden → jetzt anwenden.
        if let p = panel, p.isVisible, p.frame.height < 100, let c = lastContentSize {
            resize(to: c); return
        }
        guard let p = panel, p.isVisible, moveRecorder?.suspended == true else { return }
        let size = p.frame.size
        guard size.width > 50 else { return }   // immer noch Phantom → resize() übernimmt
        p.setFrameOrigin(PanelDock.savedOrigin(panelSize: size, id: "create", anchor: anchorRect, stage: Theme.stageInset)
                         ?? PanelDock.origin(panelSize: size, anchor: anchorRect, stage: Theme.stageInset))
        moveRecorder?.suspended = false
        reveal()
    }

    /// Runde 108b: kurzes Einblenden an der fertigen Stelle (statt Rutschen).
    private func reveal() {
        guard let p = panel, p.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            p.animator().alphaValue = 1
        }
    }

    func fitZoneList() {
        guard let p = panel else { return }
        let fit = ZoneListFit.shared
        // Runde 92: Fenster auf die echte Inhaltshöhe ziehen. Mit durchgehendem
        // Glas (`.fullSizeContentView`) rechnete AppKits Auto-Größe nach dem
        // Wachsen die Titelleiste doppelt, unten blieb ein leerer Streifen.
        // Runde 92: zustandslos. Der Rest des Fensters ist Fensterhöhe minus
        // aktuelle Listenhöhe; was der erlaubten Höhe davon übrig bleibt, darf
        // die Liste haben. (Die alte "Überstand abziehen"-Rechnung blieb mit der
        // Rundung auf ganze Zeilen in einer Zeile hängen.)
        // Runde 109: nur rechnen, wenn das Fenster zu hoch ist oder der Deckel
        // gerade greift. Sonst lief das bei jedem Klappen (Rückkanal, Neuzeichnen).
        let needsFit = p.frame.height > availableFrameHeight + 0.5 || fit.cap != .greatestFiniteMagnitude
        if fit.listHeight > 0, needsFit {
            let others = p.frame.height - fit.listHeight
            let room = availableFrameHeight - others
            let newCap = room >= fit.listHeight + 1 ? (room > 2000 ? .greatestFiniteMagnitude : room) : max(0, room)
            if newCap != fit.cap, abs(newCap - fit.cap) > 1 || newCap == .greatestFiniteMagnitude || fit.cap == .greatestFiniteMagnitude {
                fit.cap = newCap
            }
        }
        // Runde 110: Kalenderliste deckeln, wenn das Fenster sonst höher als der Bildschirm würde.
        if fit.calNatural > 0 {
            let shown = min(fit.calNatural, fit.calCap)
            let others = p.frame.height - shown
            let room = availableFrameHeight - others
            let want: CGFloat = room >= fit.calNatural ? .greatestFiniteMagnitude : max(56, (room / 28).rounded(.down) * 28)
            if want != fit.calCap { fit.calCap = want }
        } else if fit.calCap != .greatestFiniteMagnitude { fit.calCap = .greatestFiniteMagnitude }
        // AppKit lässt das Fenster beim Wachsen nach UNTEN aus dem Bildschirm
        // laufen (Oberkante bleibt stehen, gemessen y = −63). `resize()` hätte
        // das geklemmt, wird hier aber nicht aufgerufen. Also hier nachziehen,
        // mit stummem Positions-Merker (Runde 74c).
        if let vf = PanelDock.visibleFrame(containing: p.frame) {
            let y = PanelDock.clampedWindowY(frame: p.frame, vf: vf, stage: Theme.stageInset)
            if abs(y - p.frame.minY) > 0.5 {
                let wasSuspended = moveRecorder?.suspended ?? false
                moveRecorder?.suspended = true
                p.setFrameOrigin(CGPoint(x: p.frame.minX, y: y.rounded()))
                if !wasSuspended { DispatchQueue.main.async { self.moveRecorder?.suspended = false } }
            }
        }
    }

    /// Runde 99: Das Widget hat sich bewegt oder seine Höhe geändert → das Panel
    /// dockt neu an (Oberkante exakt gleich, Abstand s8, Seite mit Platz).
    /// Runde 111 (Fund 11): vom Nutzer gezogene Position gewinnt, angedockt wird nur, solange nicht gezogen.
    private(set) var userMoved = false

    func alignToWidget(_ a: CGRect) {
        guard let p = panel, p.isVisible, !userMoved else { return }
        guard PanelDock.sameScreen(p.frame, a) else { return }   // Runde 114: bleibt auf seinem Bildschirm
        anchorRect = a
        moveRecorder?.suspended = true
        p.setFrameOrigin(PanelDock.origin(panelSize: p.frame.size, anchor: a, stage: Theme.stageInset))
        moveRecorder?.suspended = false
    }

    func close() {
        let closeWidget = closeWidgetWithMe
        closeWidgetWithMe = false
        CreateLayout.shared.set(nil)
        if let o = resizeObserver { NotificationCenter.default.removeObserver(o) }
        resizeObserver = nil
        panel?.delegate = nil
        moveRecorder = nil
        // Runde 122: nach erfolgreichem Erstellen gehen Termin-Fenster und Widget GEMEINSAM aus (ein Ausblenden,
        // gleiche Dauer, gleicher Start). Vorher verschwand dieses Fenster in einem Bild, das Widget blendete danach aus.
        if closeWidget, let p = panel {
            panel = nil
            p.ignoresMouseEvents = true
            if DryCreate.isOn { print("joint close \(Date().timeIntervalSince1970)"); fflush(stdout) }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = WidgetPanelController.jointFade
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                p.animator().alphaValue = 0
            } completionHandler: {
                p.orderOut(nil)
                p.contentView = nil
            }
            WidgetPanelController.shared.close(fade: WidgetPanelController.jointFade, joint: true)
            return
        }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Runde 122 (nur MB_DRY_CREATE): Return-Taste im Eingabefeld nachstellen, über AppKit statt CGEvent.
    func dryPressReturn() {
        guard DryCreate.isOn, let p = panel, let root = p.contentView else { return }
        func find(_ v: NSView) -> EntryTextView? {
            if let t = v as? EntryTextView { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        guard let tv = find(root) else { print("dry-return: kein Feld"); fflush(stdout); return }
        p.makeKey()
        p.makeFirstResponder(tv)
        if tv.string.isEmpty { tv.insertText("Test", replacementRange: NSRange(location: 0, length: 0)) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: p.windowNumber, context: nil, characters: "\r",
                                        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                NSApp.sendEvent(e)
            }
        }
        print("dry-return gesendet"); fflush(stdout)
    }

    /// Lets the widget's dismiss monitor keep both open on clicks in here.
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === panel }
}

/// First click must land even though the accessory app is rarely "active".
private final class CreateHostingView: NSHostingView<CreatePane> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    required init(rootView: CreatePane) { super.init(rootView: rootView) }
    @objc required dynamic init?(coder: NSCoder) { fatalError("not used") }
}


/// Runde 110: eine Zeile der Kalenderliste (28 pt, Hover-Ecke 8 = 10 − 2 Innenrand).
private struct CalendarPickRow: View {
    let calendar: CalendarInfo
    let chosen: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.s8) {
                Circle().fill(calendar.color).frame(width: 8, height: 8)
                Text(calendar.title).foregroundStyle(chosen ? Theme.blue : .primary)
                Text(calendar.sourceTitle.isEmpty ? (calendar.isAppleAccount ? "iCloud" : "Google") : calendar.sourceTitle)
                    .foregroundStyle(Theme.muted).font(.theme(.small))
                Spacer(minLength: 0)
                if chosen { Image(systemName: "checkmark").foregroundStyle(Theme.blue) }
            }
            .font(.theme(.normal)).lineLimit(1)
            .padding(.horizontal, Theme.s8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.innerRadius, style: .continuous)
                .fill(hover ? Theme.fillHover : .clear).padding(2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Runde 109c: Höhe des Fensters, damit die SwiftUI-Wurzel genau so hoch ist (oben verankert).
@MainActor
final class CreateLayout: ObservableObject {
    static let shared = CreateLayout()
    @Published var height: CGFloat?
    /// Ohne Animation setzen (kommt aus dem Controller, nicht aus der Klapp-Animation).
    func set(_ h: CGFloat?) {
        guard height != h else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { height = h }
    }
}

/// The create form: title, start, duration → one click writes the event into
/// the Apple calendar with a fresh Meet link (copied to the clipboard).
struct CreatePane: View {
    @ObservedObject var state: AppState
    @ObservedObject var google = GoogleService.shared
    @ObservedObject private var layout = CreateLayout.shared
    /// Ersetzt den weggefallenen Schließen-Knopf der Titelleiste (Runde 47j).
    var onClose: (@Sendable () -> Void)? = nil
    var onSize: (@Sendable (CGSize) -> Void)? = nil

    /// Runde 113: EIN Feld. Der Titel ist der Text ohne die erkannten Teile (`entryScan.title`).
    @State private var entry = ""
    @State private var eventDays: Set<Date> = []
    @State private var entryScan = QuickScan(title: "")
    @State private var entryState: EntryState?
    /// true, solange das Feld Werte schreibt (dann ist die Änderung nicht "von Hand").
    @State private var applyingEntry = false
    private var newTitle: String { entryScan.title }
    @State private var newStart = Self.nextQuarterHour()
    @State private var newMinutes = 30
    /// Repeat rule (Runde 43): `.none` writes a single event, otherwise a series.
    @State private var newRepeat: RepeatRule = .none
    @State private var repeatOpen = false
    /// Runde 96: zugeklappte Bereiche, Zustand wird gemerkt.
    // Runde 110: @State statt @AppStorage. AppStorage meldet Änderungen erst nach dem Schreiben in
    // UserDefaults, AUSSERHALB von withAnimation: die Klappen sprangen. Gespeichert wird per onChange.
    @State private var monthOpen = UserDefaults.standard.bool(forKey: "create.monthOpen")
    @AppStorage("create.lastRepeat") private var lastRepeat = "none"
    @State private var timeHover = false
    @State private var editingTime = false
    @State private var timeText = ""
    @FocusState private var timeFocused: Bool
    @ObservedObject private var book = ZoneBook.shared
    /// Custom recurrence spec, used when `newRepeat == .custom` (Runde 43b).
    @State private var customRec = CustomRecurrence()
    // Runde 90: „Öffnen als Arbeit/Privat" und „Kalender" sind aus dem Formular
    // raus. Konto und Zielkalender kommen immer aus den Einstellungen
    // (`state.effectiveCreateCalendarIDs`, `state.meetRouting`).
    /// Runde 86: gleicher Schlüssel wie in `ZonePlanner`, hier nur gelesen.
    @AppStorage("zonePlanner.open") private var zonePlannerOpen = false
    /// Runde 87: Deckel für die Zonenliste, damit das Panel auf den
    /// Bildschirm passt. Regelt der Controller aus der echten Fensterhöhe.
    @ObservedObject private var fit = ZoneListFit.shared
    /// Runde 87: Kollisionsprüfung entprellt. Vorher lief bei jedem
    /// Schieberschritt eine Kalenderabfrage.
    @State private var conflictHits: [Meeting] = []
    /// Runde 109: nächster Termin nach dem geplanten Ende (am selben Tag), nil = Rest des Tages frei.
    /// Runde 113c: live aus dem Beginn berechnet (kein entprellter State), sonst hängt die Zeile beim Ziehen hinterher.
    private static var agendaMemo: (day: Date, items: [Meeting], at: Date)?
    private var nextAfter: Meeting? { computeNext() }
    @State private var calendarOpen = false
    nonisolated(unsafe) static var calendarListOpen = false
    @State private var calHover = false
    @State private var editSuffix: String?
    /// Runde 109: Gast-Adresse(n). Nur hier im Speicher, nie in UserDefaults, nie im Log.
    @State private var guests: [String] = [""]
    @FocusState private var focusedGuest: Int?
    @State private var guestNote: String?
    /// Runde 119: Änderungen an der Vorschau gelten nur für dieses Meeting (nil = Vorlage).
    struct MailDraft: Equatable { var subject: String; var body: String }
    @State private var mailOverride: MailDraft?
    @State private var textOverride: String?
    @State private var savedFlash = false
    @State private var subjFocus = false
    @State private var bodyFocus = false
    @State private var textFocus = false
    @State private var mailHover = false
    @State private var textHover = false
    @State private var guestShowError = false
    /// Für „Nochmal senden" nach einem Mail-Fehler.
    @State private var mailRetry: (to: [String], subject: String, body: String, ics: String?)?

    /// Testschalter `--demo-create`: Wiederholung/Kalenderliste aufklappen.
    static let demoCommand = Notification.Name("CreatePaneDemoCommand")
    /// Nur Testschalter `MB_DEMO_FAKE_EVENTS` (Demo ohne Kalenderzugriff): feste Beispieltermine heute.
    nonisolated(unsafe) static var demoMeetings: [Meeting]?
    nonisolated(unsafe) static var demoCalendars: [CalendarInfo]?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            ThemeWindowHeader(title: L.t("Neues Meeting", "New Meeting"))
            if let link = google.lastMeetLink {
                HStack(spacing: Theme.s8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    Text(L.t("Termin erstellt · Details kopiert", "Event created · details copied"))
                        .font(.theme(.normal, .semibold))
                    Spacer()
                    ThemeIconButton(systemName: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(google.lastShareText ?? link, forType: .string)
                    }
                        .help(L.t("Titel + Zeit + Meet-Link nochmal kopieren",
                                  "Copy title + time + Meet link again"))
                }
                Text(link)
                    .font(.theme(.small)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                // Kalenderdatei (Runde 47): liegt in ~/Downloads. „Kopieren" legt
                // die DATEI in die Zwischenablage, in WhatsApp/Mail eingefügt
                // wird daraus ein Anhang, kein Pfad-Text.
                if let ics = google.lastICSURL {
                    HStack(spacing: Theme.s8) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.theme(.small)).foregroundStyle(Theme.muted)
                        Text(ics.lastPathComponent)
                            .font(.theme(.small)).foregroundStyle(Theme.muted)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        ThemeIconButton(systemName: "doc.on.doc") { ICSExport.copyToPasteboard(ics, text: google.lastShareText) }
                            .help(L.t("Termin kopieren (Datei + Text)", "Copy event (file + text)"))
                        ThemeIconButton(systemName: "folder") { ICSExport.revealInFinder(ics) }
                            .help(L.t("Im Finder zeigen (~/Downloads)", "Show in Finder (~/Downloads)"))
                    }
                }
                if let note = google.lastArtifactNote {
                    HStack(alignment: .top, spacing: Theme.s4) {
                        Image(systemName: "text.bubble").font(.theme(.small)).foregroundStyle(Theme.muted)
                        Text(note).font(.theme(.small)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                mailResult
                ThemeTextRow(title: L.t("Noch einen erstellen", "Create another"), accent: true) {
                    google.resetCreateFeedback()
                    entry = ""; entryScan = QuickScan(title: ""); entryState = nil
                    newStart = Self.nextQuarterHour()
                }
            } else if !google.isConnected {
                // Runde 48: abgelaufene Sitzung beim Namen nennen statt „einmal
                // verbinden", sonst wirkt es wie ein Erstsetup, obwohl es der
                // 7-Tage-Ablauf des Testing-Modus ist.
                Text(google.needsReconnect
                     ? L.t("Google-Verbindung abgelaufen. Einmal neu verbinden, dann geht es weiter.",
                           "Google session expired. Reconnect once and you're good.")
                     : L.t("Einmal mit Google verbinden, danach erstellt MeetingBlitz Termine mit automatischem Meet-Link.",
                           "Connect Google once, MeetingBlitz then creates events with an automatic Meet link."))
                    .font(.theme(.small)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ThemePrimaryButton(title: google.busy ? L.t("Verbinde…", "Connecting…") : L.t("Mit Google verbinden", "Connect Google"),
                                   busy: google.busy) {
                    Task { await google.connect() }
                }
                .disabled(google.busy)
            } else {
                // Runde 113: EIN Feld; erkannte Teile blau, Werte werden sofort übernommen (Regel: Feld oder Hand).
                SmartEntryField(text: $entry, marks: entryMarks,
                                placeholder: L.t("Call mit Anna fr 10–11", "Call with Anna fri 10–11"),
                                onSubmit: { submitFromField() })
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .onChange(of: entry) { _, _ in scheduleEntryScan() }
                    // F9: aus meetingblitz://create?text=… vorbelegen.
                    .onAppear {
                        if let t = state.pendingQuickAdd { entry = t; state.pendingQuickAdd = nil; runEntryScan() }
                    }
                    .onChange(of: state.pendingQuickAdd) { _, new in
                        if let t = new { entry = t; state.pendingQuickAdd = nil; runEntryScan() }
                    }
                    .onAppear { if let g = state.pendingGuest { guests = g.isEmpty ? [""] : g; state.pendingGuest = nil } }
                    .onChange(of: state.pendingGuest) { _, new in
                        if let g = new { guests = g.isEmpty ? [""] : g; state.pendingGuest = nil }
                    }

                bigTime

                // Runde 47f: KEIN Scrollbereich mehr. Der Versuch (47c–47e) hat
                // dreimal hintereinander Layout-Ärger produziert, zu kleine
                // gemessene Höhe, unten verankerter Inhalt, überstehende Breite.
                // Das Formular passt ohne die beiden doppelten Toggles in jedem
                // Zustand auf den Bildschirm (~650pt normal, ~850pt mit
                // aufgeklappter Wiederholung UND Kalenderliste, bei ~1140pt
                // sichtbarer Höhe), also braucht es keins. Der Button steht
                // dadurch wieder direkt unter der letzten Zeile.
                // Falls das Panel je wieder zu hoch wird (kleinerer Screen als
                // gemeldet), stehen die drei Gotchas des Scroll-Versuchs in
                // PROGRESS.md Runde 47c–47e.
                formFields

                afterCreating
                    .padding(.top, Theme.s8)
                createButton
                    .padding(.top, Theme.s8)   // Runde 110: keine Linie, 16 pt Luft (4 + 8 + Zeilenabstand)
            }
            if let err = google.lastError {
                ErrorLine(text: err)
            }
        }
        // Runde 90: 30 pt oben = Platz für die durchsichtige Titelleiste (das
        // Glas reicht bis ganz nach oben). Die Sicherheitszone wird bewusst
        // abgeschaltet, damit die gemeldete Größe die Titelleiste enthält.
        .padding(EdgeInsets(top: Theme.s16, leading: Theme.s16, bottom: Theme.s16, trailing: Theme.s16))
        .frame(width: Theme.formWidth)
        // Runde 110: Glas im Baum, der Inhalt liegt darin.
        .background(ThemeGlass())
        // Runde 109: HIER messen (Inhalt), erst DANACH oben festmachen. Stünde
        // die Messung hinter dem maxHeight-Frame, mäße sie das Fenster.
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            if size.width > 1 { onSize?(size) }
        }
        // Runde 109c (F1): feste Höhe = Fensterhöhe (vom Controller gesetzt). Mit
        // `maxHeight: .infinity` bekam die Wurzel nur ihre Idealhöhe, und
        // NSHostingView zentrierte sie im größeren Fenster: beim Aufklappen saß
        // alles ein Bild lang um den halben Zuwachs (72 pt) zu tief.
        .themeDragHeader()
        .themeCloseCorner { onClose?() }
        .padding(Theme.stageInset)
        .frame(height: layout.height, alignment: .top)
        .ignoresSafeArea()
        .onPreferenceChange(RowFramesKey.self) { RowProbe.rows["create"] = $0 }
        .onAppear { if let r = RepeatRule(rawValue: lastRepeat), r != .custom { newRepeat = r } }
        .onChange(of: state.appLanguage) { CreatePanelController.shared.refreshTitle() }
        .onChange(of: calendarOpen) { _, v in Self.calendarListOpen = v }
        .onChange(of: newStart) { old, new in noteManualStart(old: old, new: new) }
        .onChange(of: newMinutes) { _, m in
            guard !applyingEntry, var st = entryState else { return }
            st.manualDuration(m); entryState = st
            rewriteEntryFromHand()
        }
        .onChange(of: monthOpen) { _, v in UserDefaults.standard.set(v, forKey: "create.monthOpen") }
        .onDisappear { Self.calendarListOpen = false }
        .task(id: conflictKey) {
            // Entprellt: erst prüfen, wenn der Schieber kurz stillsteht.
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            conflictHits = computeConflicts()
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.demoCommand)) { n in
            // Runde 96: Demo-Befehle für die zugeklappten Bereiche.
            if let cmd = n.object as? String {
                let parts = cmd.split(separator: " ", maxSplits: 1).map(String.init)
                let on = parts.count > 1 && parts[1] == "on"
                switch parts.first {
                case "month": withAnimation(Theme.fold) { monthOpen = on }; return
                case "more": withAnimation(Theme.fold) { repeatOpen = on }; return   // 113c: "Mehr" gibt es nicht mehr, Befehl öffnet "Wiederholen"
                case "calendar": withAnimation(Theme.fold) { calendarOpen = on }; return
                case "invite": withAnimation(Theme.fold) { previewWhich = on ? 2 : 0 }; return
                case "entry": entry = parts.count > 1 ? parts[1] : ""; runEntryScan(); return
                case "mail": withAnimation(Theme.fold) { mailOn = on }; return
                case "chips":   // Runde 111b: create:chips m,t,i  (Buchstaben = an, "-" = alle aus)
                    let f = parts.count > 1 ? parts[1] : ""
                    withAnimation(Theme.fold) {
                        mailOn = f.contains("m"); state.copyInviteOnCreate = f.contains("t"); state.createICSFile = f.contains("i")
                    }
                    return
                case "mailpreview": withAnimation(Theme.fold) { previewWhich = on ? 1 : 0 }; return
                case "wait": return
                case "guest":
                    let l = MailInvite.splitPasted(parts.count > 1 ? parts[1] : "").list
                    guests = l.isEmpty ? [""] : l; return
                case "reset": mailOverride = nil; textOverride = nil; return
                case "mailedit":   // Testschalter Runde 119: Mail-Vorschau von Hand geändert
                    let t = mailTemplate()
                    mailOverride = MailDraft(subject: t.subject, body: (L.inviteIsDE ? "Hallo Anna,\n\nhier ist der Link:\n{link}\n\n{datum}\n{zeiten}\n\nBis später,\nRobin" : "Hi Anna,\n\nhere is the link:\n{link}\n\n{date}\n{times}\n\nSpeak soon,\nRobin"))
                    return
                case "textedit":   // Testschalter Runde 119: Text-Vorschau von Hand geändert
                    textOverride = L.inviteIsDE ? "Call-Einladung: {titel}\n{datum}, {zeit}\n{link}" : "Invite: {title}\n{date}, {time}\n{link}"
                    return
                case "duration": if parts.count > 1, let v = Int(parts[1]) { newMinutes = v }; return
                case "entryclear": entry = ""; runEntryScan(); return
                case "timeedit": timeText = ZonePlanner.uiHM(newStart, .current); editingTime = true; timeFocused = true; return
                case "timecancel": editingTime = false; return
                case "settime":
                    if parts.count > 1, let (h, m) = TimeEntryParser.parse(parts[1]),
                       let d = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) {
                        newStart = d
                    }
                    return
                default: break
                }
            }
            switch n.object as? String {
            case "repeat": repeatOpen = true
            case "calendars": break
            default: break
            }
        }
    }

    private var conflictKey: String {
        "\(newStart.timeIntervalSinceReferenceDate)|\(newMinutes)|\(google.busy)|\(google.lastCreatedEventIDs.count)"
    }

    // MARK: - Eingabefeld (Runde 113)

    /// Entprellt (120 ms) erkennen und Werte übernehmen.
    private func scheduleEntryScan() {
        Task {
            let snapshot = entry
            try? await Task.sleep(for: .milliseconds(120))
            if snapshot == entry { runEntryScan() }
        }
    }

    /// Scan mit lokalen Werten (Zone: Beginn ist absolut, Tag und Uhrzeit gelten in der LOKALEN Zeit).
    private func localized(_ s: QuickScan) -> QuickScan {
        var l = s
        if let st = s.start {
            let c = Calendar.current
            l.day = c.startOfDay(for: st)
            l.hour = c.component(.hour, from: st); l.minute = c.component(.minute, from: st)
        }
        return l
    }

    private func runEntryScan() {
        let sc = QuickAdd.scan(entry, now: Date())
        entryScan = sc
        let cal = Calendar.current
        var st = entryState ?? EntryState(day: cal.startOfDay(for: newStart),
                                          minutesOfDay: cal.component(.hour, from: newStart) * 60 + cal.component(.minute, from: newStart),
                                          duration: newMinutes)
        st.apply(scan: localized(sc), text: entry)
        entryState = st
        let newS = cal.date(byAdding: .minute, value: st.minutesOfDay, to: st.day) ?? newStart
        applyingEntry = true
        withAnimation(Theme.fold) {
            if newS != newStart { newStart = newS }
            if st.duration != newMinutes { newMinutes = st.duration }
        }
        DispatchQueue.main.async { applyingEntry = false }
    }

    /// Von Hand geändert → Quelle `.manual` (Regel 2).
    private func noteManualStart(old: Date, new: Date) {
        guard !applyingEntry, var st = entryState else { return }
        let cal = Calendar.current
        if !cal.isDate(old, inSameDayAs: new) { st.manualDay(cal.startOfDay(for: new)) }
        let mo = { (d: Date) in cal.component(.hour, from: d) * 60 + cal.component(.minute, from: d) }
        if mo(old) != mo(new) { st.manualTime(mo(new)) }
        entryState = st
        rewriteEntryFromHand()
    }

    /// Runde 114 (Punkt 3): Hand gewinnt UND das Feld zeigt es. Erkannter Zeit-/Dauer-Teil wird im Text ersetzt.
    private func rewriteEntryFromHand() {
        let cal = Calendar.current
        guard !entryScan.tokens.isEmpty else { return }
        let hasTimeTok = entryScan.tokens.contains { $0.kind == .time }
        let startMin = hasTimeTok ? cal.component(.hour, from: newStart) * 60 + cal.component(.minute, from: newStart) : nil
        guard let txt = EntryRewrite.rewrite(text: entry, scan: entryScan, start: startMin, minutes: newMinutes), txt != entry else { return }
        // Ohne Tages-Wort bleibt der gezogene Tag (sonst springt "7am" von heute auf morgen).
        if !entryScan.tokens.contains(where: { $0.kind == .day }), var st = entryState {
            st.manualDay(cal.startOfDay(for: newStart)); entryState = st
        }
        entry = txt
        runEntryScan()
    }

    private var entryMarks: [SmartEntryField.Mark] {
        let manual: (QuickScan.Kind) -> Bool = { k in
            guard let st = entryState else { return false }
            switch k { case .time: return st.sourceOf(.time) == .manual; case .day: return st.sourceOf(.day) == .manual
            case .duration: return st.sourceOf(.duration) == .manual; case .zone: return st.sourceOf(.zone) == .manual }
        }
        return entryScan.tokens.map { t in
            let isManual = manual(t.kind)
            var tip: String
            switch t.kind {
            case .day: tip = entryScan.day.map { L.date($0, "EEEEMMMd") } ?? ""
            case .time:
                if let s = entryScan.start {
                    tip = "\(L.time(s))–\(L.time(s.addingTimeInterval(Double(entryScan.minutes ?? newMinutes) * 60))) (\(entryScan.minutes ?? newMinutes) min)"
                } else { tip = "" }
            case .duration: tip = "\(entryScan.minutes ?? newMinutes) min"
            case .zone: tip = L.t("Zeitzone: ", "Time zone: ") + (entryScan.zoneID.map { ZoneNames.name($0) } ?? "")
            }
            if isManual { tip = L.t("Von Hand geändert, gilt nicht", "Changed by hand, ignored") }
            return SmartEntryField.Mark(range: t.range, manual: isManual, tip: tip)
        }
    }

    // MARK: - Kollisions-Warnung

    /// Zeigt VOR dem Erstellen, ob der geplante Zeitraum schon belegt ist.
    /// Andere Werkzeuge lassen einen doppelt buchen und zeigen den Konflikt
    /// erst hinterher im Kalender. Bewusst nur eine WARNUNG, kein Verbot:
    /// Doppelbelegung ist manchmal Absicht (Reise + Call, optionaler Termin).
    ///
    /// Ein noch nicht übernommener Freitext zählt schon mit, sonst prüft die
    /// Warnung den alten Formularstand, während oben längst etwas anderes steht.
    /// Während des Erstellens steht der neue Termin schon im Kalender, die
    /// ID-Liste ist aber noch leer: sonst meldet er sich selbst als Konflikt.
    /// Angezeigt wird die Warnung seit Runde 108 in der Uhrzeit-Zeile (`bigTime`).
    private var conflictWarningActive: Bool { state.warnOnConflicts && !google.busy }

    /// Runde 108 (Rückmeldung 19.11.: „Ich sehe den Kalender nicht, in den er es
    /// einträgt"): eine feste Zeile unter dem Knopf mit Farbpunkt und Namen
    /// jedes Ziel-Kalenders. Nur Anzeige, geändert wird in den Einstellungen.
    @ViewBuilder private var targetCalendarLine: some View {
        // Runde 108b (Rückmeldung: „den Kalender muss ich auswählen können"): Zeile
        // wie „Wiederholung", Klick klappt die beschreibbaren Kalender auf.
        // Die Wahl gilt ab dann für jedes „Neue Meeting" (eigener Schlüssel
        // `formCalendarID`, das Sofort-Meeting bleibt unberührt) und schreibt
        // immer in GENAU einen Kalender.
        let cals = targetCalendarNames
        VStack(spacing: 0) {
            // Runde 109e: wie ThemeDisclosureRow (ganze Zeile klickbar, gleiche Hover-Fläche).
            Button {
                withAnimation(Theme.fold) { calendarOpen.toggle() }
            } label: {
                HStack(spacing: Theme.s8) {
                    Text(L.t("Kalender", "Calendar")).font(.theme(.normal)).foregroundStyle(Theme.label)
                    Spacer(minLength: Theme.s8)
                    ForEach(Array(cals.enumerated()), id: \.offset) { i, c in
                        if i > 0 { Text("+").foregroundStyle(Theme.muted) }
                        Circle().fill(c.1).frame(width: 8, height: 8)
                        Text(c.0).foregroundStyle(Theme.blue).truncationMode(.middle)
                    }
                    Image(systemName: "chevron.down")
                        .font(.theme(.small, .bold)).foregroundStyle(Theme.blue)
                        .rotationEffect(.degrees(calendarOpen ? 180 : 0))
                        .frame(width: Theme.s16, height: Theme.s16)   // Runde 110b (U5)
                }
                .font(.theme(.normal, .medium)).lineLimit(1)
                .padding(.horizontal, Theme.s8).themeRow()
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(calHover || Theme.demoHover == "Calendar" ? Theme.fill : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { calHover = $0 }
            .padding(.horizontal, -Theme.s8)
            // Runde 110: alle Kalender, kein Scrollen; die Wahl lässt die Liste OFFEN (Zu nur über die Kopfzeile / Esc).
            let writable = Self.demoCalendars ?? state.calendar.writableCalendars()
            let natural = CGFloat(writable.count) * 28
            let capped = fit.calCap < natural
            ThemeFold(isOpen: calendarOpen) {
                let rows = VStack(spacing: 0) {
                    ForEach(writable) { c in
                        let chosen = targetCalendarIDs.count == 1 && targetCalendarIDs.first == c.id
                        CalendarPickRow(calendar: c, chosen: chosen) { pickCalendar(c) }
                    }
                }
                Group {
                    if capped { ScrollView { rows }.scrollIndicators(.automatic).frame(height: fit.calCap) } else { rows }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            .onAppear { ZoneListFit.shared.calNatural = calendarOpen ? natural : 0 }
            .onChange(of: calendarOpen) { _, o in ZoneListFit.shared.calNatural = o ? natural : 0 }
            .onChange(of: natural) { _, n in ZoneListFit.shared.calNatural = calendarOpen ? n : 0 }
        }
    }

    private var targetCalendarNames: [(String, Color)] {
        targetCalendarIDs.map { id -> (String, Color) in
            let all = state.availableCalendars.isEmpty ? state.calendar.allCalendars() : state.availableCalendars
            if let cid = id ?? state.calendar.defaultCalendarID,
               let c = all.first(where: { $0.id == cid }) { return (c.title, c.color) }
            return (L.t("Standardkalender", "Default calendar"), Theme.muted)
        }
    }

    private func pickCalendar(_ c: CalendarInfo) {
        // Runde 110: die Liste bleibt offen, Haken und Kopfzeile folgen sofort.
        state.pickFormCalendar(c)
    }

    /// Runde 113: Termine des gewählten Tages für den Streifen (ohne Ganztägige/Geburtstage, ohne den eben selbst angelegten).
    private func dayMeetings(for day: Date) -> [Meeting] {
        let mine = Set(google.lastCreatedEventIDs)
        return (Self.demoMeetings ?? state.calendar.dayAgenda(for: day, selected: state.selectedCalendarIDs))
            .filter { !$0.isAllDay && !$0.isBirthday && !mine.contains($0.id) }
    }

    private var shownEventDays: Set<Date> {
        if let demo = Self.demoMeetings { return Set(demo.map { Calendar.current.startOfDay(for: $0.start) }) }
        return eventDays
    }

    /// Runde 113: Punkte im Raster, eine Abfrage pro gezeigtem Zeitraum.
    private func loadEventDays(_ from: Date, _ to: Date) {
        if let demo = Self.demoMeetings {
            let cal = Calendar.current
            eventDays = Set(demo.map { cal.startOfDay(for: $0.start) })
            return
        }
        eventDays = state.calendar.daysWithEvents(from: from, to: to, selected: state.selectedCalendarIDs)
    }

    /// Runde 109: der erste Termin, der nach dem geplanten Ende beginnt (selber Tag).
    private func computeNext() -> Meeting? {
        let start = newStart
        let end = start.addingTimeInterval(Double(newMinutes) * 60)
        let mine = Set(google.lastCreatedEventIDs)
        let day = Calendar.current.startOfDay(for: start)
        let agenda: [Meeting]
        if let d = Self.demoMeetings { agenda = d }
        else if let c = Self.agendaMemo, c.day == day, Date().timeIntervalSince(c.at) < 20 { agenda = c.items }
        else {
            agenda = state.calendar.dayAgenda(for: start, selected: state.selectedCalendarIDs)
            Self.agendaMemo = (day, agenda, Date())
        }
        return agenda
            .filter { m in
                !m.isAllDay && !m.isBirthday && m.start >= end && !mine.contains(m.id)
                    && Calendar.current.isDate(m.start, inSameDayAs: start)
            }
            .sorted { $0.start < $1.start }.first
    }

    /// Die eigentliche Abfrage, aufgerufen entprellt aus `.task(id:)`.
    private func computeConflicts() -> [Meeting] {
        guard state.warnOnConflicts, !google.busy else { return [] }
        let start = newStart
        let mins = newMinutes
        // Gerade selbst angelegte Termine sind kein Konflikt.
        let mine = Set(google.lastCreatedEventIDs)
        let raw = Self.demoMeetings.map { pool in
            pool.filter { $0.start < start.addingTimeInterval(Double(mins) * 60) && $0.end > start }
        } ?? state.calendar.conflicts(start: start, minutes: mins, selected: state.selectedCalendarIDs)
        return raw
            .filter { m in
                if mine.contains(m.id) { return false }
                if let c = google.lastCreatedSlot, m.title == c.title,
                   abs(m.start.timeIntervalSince(c.start)) < 60,
                   abs(m.end.timeIntervalSince(c.end)) < 60 { return false }
                return true
            }
    }

    /// Runde 90: die gewählte Zeit groß oben (v4), dahinter Tag und Dauer.
    /// Runde 96: Große Uhrzeit in Blau = das, was man auswählt. Klick darauf =
    /// Uhrzeit tippen (gleiche Regeln wie früher das Uhrzeit-Feld), daneben die
    /// zwei runden ±15-Min-Knöpfe. Die eigene Zeile "Uhrzeit" fällt weg.
    private var bigTime: some View {
        // Runde 98: zeigt nur die Formularwerte, keine Freitext-Vorschau (die steht darunter).
        let start = newStart
        // Runde 99: Uhrzeit + kleines senkrechtes ▲▼-Paar bilden EINE Hover-Fläche,
        // Datum und Dauer folgen rechts, alles vertikal zentriert.
        return HStack(alignment: .center, spacing: Theme.s8) {
            HStack(alignment: .center, spacing: Theme.s4) {
                if editingTime {
                    // Runde 108c (Fable F1): im Feld nur die Ziffern, AM/PM klein
                    // dahinter wie in der Anzeige. Vorher stand „10:30 AM" ganz in
                    // 44 pt im Feld und war breiter als das Feld (abgeschnitten).
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        TextField("", text: $timeText)
                            .textFieldStyle(.plain)
                            .font(.theme(.big, .bold).monospacedDigit())
                            .fixedSize()   // so breit wie der Text, AM/PM klebt direkt dran
                            .focused($timeFocused)
                            .onExitCommand { editingTime = false }   // Esc: erst das Feld abbrechen
                            .onSubmit(commitTime)
                            .onChange(of: timeFocused) { _, now in if !now { commitTime() } }
                        if let suffix = editSuffix {
                            Text(suffix).font(.theme(.title, .bold)).fixedSize()
                        }
                    }
                    .foregroundStyle(Theme.blue)
                } else {
                    Button {
                        let parts = Self.splitTime(ZonePlanner.uiHM(start, .current))
                        timeText = parts.0
                        editSuffix = parts.1
                        editingTime = true
                        DispatchQueue.main.async { timeFocused = true }
                    } label: {
                        // Runde 108b: KEIN minimumScaleFactor mehr. „10:15 AM" wurde
                        // dadurch kleiner als „9:00 AM", die Zeile niedriger, und
                        // der ganze Inhalt rutschte hoch (Rückmeldung: „springt", Lücke
                        // unten, „die Zeit wird immer kleiner"). Jetzt: Ziffern
                        // immer 44 pt, AM/PM klein dahinter, feste Breite.
                        let parts = Self.splitTime(ZonePlanner.uiHM(start, .current))
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(parts.0).font(.theme(.big, .bold)).monospacedDigit().contentTransition(.numericText())
                            if let suffix = parts.1 {
                                Text(suffix).font(.theme(.title, .bold))
                            }
                        }
                        .foregroundStyle(Theme.blue)
                        .lineLimit(1).fixedSize()   // Runde 110b (U1): natürliche Breite, ▲▼ direkt dahinter
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L.t("Klicken, um die Uhrzeit zu tippen", "Click to type the time"))
                }
                VStack(spacing: 0) {
                    stepArrow("chevron.up", L.t("15 Minuten später", "15 minutes later")) { shiftTime(900) }
                    stepArrow("chevron.down", L.t("15 Minuten früher", "15 minutes earlier")) { shiftTime(-900) }
                }
            }
            .padding(.leading, Theme.s8).padding(.trailing, Theme.s4)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(timeHover || Theme.demoHover == "time" ? Theme.fill : .clear))
            .onHover { timeHover = $0 }
            // Runde 108: Die Überschneidungs-Warnung steht HIER statt als eigener
            // Block unter dem Formular. Der Block ließ das Fenster beim Scrollen
            // der Uhrzeit wachsen und schrumpfen (Rückmeldung 19.11.). Immer genau zwei
            // Zeilen, also bleibt die Höhe gleich. Tag und Dauer stehen ohnehin
            // in der Wochenleiste und der Dauer-Zeile.
            let hits = conflictWarningActive ? conflictHits : []
            Group {
                if hits.isEmpty {
                    // Runde 109: statt Datum und Dauer (stehen darunter) das nächste Meeting.
                    // 109c (U1): Zeit MIT AM/PM, Titel bis 2 Zeilen, Tooltip mit vollem Titel.
                    // Runde 111b (B5): immer kleine Überschrift "Danach" und EINE Zeile darunter.
                    // Runde 112 (Fund 12): normale Schreibung statt Großbuchstaben, "Danach: …" / "Next: …".
                    VStack(alignment: .trailing, spacing: 0) {
                        if let n = nextAfter {
                            // Runde 113c: höchstens 2 Zeilen: Titel einzeilig mit "…", darunter die Uhrzeit.
                            VStack(alignment: .trailing, spacing: 0) {
                                // Runde 114 (Punkt 6): gleiches Wort wie im Widget; Zeile 1 = Wort + Uhrzeit, Zeile 2 = Titel.
                                // Runde 115: Uhrzeit immer ganz (fixedSize), nur der Titel bekommt "…".
                                ViewThatFits(in: .horizontal) {
                                    Text("\(L.t("Als Nächstes", "Next up")) · \(ZonePlanner.uiHM(n.start, .current))")
                                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                    Text(ZonePlanner.uiHM(n.start, .current))
                                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                                }
                                Text(n.title).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                            }
                            .font(.theme(.normal)).foregroundStyle(Theme.label.opacity(0.85))
                            .multilineTextAlignment(.trailing)
                            .transaction { $0.animation = nil }
                        } else {
                            Text(L.t("Sonst nichts heute", "Nothing else today"))
                                .font(.theme(.normal)).foregroundStyle(Theme.label.opacity(0.85)).lineLimit(2).multilineTextAlignment(.trailing)
                        }
                    }
                    .foregroundStyle(Theme.muted)
                    .help(nextAfter.map { "\($0.rangeLabel) · \($0.title)" } ?? "")
                } else {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("⚠︎ " + (hits.count == 1 ? L.t("Belegt", "Busy") : L.t("\(hits.count)× belegt", "\(hits.count)× busy")) + ": " + hits[0].title)
                            .font(.theme(.normal)).lineLimit(3).truncationMode(.tail).multilineTextAlignment(.trailing)
                    }
                    .foregroundStyle(Theme.warn)
                    .help(L.t("Überschneidet sich mit:", "Overlaps with:") + "\n"
                          + hits.prefix(3).map { "\($0.rangeLabel) · \($0.title)" }.joined(separator: "\n"))
                }
            }
            .font(.theme(.small))
            .lineLimit(1).layoutPriority(1)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)   // Runde 110b (U1): Block rechtsbündig
        }
        // Runde 108b: feste Höhe, egal welche Uhrzeit oder Warnung drinsteht.
        .frame(height: 56)
        // Runde 97: Scrollrad/Trackpad über der Uhrzeit: hoch = später, runter = früher.
        .modifier(ScrollStepper { shiftTime(Double($0) * 900) })
    }

    /// Runde 108c (Fable K1): Breite der Uhrzeit nach Sprache. EN „10:15" + „AM"
    /// = 164 pt, DE „10:15" = 126 pt (gemessen, 44 pt bold).
    static var timeWidth: CGFloat { L.isDE ? 130 : 168 }

    /// „10:15 AM" → ("10:15", "AM"); „10:15" → ("10:15", nil).
    static func splitTime(_ s: String) -> (String, String?) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let r = t.rangeOfCharacter(from: .whitespaces, options: .backwards) {
            let tail = String(t[r.upperBound...])
            if tail.rangeOfCharacter(from: .decimalDigits) == nil, !tail.isEmpty {
                return (String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces), tail)
            }
        }
        return (t, nil)
    }

    private func stepArrow(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.theme(.small, .bold)).foregroundStyle(Theme.muted)
                .frame(width: Theme.s24, height: Theme.s16 + Theme.s4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
        .accessibilityLabel(tip)
    }

    private func shiftTime(_ seconds: TimeInterval) {
        withAnimation(.smooth(duration: 0.2)) { newStart = newStart.addingTimeInterval(seconds) }   // 113c: Übergang nur bei Einzelschritten
    }

    private func commitTime() {
        // AM/PM aus der Anzeige gilt, solange man selbst keins tippt
        // („11:30" bei „AM" = 11:30 AM; „17:00" passt nicht zu PM → 24-h-Zeit).
        let typedRaw = timeText.trimmingCharacters(in: .whitespaces)
        let low = typedRaw.lowercased()
        var typed = typedRaw
        if let suffix = editSuffix, !low.hasSuffix("am"), !low.hasSuffix("pm"),
           TimeEntryParser.parse(typedRaw + " " + suffix) != nil {
            typed = typedRaw + " " + suffix
        }
        if let (h, m) = TimeEntryParser.parse(typed),
           let d = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: newStart) {
            newStart = d
        }
        editingTime = false
    }

    // MARK: - Freitext (F8)

    // MARK: - Formular (scrollender Teil)

    /// Alles zwischen Titelfeld und Erstellen-Button.
    @ViewBuilder private var formFields: some View {
        Group {
            // Runde 96: Standard = eine Wochenleiste (derselbe Baustein wie im
            // Widget); Klick auf den Titel klappt den ganzen Monat auf.
            MonthGrid(selection: $newStart, firstWeekday: state.firstWeekday,
                      mode: monthOpen ? .month : .week,
                      onToggleMode: {
                          withAnimation(Theme.fold) { monthOpen.toggle() }
                      },
                      dimPast: true, eventDays: shownEventDays,
                      onRange: { f, t in loadEventDays(f, t) })
                .id(state.appLanguage)

            // Runde 113: der ganze Tag 0–24 wie im Widget, der geplante Termin als ziehbarer Block.
            DayStrip(meetings: dayMeetings(for: newStart), day: newStart,
                     showNow: Calendar.current.isDateInToday(newStart),
                     onTap: { _ in },
                     draft: (newStart, newMinutes), draftTitle: newTitle, editable: true,
                     onDraftStart: { d in var t = Transaction(); t.disablesAnimations = true; withTransaction(t) { newStart = d } })

            // Runde 109: Dauer-Knöpfe wie bisher, die blaue Pille lässt sich ziehen.
            // Außerhalb der Stufen (Freitext 20 min) keine Pille, die Zahl steht ehrlich daneben.
            ThemeFormRow(title: L.t("Dauer", "Duration"),
                         note: [15, 30, 45, 60, 90].contains(newMinutes) ? "min" : "\(newMinutes) min") {   // Runde 114: Einheit immer sichtbar
                ThemeSegmented(options: [("15", 15), ("30", 30), ("45", 45), ("60", 60), ("90", 90)],
                               selection: $newMinutes, draggable: true)
            }

            // Zeitzonen: zugeklappt EINE Zeile mit den angehakten Städten.
            ZonePlanner(start: $newStart, minutes: newMinutes, listCap: fit.cap)

            // Runde 109: Kalender direkt nach den Zeitzonen, vor „Mehr…“.
            targetCalendarLine

            // Runde 113c (Punkt 8): keine Klappe "Mehr" mehr. Direkt die Zeile "Wiederholen" mit dem Wert rechts.
            VStack(spacing: 0) {
                ThemeDisclosureRow(title: L.t("Wiederholen", "Repeat"),
                                   value: newRepeat == .custom ? customRec.summary : newRepeat.label,
                                   accentValue: true, isOpen: repeatOpen) {
                    withAnimation(Theme.fold) { repeatOpen.toggle() }
                }
                ThemeFold(isOpen: repeatOpen) {
                    VStack(spacing: 0) {
                        ForEach(RepeatRule.allCases) { rule in
                            ThemeTextRow(title: rule.label, icon: rule == newRepeat ? "checkmark" : nil,
                                         accent: rule == newRepeat, compact: true) {
                                newRepeat = rule
                                if rule != .custom { lastRepeat = rule.rawValue }
                                withAnimation(Theme.fold) { repeatOpen = false }
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
                }
                ThemeFold(isOpen: newRepeat == .custom) { customBuilder }
            }
        }
    }

    // MARK: - Gast (Runde 109)

    /// Ergebniszeile(n) zur Mail in der Ergebnisansicht.
    @ViewBuilder private var mailResult: some View {
        switch google.lastMailStatus {
        case .sent(let to):
            HStack(spacing: Theme.s8) {
                Image(systemName: "envelope.fill").foregroundStyle(Theme.ok)
                Text(L.t("Einladung an \(to.joined(separator: ", ")) gesendet",
                         "Invite sent to \(to.joined(separator: ", "))"))
                    .font(.theme(.small)).foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
        case .failed(let f):
            VStack(alignment: .leading, spacing: Theme.s4) {
                Text(GoogleService.mailFailureText(f))
                    .font(.theme(.small)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                HStack(spacing: Theme.s8) {
                    if f == .needsScope || f == .expired {
                        ThemeTextRow(title: L.t("Neu verbinden", "Reconnect"), accent: true, fullWidth: false, compact: true) {
                            Task { await google.connect() }
                        }
                    }
                    if let r = mailRetry {
                        ThemeTextRow(title: L.t("Nochmal senden", "Send again"), accent: true, fullWidth: false, compact: true) {
                            Task {
                                if await google.sendInviteMail(to: r.to, subject: r.subject, body: r.body, ics: r.ics) {
                                    guests = [""]; mailRetry = nil
                                }
                            }
                        }
                    }
                    ThemeTextRow(title: L.t("Text kopieren", "Copy text"), accent: true, fullWidth: false, compact: true) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(google.lastShareText ?? "", forType: .string)
                    }
                }
            }
        case nil:
            EmptyView()
        }
    }

    private var guestList: MailInvite.GuestList { MailInvite.parseGuestList(guests) }
    private var guestParsed: (list: [String], ok: Bool, empty: Bool) { (guestList.list, guestList.ok, guestList.empty) }
    /// Mail geht wirklich raus: Haken an UND Gmail-Recht UND gültige Adresse.
    private var mailWillSend: Bool { mailOn && google.canSendMail && guestParsed.ok && !guestParsed.empty }
    /// Runde 109c (R2): Haken an, aber Google hat das Senden noch nicht erlaubt.
    private var mailNeedsReconnect: Bool { mailOn && !google.canSendMail }
    private var guestInvalid: Bool { !guestParsed.empty && !guestParsed.ok }
    private var canTickMail: Bool { !guestParsed.empty && guestParsed.ok }

    /// Runde 113: Haken der Mail-Zeile, nicht gemerkt (hängt an der Adresse).
    @State private var mailOn = false
    @State private var mailManualOff = false
    /// 0 = keine, 1 = Mail, 2 = Text. Immer nur eine Vorschau offen.
    @State private var previewWhich = 0

    private func togglePreview(_ k: Int) {
        withAnimation(Theme.fold) { previewWhich = previewWhich == k ? 0 : k }
    }

    /// Runde 113: Adresse getippt → Haken von selbst an (außer von Hand ausgemacht); gelöscht/ungültig → aus.
    private func guestChanged() {
        mailManualOff = false
        if guestParsed.empty || !guestParsed.ok { mailOn = false }
        else { mailOn = true }
    }

    // MARK: - Mehrere Gäste (Runde 119)

    private func guestBinding(_ i: Int) -> Binding<String> {
        Binding(get: { i < guests.count ? guests[i] : "" }, set: { guestSet(i, $0) })
    }

    /// Komma/Semikolon/Zeilenumbruch (oder `Name <a@b>`) = Adresse fertig bzw. Liste eingefügt → auf Zeilen verteilen.
    private func guestSet(_ i: Int, _ new: String) {
        guard i < guests.count else { return }
        let sepTyped = new.contains(where: { $0 == "," || $0 == ";" || $0 == "\n" })
        guard sepTyped || (new.contains("<") && new.contains(">")) else { guests[i] = new; return }
        let sp = MailInvite.splitPasted(new)
        guard !sp.list.isEmpty else { guests[i] = new.filter { $0 != "," && $0 != ";" && $0 != "\n" }; return }
        var rows = guests
        rows.replaceSubrange(i...i, with: sp.list)
        var cut = sp.cut
        if rows.count > MailInvite.maxGuests { rows = Array(rows.prefix(MailInvite.maxGuests)); cut = true }
        let last = min(i + sp.list.count - 1, rows.count - 1)
        let trailing = new.last.map { $0 == "," || $0 == ";" || $0 == "\n" } ?? false
        if trailing && last == rows.count - 1 && rows.count < MailInvite.maxGuests { rows.append("") }
        guests = rows
        if cut { guestNote = L.t("Nur 5 Gäste pro Mail", "Only 5 guests per mail") }
        let target = trailing ? min(last + 1, rows.count - 1) : last
        DispatchQueue.main.async { focusedGuest = target }
    }

    private func guestSubmit(_ i: Int) {
        guard i < guests.count else { return }
        let t = guests[i].trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { if i > 0 { removeGuest(i) }; return }
        if MailInvite.isValidAddress(t) && i == guests.count - 1 && guests.count < MailInvite.maxGuests {
            guests.append("")
            DispatchQueue.main.async { focusedGuest = i + 1 }
        } else if i < guests.count - 1 {
            focusedGuest = i + 1
        }
    }

    /// Erst Fokus nach oben, dann löschen (nie auf eine gelöschte Zeile zeigen).
    private func removeGuest(_ i: Int) {
        guard i > 0, i < guests.count else { return }
        focusedGuest = i - 1
        guestNote = nil
        DispatchQueue.main.async { if i < guests.count { guests.remove(at: i) } }
    }

    private var canAddGuest: Bool {
        guests.count < MailInvite.maxGuests && !guests[0].trimmingCharacters(in: .whitespaces).isEmpty
            && !guests.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func guestField(_ i: Int) -> some View {
        TextField(L.t("Gast-E-Mail", "Guest email"), text: guestBinding(i))
            .textFieldStyle(ThemeFieldStyle())
            .focused($focusedGuest, equals: i)
            .onSubmit { guestSubmit(i) }
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(guestShowError && guestList.invalidRows.contains(i) ? Theme.danger : .clear, lineWidth: 1))
            .help(L.t("Die Einladung geht in einer Mail an alle Gäste (höchstens 5).",
                      "One email goes to all guests (max 5)."))
    }

    @ViewBuilder private var extraGuestRows: some View {
        ForEach(Array(guests.indices.dropFirst()), id: \.self) { i in
            HStack(spacing: Theme.s8) {
                guestField(i)
                Button { removeGuest(i) } label: {
                    Image(systemName: "minus.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help(L.t("Gast entfernen", "Remove guest"))
            }
            .padding(.leading, Theme.s24)
            .frame(minHeight: 32)
            .padding(.top, Theme.s4)
        }
        if canAddGuest {
            ThemeTextRow(title: L.t("+ Gast", "+ Add guest"), accent: true, fullWidth: false, compact: true) {
                guests.append(""); DispatchQueue.main.async { focusedGuest = guests.count - 1 }
            }
            .padding(.leading, Theme.s24)
        } else if guests.count >= MailInvite.maxGuests {
            Text(L.t("Höchstens 5 Gäste", "Max 5 guests")).font(.theme(.small)).foregroundStyle(Theme.muted)
                .padding(.leading, Theme.s24).padding(.vertical, Theme.s4)
        }
    }

    // MARK: - Nach dem Erstellen (Runde 113)

    private func afterRow<Content: View, Trailing: View>(on: Bool, enabled: Bool = true, toggle: @escaping () -> Void,
                                                          @ViewBuilder content: () -> Content,
                                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Theme.s8) {
            Button(action: toggle) {
                HStack(spacing: Theme.s8) {
                    ThemeCheck(isOn: on, enabled: enabled)
                    content()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
        .frame(minHeight: 32)
    }

    private func previewButton(_ k: Int) -> some View {
        ThemeTextRow(title: L.t("Vorschau", "Preview"), trailingIcon: previewWhich == k ? "chevron.up" : "chevron.down",
                     fullWidth: false, compact: true) { togglePreview(k) }
    }

    @ViewBuilder private var afterCreating: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ThemeSectionTitle(L.t("Nach dem Erstellen", "After creating"))
                Spacer(minLength: Theme.s8)
                // Runde 114 (Punkt 6): beschriftet, sonst sieht der Schalter wie die App-Sprache aus.
                Text(L.t("Einladung", "Invite")).font(.theme(.small)).foregroundStyle(Theme.muted)
                ThemeSegmented(options: [("EN", "en"), ("DE", "de")], selection: $state.inviteLanguage)
            }
            .frame(minHeight: 32)

            // Mail: Haken + Feld direkt in der Zeile
            HStack(spacing: Theme.s8) {
                Button {
                    guard canTickMail else { return }
                    mailOn.toggle(); mailManualOff = !mailOn
                } label: { ThemeCheck(isOn: mailOn, enabled: canTickMail).frame(height: 32).contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .help(canTickMail ? "" : L.t("Erst eine gültige Adresse eintragen.", "Enter a valid address first."))
                guestField(0)
                previewButton(1)
            }
            .frame(minHeight: 32)
            .task(id: guests) {
                // Entprellt: Fehler erst zeigen, wenn man kurz aufhört zu tippen.
                guestShowError = false
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { guestShowError = true }
            }
            extraGuestRows
            ThemeFold(isOpen: (guestInvalid && guestShowError) || !guestList.dupRows.isEmpty || (guestNote != nil && guests.count >= MailInvite.maxGuests) || mailNeedsReconnect, gap: 0) {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    if guestInvalid && guestShowError {
                        Text(L.t("Adresse prüfen", "Check the address"))
                            .font(.theme(.small)).foregroundStyle(Theme.danger)
                    } else if !guestList.dupRows.isEmpty {
                        Text(L.t("Schon eingetragen", "Already added"))
                            .font(.theme(.small)).foregroundStyle(Theme.muted)
                    } else if let n = guestNote, guests.count >= MailInvite.maxGuests {
                        Text(n).font(.theme(.small)).foregroundStyle(Theme.muted)
                    } else if mailNeedsReconnect {
                        HStack(spacing: Theme.s8) {
                            Text(L.t("Mail geht erst nach „Google neu verbinden“.", "Mail only works after “Reconnect Google”."))
                                .font(.theme(.small)).foregroundStyle(Theme.warn)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            ThemeTextRow(title: L.t("Neu verbinden", "Reconnect"), accent: true, fullWidth: false, compact: true) {
                                Task { await google.connect() }
                            }
                        }
                    }
                }
                .padding(.leading, Theme.s24)
                .padding(.bottom, Theme.s4)
            }
            ThemeFold(isOpen: previewWhich == 1, gap: 0) { mailPreviewBox.padding(.vertical, Theme.s4) }

            // Text
            afterRow(on: state.copyInviteOnCreate, toggle: { state.copyInviteOnCreate.toggle() },
                     content: { Text(L.t("Einladungstext kopieren", "Copy invite text")).font(.theme(.normal)).foregroundStyle(Theme.label) },
                     trailing: { previewButton(2) })
            ThemeFold(isOpen: previewWhich == 2, gap: 0) { textPreviewBox.padding(.vertical, Theme.s4) }

            // Datei
            afterRow(on: state.createICSFile, toggle: { state.createICSFile.toggle() },
                     content: { Text(L.t("Kalenderdatei (.ics) sichern", "Save calendar file (.ics)")).font(.theme(.normal)).foregroundStyle(Theme.label) },
                     trailing: { Text("Downloads").font(.system(size: 11)).foregroundStyle(Theme.muted) })
        }
        .onChange(of: guests) { _, _ in guestChanged() }
        .onChange(of: mailOn) { _, on in if on { state.mailInviteEnabled = true } }
    }

    // MARK: - Vorschau bearbeitbar (Runde 119)

    /// Aktuelle Formularwerte als Marken-Werte (Anzeige in den Pillen). Meet-Link = „Meet link“.
    private func tokenValues(text: Bool) -> [String: String] {
        let end = newStart.addingTimeInterval(Double(newMinutes) * 60)
        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var f = MailInvite.Fields(title: t.isEmpty ? "Meeting" : t, start: newStart, end: end, link: Self.placeholderLink,
                                  zoneIDs: book.invitedIDs, labels: book.labels, de: L.inviteIsDE)
        if text { f.timesSeparator = nil }
        var d: [String: String] = [:]
        for k in MailInvite.tokenKeys { d[k] = MailInvite.render("{\(k)}", f) }
        d["link"] = L.t("Meet-Link", "Meet link")
        return d
    }

    private var effectiveMail: MailDraft {
        mailOverride ?? { let t = mailTemplate(); return MailDraft(subject: t.subject, body: t.body) }()
    }
    private var mailEdited: Bool {
        guard let o = mailOverride else { return false }
        let t = mailTemplate(); return o != MailDraft(subject: t.subject, body: t.body)
    }
    private var textTemplateNow: String {
        let de = L.inviteIsDE
        let v = de ? state.inviteTextDE : state.inviteTextEN
        return v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (de ? MailInvite.defaultInviteTextDE : MailInvite.defaultInviteTextEN) : v
    }
    private var textEdited: Bool { textOverride != nil && textOverride != textTemplateNow }

    private var mailSubjectBinding: Binding<String> {
        Binding(get: { effectiveMail.subject }, set: { mailOverride = MailDraft(subject: $0, body: effectiveMail.body) })
    }
    private var mailBodyBinding: Binding<String> {
        Binding(get: { effectiveMail.body }, set: { mailOverride = MailDraft(subject: effectiveMail.subject, body: $0) })
    }
    private var textBinding: Binding<String> {
        Binding(get: { textOverride ?? textTemplateNow }, set: { textOverride = $0 })
    }

    private func boxBorder(focus: Bool, hover: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(focus ? Theme.blue : (hover ? Theme.muted.opacity(0.4) : Color.clear), lineWidth: focus ? 1.5 : 1)
    }

    private func flashSaved() {
        savedFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedFlash = false }
    }

    @ViewBuilder private func previewFooter(edited: Bool, reset: @escaping () -> Void, save: @escaping () -> Void) -> some View {
        if edited {
            VStack(alignment: .leading, spacing: 0) {
                Text(L.t("Geändert · nur dieses Meeting", "Edited · only this meeting"))
                    .font(.theme(.small)).foregroundStyle(Theme.muted)
                HStack(spacing: Theme.s16) {
                    ThemeTextRow(title: L.t("Zurücksetzen", "Reset"), accent: true, fullWidth: false, compact: true, action: reset)
                    ThemeTextRow(title: L.t("Als Vorlage speichern", "Save as template"), accent: true, fullWidth: false, compact: true, action: save)
                }
            }
        } else if savedFlash {
            Text(L.t("Als Vorlage gespeichert", "Saved as template")).font(.theme(.small)).foregroundStyle(Theme.muted)
        } else {
            ThemeTextRow(title: L.t("Vorlage bearbeiten …", "Edit template …"), accent: true, fullWidth: false, compact: true) {
                UserDefaults.standard.set(3, forKey: "settingsTab")
                UserDefaults.standard.set("mailText", forKey: "settingsScrollTo")
                // Termin-Fenster bleibt offen, Einstellungen gehen daneben auf (Runde 109c R1).
                SettingsPanelController.shared.close()
                state.toggleSettingsPanel()
            }
        }
    }

    private var mailPreviewBox: some View {
        let vals = tokenValues(text: false)
        return VStack(alignment: .leading, spacing: Theme.s8) {
            VStack(alignment: .leading, spacing: Theme.s8) {
                TokenTextView(template: mailSubjectBinding, values: vals, bold: true, single: true, focused: $subjFocus)
                Rectangle().fill(Theme.muted.opacity(0.25)).frame(height: 1)
                TokenTextView(template: mailBodyBinding, values: vals, focused: $bodyFocus)
            }
            .padding(Theme.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
            .overlay(boxBorder(focus: subjFocus || bodyFocus, hover: mailHover))
            .onHover { mailHover = $0 }
            Text(L.t("Der Meet-Link kommt beim Erstellen dazu.", "The Meet link is added when you create the meeting."))
                .font(.theme(.small)).foregroundStyle(Theme.muted)
            previewFooter(edited: mailEdited, reset: { mailOverride = nil }, save: {
                let m = effectiveMail
                if L.inviteIsDE { state.mailSubjectDE = m.subject; state.mailBodyDE = m.body }
                else { state.mailSubjectEN = m.subject; state.mailBodyEN = m.body }
                mailOverride = nil; flashSaved()
            })
        }
    }

    private var textPreviewBox: some View {
        VStack(alignment: .leading, spacing: Theme.s8) {
            TokenTextView(template: textBinding, values: tokenValues(text: true), focused: $textFocus)
                .padding(Theme.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
                .overlay(boxBorder(focus: textFocus, hover: textHover))
                .onHover { textHover = $0 }
            Text(L.t("Der Meet-Link kommt beim Erstellen dazu.", "The Meet link is added when you create the meeting."))
                .font(.theme(.small)).foregroundStyle(Theme.muted)
            previewFooter(edited: textEdited, reset: { textOverride = nil }, save: {
                let t = textBinding.wrappedValue
                if L.inviteIsDE { state.inviteTextDE = t } else { state.inviteTextEN = t }
                textOverride = nil; flashSaved()
            })
        }
    }

    /// Mailvorlage (Betreff, Text) in der Einladungssprache; leer = Standard.
    private func mailTemplate() -> (subject: String, body: String) {
        let de = L.inviteIsDE
        let subj = de ? state.mailSubjectDE : state.mailSubjectEN
        let body = de ? state.mailBodyDE : state.mailBodyEN
        return (subj.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? MailInvite.defaultSubject : subj,
                body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (de ? MailInvite.defaultBodyDE : MailInvite.defaultBodyEN) : body)
    }

    /// Baut und sendet die Mail zu dem gerade erstellten Termin. Fehler stehen danach in `google.lastMailStatus`.
    private func sendGuestMail(to: [String], title: String, start: Date, minutes: Int) async {
        let end = start.addingTimeInterval(Double(minutes) * 60)
        let link = google.lastMeetLink ?? ""
        let f = MailInvite.Fields(title: title, start: start, end: end, link: link,
                                  zoneIDs: book.invitedIDs, labels: book.labels, de: L.inviteIsDE)
        let t = effectiveMail
        let subject = MailInvite.render(t.subject, f)
        let body = MailInvite.render(t.body, f)
        let ics = state.mailAttachICS
            ? ICSExport.build(title: title, start: start, end: end, link: link,
                              recurrence: newRepeat, custom: newRepeat == .custom ? customRec : nil)
            : nil
        mailRetry = (to, subject, body, ics)
        if await google.sendInviteMail(to: to, subject: subject, body: body, ics: ics) {
            guests = [""]; mailRetry = nil
        }
    }

    // MARK: - Fuß (steht immer sichtbar unter dem Formular)

    /// Runde 111b: Hinweiszeile weg, die drei Schalter unter dem Knopf sagen es.
    private static let placeholderLink = "https://meet.google.com/…"

    private var createButton: some View {
        ThemePrimaryButton(title: google.busy ? L.t("Erstelle…", "Creating…")
                                              : CreateButtonTitle.make(mailTo: mailWillSend ? guestParsed.list : [],
                                                                       text: state.copyInviteOnCreate, ics: state.createICSFile,
                                                                       de: L.isDE),
                           busy: google.busy, keyHint: "↩") {
            performCreate()
        }
        .keyboardShortcut(.return, modifiers: .command)   // Runde 114: ⌘↩ erstellt von überall im Fenster
        .disabled(google.busy)
        .help(CreateButtonTitle.tooltip(calendar: targetCalendarNames.map(\.0).joined(separator: " + "),
                                        mailTo: mailWillSend ? guestParsed.list : [],
                                        text: state.copyInviteOnCreate, ics: state.createICSFile, de: L.isDE))
    }

    /// Runde 114: Return im Eingabefeld erstellt (nur mit Text, damit ein Versehen keinen leeren Termin macht).
    private func submitFromField() {
        guard !google.busy, !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        performCreate()
    }

    private func performCreate() {
        // Runde 113: alles ist schon übernommen, es gilt, was angezeigt wird. Der Titel ist der Text ohne erkannte Teile.
        let title = newTitle
        let start = newStart
        let minutes = newMinutes
        // Zeitzone aus dem Text kommt erst beim Erstellen in die Zonenliste (Regel 7).
        if let id = entryScan.zoneID { ZoneBook.shared.add(id) }
        let mailTo = mailWillSend ? guestParsed.list : []
        let finalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Meeting"
            : title.trimmingCharacters(in: .whitespacesAndNewlines)

        let textTpl = textEdited ? textOverride : nil
        // Runde 122c: geht das Widget gleich mit zu, friert sein Inhalt JETZT ein (vor dem Schreiben, denn EventKit
        // meldet die Änderung schon während des Erstellens). Aufgetaut wird nach dem Ausblenden oder sofort, wenn
        // das Widget doch offen bleibt (Fehler, Mail-Fehler).
        let freeze = !state.keepWidgetOpenAfterCreate && !state.showResultAfterCreate && WidgetPanelController.shared.isOpen
        if freeze { state.monitor.freezeForClose() }
        Task {
            GoogleService.textTemplateOverride = textTpl
            defer { GoogleService.textTemplateOverride = nil }
            var closingNow = false
            defer { if freeze, !closingNow { state.monitor.unfreeze() } }
            if await google.createAppleMeeting(title: title, start: start,
                                               minutes: minutes,
                                               calendarIDs: targetCalendarIDs,
                                               recurrence: newRepeat,
                                               custom: newRepeat == .custom ? customRec : nil,
                                               autoTranscribe: state.autoTranscribe,
                                               autoSmartNotes: state.autoSmartNotes,
                                               makeICS: state.createICSFile,
                                               copyInvite: state.copyInviteOnCreate,
                                               calendarService: state.calendar) {
                state.monitor.tickNow()   // show it in agenda/timeline right away
                if !mailTo.isEmpty, !DryCreate.isOn { await sendGuestMail(to: mailTo, title: finalTitle, start: start, minutes: minutes) }
                // Runde 87: „im Call" gilt für DIESEN Call. Der Einladungs-
                // text ist schon geschrieben, die Haken gehen zurück.
                ZoneBook.shared.resetTicks()
                mailOverride = nil; textOverride = nil   // Runde 119: Bearbeitung galt nur für dieses Meeting
                // Runde 84: ohne Ergebnisansicht gleich zu, die .ics liegt
                // trotzdem schon in ~/Downloads.
                // Runde 109: bei Mail-Fehler bleibt das Fenster offen, damit man ihn sieht.
                var mailFailed = false
                if case .failed = google.lastMailStatus { mailFailed = true }
                // Runde 121: Erfolg (kein Mail-Fehler) und Widget nicht „offen lassen" -> Widget geht mit zu.
                let closeWidget = AfterCreate.closeWidget(keepOpen: state.keepWidgetOpenAfterCreate, success: true, mailFailed: mailFailed)
                if closeWidget { CreatePanelController.shared.closeWidgetWithMe = true }
                if !state.showResultAfterCreate, !mailFailed {
                    google.resetCreateFeedback()
                    closingNow = closeWidget && WidgetPanelController.shared.isOpen   // taut nach dem Ausblenden auf
                    onClose?()
                }
            }
        }
    }

    /// Wohin geschrieben wird: immer das Ziel aus den Einstellungen.
    private var targetCalendarIDs: [String?] { state.effectiveCreateCalendarIDs }

    /// Custom recurrence editor (Runde 43b): "every N days/weeks/months", plus
    /// weekday chips for the weekly case ("jeden Montag, Dienstag").
    private var customBuilder: some View {
        VStack(alignment: .leading, spacing: Theme.s8) {
            HStack(spacing: Theme.s8) {
                Text(L.t("Alle", "Every")).font(.theme(.normal))
                ThemeIconButton(systemName: "minus") { customRec.interval = max(1, customRec.interval - 1) }
                Text("\(customRec.interval)").font(.theme(.normal).monospacedDigit())
                    .frame(minWidth: Theme.s16)
                ThemeIconButton(systemName: "plus") { customRec.interval = min(30, customRec.interval + 1) }
                ThemeSegmented(options: CustomRecurrence.Unit.allCases.map { ($0.label, $0) },
                               selection: $customRec.unit)
            }
            if customRec.unit == .weeks {
                ThemeMultiSegmented(options: CustomRecurrence.weekdayOrder.map { ($0.label, $0.ek) },
                                    selection: $customRec.weekdays)
                Text(L.t("Keine Auswahl = am Wochentag des Termins.",
                         "None selected = on the event's own weekday."))
                    .font(.theme(.small)).foregroundStyle(Theme.muted)
            }
        }
        .padding(Theme.s8)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
        .transition(.opacity)
    }

    /// Default start for a new meeting: the next quarter-hour from now.
    private static func nextQuarterHour() -> Date {
        Date(timeIntervalSinceReferenceDate:
                ceil(Date().timeIntervalSinceReferenceDate / 900) * 900)
    }
}

/// Scrollable quarter-hour picker (Runde 29/30: always in full view),
/// pre-scrolled to the current selection; a tap just picks, the list stays.
private struct TimeSlotList: View {
    @Binding var selection: Date

    var body: some View {
        let cal = Calendar.current
        let current = cal.component(.hour, from: selection) * 4
            + cal.component(.minute, from: selection) / 15
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.s4) {
                    ForEach(0..<96, id: \.self) { slot in
                        let label = ZonePlanner.uiHM(cal.date(bySettingHour: slot / 4, minute: (slot % 4) * 15, second: 0, of: selection) ?? selection, .current)
                        ThemeTextRow(title: label, icon: slot == current ? "checkmark" : nil,
                                     accent: slot == current, compact: true) {
                            selection = cal.date(bySettingHour: slot / 4, minute: (slot % 4) * 15,
                                                 second: 0, of: selection) ?? selection
                        }
                        .id(slot)
                    }
                }
            }
            // FIXED height (scroll views collapse in fitting-size panels).
            .frame(height: Theme.s24 * 4)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
            .onAppear { proxy.scrollTo(current, anchor: .center) }
        }
    }
}

/// Zeit-Parser fürs Tippen der Uhrzeit (Runde 92/96): "19:30", "1930", "19",
/// "7:30 pm", "7pm" → (Stunde, Minute); bei Unsinn nil.
enum TimeEntryParser {
    static func parse(_ raw: String) -> (Int, Int)? {
        var t = raw.lowercased().trimmingCharacters(in: .whitespaces)
        var pm: Bool?
        if t.hasSuffix("pm") { pm = true; t = String(t.dropLast(2)) }
        else if t.hasSuffix("am") { pm = false; t = String(t.dropLast(2)) }
        t = t.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: ":")
        var h = 0, m = 0
        if t.contains(":") {
            let p = t.split(separator: ":", omittingEmptySubsequences: false)
            guard p.count == 2, let a = Int(p[0]), let b = Int(p[1]) else { return nil }
            h = a; m = b
        } else if let n = Int(t) {
            if t.count >= 3 { h = n / 100; m = n % 100 } else { h = n }
        } else { return nil }
        if let pm {
            guard (1...12).contains(h) else { return nil }
            h = h % 12 + (pm ? 12 : 0)
        }
        guard (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }
}
