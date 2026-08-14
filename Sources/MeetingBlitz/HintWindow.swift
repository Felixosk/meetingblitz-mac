import SwiftUI
import AppKit

/// Eigener Tooltip als schwebendes Fenster plus eigene Treffer-Rechnung
/// (Runde 56). Warum nicht AppKit/SwiftUI-Hover: siehe Hints.swift, vier
/// gescheiterte Anläufe.
///
/// Der Maus-Monitor des Widgets ruft `mouseMoved()` bei jeder Bewegung.
/// Getroffene Fläche + 0,3s Ruhe = Box an der Maus. Fläche verlassen = weg.
///
/// Das Fenster ist reine Anzeige: `ignoresMouseEvents`, nie key, nie aktiv.
/// Damit fällt es nicht in die Klasse von Runde 47j, wo ein neues Panel die
/// ganze App unklickbar gemacht hat.
@MainActor
final class HintWindow {
    static let shared = HintWindow()

    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var autoHide: DispatchWorkItem?
    private var anchor: NSPoint = .zero
    private var currentText: String?
    private var lastMoveLog = Date.distantPast

    /// Anzeige erst, wenn der Zeiger kurz ruht, wie beim Systemtooltip.
    private let delay: TimeInterval = 0.3

    /// Rand, den die Blase innerhalb des Fensters für ihren Schatten frei lässt.
    private let shadowPad: CGFloat = 6

    /// Vom Maus-Monitor des Widgets bei jeder Bewegung gerufen. Rechnet selbst,
    /// ob der Zeiger auf einer registrierten Fläche steht.
    /// Während des `--demo-hint`-Selbsttests ignoriert die Box Mausbewegungen,
    /// sonst räumt eine zufällige Bewegung sie weg, bevor der Screenshot sie
    /// vermessen kann. Räumt der autoHide-Timer ab.
    private var debugPinned = false

    func mouseMoved() {
        guard !debugPinned else { return }
        guard WidgetPanelController.shared.isOpen,
              let wf = WidgetPanelController.shared.frame else {
            if panel != nil || pending != nil { hide() }
            return
        }
        let m = NSEvent.mouseLocation

        // Registrierte Flächen sind in SwiftUI-Fensterkoordinaten (Ursprung
        // oben links, y nach unten); der Fensterrahmen wf ist AppKit (y nach
        // oben). Fensteroberkante = wf.maxY.
        var hit: String?
        for s in HintSpots.shared.spots.values {
            let screenRect = CGRect(x: wf.minX + s.rect.minX,
                                    y: wf.maxY - s.rect.maxY,
                                    width: s.rect.width,
                                    height: s.rect.height)
            if screenRect.insetBy(dx: -2, dy: -2).contains(m) { hit = s.text; break }
        }

        // Trail gedrosselt mitschreiben, solange die Maus im Widget ist. Das
        // ist das Werkzeug, mit dem sich ein Fehlstand in Minuten statt in
        // Rateschleifen eingrenzen lässt (Lektion Runde 47i).
        if wf.insetBy(dx: -20, dy: -20).contains(m), Date().timeIntervalSince(lastMoveLog) > 0.4 {
            lastMoveLog = Date()
            Self.log("move mouse=\(m) hit=\(hit ?? "-") widget=\(wf)")
        }

        guard let text = hit else {
            if panel != nil || pending != nil { hide() }
            return
        }
        anchor = m
        if panel != nil, currentText == text { return }   // Box steht schon richtig
        currentText = text
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.present(text) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        autoHide?.cancel()
        autoHide = nil
        currentText = nil
        debugPinned = false
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private func present(_ text: String) {
        autoHide?.cancel()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil

        // Blase in reinem AppKit, KEIN SwiftUI. DER eigentliche Übeltäter
        // hinter „Box hängt 200pt zu tief" war nie das Hovering, sondern die
        // Anzeige: Die NSHostingView hat das Panel NACH dem Anzeigen selbst
        // resized (38pt -> 248pt, Oberkante bleibt, Unterkante sackt ab, Blase
        // klebt unten). `sizingOptions = []` hat das NICHT verhindert, und
        // `fittingSize` lieferte im nie-aktiven Panel auch noch die
        // Phantom-Größe 0x0 (Messungen 19:36 + 19:40, /tmp/mb_hints.log).
        // Ein NSTextField mit Handvermessung kann nichts davon.
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .white
        label.isSelectable = false
        let textSize = label.sizeThatFits(NSSize(width: 242, height: 600))
        label.frame = NSRect(x: 9, y: 6, width: ceil(textSize.width), height: ceil(textSize.height))

        let bubble = NSView(frame: NSRect(x: shadowPad, y: shadowPad,
                                          width: label.frame.width + 18,
                                          height: label.frame.height + 12))
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.97).cgColor
        bubble.layer?.cornerRadius = 6
        bubble.layer?.borderWidth = 0.5
        bubble.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        bubble.addSubview(label)

        let host = NSView(frame: NSRect(x: 0, y: 0,
                                        width: bubble.frame.width + shadowPad * 2,
                                        height: bubble.frame.height + shadowPad * 2))
        host.addSubview(bubble)
        let size = host.frame.size

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.ignoresMouseEvents = true          // darf niemals einen Klick schlucken
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = host

        // Sichtbare Blase knapp rechts unter dem Zeiger, damit er den Text
        // nicht verdeckt. Auf den sichtbaren Bildschirm geklemmt; unten kein
        // Platz, dann über den Zeiger.
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        var x = anchor.x + 10 - shadowPad
        var y = anchor.y - 10 + shadowPad - size.height
        x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
        if y < vf.minY + 4 { y = anchor.y + 12 - shadowPad }
        p.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        p.orderFrontRegardless()
        panel = p

        Self.log("SHOW \"\(text)\" anchor=\(anchor) box=\(p.frame)")
        // Frame nochmal NACH dem Anzeigen prüfen: Verdacht, dass das Fenster
        // woanders GEZEICHNET wird, als sein Frame behauptet (Messung 19:31:
        // gesetzt y=895, sichtbar ~195pt tiefer).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak p] in
            if let p { Self.log("SHOW+0.5s frame=\(p.frame) visible=\(p.isVisible) screen=\(p.screen?.frame ?? .zero)") }
        }

        // Sicherheitsnetz gegen eine verwaiste Box, falls keine Bewegungen
        // mehr gemeldet werden (Widget zu, Monitor weg).
        let kill = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        autoHide = kill
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: kill)
    }

    /// Testschalter `--demo-hint`: zeigt die Box programmatisch an einer
    /// registrierten Fläche, ganz ohne Maus. Trennt die Frage „wird das Fenster
    /// dort gezeichnet, wo sein Frame liegt?" von der gesamten Hover-Logik.
    func debugShowAtFirstSpot() {
        guard let wf = WidgetPanelController.shared.frame,
              let s = HintSpots.shared.spots.values.min(by: { $0.rect.minY < $1.rect.minY }) else {
            Self.log("demo-hint: keine Spots / kein Widget")
            return
        }
        anchor = NSPoint(x: wf.minX + s.rect.midX, y: wf.maxY - s.rect.midY)
        debugPinned = true
        Self.log("demo-hint anchor=\(anchor) spot=\(s.rect) widget=\(wf)")
        present("TESTBOX \(Int(anchor.x))/\(Int(anchor.y))")
    }

    private static let logPath = "/tmp/mb_hints.log"

    /// Nur mit `--demo-hint` oder `--hint-log` aktiv: im Normalbetrieb schreibt
    /// eine Menüleisten-App nicht bei jeder Mausbewegung auf die Platte.
    static let logEnabled = CommandLine.arguments.contains("--demo-hint")
        || CommandLine.arguments.contains("--hint-log")

    /// Messwerte in eine DATEI, nicht NSLog: `log show` schwärzt die Inhalte
    /// (<private>), die Datei war schon in Runde 47i das Werkzeug, das in
    /// Minuten fand, was Rateschleifen nicht fanden.
    static func log(_ msg: String) {
        guard logEnabled else { return }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        let line = "\(f.string(from: Date())) \(msg)\n"
        if let d = line.data(using: .utf8), let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        } else {
            try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }
}

