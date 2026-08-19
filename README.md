# MeetingBlitz

**A macOS menu bar app that warns you before every calendar event.** Shortly
before something from your Apple Calendar starts, a submarine flies across your
screens.

### ⬇ [Download MeetingBlitz 1.4](https://github.com/Felixosk/meetingblitz-mac/releases/latest/download/MeetingBlitz.zip)

Ready-made app · 2.8 MB · macOS 14+ · Apple Silicon **and** Intel ·
[one extra command on first launch](#option-a-download-the-ready-made-app) ·
or [build it yourself](#option-b-build-it-yourself) in two minutes

[Deutsche Version](README.de.md)

![Two meetings at 17:00, each with its own flying banner](docs/demo.gif)

<img src="docs/widget.png" width="470" alt="The menu bar widget: timeline, birthdays, and per-event actions">

*Click the submarine in the menu bar and this is your day: a timeline, birthdays
with a call button, and per event copy link, join, export .ics or hide.*

## Why this exists

Two reasons, and they are the whole point of the app.

**1. Every overlapping event gets its own warning.** Most tools show *the* next
meeting — one line, one notification, one timeslot. So a call nested inside a
focus block, or two meetings booked over each other, quietly collapses into a
single reminder and you miss the other one. Here each event fires its own
banner, and overlapping banners stack into separate lanes instead of replacing
each other. MeetingBar's request for this has been
[open since May 2021](https://github.com/leits/MeetingBar/issues/271).

**2. A visual warning, not a notification.** Notifications are built to be
ignorable: they slide in at the edge, wait a few seconds, and file themselves
away in a list you look at later. That is fine for a package delivery and
useless for something starting in five minutes. A submarine flying across every
monitor is not something you scroll past — and because it is drawn by the app
itself, it never lands in Do Not Disturb, never queues behind other apps'
notifications, and shows up on all screens at once.

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
| **Conflict warning while creating** | **yes** | no | no | no |
| Meeting link detection | 53 services | 50+ services | none | basic |
| Natural-language input | yes (`fri 4pm to 5pm call with chris`) | no | no | yes |
| Week / month picker in the widget | yes, one click steps through | no | yes | yes |
| Second time zone | yes | no | no | yes |
| Meeting stats (week / month / year) | yes | no | no | no |
| URL scheme for automation | `meetingblitz://` | Shortcuts + AppleScript | no | `calendr://` |
| Apple Reminders in the same list | yes | no | yes | yes |
| Calendar sources | Apple Calendar (so iCloud, Google, Exchange via macOS) | Apple Calendar + Google directly | Apple Calendar | Apple Calendar |
| Maturity | hobby project | 5.3k stars, years of polish | 4.0k stars | 2.3k stars |

Those three are the field: below Calendr, a search for macOS menu-bar calendars
turns up nothing above a handful of stars. The other well-known options are
commercial and closed source — **Dato** and **Fantastical** — so they are named
here rather than ticked off in a table, since their feature set cannot be
verified from the outside.

### The other camp: apps that interrupt you

The table above compares calendars. But MeetingBlitz is not really trying to be
a calendar — it is trying to *interrupt* you, and that is a much smaller field.
Everything in it, as of August 2026:

| | Stars | Language | How it interrupts | Also does |
|---|---|---|---|---|
| **MeetingBlitz** | this repo | Swift | banner per event, on every screen, overlapping ones stack | join, create, quick-add, conflict warning, stats, reminders |
| [QuakPit](https://github.com/Ooble-Studio/QuakPit) | 110 | TypeScript | a rubber duck flies across the screen | nothing else; last push May 2026 |
| [meeting-reminder](https://github.com/nilBora/meeting-reminder) | 7 | Swift | full-screen blocking overlay | one-click join |
| [alwayshaveaplan](https://github.com/ChrisZou/alwayshaveaplan) | 18 | Swift | shows your schedule when you unlock the Mac | — |
| [cyclop](https://github.com/akalikbergenov/cyclop) | 225 | Swift | notch panel, calendar is one tab of many | clipboard, snippets, file shelf, translation |

QuakPit proves the idea resonates: 110 stars for a duck that does nothing but
fly. What is missing everywhere else is the *per-event* part — and everything
you actually do after the reminder fires.

**Be honest about it:** if you want the most mature, best supported option with
the widest service coverage, install MeetingBar. It is excellent, and this
project started as a fan of it.

In the words of that open request: *"If two events are at the same time, I can
only see that only one is active in the status bar."* There is a related bug
where the fullscreen notification for the first of two back-to-back meetings
[never fires at all](https://github.com/leits/MeetingBar/issues/769).

![First launch walkthrough and settings](docs/tour.png)

## Features

- **A banner before every meeting**, on all monitors at once, with configurable lead time
- **Today at a glance** in the menu bar, with a timeline, a week/month picker and any day one click away
- **One-click join** for 53 services: Meet, Zoom, Teams, Webex, Whereby, Jitsi, Discord, Slack huddles, GoTo, Tencent and more
- **Type an event in one line**: `fri 4pm to 5pm call with chris`, with a live preview before anything is created
- **Conflict warning** while creating: tells you the slot is taken *before* you double-book
- **Instant meeting**: one click mints a Meet room, files the event and opens the call
- **Meeting stats** for the week, month and year, as bar charts
- **Export an event as .ics**, landing straight on your clipboard as a file
- **Apple Reminders** due today show up next to your events
- **Per calendar** you choose what shows, what fires a banner, and whether its birthdays appear
- **Declined invitations never warn you** — they stay visible, struck through
- **Quiet mode**, timed (1h / 5h / 1 day / 1 week) and automatically while sharing your screen, with a silent notice so nothing is missed
- **Two global shortcuts**, both rebindable: open the widget, join the current or next call
- **Automation** via `meetingblitz://show`, `join-next`, `instant`, `create?text=…`
- **Second time zone** in the widget, hidden while it matches your Mac
- **English and German**, switchable live, follows your system language on first run

Optional, only with your own Google Cloud credentials: create an event with a
ready Google Meet link straight from the app. Without that config the whole
feature hides itself, everything else works the same.
[Setup instructions below.](#optional-create-meetings-with-a-google-meet-link)

## Requirements

- **macOS 14 (Sonoma) or newer**
- Apple Silicon or Intel, the app builds as a universal binary
- **Xcode Command Line Tools** to build (one-time, see below)

## Install

### Option A: download the ready-made app

Grab `MeetingBlitz.zip` from the [latest release](https://github.com/Felixosk/meetingblitz-mac/releases/latest),
unzip it, and move **MeetingBlitz.app** into your **Applications** folder.

The app is signed with a self-made certificate, not with a paid Apple developer
account, so macOS quarantines it on download. One command clears that flag:

```bash
xattr -dr com.apple.quarantine /Applications/MeetingBlitz.app
```

Then open it normally. **Understand what that command does:** it tells macOS you
vouch for this app yourself, skipping the Gatekeeper check. Only run it on
software you actually trust — here you can read every line of the source first,
or take option B and build it yourself.

Without the command you can still launch it the long way: double-click, click
**Done** on the warning, then **System Settings → Privacy & Security → Open
Anyway**, and confirm once more.

### Option B: build it yourself

Two minutes, and no Gatekeeper dance at all, because software you compile
locally is not quarantined.

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

## Optional: create meetings with a Google Meet link

Everything above works without this. This one feature — the **Instant meeting**
button and the Meet link on events you create — talks to Google on your behalf,
so it needs credentials that belong to *you*. There is no shared app key, and
none ships in this repo.

It is a ten-minute, one-time setup:

1. Open the [Google Cloud Console](https://console.cloud.google.com/) and create
   a project (any name).
2. **APIs & Services → Library**: enable the **Google Calendar API**.
3. **APIs & Services → OAuth consent screen**: pick **External**, fill in the app
   name and your email. Under **Audience**, add your own Google address as a test
   user. *(If you have a Workspace account, choose Internal instead — then tokens
   don't expire every 7 days.)*
4. **APIs & Services → Credentials → Create credentials → OAuth client ID**,
   application type **Desktop app**. Download the JSON.
5. Put that file here, creating the folder if needed:

```bash
mkdir -p ~/Library/Application\ Support/MeetingBlitz
cp ~/Downloads/client_secret_*.json ~/Library/Application\ Support/MeetingBlitz/google-oauth.json
```

6. Restart MeetingBlitz. **Settings → Creating meetings** now offers
   **Connect Google**. Sign in once; the refresh token is stored in your macOS
   Keychain, never in a file.

Without that JSON the whole section stays hidden and no Google code ever runs.

**Heads-up on the 7-day expiry:** while the OAuth client sits in *Testing* mode,
Google invalidates refresh tokens after a week and you have to reconnect. The
consent screen's **Publish** button (or an Internal Workspace audience) ends
that for good.

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
