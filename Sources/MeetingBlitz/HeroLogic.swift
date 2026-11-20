import Foundation
import SwiftUI

// Runde 93: Was steht oben im Widget (Hero)?
//
// Fehler vom 17.11.2026, 10:30: Oben stand "Reply to Robin, 9 h 29 min", obwohl
// "Weekly sync" (10:30–11:00) genau jetzt anfing. Regeln:
//  (a) Ein Meeting, das läuft oder in höchstens 5 Minuten startet, steht oben.
//  (b) Sonst das nächste Meeting von heute.
//  Ein Meeting verlässt den Hero erst, wenn es vorbei ist.
//  "Meeting" = Termin mit Videolink ODER mit Gästen. Termine ohne Link
//  (To-dos wie "Reply to Robin") und Ganztägiges kommen nie in den Hero.

enum HeroState: Equatable {
    case running(Meeting)   // läuft gerade
    case soon(Meeting)      // startet in ≤ 5 min
    case next(Meeting)      // nächstes heute
    case none               // heute kein Meeting mehr

    var meeting: Meeting? {
        switch self {
        case .running(let m), .soon(let m), .next(let m): return m
        case .none: return nil
        }
    }
}

enum HeroPicker {
    /// Ein echtes Meeting im Sinne der Zeilen-Gestaltung (Link oder Gäste).
    /// Runde 99: nur echte Call-Links (Meet, Zoom, Teams …) zählen.
    static func hasCallLink(_ m: Meeting) -> Bool {
        guard let u = m.joinURL else { return false }
        return JoinLink.isMeetingLink(u)
    }

    static func isMeeting(_ m: Meeting) -> Bool {
        !m.isAllDay && !m.isBirthday && m.myStatus != .declined
            && (hasCallLink(m) || m.hasGuests)
    }

    /// Hero-Kandidat: Termin mit Uhrzeit, nicht abgesagt, noch nicht vorbei.
    static func isCandidate(_ m: Meeting, now: Date) -> Bool {
        !m.isAllDay && !m.isBirthday && m.myStatus != .declined && m.end > now
    }

    /// Runde 95: Hero = Termin, der gerade läuft, sonst der nächste Termin mit
    /// Uhrzeit heute (Ganztägiges nie). Termine MIT Link haben Vorrang, wenn
    /// sie gleichzeitig laufen oder innerhalb von 5 Minuten starten.
    /// `agenda` = die Termine von heute.
    static func pick(_ agenda: [Meeting], now: Date, soonWindow: TimeInterval = 300) -> HeroState {
        let c = agenda.filter { isCandidate($0, now: now) }.sorted { $0.start < $1.start }
        let running = c.filter { $0.start <= now }
        if let r = running.first(where: hasCallLink) ?? running.first { return .running(r) }
        let soon = c.filter { $0.start.timeIntervalSince(now) <= soonWindow }
        if let s = soon.first(where: hasCallLink) ?? soon.first { return .soon(s) }
        if let n = c.first { return .next(n) }
        return .none
    }
}

enum HeroTests {
    static func failures() -> [String] {
        var out: [String] = []
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func m(_ id: String, _ startMin: Double, _ lenMin: Double, link: Bool = true, guests: Bool = false,
               allDay: Bool = false, birthday: Bool = false) -> Meeting {
            Meeting(id: id, title: id, start: now.addingTimeInterval(startMin * 60),
                    end: now.addingTimeInterval((startMin + lenMin) * 60),
                    isAllDay: allDay, isBirthday: birthday, calendarTitle: "", calendarID: nil,
                    color: .gray, joinURL: link ? URL(string: "https://meet.google.com/abc-defg-hij") : nil,
                    contactID: nil, calendarItemID: nil, hasGuests: guests)
        }
        func name(_ s: HeroState) -> String {
            switch s {
            case .running(let x): return "läuft:\(x.id)"
            case .soon(let x): return "gleich:\(x.id)"
            case .next(let x): return "nächstes:\(x.id)"
            case .none: return "keins"
            }
        }
        func check(_ label: String, _ agenda: [Meeting], _ want: String) {
            let got = name(HeroPicker.pick(agenda, now: now))
            if got != want { out.append("Hero \(label): erwartet \(want), bekommen \(got)") }
        }
        let todo = m("todo", 600, 15, link: false)             // "Reply to Robin" in 10 h
        let bday = m("bday", -300, 1440, link: false, allDay: true, birthday: true)
        // Der Fehler vom 17.11.: Call läuft seit 1 min, To-do kommt in 10 h.
        check("läuft gerade", [todo, m("call", -1, 30), bday], "läuft:call")
        check("läuft, später noch eins", [m("call", -10, 30), m("zweiter", 60, 30)], "läuft:call")
        check("Link hat Vorrang beim Laufen", [m("ohne", -5, 30, link: false), m("mit", -2, 30)], "läuft:mit")
        check("läuft ohne Link", [m("ohne", -5, 30, link: false), todo], "läuft:ohne")
        check("startet in 3 min", [todo, m("call", 3, 30)], "gleich:call")
        check("startet in 5 min", [m("call", 5, 30)], "gleich:call")
        check("startet in 6 min", [m("call", 6, 30)], "nächstes:call")
        check("Link hat Vorrang bei gleich", [m("ohne", 2, 30, link: false), m("mit", 4, 30)], "gleich:mit")
        check("gleich ohne Link", [m("ohne", 2, 30, link: false)], "gleich:ohne")
        // Runde 95: nur Termine ohne Link übrig → der nächste, NICHT "keins".
        check("nur Termine ohne Link übrig", [todo, bday], "nächstes:todo")
        check("nächster ohne Link vor spätem Meeting", [m("todo2", 10, 15, link: false), m("call", 120, 30)], "nächstes:todo2")
        check("nur Ganztägiges", [bday], "keins")
        check("nichts", [], "keins")
        check("alles vorbei", [m("alt", -60, 30)], "keins")
        check("Vorbei, danach To-do", [m("alt", -60, 30), todo], "nächstes:todo")
        check("Gäste statt Link", [m("mitGaesten", 20, 30, link: false, guests: true)], "nächstes:mitGaesten")
        let maps = Meeting(id: "maps", title: "maps", start: now.addingTimeInterval(120 * 60),
                           end: now.addingTimeInterval(150 * 60), isAllDay: false, isBirthday: false,
                           calendarTitle: "", calendarID: nil, color: .gray,
                           joinURL: URL(string: "https://maps.app.goo.gl/abc"), contactID: nil,
                           calendarItemID: nil, hasGuests: false)
        if HeroPicker.isMeeting(maps) { out.append("Maps-Link zählt als Meeting") }
        check("Maps-Link verdrängt nichts", [maps, m("call", 3, 30)], "gleich:call")
        var declined = m("abgesagt", -5, 30); declined.myStatus = .declined
        check("abgesagt zählt nicht", [declined], "keins")
        return out
    }
}

/// Testschalter `--demo-hero=running|soon|next|late|none`: setzt eine
/// ausgedachte Tagesliste ins Widget (für Fotos aller Hero-Zustände).
enum HeroDemo {
    static func agenda(_ kind: String) -> [Meeting] {
        let now = Date()
        func m(_ title: String, _ startMin: Double, _ lenMin: Double, link: Bool, guests: Bool = false,
               allDay: Bool = false, birthday: Bool = false, color: Color) -> Meeting {
            Meeting(id: "demo-\(title)", title: title, start: now.addingTimeInterval(startMin * 60),
                    end: now.addingTimeInterval((startMin + lenMin) * 60), isAllDay: allDay, isBirthday: birthday,
                    calendarTitle: "", calendarID: nil, color: color,
                    joinURL: link ? URL(string: "https://meet.google.com/abc-defg-hij") : nil,
                    contactID: nil, calendarItemID: nil, hasGuests: guests)
        }
        let bday = m("Sarah's 30th Birthday", -300, 1440, link: false, allDay: true, birthday: true, color: .gray)
        let bday2 = m("Max's 26th Birthday", -300, 1440, link: false, allDay: true, birthday: true, color: .gray)
        let todo = m("Reply to Robin", 600, 15, link: false, color: .brown)
        switch kind {
        case "running":
            return [m("Weekly sync", -2, 30, link: true, color: .green), m("Sprint Planning", 90, 45, link: true, guests: true, color: .blue), todo, bday, bday2]
        case "soon":
            return [m("Design Review", 3, 30, link: true, color: .green), m("Handover Call", 8, 30, link: true, color: .purple), todo, bday]
        case "next24":
            return [m("Design Review", 24, 30, link: true, color: .green), m("Handover Call", 30, 30, link: true, color: .purple), todo, bday]
        case "next":
            return [m("Abend-Call mit Jordan", 9 * 60 + 29, 30, link: true, color: .green), bday]
        case "late":
            return [m("Frühstück", -240, 30, link: false, color: .orange), m("Alter Call", -120, 30, link: true, color: .green), todo, bday]
        case "nolink":
            return [m("Weekly sync", -60, 30, link: true, color: .green), m("Call with Robin", 240, 30, link: false, color: .brown), todo, bday]
        default:
            return [m("Weekly sync", -60, 30, link: true, color: .green), bday]
        }
    }
}
