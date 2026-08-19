# MeetingBlitz, a guide for Claude Code

You are helping get MeetingBlitz running on this Mac, or extending it. This
directory is the complete source.

**Build it locally and do real diagnosis** (build, launch, read logs and
screenshots). Don't guess. Every pitfall below cost the author several attempts
and is written down for a reason.

---

## 1. What this is

A native macOS **menu bar app** (SwiftUI + AppKit, **SwiftPM, no Xcode project**).
It reads Apple Calendar through EventKit and flies an animated submarine banner
across all screens shortly before an event starts.

**No dock icon, no main window.** Everything hangs off an `NSStatusItem` and
self-managed `NSPanel`s (widget, settings, new meeting, walkthrough). That is the
reason for most of the quirks below: the app is never the active application,
and a lot of SwiftUI's convenience assumes exactly that.

## 2. Build and run

```bash
xcode-select --install          # once, if the Command Line Tools are missing
./build.sh                      # universal binary, produces dist/MeetingBlitz.app
open dist/MeetingBlitz.app      # ALWAYS via open, never the binary directly
```

`build.sh` compiles release for both architectures, merges them with `lipo`,
assembles the `.app` bundle with its Info.plist (`LSUIElement`, the usage strings
for calendars and reminders) and signs it.

**Signing:** without configuration it signs ad-hoc, which means **macOS discards
granted permissions on every rebuild**, because it treats the app as a new one.
If you build often, create a self-signed certificate and copy
`signing.local.example` to `signing.local` (that file is not versioned).

## 3. Restart ritual while testing

```bash
pkill -x MeetingBlitz && sleep 1 && open dist/MeetingBlitz.app
```

A **single-instance guard** exits any second instance immediately (`exit(0)`).
Without knowing that, you launch the app and wonder why your new build isn't
running. Only `--diagnose` is exempt.

## 4. Debug flags

| Flag | Effect |
|---|---|
| `--demo` | fires a test banner every 8 s |
| `--demo-widget` | opens widget and settings programmatically |
| `--demo-create` | opens the "New Meeting" form |
| `--demo-splash` | water shader on a loop, for tuning |
| `--demo-onboarding` | shows the walkthrough even when already completed |
| `--onboarding-step=N` | starts the walkthrough at step N |
| `--demo-day=N` | opens the widget on a specific day, for layout measurements |
| `--demo-hint` | shows the icon explanation box without a mouse |
| `--hint-log` | writes hover measurements to `/tmp/mb_hints.log` |
| `--diagnose` | writes a status report to `~/Downloads` |
| `--diagnose --stdout` | same report on the console |

**Always kill demo instances afterwards.** A forgotten `--demo` sends a submarine
across the screen every 8 seconds.

## 5. Architecture (Sources/MeetingBlitz/)

| File | Role |
|---|---|
| `MeetingBlitzApp.swift` | `@main`, AppDelegate, NSStatusItem, menu bar title |
| `AppState.swift` | central `ObservableObject`, all settings, calendar filters |
| `CalendarService.swift` | EventKit: access, calendar list, events, reminders |
| `MeetingMonitor.swift` | 20 s timer + `EKEventStoreChanged`, fires per occurrence |
| `Models.swift` | `Meeting`, `CalendarInfo`, `ReminderItem`, recurrence rules |
| `WidgetPanel.swift` | the dropdown panel (borderless, NSVisualEffectView) |
| `MenuPanel.swift` | widget contents: timeline, agenda, reminders, footer |
| `SettingsPanel.swift` | settings as tabs (General/Banner/Calendars/Google) |
| `OnboardingPanel.swift` | first-run walkthrough |
| `CreatePanel.swift` | "New Meeting" form (only with a Google config) |
| `BannerPresenter.swift` | flight path, per-screen panels, lane stacking |
| `BannerContent.swift` | the banner capsule and the detail popover |
| `CloseButton.swift` | shared close control for floating surfaces |
| `HintWindow.swift` | the icon explanation box, plus its own hover hit-testing |
| `Hints.swift` | registers the icon areas for that hover |
| `SubmarineView.swift` | the submarine (Canvas) |
| `SplashMetalView.swift` | water shader, compiled at runtime |
| `MenuBarIcon.swift` | menu bar symbol as a template NSImage |
| `PanelDock.swift` | placement and remembered panel positions |
| `HotKeyManager.swift` | global shortcut ⌃⌥M (Carbon, no accessibility grant) |
| `MeetingLauncher.swift` | opens meeting links, optional account routing |
| `GoogleService.swift` | optional Google OAuth (inactive without a config) |
| `ICSExport.swift` | .ics file for a single event |
| `Diagnostics.swift` | the status report |
| `L10n.swift` | `L.t(de, en)`, **every new string goes through this** |

## 6. Pitfalls (do not code against these)

1. **`.regularMaterial` and `.borderedProminent` render dead in this app.**
   The app is never active, so SwiftUI materials fall back to their inactive
   look: a flat dark slab, muddy text, grey instead of coloured buttons. In
   panels **always** use a real `NSVisualEffectView` with `state = .active`, or
   an explicitly painted fill.

2. **`.behindWindow` blur belongs only in resting panels.** In a moving banner
   panel it cannot sample and falls back to black. Always fill flying elements
   with an opaque colour.

3. **`.menu` pickers hang inside a `.nonactivatingPanel`.** The modal NSMenu
   blocks every click in the panel afterwards. Use `.segmented` or buttons.

4. **`ScrollView` has no intrinsic height** and collapses to zero in panels that
   size themselves by their fitting size. Always give it a fixed `.frame(height:)`.

5. **`hosting.fittingSize` is often still ~0 right after creation.** Do the final
   panel placement one runloop later.

6. **An overly wide NSStatusItem disappears silently.** macOS does not truncate,
   it throws out the leftmost items: no log, no crash, `isVisible` stays true.
   When the icon is gone, first count instances, then check login items, then
   compute the item width against `NSScreen.auxiliaryTopRightArea`. The constant
   `maxMenuBarWidth` is calibrated for one specific Mac and may be adjusted.

7. **Borderless frosted-glass panels once made the whole app unclickable.** If
   you try that look again: commit first, then build, then test ONE click, and
   only then continue.

8. **Launching the binary straight from a shell means no calendar access.** The
   grant hangs off the calling process. A diagnostics report will then falsely
   claim "no access". Always `open -n dist/MeetingBlitz.app --args --diagnose`.

9. **Never check `EKAuthorizationStatus` by raw value.** The numbering shifted
   between macOS releases. Check against the enum cases. Note `.writeOnly` means
   the app may write but sees no events at all.

10. **Small transient windows must not use NSHostingView.** In this never-active
    app the hosting view resizes a freshly ordered panel *after* it is shown (top
    edge stays, bottom drops, content sticks to the bottom, the window appears
    ~200pt away from its own frame). `sizingOptions = []` does **not** prevent
    it, and `fittingSize` sometimes returns a phantom 0×0 on top. That is why
    `HintWindow` is pure AppKit: an NSTextField, measured by hand.

11. **SwiftUI hover tracking lies inside this widget.** `.onHover` and
    `.onContinuousHover` fire with stale tracking areas (~190pt off), because the
    panel moves and resizes itself after opening. The icon explanations therefore
    do their own hit-testing: icons register their frames (`HintSpots`), and a
    mouse monitor on the widget computes the hit. Do not "simplify" this back to
    SwiftUI hover.

12. **Measurements belong in a file, not in NSLog.** `log show` redacts message
    contents as `<private>`. `HintWindow.log` writes to `/tmp/mb_hints.log`
    behind a flag, and that file has solved in minutes what guessing did not.

## 7. Google Meet is optional

Without a config file `GoogleService.hasConfig` is false, and the app hides the
"New Meeting" button plus the entire Google section of the settings. There is no
error and nothing to fix. The core feature does not need Google.

If you want it, create your own Google Cloud project (enable the Calendar API,
OAuth client of type Desktop) and put the downloaded JSON at
`~/Library/Application Support/MeetingBlitz/google-oauth.json`, or bundle it as
`google-oauth.json` in `Contents/Resources/`. `GoogleService.loadConfig()` checks
both. The step-by-step version is in the README under "Optional: create meetings
with a Google Meet link". No credentials are included in this repository on
purpose, and none are needed unless you want this one feature.

## 8. It is done when

- `./build.sh` completes without errors
- the app launches and **exactly one** instance is running
- the menu bar symbol is visible and opens the widget
- the agenda shows today's real events
- a test banner (Settings → Banner → Test banner) flies across the screen
- every demo instance has been killed
