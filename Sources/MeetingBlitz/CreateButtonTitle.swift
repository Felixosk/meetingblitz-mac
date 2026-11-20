import SwiftUI
import AppKit

/// Runde 113: Haken links in der Zeile "Nach dem Erstellen" (16 pt, an = blau mit weißem Haken, aus = Rand muted).
struct ThemeCheck: View {
    let isOn: Bool
    var enabled = true
    var body: some View {
        Image(systemName: isOn ? "checkmark" : "")
            .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.onBlue)
            .frame(width: Theme.s16, height: Theme.s16)
            .background(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                .fill(isOn ? Theme.blue : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous)
                .strokeBorder(isOn ? Color.clear : Theme.muted, lineWidth: 1))
            .opacity(enabled ? 1 : 0.4)
    }
}

/// Runde 113: EIN Text, EINE Regel für den Erstellen-Knopf. Rein rechnend (testbar).
enum CreateButtonTitle {
    /// `mailTo` = Adressen, an die wirklich gemailt wird (leer = keine Mail). `maxWidth` in pt bei 13 pt semibold.
    static func make(mailTo: [String], text: Bool, ics: Bool, de: Bool, maxWidth: CGFloat = 256) -> String {
        guard !mailTo.isEmpty else {
            switch (text, ics) {
            case (true, false): return de ? "Erstellen & Einladung kopieren" : "Create & copy invite"
            case (true, true): return de ? "Erstellen, kopieren & .ics sichern" : "Create, copy & save .ics"
            case (false, true): return de ? "Erstellen & .ics sichern" : "Create & save .ics"
            case (false, false): return de ? "Erstellen" : "Create"
            }
        }
        func build(_ target: String) -> String {
            let multi = mailTo.count > 1
            if de {
                let m = multi ? "an \(mailTo.count) Gäste mailen" : "an \(target) mailen"
                return text ? "Erstellen, \(m) & kopieren" : "Erstellen & \(m)"
            }
            let m = multi ? "email \(mailTo.count) guests" : "email \(target)"
            return text ? "Create, \(m) & copy" : "Create & \(m)"
        }
        let a = mailTo[0]
        var s = build(a)
        if mailTo.count > 1 || width(s) <= maxWidth { return s }
        // Adresse in der Mitte kürzen, solange sie noch mehr als 8 Zeichen hat.
        var keep = a.count - 2
        while keep >= 8 {
            s = build(shorten(a, keep: keep))
            if width(s) <= maxWidth { return s }
            keep -= 1
        }
        return build(de ? "Gast" : "guest")
    }

    static func shorten(_ a: String, keep: Int) -> String {
        guard a.count > keep, keep >= 3 else { return a }
        let head = (keep + 1) / 2, tail = keep - head
        return String(a.prefix(head)) + "…" + String(a.suffix(tail))
    }

    static func width(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width
    }

    /// Tooltip am Knopf: alles in ganzen Worten.
    static func tooltip(calendar: String, mailTo: [String], text: Bool, ics: Bool, de: Bool) -> String {
        var parts: [String] = []
        let list = mailTo.joined(separator: ", ")
        if de {
            parts.append("Legt den Termin in „\(calendar)“ an")
            if !mailTo.isEmpty { parts.append("schickt die Mail an \(list)") }
            if text { parts.append("kopiert den Einladungstext") }
            if ics { parts.append("sichert die Kalenderdatei (.ics) in Downloads") }
            if parts.count == 1 { return parts[0] + "." }
            return parts.dropLast().joined(separator: ", ") + " und " + parts.last! + "."
        }
        parts.append("Creates the event in “\(calendar)”")
        if !mailTo.isEmpty { parts.append("emails \(list)") }
        if text { parts.append("copies the invite text") }
        if ics { parts.append("saves the calendar file (.ics) to Downloads") }
        if parts.count == 1 { return parts[0] + "." }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last! + "."
    }

    static func failures() -> [String] {
        var f: [String] = []
        let a = ["anna@kunde.com"]
        let cases: [(String, [String], Bool, Bool, Bool, String)] = [
            ("1", a, false, false, false, "Create & email anna@kunde.com"),
            ("1d", a, false, false, true, "Erstellen & an anna@kunde.com mailen"),
            ("2", a, true, false, false, "Create, email anna@kunde.com & copy"),
            ("2d", a, true, true, true, "Erstellen, an Gast mailen & kopieren"),   // zu breit → Adresse wird "Gast"
            ("3", [], true, false, false, "Create & copy invite"),
            ("3d", [], true, false, true, "Erstellen & Einladung kopieren"),
            ("4", [], true, true, false, "Create, copy & save .ics"),
            ("4d", [], true, true, true, "Erstellen, kopieren & .ics sichern"),
            ("5", [], false, true, false, "Create & save .ics"),
            ("5d", [], false, true, true, "Erstellen & .ics sichern"),
            ("6", [], false, false, false, "Create"),
            ("6d", [], false, false, true, "Erstellen"),
            ("multi", ["a@x.de", "b@x.de"], false, false, false, "Create & email 2 guests"),
            ("multid", ["a@x.de", "b@x.de"], false, false, true, "Erstellen & an 2 Gäste mailen"),
        ]
        for c in cases {
            let got = make(mailTo: c.1, text: c.2, ics: c.3, de: c.4)
            if got != c.5 { f.append("createButtonTitle \(c.0): \"\(got)\" statt \"\(c.5)\"") }
        }
        let long = ["sehr.lange.adresse.fuer.einen.gast@sehr-lange-firma-domain.example.com"]
        for de in [false, true] {
            let got = make(mailTo: long, text: true, ics: false, de: de)
            if width(got) > 256 { f.append("createButtonTitle lang: \(Int(width(got))) pt > 256 (\(got))") }
            if !got.contains("…") && !got.contains("guest") && !got.contains("Gast") { f.append("createButtonTitle lang: nicht gekürzt (\(got))") }
        }
        return f
    }
}
