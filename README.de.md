# MeetingBlitz

**Eine macOS-Menüleisten-App, die dich vor jedem Termin warnt.** Kurz bevor
etwas aus deinem Apple Kalender beginnt, fliegt ein U-Boot über deine
Bildschirme.

### ⬇ [MeetingBlitz 1.4 laden](https://github.com/Felixosk/meetingblitz-mac/releases/latest/download/MeetingBlitz.zip)

Fertige App · 2,8 MB · macOS 14+ · Apple Silicon **und** Intel ·
[ein Befehl beim ersten Start](#möglichkeit-a-fertige-app-laden) ·
oder [selbst bauen](#möglichkeit-b-selbst-bauen) in zwei Minuten

[English version](README.md)

![Zwei Termine um 17:00, jeder mit eigenem fliegendem Banner](docs/demo.gif)

<img src="docs/widget.png" width="470" alt="Das Menüleisten-Widget: Zeitachse, Geburtstage und Aktionen pro Termin">

*Ein Klick aufs U-Boot in der Menüleiste zeigt deinen Tag: Zeitachse,
Geburtstage mit Anruf-Knopf, und pro Termin Link kopieren, beitreten,
.ics exportieren oder ausblenden.*

Eine Menüleisten-App für den Mac, die dich vor Terminen warnt. Kurz bevor etwas
aus deinem Apple-Kalender startet, fliegt ein U-Boot über den Bildschirm.

Der Unterschied zu den üblichen Menüleisten-Kalendern: **Überschneidende Termine
bekommen jeder ihre eigene Warnung.** Wer parallele und verschachtelte Termine
hat, verpasst den zweiten sonst regelmäßig, weil die meisten Tools nur den
längsten anzeigen.

---

## Im Vergleich

Es gibt schon gute Kalender-Apps für die Menüleiste. Hier steht, wo jede sitzt
und wo diese sich wirklich unterscheidet.

| | MeetingBlitz | [MeetingBar](https://github.com/leits/MeetingBar) | [Itsycal](https://github.com/sfsam/Itsycal) | [Calendr](https://github.com/pakerwreah/Calendr) |
|---|---|---|---|---|
| Überschneidende Termine warnen **einzeln** | **ja** | nein ([offen seit 2021](https://github.com/leits/MeetingBar/issues/271)) | entfällt | entfällt |
| Art der Warnung | Banner fliegt über **alle** Bildschirme | Menüleistentext, Mitteilung, optional Vollbild | keine | keine |
| **Warnung vor Überschneidung beim Anlegen** | **ja** | nein | nein | nein |
| Erkannte Meeting-Links | 53 Dienste | 50+ Dienste | keine | einfach |
| Termin als Fließtext eintippen | ja (`fr 16 uhr bis 17 uhr call mit chris`) | nein | nein | ja |
| Wochen-/Monatswahl im Widget | ja, ein Klick schaltet durch | nein | ja | ja |
| Zweite Zeitzone | ja | nein | nein | ja |
| Auswertung (Woche/Monat/Jahr) | ja | nein | nein | nein |
| URL-Schema für Automation | `meetingblitz://` | Kurzbefehle + AppleScript | nein | `calendr://` |
| Apple Erinnerungen in derselben Liste | ja | nein | ja | ja |
| Kalenderquellen | Apple Kalender (damit iCloud, Google, Exchange über macOS) | Apple Kalender + Google direkt | Apple Kalender | Apple Kalender |
| Reife | Hobbyprojekt | 5300 Sterne, jahrelang poliert | 4000 Sterne | 2300 Sterne |

### Das andere Feld: Apps, die dich unterbrechen

Die Tabelle oben vergleicht Kalender. MeetingBlitz will aber gar kein Kalender
sein, sondern dich *unterbrechen* — und dieses Feld ist deutlich kleiner. Alles,
was es darin gibt, Stand August 2026:

| | Sterne | Sprache | Wie unterbrochen wird | Kann außerdem |
|---|---|---|---|---|
| **MeetingBlitz** | dieses Repo | Swift | Banner pro Termin, auf allen Bildschirmen, überschneidende stapeln sich | beitreten, anlegen, Freitext, Kollisionswarnung, Auswertung, Erinnerungen |
| [QuakPit](https://github.com/Ooble-Studio/QuakPit) | 110 | TypeScript | eine Gummiente fliegt über den Bildschirm | sonst nichts; letzter Push Mai 2026 |
| [meeting-reminder](https://github.com/nilBora/meeting-reminder) | 7 | Swift | Vollbild-Overlay, das alles blockiert | Beitreten mit einem Klick |
| [alwayshaveaplan](https://github.com/ChrisZou/alwayshaveaplan) | 18 | Swift | zeigt den Tagesplan beim Entsperren | — |
| [cyclop](https://github.com/akalikbergenov/cyclop) | 225 | Swift | Notch-Panel, Kalender ist einer von vielen Tabs | Zwischenablage, Snippets, Dateiablage, Übersetzung |

QuakPit zeigt, dass die Idee zieht: 110 Sterne für eine Ente, die nichts weiter
tut als fliegen. Was überall fehlt, ist das *pro Termin* — und alles, was man
nach der Erinnerung eigentlich tun will.

**Ganz ehrlich:** Wer die reifste, bestgepflegte Lösung mit der breitesten
Dienstabdeckung will, installiert MeetingBar. Die App ist hervorragend, und
dieses Projekt hat als ihr Fan angefangen.

**Das eine, was sie nicht kann:** eine Warnung *pro Termin* statt pro Zeitfenster.
MeetingBar zeigt den laufenden oder nächsten Termin, und der Wunsch, gleichzeitig
laufende Termine anzuzeigen, ist
[seit Mai 2021 offen](https://github.com/leits/MeetingBar/issues/271): „Wenn zwei
Termine zur selben Zeit liegen, sehe ich in der Leiste nur, dass einer aktiv
ist." Dazu ein verwandter Fehler, bei dem die Vollbild-Mitteilung für den ersten
von zwei knapp aufeinanderfolgenden Terminen
[gar nicht erst kommt](https://github.com/leits/MeetingBar/issues/769).

Wer parallele oder verschachtelte Termine hat, einen Fokusblock mit einem Call
darin, zwei übereinander gebuchte Calls, ein Standup das in eine Übergabe
ragt, verpasst genau diesen zweiten Termin regelmäßig. MeetingBlitz schickt für
jeden ein eigenes Banner, und überschneidende stapeln sich in eigenen Bahnen,
statt sich gegenseitig zu ersetzen.

Der zweite Unterschied ist die Lautstärke. Eine Mitteilung wischt man weg, ohne
sie gelesen zu haben. Ein U-Boot, das über alle Monitore fliegt, nicht.

![Einstieg beim ersten Start und Einstellungen](docs/tour.png)

## Was sie kann

- **Banner vor jedem Termin**, gleichzeitig auf allen Monitoren, Vorlaufzeit einstellbar
- **Tagesübersicht** in der Menüleiste, mit Zeitachse, Wochen-/Monatswahl und jedem Tag einen Klick entfernt
- **Beitreten mit einem Klick** für 53 Dienste: Meet, Zoom, Teams, Webex, Whereby, Jitsi, Discord, Slack-Huddles, GoTo, Tencent und mehr
- **Termin in einer Zeile tippen**: `fr 16 uhr bis 17 uhr call mit chris`, mit Vorschau bevor etwas entsteht
- **Warnung vor Überschneidungen** beim Anlegen, *bevor* doppelt gebucht wird
- **Sofort-Meeting**: ein Klick erzeugt den Meet-Raum, legt den Termin an und öffnet den Call
- **Auswertung** für Woche, Monat und Jahr als Balkengrafik
- **Termin als .ics exportieren**, landet direkt als Datei in der Zwischenablage
- **Apple Erinnerungen**, die heute fällig sind, stehen mit in der Übersicht
- **Pro Kalender einstellbar**, was angezeigt wird, was ein Banner auslöst und ob Geburtstage mitkommen
- **Abgesagte Termine warnen nie** — sie bleiben durchgestrichen sichtbar
- **Ruhe-Modus**, befristet (1h / 5h / 1 Tag / 1 Woche) und automatisch bei Bildschirmfreigabe, mit stillem Hinweis statt gar nichts
- **Zwei globale Tastenkürzel**, beide umbelegbar: Widget öffnen, laufendem oder nächstem Call beitreten
- **Automation** über `meetingblitz://show`, `join-next`, `instant`, `create?text=…`
- **Zweite Zeitzone** im Widget, versteckt sich bei gleicher Zeit
- Komplett auf **Deutsch oder Englisch**, live umschaltbar

Optional, nur mit eigener Google-Cloud-Konfiguration: Termine mit fertigem
Google-Meet-Link direkt aus der App anlegen. Ohne diese Konfiguration ist die
Funktion einfach ausgeblendet, alles andere funktioniert normal.

## Voraussetzungen

- **macOS 14 (Sonoma) oder neuer**
- Apple Silicon oder Intel, die App wird als Universal Binary gebaut
- **Xcode Command Line Tools** zum Bauen (einmalig, siehe unten)

## Installation

### Möglichkeit A: fertige App laden

`MeetingBlitz.zip` aus dem [neuesten Release](https://github.com/Felixosk/meetingblitz-mac/releases/latest)
laden, entpacken und **MeetingBlitz.app** nach **Programme** ziehen.

Die App ist mit einem selbstgebauten Zertifikat signiert, nicht mit einem
bezahlten Apple-Entwicklerkonto. macOS stellt sie deshalb beim Download unter
Quarantäne. Ein Befehl hebt das auf:

```bash
xattr -dr com.apple.quarantine /Applications/MeetingBlitz.app
```

Danach startet sie normal. **Was der Befehl tut, sollte klar sein:** Du sagst
macOS damit, dass du selbst für diese App bürgst, und überspringst die
Gatekeeper-Prüfung. Führe ihn nur bei Software aus, der du wirklich traust —
hier kannst du vorher jede Zeile Quelltext lesen, oder gleich Möglichkeit B
nehmen.

Ohne den Befehl geht es auch umständlich: doppelklicken, im Hinweis auf
**Fertig**, dann **Systemeinstellungen → Datenschutz & Sicherheit → Trotzdem
öffnen**, und noch einmal bestätigen.

### Möglichkeit B: selbst bauen

Zwei Minuten, und gar kein Gatekeeper-Tanz: selbst kompilierte Software wird
nicht unter Quarantäne gestellt.

```bash
git clone https://github.com/Felixosk/meetingblitz-mac.git
cd meetingblitz-mac
```

Falls die Command Line Tools fehlen, installiert dieser Befehl sie (ein paar
hundert MB, einmalig):

```bash
xcode-select --install
```

Dann bauen und starten:

```bash
./build.sh && open dist/MeetingBlitz.app
```

Beim ersten Start führt dich ein kurzer Einstieg durch Kalenderfreigabe,
Kalenderauswahl und Autostart. Du kannst ihn jederzeit über
**Einstellungen → Allgemein → Einführung → Nochmal zeigen** wiederholen.

### Falls du eine fertig gebaute App bekommen hast

Dann greift Gatekeeper, weil die App nicht von einem bezahlten
Apple-Entwicklerkonto signiert ist. Der Weg auf aktuellen macOS-Versionen:

1. App nach **Programme** ziehen, und zwar **vor** dem ersten Start. Sonst läuft
   sie aus einem temporären Nur-Lese-Ordner und "Beim Login starten" funktioniert
   nicht zuverlässig.
2. Doppelklick. Im Dialog "Apple konnte nicht überprüfen…" auf **Fertig** klicken.
   Niemals "In den Papierkorb legen".
3.  → **Systemeinstellungen** → **Datenschutz & Sicherheit**, dort ganz nach
   unten zum Abschnitt **Sicherheit**. Da steht jetzt "MeetingBlitz wurde
   blockiert" mit dem Knopf **Trotzdem öffnen**.
4. Nochmal doppelklicken und im letzten Dialog **Öffnen** bestätigen.

**Schritt 3 muss zeitnah nach Schritt 2 passieren**, sonst verschwindet der Knopf
und du fängst bei Schritt 2 an. Danach ist die App dauerhaft freigeschaltet.

Der früher übliche Rechtsklick → Öffnen funktioniert seit macOS 15 **nicht mehr**
und führt in denselben Blockier-Dialog.

Nur falls tatsächlich "beschädigt und kann nicht geöffnet werden" erscheint:

```bash
xattr -cr "/Applications/MeetingBlitz.app"
```

### Wichtig zu wissen

**Diese App hat kein Fenster und kein Dock-Symbol.** Sie lebt oben rechts in der
Menüleiste. Wenn nach dem Start scheinbar nichts passiert, ist das kein Fehler:
Such das U-Boot in der Menüleiste und klick es an.

## Berechtigungen und Datenschutz

Die App fragt beim ersten Start nach **Kalenderzugriff**, optional nach
**Erinnerungen**. Beides bleibt lokal auf deinem Mac. Es gibt keinen Server,
keine Telemetrie und keinen Account. Der Quellcode liegt hier vollständig offen.

Der Google-Teil ist optional und kommt nur zum Zug, wenn du selbst eine
OAuth-Konfiguration hinterlegst. Im Repository sind keine Zugangsdaten enthalten.

## Wenn etwas klemmt

**Das Menüleisten-Icon ist nicht da.** Der häufigste Grund ist banal und kostet
sonst Stunden: In der Menüleiste rechts vom Notch ist der Platz begrenzt (auf
einem MacBook rund 790 Punkte für alle Apps zusammen). Ist er voll, wirft macOS
Icons **kommentarlos** raus, ohne Fehlermeldung. Abhilfe: andere Menüleisten-Apps
beenden, oder das Fenster einfach per **⌃⌥M** öffnen.

**Die App sieht keine Termine.** Systemeinstellungen → Datenschutz & Sicherheit →
Kalender → MeetingBlitz einschalten. Achtung, macOS kennt dort auch die Stufe
"nur hinzufügen": Damit darf die App zwar schreiben, sieht aber nichts. Es muss
der volle Zugriff sein.

**Statusbericht erzeugen.** Rechtsklick auf das Menüleisten-Icon →
"Diagnose speichern". Der Bericht landet in `~/Downloads` und nennt Version,
Berechtigungen, Bildschirme und Fensterpositionen im Klartext. Er enthält deine
Kalendernamen, schau also kurz drüber, bevor du ihn weitergibst.

## Mit Claude Code

Wenn du Claude Code nutzt: Im Repository liegt eine `CLAUDE.md` mit Architektur,
Bau-Anleitung und den Stolperfallen, in die man bei dieser App reinläuft. Öffne
Claude Code einfach in diesem Ordner und sag, was klemmt.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
