import AppKit

/// Dezenter Hinweis, wenn das Banner unterdrückt ist (P1).
///
/// Das Loch, das er schließt: Ruhe-Modus und „Ruhe bei Bildschirmfreigabe"
/// unterdrücken die Warnung KOMPLETT. Wer gerade teilt, verpasst dadurch sein
/// nächstes Meeting — ausgerechnet in der Situation, in der ein fliegendes
/// U-Boot vor Publikum peinlich wäre, ein leiser Hinweis aber genau richtig.
///
/// 🚨 **Warum KEINE macOS-Systemmitteilung** (erst so gebaut, dann verworfen,
/// 19.08.2026): `UNUserNotificationCenter` antwortet dieser App mit
/// „Notifications are not allowed for this application" — auch aus
/// `/Applications` heraus. Ursache ist die Signatur: `TeamIdentifier=not set`,
/// die App ist mit einem selbstgebauten Zertifikat signiert. macOS lässt
/// Mitteilungen nur für Apps mit echter Apple-Signatur zu. Das wäre also erst
/// mit dem Apple Developer Program (99 $/Jahr) zu haben, siehe
/// Notarisierungs-Abschnitt in der ROADMAP.
///
/// Stattdessen ein eigenes kleines Fenster: oben rechts unter der Menüleiste,
/// kein Ton, keine Bewegung, verschwindet von selbst. Für den Screenshare-Fall
/// sogar besser steuerbar als eine Systemmitteilung — Größe, Dauer und Ort
/// liegen in unserer Hand.
///
/// Reines AppKit, kein SwiftUI: kleine transiente Fenster mit NSHostingView
/// resizen sich nach dem Anzeigen selbst und rutschen weg (Runde 56c).
@MainActor
enum QuietNotice {
    private static var panel: NSPanel?
    private static var hideTimer: Timer?

    /// Wie lange der Hinweis stehen bleibt.
    private static let visibleSeconds = 6.0

    static func show(_ meeting: Meeting) {
        let mins = max(0, Int(meeting.start.timeIntervalSinceNow / 60))
        let sub = mins <= 0 ? L.t("startet jetzt", "starting now")
                            : L.t("in \(mins) Min", "in \(mins) min")
        present(title: meeting.title, subtitle: sub)
    }

    /// Beispiel-Hinweis für den „Testen"-Knopf in den Einstellungen: sonst
    /// bekommt man das Feature nie zu sehen, es greift ja nur bei aktiver Ruhe
    /// UND anstehendem Termin.
    static func test() {
        present(title: L.t("Beispiel-Meeting", "Sample meeting"),
                subtitle: L.t("So sieht der stille Hinweis aus", "This is the silent notice"))
    }

    private static func present(title: String, subtitle: String) {
        hide()

        let text = NSTextField(labelWithString: title)
        text.font = .systemFont(ofSize: 13, weight: .semibold)
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor

        // Handvermessung statt fittingSize (Runde 56c): die ist bei frisch
        // erzeugten Fenstern unzuverlässig.
        let maxTextW: CGFloat = 260
        let w = min(maxTextW, max(text.intrinsicContentSize.width, sub.intrinsicContentSize.width)) + 34
        let h: CGFloat = 52

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active            // sonst flache dunkle Platte (Runde 6)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        let dot = NSView(frame: NSRect(x: 12, y: h / 2 - 4, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dot.layer?.cornerRadius = 4
        effect.addSubview(dot)

        text.frame = NSRect(x: 28, y: h / 2 + 1, width: w - 40, height: 17)
        sub.frame = NSRect(x: 28, y: h / 2 - 18, width: w - 40, height: 15)
        effect.addSubview(text)
        effect.addSubview(sub)

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = effect
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true       // nichts abfangen, es ist nur ein Hinweis
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Oben rechts unter der Menüleiste, auf dem Bildschirm mit der Maus.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        p.setFrameOrigin(NSPoint(x: vf.maxX - w - 12, y: vf.maxY - h - 8))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 1
        }
        panel = p

        hideTimer = Timer.scheduledTimer(withTimeInterval: visibleSeconds, repeats: false) { _ in
            Task { @MainActor in hide(animated: true) }
        }
    }

    static func hide(animated: Bool = false) {
        hideTimer?.invalidate(); hideTimer = nil
        guard let p = panel else { return }
        panel = nil
        guard animated else { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        } completionHandler: { p.orderOut(nil) }
    }
}
