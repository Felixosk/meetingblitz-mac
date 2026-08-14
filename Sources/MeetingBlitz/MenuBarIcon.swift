import AppKit

/// The menu-bar submarine, drawn in code as a template image so it adapts to
/// light/dark menu bars automatically. It only ever shows when no meeting text
/// is up, i.e. the day is done, so it SLEEPS: drooping periscope + Zzz
/// (Runde 28). Shape previewed via design/preview_menubar_icon.swift
/// (keep the drawing in sync!).
enum MenuBarIcon {
    static let submarine: NSImage = {
        let img = NSImage(size: NSSize(width: 24, height: 16), flipped: false) { _ in
            let path = NSBezierPath()

            // Hull: capsule, bow to the right (the sub flies left→right in the app).
            path.appendRoundedRect(NSRect(x: 2.6, y: 2.4, width: 15.4, height: 8.2),
                                   xRadius: 4.1, yRadius: 4.1)

            // Tail fin at the stern (left): a small vertical rounded blade.
            path.appendRoundedRect(NSRect(x: 0.0, y: 3.0, width: 3.0, height: 7.0),
                                   xRadius: 1.2, yRadius: 1.2)

            // Conning tower on top.
            path.appendRoundedRect(NSRect(x: 8.2, y: 9.6, width: 5.0, height: 3.4),
                                   xRadius: 1.4, yRadius: 1.4)

            NSColor.black.setFill()
            path.fill()

            // Sleeping periscope: rises a little, then the head droops down-right.
            let scope = NSBezierPath()
            scope.lineWidth = 1.4
            scope.lineCapStyle = .round
            scope.lineJoinStyle = .round
            scope.move(to: NSPoint(x: 10.2, y: 12.4))
            scope.line(to: NSPoint(x: 10.2, y: 13.8))
            scope.line(to: NSPoint(x: 11.7, y: 13.1))
            NSColor.black.setStroke()
            scope.stroke()

            // Zzz drifting up ahead of the bow (idle = asleep).
            func z(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat, w: CGFloat) {
                let p = NSBezierPath()
                p.lineWidth = w
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                p.move(to: NSPoint(x: x, y: y + s))
                p.line(to: NSPoint(x: x + s, y: y + s))
                p.line(to: NSPoint(x: x, y: y))
                p.line(to: NSPoint(x: x + s, y: y))
                p.stroke()
            }
            z(17.6, 9.6, 3.0, w: 1.2)
            z(21.0, 12.6, 2.1, w: 1.0)

            // Portholes: punched out of the hull so the menu bar shows through.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            for x in [5.6, 9.3, 13.0] {
                NSBezierPath(ovalIn: NSRect(x: x, y: 5.2, width: 2.6, height: 2.6)).fill()
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        img.isTemplate = true   // menu bar tints it for light/dark automatically
        return img
    }()
}
