import SwiftUI
import AppKit

/// Runde 113 (B1): ein Eingabefeld, das erkannte Teile ("fri", "10-12", "45 min", "dubai") blau unterlegt (wie Fantastical).
///
/// `NSTextView` statt `TextField`: ein SwiftUI-TextField kann keine Teilbereiche färben. Die Markierung läuft über
/// TEMPORÄRE Attribute des Layout-Managers, der Text selbst bleibt unverändert und das Tippen ungestört.
struct SmartEntryField: NSViewRepresentable {
    struct Mark: Equatable {
        var range: NSRange
        var manual: Bool        // von Hand geändert → grau statt blau
        var tip: String
    }
    @Binding var text: String
    var marks: [Mark]
    var placeholder: String
    /// Runde 114: Return im Feld = Erstellen (kein Zeilenumbruch).
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> EntryTextView {
        let v = EntryTextView()
        v.delegate = context.coordinator
        v.isRichText = false
        v.allowsUndo = true
        v.drawsBackground = false
        v.font = .systemFont(ofSize: 13)
        v.textColor = .labelColor
        v.insertionPointColor = .labelColor
        v.textContainerInset = NSSize(width: 8, height: 8)
        v.textContainer?.widthTracksTextView = false
        v.textContainer?.containerSize = NSSize(width: 100_000, height: 20)
        v.isHorizontallyResizable = true
        v.isVerticallyResizable = false
        v.isAutomaticQuoteSubstitutionEnabled = false
        v.isAutomaticDashSubstitutionEnabled = false
        v.isAutomaticTextReplacementEnabled = false
        v.isAutomaticSpellingCorrectionEnabled = false
        v.placeholder = placeholder
        v.string = text
        return v
    }

    func updateNSView(_ v: EntryTextView, context: Context) {
        context.coordinator.parent = self
        if v.string != text { v.string = text }
        v.placeholder = placeholder
        context.coordinator.applyMarks(v)
        v.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate, @unchecked Sendable {
        var parent: SmartEntryField
        var tips: [Int: String] = [:]
        init(_ p: SmartEntryField) { parent = p }

        func textDidChange(_ n: Notification) {
            guard let v = n.object as? NSTextView else { return }
            parent.text = v.string
        }

        // Eine Zeile: Return wird nicht eingefügt.
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            return sel == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        }

        func applyMarks(_ v: EntryTextView) {
            guard let lm = v.layoutManager else { return }
            let full = NSRange(location: 0, length: (v.string as NSString).length)
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            v.removeAllToolTips()
            tips = [:]
            for (i, m) in parent.marks.enumerated() {
                guard NSMaxRange(m.range) <= full.length, m.range.length > 0 else { continue }
                // Runde 114 (Punkt 7): EINE Akzentfarbe, dieselbe wie Knopf, Dauer-Leiste und Block (Theme.blue).
                let blue = NSColor(Theme.blue)
                let dark = v.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let fg = m.manual ? NSColor.secondaryLabelColor : (dark ? (blue.blended(withFraction: 0.45, of: .white) ?? blue) : (blue.blended(withFraction: 0.25, of: .black) ?? blue))
                let bg = m.manual ? NSColor.labelColor.withAlphaComponent(0.12) : blue.withAlphaComponent(dark ? 0.28 : 0.16)
                lm.addTemporaryAttribute(.foregroundColor, value: fg, forCharacterRange: m.range)
                lm.addTemporaryAttribute(.backgroundColor, value: bg, forCharacterRange: m.range)
                if let tc = v.textContainer {
                    let gr = lm.glyphRange(forCharacterRange: m.range, actualCharacterRange: nil)
                    var r = lm.boundingRect(forGlyphRange: gr, in: tc)
                    r.origin.x += v.textContainerInset.width; r.origin.y += v.textContainerInset.height
                    tips[i] = m.tip
                    v.addToolTip(r, owner: self, userData: UnsafeMutableRawPointer(bitPattern: i + 1))
                }
            }
        }

        @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
            guard let u = userData else { return "" }
            return tips[Int(bitPattern: u) - 1] ?? ""
        }
    }
}

final class EntryTextView: NSTextView {
    var placeholder = ""
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 32) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
                                           withAttributes: [.font: NSFont.systemFont(ofSize: 13),
                                                            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.4)])
        }
    }
}
