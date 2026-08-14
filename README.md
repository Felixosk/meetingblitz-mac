# MeetingBlitz

**A macOS menu bar app that warns you before every calendar event.** Shortly
before something from your Apple Calendar starts, a submarine flies across your
screens.

[Deutsche Version](README.de.md)

![Two meetings at 17:00, each with its own flying banner](docs/demo.gif)

<img src="docs/widget.png" width="470" alt="The menu bar widget: timeline, birthdays, and per-event actions">

*Click the submarine in the menu bar and this is your day: a timeline, birthdays
with a call button, and per event copy link, join, export .ics or hide.*

The difference to the usual menu bar calendars: **overlapping events each get
their own warning.** If you have parallel or nested meetings, most tools only
surface the longest one, and you keep missing the second.

Native Swift and SwiftUI, no Electron, no server, no account. Builds in about
two minutes.

---

## How it compares

The macOS menu bar has good calendar apps already. Here is where each one sits,
and where this one is genuinely different.

| | MeetingBlitz | [MeetingBar](https://github.com/leits/MeetingBar) | [Itsycal](https://github.com/sfsam/Itsycal) | [Calendr](https://github.com/pakerwreah/Calendr) |
|---|---|---|---|---|
| Overlapping events warn **individually** | **yes** | no ([open since 2021](https://github.com/leits/MeetingBar/issues/271)) | n/a | n/a |
| Warning style | flying banner across **all** screens | menu bar title, notification, optional fullscreen | none | none |
| Meeting link detection | Meet, Zoom, Teams, Webex, Whereby | 50+ services | none | basic |
| Calendar sources | Apple Calendar (so iCloud, Google, Exchange via macOS) | Apple Calendar + Google directly | Apple Calendar | Apple Calendar |
| Apple Reminders in the same list | yes | no | yes | yes |
| Month grid view | no | no | yes | yes |
| Maturity | hobby project | 5k+ stars, years of polish | 3.9k+ stars | 2.3k+ stars |

**Be honest about it:** if you want the most mature, best supported option with
the widest service coverage, install MeetingBar. It is excellent, and this
project started as a fan of it.

**The one thing it does that they don't:** a warning *per event*, not per
timeslot. MeetingBar shows the current or next meeting, and its request to
surface simultaneously active events has been
[open since May 2021](https://github.com/leits/MeetingBar/issues/271): *"If two
events are at the same time, I can only see that only one is active in the
status bar."* There is a related bug where the fullscreen notification for the
first of two back-to-back meetings
[never fires at all](https://github.com/leits/MeetingBar/issues/769).

If your calendar has parallel or nested events, a focus block with a call
inside it, two calls booked over each other, a standup that overlaps a
handover, that is exactly the meeting you keep missing. MeetingBlitz fires an
independent banner for each one, and overlapping banners stack into their own
lanes instead of replacing each other.

The second difference is how loud it is. A notification is easy to swipe away
without reading. A submarine flying across every monitor is not.

![First launch walkthrough and settings](docs/tour.png)

## Features

- **A banner before every meeting**, on all monitors at once, with configurable lead time
- **Today at a glance** in the menu bar, with a timeline and up to a week ahead
- **One-click join**: detects Google Meet, Zoom, Teams, Webex and Whereby links
- **Export an event as .ics**, landing straight on your clipboard as a file
- **Apple Reminders** due today show up next to your events
- **Per calendar** you choose what shows, what fires a banner, and whether its birthdays appear
- **Quiet mode**, automatically also while sharing your screen
- **Global shortcut ⌃⌥M**, for when the menu bar icon runs out of room
- **English and German**, switchable live, follows your system language on first run

Optional, only with your own Google Cloud credentials: create an event with a
ready Google Meet link straight from the app. Without that config the whole
feature hides itself, everything else works the same.

## Requirements

- **macOS 14 (Sonoma) or newer**
- Apple Silicon or Intel, the app builds as a universal binary
- **Xcode Command Line Tools** to build (one-time, see below)

## Install

Building it yourself takes two minutes and saves you the Gatekeeper dance macOS
performs for any app not signed by a paid Apple developer account.

```bash
git clone https://github.com/Felixosk/meetingblitz-mac.git
cd meetingblitz-mac
./build.sh && open dist/MeetingBlitz.app
```

If the Command Line Tools are missing, this installs them (a few hundred MB,
one time), then build again:

```bash
xcode-select --install
```

On first launch a short walkthrough covers calendar access, calendar selection
and launch at login. You can replay it any time under
**Settings → General → Walkthrough**.

### Good to know

**This app has no window and no dock icon.** It lives in the menu bar, top
right. If nothing seems to happen after launch, that is not a bug: look for the
submarine up there.

### If you were handed a prebuilt app

Then Gatekeeper blocks it, because it is not signed by a paid Apple developer
account. On current macOS:

1. Drag the app into **Applications**, *before* first launch. Otherwise it runs
   from a temporary read-only folder and "launch at login" is unreliable.
2. Double-click. In the "Apple could not verify…" dialog click **Done**. Never
   "Move to Trash".
3.  → **System Settings** → **Privacy & Security**, scroll to the bottom
   **Security** section. It now says "MeetingBlitz was blocked" with an
   **Open Anyway** button.
4. Double-click again and confirm **Open** in the final dialog.

**Step 3 has to follow soon after step 2**, otherwise the button disappears and
you start over at step 2. After that the app is cleared for good.

The old right-click → Open trick **no longer works** since macOS 15 and lands
you in the same blocking dialog.

Only if it actually says "damaged and can't be opened":

```bash
xattr -cr "/Applications/MeetingBlitz.app"
```

## Permissions and privacy

The app asks for **calendar access** on first launch, optionally for
**reminders**. Both stay local on your Mac. There is no server, no telemetry,
no account. The source is right here.

The Google part is optional and only kicks in if you supply your own OAuth
config. No credentials are included in this repository.

## Troubleshooting

**The menu bar icon is missing.** The most common reason is mundane and costs
hours otherwise: space right of the notch is limited (roughly 790 points on a
MacBook, shared by all apps). Once it is full, macOS drops icons **silently**,
without any error. Fix: quit other menu bar apps, or just open the window with
**⌃⌥M**.

**The app sees no events.** System Settings → Privacy & Security → Calendars →
enable MeetingBlitz. Careful, macOS also offers "add only" there: with that the
app may write but sees nothing. It needs full access.

**Generate a status report.** Right-click the menu bar icon → "Save diagnostics".
The report lands in `~/Downloads` and lists version, permissions, screens and
window positions in plain text. It contains your calendar names, so glance over
it before sharing.

## Working on it with Claude Code

There is a `CLAUDE.md` in this repository with the architecture, the build
process and the traps this app has in store. Open Claude Code in this folder and
tell it what you want changed.

## Signing

Without config `build.sh` signs ad-hoc, which means **macOS drops your granted
permissions on every rebuild**, because it considers the app a new one. If you
build often, create a self-signed certificate and copy `signing.local.example`
to `signing.local`. Instructions are inside that file.

## License

MIT, see [LICENSE](LICENSE).
