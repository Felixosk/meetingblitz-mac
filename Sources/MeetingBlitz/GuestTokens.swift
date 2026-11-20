import Foundation
import AppKit
import SwiftUI

/// Runde 119: mehrere Gäste (reine Rechnerei) + Marken-Text (NSTextView) für die bearbeitbare Vorschau.

// MARK: - Gäste

extension MailInvite {
    static let maxGuests = 5

    /// Einfügen/URL: Komma, Semikolon, Zeilenumbruch, Leerzeichen; `Name <a@x.de>` wird zu `a@x.de`.
    /// Doppelte (ohne Groß/Klein) raus, höchstens 5 (`cut` = es waren mehr).
    static func splitPasted(_ raw: String) -> (list: [String], cut: Bool) {
        var s = raw
        if let re = try? NSRegularExpression(pattern: "[^<,;\\n]*<([^<>]*)>") {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        }
        let parts = s.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace || $0.isNewline }).map(String.init)
        var seen = Set<String>(), out: [String] = []
        for p in parts where seen.insert(p.lowercased()).inserted { out.append(p) }
        return (Array(out.prefix(maxGuests)), out.count > maxGuests)
    }

    struct GuestList: Equatable {
        var list: [String]       // getrimmt, ohne leere und ohne Doppelte
        var ok: Bool             // mindestens eine, alle gültig
        var empty: Bool
        var invalidRows: [Int]
        var dupRows: [Int]
    }

    /// Zeilen des Gast-Felds → fertige Liste. Leere Zeilen zählen nicht, eine falsche macht `ok` falsch.
    static func parseGuestList(_ rows: [String]) -> GuestList {
        var seen = Set<String>(), list: [String] = [], bad: [Int] = [], dup: [Int] = []
        for (i, r) in rows.enumerated() {
            let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if !isValidAddress(t) { bad.append(i); continue }
            if seen.insert(t.lowercased()).inserted { list.append(t) } else { dup.append(i) }
        }
        let empty = list.isEmpty && bad.isEmpty
        return GuestList(list: list, ok: bad.isEmpty && !list.isEmpty && list.count <= maxGuests,
                         empty: empty, invalidRows: bad, dupRows: dup)
    }

    // MARK: Einladungstext-Vorlage (Text-Vorschau / Kopieren)
    static let defaultInviteTextEN = "{title}\n{date}\n{times}\n{link}"
    static let defaultInviteTextDE = "{titel}\n{datum}\n{zeiten}\n{link}"
    static let tokenKeys = ["title", "titel", "date", "datum", "time", "zeit", "times", "zeiten", "duration", "dauer", "link"]
}

// MARK: - Marken

extension NSAttributedString.Key { static let mbToken = NSAttributedString.Key("mbToken") }

enum TokenCodec {
    static var font: NSFont { NSFont.systemFont(ofSize: 13) }
    static var boldFont: NSFont { NSFont.systemFont(ofSize: 13, weight: .semibold) }

    /// Pille mit dem aktuellen Wert. Mehrzeilig (z. B. {times}) = mehrere Zeilen in einer Pille.
    static func pill(_ value: String) -> NSImage {
        let lines = value.components(separatedBy: "\n")
        let lh: CGFloat = 17, padX: CGFloat = 6
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.blueNS]
        let w = (lines.map { ($0 as NSString).size(withAttributes: attrs).width }.max() ?? 10).rounded(.up) + 2 * padX
        let h = lh * CGFloat(lines.count) + 3
        return NSImage(size: NSSize(width: w, height: h), flipped: true) { r in
            Theme.blueNS.withAlphaComponent(0.20).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            for (i, l) in lines.enumerated() {
                (l as NSString).draw(at: NSPoint(x: padX, y: 1.5 + lh * CGFloat(i)), withAttributes: attrs)
            }
            return true
        }
    }

    static func attachment(key: String, value: String) -> NSAttributedString {
        let a = NSTextAttachment()
        let img = pill(value)
        a.image = img
        a.bounds = CGRect(x: 0, y: 12 - img.size.height, width: img.size.width, height: img.size.height)
        let s = NSMutableAttributedString(attachment: a)
        s.addAttribute(.mbToken, value: key, range: NSRange(location: 0, length: s.length))
        return s
    }

    /// Vorlage → Anzeige. Bekannte Marken (wie `MailInvite.render`) werden Pillen, Rest bleibt Text.
    static func attributed(_ template: String, values: [String: String], bold: Bool) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: bold ? boldFont : font, .foregroundColor: NSColor.labelColor]
        let out = NSMutableAttributedString()
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out.append(NSAttributedString(string: String(rest[..<open]), attributes: base))
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), MailInvite.tokenKeys.contains(after[..<close].lowercased()) {
                let key = String(after[..<close])
                out.append(attachment(key: key, value: values[key.lowercased()] ?? key))
                rest = after[after.index(after: close)...]
            } else {
                out.append(NSAttributedString(string: "{", attributes: base))
                rest = after
            }
        }
        out.append(NSAttributedString(string: String(rest), attributes: base))
        return out
    }

    /// Anzeige → Vorlage (Pille wird wieder `{key}`).
    static func template(from a: NSAttributedString) -> String {
        var out = ""
        let s = a.string as NSString
        a.enumerateAttribute(.mbToken, in: NSRange(location: 0, length: a.length)) { v, r, _ in
            if let k = v as? String { out += "{\(k)}" } else { out += s.substring(with: r) }
        }
        return out
    }
}

private final class MBTextView: NSTextView {
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}

/// Bearbeitbarer Kasten mit lebendigen Marken. Wahrheit ist der Vorlagen-String (`template`).
struct TokenTextView: NSViewRepresentable {
    @Binding var template: String
    var values: [String: String]
    var bold = false
    var single = false
    var maxHeight: CGFloat = 220
    @Binding var focused: Bool

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TokenTextView
        var lastTemplate: String?
        var sig = ""
        init(_ p: TokenTextView) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView, let ts = tv.textStorage else { return }
            let t = TokenCodec.template(from: ts)
            lastTemplate = t
            parent.template = t
        }
        func textDidBeginEditing(_ n: Notification) { DispatchQueue.main.async { self.parent.focused = true } }
        func textDidEndEditing(_ n: Notification) { DispatchQueue.main.async { self.parent.focused = false } }
        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            if parent.single && sel == #selector(NSResponder.insertNewline(_:)) {
                tv.window?.selectNextKeyView(nil); return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.drawsBackground = false; sv.hasVerticalScroller = true; sv.autohidesScrollers = true
        sv.borderType = .noBorder; sv.scrollerStyle = .overlay
        let tv = MBTextView(frame: .zero)
        tv.isRichText = true; tv.allowsUndo = true; tv.drawsBackground = false
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainerInset = .zero
        tv.textContainer?.widthTracksTextView = true
        tv.focusRingType = .none
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.typingAttributes = [.font: bold ? TokenCodec.boldFont : TokenCodec.font, .foregroundColor: NSColor.labelColor]
        tv.delegate = context.coordinator
        sv.documentView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = sv.documentView as? NSTextView, let ts = tv.textStorage else { return }
        let sig = values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "|") + (bold ? "b" : "")
        if c.lastTemplate == template && c.sig == sig { return }
        let sel = tv.selectedRange()
        ts.setAttributedString(TokenCodec.attributed(template, values: values, bold: bold))
        tv.setSelectedRange(NSRange(location: min(sel.location, ts.length), length: 0))
        c.lastTemplate = template; c.sig = sig
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView sv: NSScrollView, context: Context) -> CGSize? {
        let w = proposal.width ?? 280
        guard let tv = sv.documentView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer else { return nil }
        tv.frame.size.width = w
        tc.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height
        return CGSize(width: w, height: min(max(h, single ? 18 : 36), maxHeight))
    }
}

// MARK: - Selbsttest

@MainActor enum GuestTokenTests {
    static func failures() -> [String] {
        var f: [String] = []
        func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) { if a != b { f.append("Gäste: \(what): \(a) ≠ \(b)") } }

        let rot = ProcessInfo.processInfo.environment["MB_ROTPROBE"] != nil   // Rotprobe: Erwartungen absichtlich falsch
        let a = MailInvite.splitPasted("a@x.de, b@y.de;c@z.de")
        eq(a.list.count, rot ? 4 : 3, "split 3")
        eq(MailInvite.splitPasted("Anna <a@x.de>\nb@y.de").list, ["a@x.de", "b@y.de"], "Name <…> + Zeile")
        eq(MailInvite.splitPasted("a@x.de A@X.de b@y.de").list, ["a@x.de", "b@y.de"], "Doppelte raus")
        let seven = MailInvite.splitPasted("1@a.de,2@a.de,3@a.de,4@a.de,5@a.de,6@a.de,7@a.de")
        eq(seven.list.count, 5, "7 → 5"); eq(seven.cut, true, "cut-Flag")

        eq(MailInvite.parseGuestList(["a@x.de", ""]).list, ["a@x.de"], "leere Zeile zählt nicht")
        eq(MailInvite.parseGuestList(["a@x.de", ""]).ok, true, "a + leer ok")
        eq(MailInvite.parseGuestList(["a@x.de", "kaputt"]).ok, false, "falsche Zeile → nicht ok")
        eq(MailInvite.parseGuestList(["a@x.de", "kaputt"]).invalidRows, [1], "falsche Zeile Nr.")
        eq(MailInvite.parseGuestList(["a@x.de", "A@x.de"]).dupRows, [1], "Doppelte Zeile")
        eq(MailInvite.parseGuestList([""]).empty, true, "alles leer")
        eq(MailInvite.parseGuestList(["a@x.de\r\nBcc: y@z.de"]).ok, false, "Header-Einschleusung abgelehnt")

        // MIME: 3 Gäste = eine To-Zeile, kein Bcc
        let mime = MailInvite.mime(from: "me@x.de", to: ["a@x.de", "b@y.de", "c@z.de"], subject: "S", body: "B", ics: nil)
        let toLines = mime.components(separatedBy: "\r\n").filter { $0.hasPrefix("To:") }
        eq(toLines.count, 1, "eine To-Zeile"); eq(toLines.first?.components(separatedBy: "@").count, 4, "3 Adressen in To")
        eq(mime.contains("Bcc:"), false, "kein Bcc")

        // Marken: Rundreise für beide Standardvorlagen + Text-Vorlagen
        let vals = Dictionary(uniqueKeysWithValues: MailInvite.tokenKeys.map { ($0, "‹\($0)›") })
        for t in [MailInvite.defaultSubject, MailInvite.defaultBodyEN, MailInvite.defaultBodyDE,
                  MailInvite.defaultInviteTextEN, MailInvite.defaultInviteTextDE, "Eigen {x} {date} {"] {
            eq(TokenCodec.template(from: TokenCodec.attributed(t, values: vals, bold: false)), t, "Rundreise \(t.prefix(12))")
        }
        // Marke löschen entfernt genau {date}
        let at = NSMutableAttributedString(attributedString: TokenCodec.attributed("A {date} B", values: vals, bold: false))
        var del: NSRange?
        at.enumerateAttribute(.mbToken, in: NSRange(location: 0, length: at.length)) { v, r, _ in if v != nil { del = r } }
        if let del { at.deleteCharacters(in: del) }
        eq(TokenCodec.template(from: at), "A  B", "Marke löschen")
        // Marke zeigt den Wert, Text drumherum bleibt
        var tokens = 0
        let shown = TokenCodec.attributed("Hi {title}!", values: ["title": "Call"], bold: false)
        shown.enumerateAttribute(.mbToken, in: NSRange(location: 0, length: shown.length)) { v, _, _ in if v != nil { tokens += 1 } }
        eq(tokens, 1, "eine Marke")

        // Lebendig: neue Zeit → neuer gerenderter Text
        let s = Date(timeIntervalSince1970: 1_800_000_000)
        func fld(_ st: Date) -> MailInvite.Fields {
            MailInvite.Fields(title: "T", start: st, end: st.addingTimeInterval(1800), link: "L", zoneIDs: [], labels: [:], de: false)
        }
        eq(MailInvite.render("{time}", fld(s)) != MailInvite.render("{time}", fld(s.addingTimeInterval(3600))), true, "lebendig: Zeit ändert sich")

        // Text-Vorlage: Standard-Vorlage = alter Aufbau, mit und ohne Link
        let e = s.addingTimeInterval(1800)
        let old = GoogleService.shareText(title: "Call", start: s, end: e, link: "https://meet.google.com/x", zoneIDs: [])
        eq(GoogleService.renderInviteText(MailInvite.defaultInviteTextEN, title: "Call", start: s, end: e, link: "https://meet.google.com/x", zoneIDs: []),
           rot ? old + "\n" : old, "Text-Vorlage = alter Text")
        let oldNoLink = GoogleService.shareText(title: "Call", start: s, end: e, link: nil, zoneIDs: [])
        eq(GoogleService.renderInviteText(MailInvite.defaultInviteTextEN, title: "Call", start: s, end: e, link: nil, zoneIDs: []),
           oldNoLink, "Text-Vorlage ohne Link")
        return f
    }
}
