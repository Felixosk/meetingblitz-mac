import Foundation

/// Recognising meeting links (F7).
///
/// Was five hardcoded hosts; a Jitsi or Discord invite simply had no Join
/// button. The table below covers the services people actually send, and the
/// ORDER matters: a description can carry several links (a dial-in page, a
/// company wiki, the actual room), and the first match wins.
///
/// Patterns are matched against the URL's host, so a mention of "zoom" in the
/// meeting title can never be mistaken for a link.
///
/// Self-check: `MeetingBlitz --selftest` runs `JoinLink.selfTest()` over the
/// examples in `JoinLinkTests.swift` and exits non-zero on a mismatch. That
/// replaces a unit-test target: XCTest ships with Xcode, not with the Command
/// Line Tools this project builds on, so `swift test` cannot run here.
enum JoinLink {

    /// Known services, most specific first. `hosts` are matched as substrings
    /// of the URL host (lowercased).
    static let services: [(name: String, hosts: [String])] = [
        // Preferred: what meetings are actually held in.
        ("Google Meet",   ["meet.google.com"]),
        ("Zoom",          ["zoom.us", "zoom.com", "zoomgov.com"]),
        ("Microsoft Teams", ["teams.microsoft.com", "teams.live.com", "teams.microsoft.us"]),
        ("Webex",         ["webex.com", "webex.com.cn"]),
        ("Whereby",       ["whereby.com", "appear.in"]),
        // Widely used alternatives.
        ("Jitsi",         ["meet.jit.si", "jitsi.member.fsf.org", "8x8.vc"]),
        ("Discord",       ["discord.gg", "discord.com/events", "discord.com/channels"]),
        ("Slack",         ["slack.com/call", "app.slack.com/huddle"]),
        ("Around",        ["around.co"]),
        ("Butter",        ["butter.us"]),
        ("Chime",         ["chime.aws"]),
        ("Coscreen",      ["coscreen.co"]),
        ("Demodesk",      ["demodesk.com"]),
        ("Facetime",      ["facetime.apple.com"]),
        ("Gather",        ["gather.town"]),
        ("GoTo",          ["gotomeeting.com", "goto.com", "gotowebinar.com", "join.me"]),
        ("Livestorm",     ["livestorm.co"]),
        ("Lark",          ["vc.larksuite.com", "lark.com"]),
        ("Bluejeans",     ["bluejeans.com"]),
        ("Pop",           ["pop.com"]),
        ("Riverside",     ["riverside.fm"]),
        ("Skype",         ["join.skype.com", "skype.com"]),
        ("Starleaf",      ["starleaf.com"]),
        ("Tuple",         ["tuple.app"]),
        ("Vimeo",         ["vimeo.com/event"]),
        ("Vowel",         ["vowel.com"]),
        ("Zoho",          ["meeting.zoho.com"]),
        ("Ring Central",  ["ringcentral.com"]),
        ("Amazon Connect", ["my.connect.aws"]),
        ("BigBlueButton", ["bigbluebutton.org"]),
        ("Google Hangouts", ["hangouts.google.com"]),
        ("Teamviewer",    ["go.teamviewer.com"]),
        ("Youtube Live",  ["youtube.com/live", "youtu.be"]),
        ("Twitch",        ["twitch.tv"]),
        ("Telegram",      ["t.me"]),
        ("Signal",        ["signal.group"]),
        ("Element",       ["app.element.io", "matrix.to"]),
        ("Nextcloud Talk", ["nextcloud.com/call"]),
        ("Kmeet",         ["kmeet.infomaniak.com"]),
        ("Tencent",       ["meeting.tencent.com", "voovmeeting.com"]),
        ("Dingtalk",      ["dingtalk.com"]),
        ("Feishu",        ["vc.feishu.cn"]),
        ("Wechat",        ["meeting.wechat.com"]),
        ("Doxy",          ["doxy.me"]),
        ("Teemyco",       ["app.teemyco.com"]),
        ("Suit",          ["suitconference.com"]),
        ("Preply",        ["preply.com"]),
        ("Userzoom",      ["go.userzoom.com"]),
        ("Venue",         ["venue.live"]),
        ("Vonage",        ["meetings.vonage.com"]),
        ("Meetecho",      ["meetings.conf.meetecho.com"]),
        ("Jam",           ["jam.systems"]),
        ("Discourse",     ["discourse.org"]),
    ]

    /// The service a URL belongs to, or nil if it is not a known meeting link.
    static func service(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let full = (host + (url.path)).lowercased()
        for s in services where s.hosts.contains(where: { full.contains($0) }) {
            return s.name
        }
        return nil
    }

    static func isMeetingLink(_ url: URL) -> Bool { service(for: url) != nil }

    /// Pick the join link out of an event: the explicit URL field first, then
    /// the first known link found in location/notes. A non-meeting URL in the
    /// URL field is still returned as a last resort, unchanged from before —
    /// some people paste a company-internal room link there.
    static func best(explicit: URL?, texts: [String?]) -> URL? {
        if let u = explicit, isMeetingLink(u) { return u }
        let text = texts.compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty else { return explicit }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let urls = detector?.matches(in: text, options: [], range: range).compactMap { $0.url } ?? []
        return urls.first(where: isMeetingLink) ?? urls.first ?? explicit
    }
}
