# MeetingBlitz, Leitfaden für Claude Code

Du hilfst dabei, MeetingBlitz auf diesem Mac zum Laufen zu bringen oder zu
erweitern. Dieses Verzeichnis ist der vollständige Quellcode.

**Bau die App lokal und führe echte Diagnose durch** (bauen, starten, Logs und
Screenshots prüfen). Rate nicht. Die Stolperfallen unten haben den Autor jeweils
mehrere Anläufe gekostet und sind hart erkauft.

---

## 1. Was die App ist

Native macOS-**Menüleisten-App** (SwiftUI + AppKit, **SwiftPM, kein Xcode-Projekt**).
Sie liest den Apple-Kalender über EventKit und schickt kurz vor einem Termin ein
animiertes U-Boot-Banner über alle Bildschirme.

**Kein Dock-Icon, kein Hauptfenster.** Alles hängt an einem `NSStatusItem` und an
selbstverwalteten `NSPanel`s (Widget, Einstellungen, Neues Meeting, Einstieg).
Das ist der Grund für die meisten Eigenheiten weiter unten: Die App ist nie die
aktive Anwendung, und viele SwiftUI-Automatismen setzen genau das voraus.

## 2. Bauen und starten

```bash
xcode-select --install          # einmalig, falls die Command Line Tools fehlen
./build.sh                      # Universal Binary, erzeugt dist/MeetingBlitz.app
open dist/MeetingBlitz.app      # IMMER über open, nie das Binary direkt
```

`build.sh` kompiliert release für beide Architekturen, fügt sie per `lipo`
zusammen, baut das `.app`-Bundle mit Info.plist (`LSUIElement`, die
Usage-Strings für Kalender und Erinnerungen) und signiert es.

**Signatur:** Ohne Konfiguration signiert `build.sh` ad-hoc. Das bedeutet:
**macOS wirft bei jedem Rebuild die erteilten Berechtigungen weg**, weil es die
App für eine neue hält. Wer öfter baut, legt sich ein selbstsigniertes
Zertifikat an und kopiert `signing.local.example` nach `signing.local` (die
Datei ist nicht versioniert). Die Anleitung steht in der Vorlage selbst.

## 3. Neustart-Ritual beim Testen

```bash
pkill -x MeetingBlitz && sleep 1 && open dist/MeetingBlitz.app
```

Ein **Single-Instance-Guard** beendet jede zweite Instanz sofort (`exit(0)`).
Wer das nicht weiß, startet die App und wundert sich, dass der neue Build nicht
greift. Ausgenommen ist nur `--diagnose`.

## 4. Debug-Schalter

| Schalter | Wirkung |
|---|---|
| `--demo` | feuert alle 8 s ein Test-Banner |
| `--demo-widget` | öffnet Widget und Einstellungen programmatisch |
| `--demo-create` | öffnet das Formular „Neues Meeting" |
| `--demo-splash` | Wasser-Shader als Endlosschleife zum Tunen |
| `--demo-onboarding` | zeigt den Einstieg, auch wenn er schon erledigt ist |
| `--demo-hint` | zeigt die Symbol-Erklärbox programmatisch, ohne Maus (mit `--demo-widget` kombinieren) |
| `--hint-log` | schreibt Hover-Messwerte nach `/tmp/mb_hints.log` |
| `--onboarding-step=N` | startet den Einstieg bei Schritt N (0–3) |
| `--diagnose` | schreibt einen Statusbericht nach `~/Downloads` |
| `--diagnose --stdout` | derselbe Bericht auf die Konsole |

**Demo-Instanzen nach dem Test immer killen.** Ein vergessenes `--demo` schickt
alle 8 Sekunden ein U-Boot über den Schirm.

## 5. Architektur (Sources/MeetingBlitz/)

| Datei | Rolle |
|---|---|
| `MeetingBlitzApp.swift` | `@main`, AppDelegate, NSStatusItem, Menüleisten-Titel |
| `AppState.swift` | zentraler `ObservableObject`, alle Einstellungen, Kalenderfilter |
| `CalendarService.swift` | EventKit: Zugriff, Kalenderliste, Termine, Erinnerungen |
| `MeetingMonitor.swift` | Timer (20 s) + `EKEventStoreChanged`, feuert pro Occurrence |
| `Models.swift` | `Meeting`, `CalendarInfo`, `ReminderItem`, Wiederholungsregeln |
| `WidgetPanel.swift` | das Dropdown-Panel (borderless, NSVisualEffectView) |
| `MenuPanel.swift` | Inhalt des Widgets: Zeitachse, Agenda, Erinnerungen, Footer |
| `SettingsPanel.swift` | Einstellungen als Tabs (Allgemein/Banner/Kalender/Google) |
| `OnboardingPanel.swift` | Einstieg beim ersten Start, 4 Schritte |
| `CreatePanel.swift` | Formular „Neues Meeting" (nur mit Google-Konfiguration) |
| `BannerPresenter.swift` | Flugbahn, Panels pro Bildschirm, Stapelung |
| `BannerContent.swift` | die Banner-Kapsel und das Detail-Popover |
| `CloseButton.swift` | gemeinsames Schließkreuz für schwebende Flächen |
| `SubmarineView.swift` | das U-Boot (Canvas) |
| `SplashMetalView.swift` | Wasser-Shader, zur Laufzeit kompiliert |
| `MenuBarIcon.swift` | Menüleisten-Symbol als Template-NSImage |
| `PanelDock.swift` | Positionierung und gemerkte Panel-Positionen |
| `HotKeyManager.swift` | globales Kürzel ⌃⌥M (Carbon, keine Bedienungshilfen nötig) |
| `MeetingLauncher.swift` | öffnet Meeting-Links, optionales Konto-Routing |
| `GoogleService.swift` | optionales Google-OAuth (ohne Konfiguration inaktiv) |
| `ICSExport.swift` | .ics-Datei für einen Termin |
| `Diagnostics.swift` | der Statusbericht |
| `L10n.swift` | `L.t(de, en)`, **jeder neue String gehört hier durch** |
| `Hints.swift` | Tooltip-Helfer für die Bedienelemente |

## 6. Stolperfallen (nicht dagegen anprogrammieren)

1. **`.regularMaterial` und `.borderedProminent` rendern in dieser App tot.**
   Die App ist nie aktiv, also fallen SwiftUI-Materialien auf ihr Inaktiv-Aussehen
   zurück: eine flache dunkle Platte, matschiger Text, graue statt farbige Knöpfe.
   In Panels **immer** eine echte `NSVisualEffectView` mit `state = .active`
   oder eine explizit gemalte Fläche verwenden.

2. **`.behindWindow`-Blur gehört nur in ruhende Panels.** In einem bewegten
   Banner-Panel kann er nicht sampeln und fällt auf Schwarz zurück. Fliegende
   Elemente immer mit deckender Farbe füllen.

3. **`.menu`-Picker hängen in einem `.nonactivatingPanel`.** Das modale NSMenu
   blockiert danach alle Klicks im Panel. `.segmented` oder Knöpfe verwenden.

4. **`ScrollView` hat keine intrinsische Höhe** und kollabiert in Panels, die
   sich nach ihrer Fitting-Size messen, auf null. Immer feste `.frame(height:)`.

5. **`hosting.fittingSize` ist direkt nach dem Erzeugen oft noch ~0.** Panels
   deshalb einen Runloop später endgültig platzieren.

6. **Ein zu breites NSStatusItem verschwindet kommentarlos.** macOS kürzt nicht,
   es wirft die am weitesten links liegenden Items raus: kein Log, kein Crash,
   `isVisible` bleibt true. Bei „Icon weg" zuerst Instanzen zählen, dann Login
   Items prüfen, dann die Item-Breite gegen `NSScreen.auxiliaryTopRightArea`
   rechnen. Die Konstante `maxMenuBarWidth` ist auf einen bestimmten Mac
   kalibriert und darf angepasst werden.

7. **Randlose Milchglas-Panels haben die App schon einmal komplett unklickbar
   gemacht.** Wenn du diesen Look nochmal versuchst: erst committen, dann bauen,
   dann EINEN Klick testen, erst dann weitermachen.

8. **Das Binary direkt aus der Shell zu starten bedeutet keinen Kalenderzugriff.**
   Die Berechtigung hängt am aufrufenden Prozess. Ein Diagnosebericht meldet dann
   fälschlich „kein Zugriff". Immer `open -n dist/MeetingBlitz.app --args --diagnose`.

9. **`EKAuthorizationStatus` nie über den Rohwert prüfen.** Die Nummerierung hat
   sich zwischen macOS-Versionen verschoben. Gegen die Enum-Fälle prüfen. Achtung:
   `.writeOnly` heißt, die App darf schreiben, sieht aber keine Termine.

10. **Tooltips brauchen die richtige Modifier-Reihenfolge.** `.help()` muss
    *nach* einem `.opacity()` stehen, sonst hängt der Tooltip an der
    durchsichtigen Ebene und erscheint nie.

11. **Kleine transiente Fenster nie mit NSHostingView bauen.** In dieser
    nie-aktiven App resized die NSHostingView ein frisch geordertes Panel
    NACH dem Anzeigen selbst (Oberkante bleibt, Unterkante sackt ab, Inhalt
    klebt unten, das Fenster erscheint 200pt neben seinem Frame).
    `sizingOptions = []` verhindert das NICHT, und `fittingSize` liefert
    zusätzlich manchmal die Phantom-Größe 0×0. Die Erklärbox (HintWindow) ist
    deshalb reines AppKit: NSTextField, von Hand vermessen. Genauso wieder
    bauen, wenn je ein weiteres Mini-Fenster dazukommt.

12. **SwiftUIs Hover-Tracking lügt in diesem Widget.** `.onHover` und
    `.onContinuousHover` feuern mit veralteten Flächen (~190pt daneben), weil
    sich das Panel nach dem Öffnen selbst verschiebt und vergrößert. Das
    Hovering der Symbol-Erklärungen läuft deshalb in Eigenregie: die Symbole
    registrieren ihre Flächen (`HintSpots`), ein Maus-Monitor des Widgets
    rechnet den Treffer selbst. Nicht auf SwiftUI-Hover zurückbauen.

## 7. Google Meet ist optional

Ohne Konfigurationsdatei ist `GoogleService.hasConfig` false, dann blendet die
App den Knopf „Neues Meeting" und den ganzen Google-Bereich der Einstellungen
aus. Es gibt keine Fehlermeldung und nichts zu reparieren. Die Kernfunktion
braucht Google nicht.

Wer es will, legt ein eigenes Google-Cloud-Projekt an (Calendar API aktivieren,
OAuth-Client vom Typ Desktop) und die heruntergeladene JSON unter
`~/.claude/secrets/meetingblitz-google-oauth.json` ab. Im Repository sind
bewusst keine Zugangsdaten enthalten.

## 8. Fertig ist es, wenn

- `./build.sh` ohne Fehler durchläuft
- die App startet und **genau eine** Instanz läuft
- das Menüleisten-Symbol sichtbar ist und das Widget öffnet
- die Agenda die echten Termine des Tages zeigt
- ein Test-Banner (Einstellungen → Banner → Test-Banner) über den Schirm fliegt
- alle Demo-Instanzen beendet sind
