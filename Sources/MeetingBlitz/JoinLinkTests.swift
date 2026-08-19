import Foundation

/// Self-test for the join-link recognition (F7), run via
/// `MeetingBlitz --selftest`. `build.sh` calls it after every build and fails
/// the build on a mismatch.
///
/// Why not XCTest: it ships with Xcode, not with the Command Line Tools this
/// project is built with, so `swift test` cannot compile a test target here
/// (verified 18.08.2026: "no such module 'XCTest'"). A plain executable check
/// gives the same safety net without adding a toolchain dependency.
enum JoinLinkTests {

    /// (URL, expected service or nil when it must NOT be treated as a meeting.)
    static let cases: [(String, String?)] = [
        ("https://meet.google.com/abc-defg-hij", "Google Meet"),
        ("https://us02web.zoom.us/j/1234567890?pwd=xyz", "Zoom"),
        ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc", "Microsoft Teams"),
        ("https://company.webex.com/meet/felix", "Webex"),
        ("https://whereby.com/my-room", "Whereby"),
        ("https://meet.jit.si/StandupDaily", "Jitsi"),
        ("https://discord.gg/abcd1234", "Discord"),
        ("https://app.slack.com/huddle/T123/C456", "Slack"),
        ("https://chime.aws/1234567890", "Chime"),
        ("https://global.gotomeeting.com/join/123456789", "GoTo"),
        ("https://join.skype.com/abcXYZ", "Skype"),
        ("https://meeting.tencent.com/dm/abcdef", "Tencent"),
        ("https://kmeet.infomaniak.com/room-name", "Kmeet"),
        ("https://app.gather.town/app/xyz/office", "Gather"),
        ("https://my.connect.aws/meet/123", "Amazon Connect"),
        // Negatives: ordinary links in a description must NOT become a call.
        ("https://www.notion.so/Agenda-123", nil),
        ("https://github.com/Felixosk/meetingblitz-mac", nil),
        ("https://calendar.google.com/calendar/u/0/r", nil),
        ("https://example.com/zoom-guide", nil),   // "zoom" only in the path
        ("https://docs.google.com/document/d/abc", nil),
    ]

    /// Returns the failures as readable lines; empty means everything passed.
    static func failures() -> [String] {
        var out: [String] = []
        for (raw, expected) in cases {
            guard let url = URL(string: raw) else {
                out.append("ungültige Test-URL: \(raw)")
                continue
            }
            let got = JoinLink.service(for: url)
            if got != expected {
                out.append("\(raw)\n   erwartet: \(expected ?? "kein Meeting")   bekommen: \(got ?? "kein Meeting")")
            }
        }
        // The preference order is load-bearing: an event carrying both a wiki
        // page and a Meet room must join the room.
        let mixed = JoinLink.best(explicit: URL(string: "https://www.notion.so/Agenda"),
                                  texts: ["Notizen: https://www.notion.so/Agenda\nRaum: https://meet.google.com/xyz-abcd-efg"])
        if mixed?.host != "meet.google.com" {
            out.append("Vorrang falsch: bei Wiki + Meet-Link muss der Meet-Link gewinnen, bekommen: \(mixed?.absoluteString ?? "nil")")
        }
        return out
    }
}

/// Selbsttest der Klick-Stufen am Datum (19.08.2026). Reine Rechnerei, also
/// hier prüfbar statt per Klick im Widget — genau die Art Logik, die still
/// kaputtgeht, wenn später eine Option dazukommt.
enum CalendarStageTests {
    static func failures() -> [String] {
        var out: [String] = []

        func check(_ what: String, _ got: CalendarViewMode?, _ want: CalendarViewMode?) {
            if got != want {
                out.append("\(what): erwartet \(want?.rawValue ?? "zu"), bekommen \(got?.rawValue ?? "zu")")
            }
        }
        // Beide: zu → Woche → Monat → zu
        check("beide, 1. Klick", CalendarViewMode.stepped.nextStage(after: nil), .week)
        check("beide, 2. Klick", CalendarViewMode.stepped.nextStage(after: .week), .month)
        check("beide, 3. Klick", CalendarViewMode.stepped.nextStage(after: .month), nil)
        // Nur Woche: zu → Woche → zu
        check("nur Woche, 1. Klick", CalendarViewMode.week.nextStage(after: nil), .week)
        check("nur Woche, 2. Klick", CalendarViewMode.week.nextStage(after: .week), nil)
        // Nur Monat: zu → Monat → zu, NIE über die Woche
        check("nur Monat, 1. Klick", CalendarViewMode.month.nextStage(after: nil), .month)
        check("nur Monat, 2. Klick", CalendarViewMode.month.nextStage(after: .month), nil)
        // Aus: bleibt zu, egal was vorher war
        check("aus, 1. Klick", CalendarViewMode.off.nextStage(after: nil), nil)
        check("aus, aus offenem Zustand", CalendarViewMode.off.nextStage(after: .week), nil)
        return out
    }
}
