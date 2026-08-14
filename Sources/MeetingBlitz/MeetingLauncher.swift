import Foundation
import AppKit

/// Central join-link opener (Runde 43). Someone may work in ONE Chrome profile
/// (personal@gmail.example is his private default) but hosts agency meetings under
/// you@work-domain.example, which is ALSO signed into that same profile. So
/// clicking a Meet link opened it as the wrong (default) account and he had to
/// switch by hand every time.
///
/// The fix needs no change to his Chrome setup: for a Google Meet link we append
/// `?authuser=<agency-email>` and open it in Chrome's profile. Google web apps
/// honour `authuser` and select that signed-in account directly. Non-Google
/// links (Zoom/Teams/…) are opened unchanged via the system default browser.
///
/// Every join in the app (agenda row, banner, banner detail, auto-join) routes
/// through here so the behaviour is identical everywhere.
@MainActor
enum MeetingLauncher {

    /// Open a meeting's join link with account routing applied.
    static func join(_ meeting: Meeting) {
        guard let url = meeting.joinURL else { return }
        open(url, title: meeting.title)
    }

    /// Open a join URL, routing Google Meet links to the right account. `title`
    /// selects a per-meeting override (a weekly series shares one title).
    static func open(_ url: URL, title: String?) {
        guard isGoogleMeet(url) else { NSWorkspace.shared.open(url); return }

        switch AppState.shared.meetRouting(forTitle: title) {
        case .systemDefault:
            NSWorkspace.shared.open(url)
        case .chrome(let authuser):
            openInChrome(url, authuser: authuser)
        }
    }

    /// Where a Meet link should open.
    enum Route {
        case systemDefault           // untouched, system default browser
        case chrome(authuser: String?)   // Chrome; nil = default profile account
    }

    // MARK: - Chrome

    /// Launch the URL in Chrome's chosen profile, optionally forcing a specific
    /// signed-in account via `authuser`. Executing Chrome's binary directly is
    /// the reliable way to honour `--profile-directory` whether or not Chrome is
    /// already running (`open -a … --args` silently drops the args when Chrome
    /// is up). Falls back to the system browser if Chrome isn't installed.
    private static func openInChrome(_ url: URL, authuser: String?) {
        let finalURL = authuser.flatMap { appendAuthuser(url, email: $0) } ?? url

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
            NSWorkspace.shared.open(finalURL)   // no Chrome (e.g. a machine without Chrome)
            return
        }
        let bin = appURL.appendingPathComponent("Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath: bin.path) else {
            NSWorkspace.shared.open(finalURL)   // odd bundle layout → default browser
            return
        }
        let profile = AppState.shared.meetChromeProfile.isEmpty ? "Default" : AppState.shared.meetChromeProfile
        let p = Process()
        p.executableURL = bin
        p.arguments = ["--profile-directory=\(profile)", finalURL.absoluteString]
        do { try p.run() }
        catch { NSWorkspace.shared.open(finalURL) }   // last resort
    }

    // MARK: - Helpers

    static func isGoogleMeet(_ url: URL) -> Bool {
        (url.host ?? "").lowercased().contains("meet.google")
    }

    /// Add/replace `authuser=<email>` on a Meet URL. The email form is more
    /// stable than the numeric index (which depends on sign-in order).
    private static func appendAuthuser(_ url: URL, email: String) -> URL {
        guard !email.isEmpty,
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        items.removeAll { $0.name == "authuser" }
        items.append(URLQueryItem(name: "authuser", value: email))
        comps.queryItems = items
        return comps.url ?? url
    }
}
