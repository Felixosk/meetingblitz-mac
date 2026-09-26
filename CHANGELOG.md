# Changelog

All notable changes to MeetingBlitz. Newest first.

## 1.7.2 — 2026-09-26

**You choose how long the title in the menu bar gets.** A long meeting title
could push other apps' icons behind the notch, where macOS hides them without
a word. Settings → Widget now has Title length: Short, Medium or Long. Medium
is the new default, Long is the old behaviour. The time never gets cut, only
the name.

**"Time only" works for the next meeting too.** Until now it only applied
while a meeting was running. For the next meeting the menu bar still showed
the title. Now it shows just "in 5h 15m".

## 1.7.1 — 2026-09-21

**Claude wrote events to one calendar only.** With "both" set as the target,
the New meeting form put an event in the Google and the Apple calendar, but
anything Claude created reached only the first of the two. The event was
missing from the other calendar and nothing reported an error. Claude now
writes to every calendar you picked, and the reply names all of them.

**Deleting and moving cover both copies.** An event that sits in two calendars
is still one event. Deleting it removes both halves instead of leaving one
behind, and moving it moves both, so the two cannot drift to different times.

## 1.7.0 — 2026-09-21

**Claude can manage your calendar.** MeetingBlitz now works as an MCP server.
Six tools: `get_context`, `list_calendars`, `list_events`, `create_event`,
`move_event` and `delete_event`. It is off by default. Settings → Claude access
(MCP) switches it on and copies the setup command. See the README for details.

**Times without a time zone use the Mac's zone.** `get_context` returns the
zone and the current time, so "10 am" means 10 am where you are. No IP lookup.

**Moving is safe.** In a recurring series only that one day moves. Events you
were invited to are refused with an explanation. Delete only works on events
Claude created.

**The menu bar moves on to the next meeting.** Once a meeting has been running
for ten minutes, the menu bar stops counting that one down and shows when the
next meeting starts instead. You already know what you are sitting in; what you
cannot see is how far you may overrun. Settings → Widget picks the threshold
(5, 10, 15 or 30 minutes) or turns the whole thing off.

**New switch: Copy invite text.** Settings → Creating meetings has a switch for
the invite text that lands on the clipboard, right above the `.ics` switch.

## 1.6.3 — 2026-09-14

**Calendars you switched off came back after every restart.** On launch the app
treated every calendar as newly added, and new calendars are switched on by
default. Unticked calendars under Show, Banner and Birthdays were quietly ticked
again. The app now remembers which calendars it has already seen, so only a
calendar that really is new starts out switched on.

**The widget did not grow when you changed the day.** It kept the height of
today, so on a busier day the buttons covered the last events. It now measures
itself again whenever the day or the list changes.

**Long days scroll instead of running off the screen.** Up to 10 events show on
one page; beyond that the list scrolls. Settings → Widget & menu bar → Events
before scrolling offers 6, 8, 10, 15 or All.

## 1.6.2 — 2026-08-31

**The calendar you picked for a new meeting did not stick.** "New meeting" kept
showing the target calendar from Settings, even right after you had picked a
different one in the form. That was not only the label: the meeting was filed
there too, so a pick in the form held for exactly one meeting and was then
forgotten. Your choice now survives closing the window and quitting the app. If
the calendar behind it disappears, because the account was removed, the form
falls back to the target from Settings instead of quietly using the system
default calendar — and picking a target in Settings overrides an earlier choice
from the form, so that page works again.

## 1.6.1 — 2026-08-26

**The settings window could open smaller than its own content.** On some Macs it
stayed at the minimum size the panel rescue falls back to, and a page that does
not fit its window overflows at the top *and* the bottom: you saw a strip from
the middle, without the tab bar and without the style switcher, so the
photoreal and photo motifs were out of reach. The window now measures what its
content needs and grows to it, both when it opens and after the rescue. The
diagnostics report gained a line naming the actual and the needed height.

## 1.6 — 2026-08-23

**The flying motif can now rotate.** Picking one of 27 motifs and never seeing
the other 26 was the odd default. Settings → Flying object offers **Fixed**,
**In order** and **Random** (random never draws the same motif twice in a row),
and while rotation is on, tapping a tile adds or removes it from the rotation
instead of selecting it. The ⓘ on a tile opens its story without changing
anything.

**Settings split into more tabs.** Banner, Flying object and Quiet & silence are
now separate, because the alerts tab had grown taller than a laptop screen.

**A panel that ends up invisible now rescues itself.** Half a second after
opening, Settings and New Meeting check whether they are actually on a screen
and large enough; if not, they move to the centre of the screen the mouse is on.
A report was traced to a settings window that was open the whole time, just a
few pixels tall. The diagnostics report now names the panels, their size and
which screen they are on.

**Fixes:** the widget hugs its content again instead of reserving four rows of
empty space; long hint texts in Settings wrap instead of being cut off.

## 1.5.1 — 2026-08-22

**Settings and other panels now show up over fullscreen apps.**

If you were working in a fullscreen app, clicking Settings appeared to do
nothing. The window did open, just on the desktop next to the one you were
looking at: no error, no log, nothing visible. The widget was allowed to follow
you across desktops, its companion panels were not. Settings, New Meeting and
the walkthrough now behave like the widget.

Two new entries in the right-click menu on the menu bar icon:

- **Bring windows back** — pulls the widget and its panels onto the screen your
  mouse is on and forgets remembered window positions. Useful if a panel ended
  up on a monitor that is no longer connected.
- **Restart MeetingBlitz** — quits and relaunches without hunting for the app in
  Finder.

New URL scheme entries for automation: `meetingblitz://settings`,
`meetingblitz://rescue`, `meetingblitz://restart`.

## 1.5 — 2026-08-21

**27 skins in 4 styles for the flying banner.** The submarine is no longer the
only option: swap it for a whale, a jet, a UFO or 24 other motifs, in styles
ranging from a plain outline to real photographs. Every photo-style motif is a
real thing — a Cold War submarine, a whale that sank a whaling ship, a rubber
duck that drifted the Pacific for fifteen years — and double-clicking a tile
opens its actual story with a source.

Air motifs now burst out of a cloud instead of leaping from the sea, and the
banner as a whole got larger with a pass over its motion.

## 1.4 — 2026-08-19

First release with a **prebuilt app attached**, as a universal binary for both
Apple Silicon and Intel. Earlier releases were source-only.

Also in this release: natural-language event entry, a conflict warning while
creating an event, meeting statistics, and a Google setup path that no longer
expires after seven days.

## 1.3 — 2026-08-14

**First public release.** Source only, on purpose: an unsigned prebuilt app gets
blocked by macOS, and building takes two minutes.

Flies a submarine banner across all screens shortly before a calendar event
starts, with every overlapping event getting its own independent warning.
