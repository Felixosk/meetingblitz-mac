import AppKit

/// Runde 111b (B4): kleiner Hinweis "Meeting erstellt · Rückgängig" unter dem Menüleisten-Symbol, 5 s.
///
/// Reines AppKit wie `QuietNotice` (Begründung dort: kleine transiente Fenster mit NSHostingView resizen sich
/// nach dem Anzeigen selbst und rutschen weg). Ebene `.popUpMenu` (über allem, auch über dem Widget), dunkel,
/// nicht aktivierend, nimmt Mausklicks an. Maus darüber hält die Zeit an (wie Apples Mail-Rückgängig).
@MainActor
enum UndoToast {
    private static var panel: NSPanel?
    private static var timer: Timer?
    private static var remaining: TimeInterval = 0
    private static var tickTimer: Timer?
    private static var paused = false

    /// `onAction` läuft beim Klick auf den Knopf; der Hinweis schließt dann selbst.
    static func show(message: String, actionTitle: String?, seconds: TimeInterval = 5, onAction: (() -> Void)?) {
        hide()
        let h: CGFloat = 36
        let text = NSTextField(labelWithString: message)
        text.font = .systemFont(ofSize: 13)
        text.textColor = .labelColor
        text.lineBreakMode = .byTruncatingTail
        let textW = min(300, ceil(text.attributedStringValue.size().width) + 4)
        var w = 14 + textW + 14
        let btn: NSButton? = actionTitle.map { title in
            let b = ToastButton(title: title, target: nil, action: nil)
            b.isBordered = false
            b.font = .systemFont(ofSize: 13, weight: .semibold)
            b.contentTintColor = NSColor(srgbRed: 0.16, green: 0.42, blue: 0.98, alpha: 1)
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor(srgbRed: 0.30, green: 0.52, blue: 1, alpha: 1)])
            b.sizeToFit()
            return b
        }
        if let b = btn { w += b.frame.width + 14 }

        let view = ToastView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = h / 2
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        // Runde 115: Aussehen kommt von NSApp.appearance (Look.apply).
        text.frame = NSRect(x: 14, y: (h - 17) / 2, width: textW, height: 17)
        view.addSubview(text)
        if let b = btn {
            b.frame = NSRect(x: 14 + textW + 14, y: (h - b.frame.height) / 2, width: b.frame.width, height: b.frame.height)
            let target = ActionTarget { hide(animated: true); onAction?() }
            b.target = target; b.action = #selector(ActionTarget.fire)
            objc_setAssociatedObject(b, &actionKey, target, .OBJC_ASSOCIATION_RETAIN)
            view.addSubview(b)
        }
        view.onHover = { inside in paused = inside }

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = view
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.isFloatingPanel = true
        p.level = .popUpMenu
        // Runde 115: Aussehen kommt von NSApp.appearance (Look.apply).
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Unter dem Menüleisten-Symbol (Widget-Anker), sonst oben rechts auf dem Bildschirm mit der Maus.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = WidgetPanelController.shared.anchorCenterX ?? (vf.maxX - 140)
        let x = min(max(anchor - w / 2, vf.minX + 8), vf.maxX - w - 8)
        var y = vf.maxY - h - 8
        // Ist das Widget offen, steht der Hinweis UNTER seinem Glas (sonst verdeckt er Datum und Pfeile).
        if let g = WidgetPanelController.shared.glassFrame, WidgetPanelController.shared.isOpen { y = max(vf.minY + 8, g.minY - h - 8) }
        p.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.15; p.animator().alphaValue = 1 }
        panel = p

        remaining = seconds; paused = false
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                if paused { return }
                remaining -= 0.1
                if remaining <= 0 { hide(animated: true) }
            }
        }
    }

    static var isShowing: Bool { panel != nil }
    static func owns(_ w: NSWindow?) -> Bool { w != nil && w === panel }

    static func hide(animated: Bool = false) {
        tickTimer?.invalidate(); tickTimer = nil
        guard let p = panel else { return }
        panel = nil
        guard animated else { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        } completionHandler: { p.orderOut(nil) }
    }
}

nonisolated(unsafe) private var actionKey: UInt8 = 0

private final class ToastButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ActionTarget: NSObject {
    let block: () -> Void
    init(_ b: @escaping () -> Void) { block = b }
    @objc func fire() { block() }
}

/// Erste Klick greift auch ohne aktive App; Maus drin/draußen für die Pause.
private final class ToastView: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// Sichert/stellt die Zwischenablage wieder her (alle Einträge, alle Typen).
@MainActor
struct PasteboardSnapshot {
    let items: [[(NSPasteboard.PasteboardType, Data)]]
    static func capture(_ pb: NSPasteboard = .general) -> PasteboardSnapshot {
        PasteboardSnapshot(items: (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        })
    }
    func restore(_ pb: NSPasteboard = .general) {
        pb.clearContents()
        let new = items.map { entries -> NSPasteboardItem in
            let i = NSPasteboardItem(); for (t, d) in entries { i.setData(d, forType: t) }; return i
        }
        if !new.isEmpty { pb.writeObjects(new) }
    }
}
