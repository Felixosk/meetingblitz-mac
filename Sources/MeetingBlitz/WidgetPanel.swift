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
    var isOpen: Bool { panel?.isVisible ?? false }

    /// A resizable rounded-rect mask so NSVisualEffectView clips to clean,
    /// crisp corners (no bright antialiased fringe).
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func toggle(state: AppState, statusButton: NSStatusBarButton?, anchorToMouseScreen: Bool = false) {
        if isOpen { close(); return }

        state.dayOffset = 0   // always open on today
        let host = FirstMouseHostingView(rootView: MenuPanel(state: state, onSize: { size in
            Task { @MainActor in WidgetPanelController.shared.resize(to: size) }
        }))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active            // never the flat "inactive" fallback
        // Round with a mask IMAGE, not just layer.cornerRadius: a plain layer
        // radius leaves bright antialiased fringes at the corners (das
        // "weiße Ecken"). A mask image clips the vibrancy cleanly.
        effect.maskImage = Self.roundedMask(radius: 13)
        effect.frame = CGRect(origin: .zero, size: size)
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true                // native shadow, no painted halo
        p.isFloatingPanel = true
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
        p.orderFrontRegardless()
        installDismissMonitors()
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
            Task { @MainActor in WidgetPanelController.shared.close() }
        }
        let l = measuring ? nil : NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                let w = event.window
                let keepOpen = w === WidgetPanelController.shared.panel
                    || SettingsPanelController.shared.owns(w)
                    || CreatePanelController.shared.owns(w)
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
        dismissMonitors = [g, l, gm, lm].compactMap { $0 }
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
        place(size: size)
    }

    private func place(size: CGSize) {
        guard let p = panel else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchorX, y: topY - 1)) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchorX - size.width / 2
        x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
        let y = topY - size.height
        p.setFrame(CGRect(x: x.rounded(), y: y.rounded(),
                          width: size.width.rounded(.up), height: size.height.rounded(.up)),
                   display: true)
        p.invalidateShadow()
        HintWindow.log("widget place day=\(AppState.shared.dayOffset) size=\(size) frame=\(p.frame) topY=\(topY)")
    }

    func close() {
        removeDismissMonitors()
        HintWindow.shared.hide()     // sonst bleibt eine Erklaerbox stehen
        SettingsPanelController.shared.close()   // don't orphan the settings panel
        // The "Neues Meeting" panel deliberately survives, it closes ONLY via
        // its own × (Runde 28: a stray click must not eat a half-typed
        // meeting).
        lastFrame = panel?.frame ?? lastFrame
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}
