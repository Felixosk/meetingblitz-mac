# Changelog

All notable changes to MeetingBlitz. Newest first.

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
