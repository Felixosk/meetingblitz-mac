#!/bin/bash
set -euo pipefail

# Builds MeetingBlitz.app: compiles the Swift package, assembles a proper
# .app bundle with Info.plist (calendar permission, no dock icon), and
# ad-hoc code signs it so macOS remembers the calendar grant.

cd "$(dirname "$0")"

APP_NAME="MeetingBlitz"
BUNDLE_ID="app.meetingblitz.MeetingBlitz"
DIST="dist"
APP="$DIST/$APP_NAME.app"

# ---------------------------------------------------------------------------
# Lint: Hinweistexte muessen umbrechen duerfen (23.08.2026).
#
# In diesen selbstvermessenden Panels bekommt ein `Text` ohne
# `.fixedSize(horizontal: false, vertical: true)` seine EINZEILIGE Wunschbreite
# vorgeschlagen und wird bei 300pt Panelbreite hinten abgeschnitten, statt
# umzubrechen. Das faellt im Code nicht auf und im Screenshot erst, wenn man
# genau hinsieht: gemeldet wurde „der Text ist da abgeschnitten" fuer eine
# Erklaerung, die seit Runde 72 stumm gekuerzt war.
# ---------------------------------------------------------------------------
echo "==> Hinweistexte pruefen (Umbruch statt Abschneiden)"
python3 - "$@" <<'LINT' || exit 1
import re, sys, glob
bad = []
for path in glob.glob("Sources/MeetingBlitz/*.swift"):
    lines = open(path).read().split("\n")
    for i, line in enumerate(lines):
        if "foregroundStyle(.secondary)" not in line:
            continue
        if not ("size: 10" in line or "size: 11" in line or "size: 10" in lines[i-1]):
            continue
        # Text-Literal davor einsammeln (bis zu 3 Zeilen zurueck)
        # Nur echte Beschriftungen zaehlen: Kommentarzeilen (dort steht die
        # Begruendung, oft mit Zitaten) und SF-Symbolnamen sind kein Fliesstext.
        block_lines = [l for l in lines[max(0, i-3):i+1]
                       if not l.strip().startswith("//") and "systemName" not in l]
        block = "\n".join(block_lines)
        literals = re.findall(r'"([^"]{2,})"', block)
        # Eingesetzte Werte (\(...)) sind zur Bauzeit unbekannt lang und meist
        # einzeilige Kopfzeilen wie „Berlin 19:52" — die sollen NICHT umbrechen.
        literals = [t for t in literals if "\\(" not in t]
        longest = max((len(t) for t in literals), default=0)
        if longest < 45:            # kurze Beschriftungen brechen nie
            continue
        window = "\n".join(lines[i:i+3])
        if "fixedSize" in window or "lineLimit" in window:
            continue
        bad.append(f"{path}:{i+1}  {literals[0][:60]}...")
if bad:
    print("!! ABBRUCH: Hinweistexte ohne Umbruch, sie werden abgeschnitten:")
    for b in bad:
        print("   " + b)
    print("   Fix: .fixedSize(horizontal: false, vertical: true) hinter den Text haengen.")
    sys.exit(1)
print("    alle langen Hinweistexte duerfen umbrechen")
LINT

echo "==> Compiling ($APP_NAME, universal arm64 + x86_64)"
# Universal Binary, damit die App auch auf aelteren Intel-Macs laeuft.
# Command Line Tools can't do multi-arch in one go (needs Xcode's xcbuild),
# so: build each arch separately, then merge with lipo.
swift build -c release --arch arm64
swift build -c release --arch x86_64
BIN=".build/universal-$APP_NAME"
lipo -create ".build/arm64-apple-macosx/release/$APP_NAME" \
             ".build/x86_64-apple-macosx/release/$APP_NAME" \
     -output "$BIN"
echo "==> Architectures: $(lipo -archs "$BIN")"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp design/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 27 Skin-Motive x 2 Stile (verspielt/fotoreal), SVGs als Bundle-Resource fuer
# das auswaehlbare Flugobjekt im Banner (Skins.swift laedt sie per NSImage).
cp -R Resources/Skins "$APP/Contents/Resources/Skins"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>     <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.6.1</string>
    <key>CFBundleVersion</key>         <string>10</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>LSUIElement</key>             <true/>
    <key>CFBundleURLTypes</key>
    <array>
      <dict>
        <key>CFBundleURLName</key>    <string>$BUNDLE_ID</string>
        <key>CFBundleURLSchemes</key> <array><string>meetingblitz</string></array>
      </dict>
    </array>
    <key>NSCalendarsUsageDescription</key>
    <string>MeetingBlitz liest deinen Kalender, um dich rechtzeitig vor Meetings zu warnen.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>MeetingBlitz liest deinen Kalender, um dich rechtzeitig vor Meetings zu warnen.</string>
    <key>NSRemindersUsageDescription</key>
    <string>MeetingBlitz zeigt deine fälligen Erinnerungen neben den Terminen an.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>MeetingBlitz zeigt deine fälligen Erinnerungen neben den Terminen an.</string>
</dict>
</plist>
PLIST

echo "==> Code signing"
# Signieren mit dem stabilen selbstsignierten Zertifikat, falls vorhanden.
# WARUM: Ad-hoc-Signaturen ("--sign -") aendern die Identitaet der App bei JEDEM
# Build. macOS haelt sie dann fuer eine andere App und wirft alle erteilten
# Berechtigungen weg (Kalender, Mikrofon, Bildschirmaufnahme) -- man erlaubt es
# neu, baut einmal, und es ist wieder kaputt. Mit einem festen Zertifikat lautet
# die Designated Requirement "identifier + certificate leaf" und bleibt ueber
# Rebuilds gleich, damit bleiben auch die Freigaben erhalten.
# Fallback auf ad-hoc, damit fremde Rechner ohne dieses Zertifikat bauen koennen.
#
# Die Zertifikatsdaten stehen NICHT hier, sondern in einer lokalen, nicht
# versionierten Datei signing.local (Vorlage: signing.local.example):
#     SIGN_ID="Mein Dev Signing"
#     SIGN_SHA1="<Fingerabdruck>"
# Ohne diese Datei signiert das Skript ad-hoc, das genuegt zum Ausprobieren.
[ -f "signing.local" ] && . ./signing.local
SIGN_ID="${SIGN_ID:-}"
# Fingerabdruck mitpruefen, nicht nur den Namen. Lagen im Schluesselbund einmal
# ZWEI gleichnamige Zertifikate, aenderte sich die Designated Requirement und
# alle Berechtigungen waren still kaputt, obwohl in den Systemeinstellungen der
# Haken stand.
SIGN_SHA1="${SIGN_SHA1:-}"
FOUND_SHA1=""
if [ -n "$SIGN_ID" ]; then
    FOUND_SHA1=$(security find-certificate -c "$SIGN_ID" -Z 2>/dev/null | awk '/SHA-1 hash:/ {print $3; exit}')
fi
if [ -n "$FOUND_SHA1" ] && [ -n "$SIGN_SHA1" ] && [ "$FOUND_SHA1" != "$SIGN_SHA1" ]; then
    echo "    FEHLER: Zertifikat '$SIGN_ID' hat den falschen Fingerabdruck."
    echo "            erwartet: $SIGN_SHA1"
    echo "            gefunden: $FOUND_SHA1"
    echo "            Ein zweites gleichnamiges Zertifikat wuerde alle App-"
    echo "            Berechtigungen unbrauchbar machen. Pruefe den"
    echo "            Schluesselbund auf Duplikate."
    exit 1
fi
if [ -n "$FOUND_SHA1" ]; then
    codesign --force --deep --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
else
    echo "    (ad-hoc signiert. Fuer stabile Berechtigungen siehe signing.local.example)"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || \
        codesign --force --sign - "$APP"
fi

# F7: Selbsttest der Link-Erkennung. Ersetzt ein Test-Target, denn XCTest
# gehoert zu Xcode und nicht zu den Command Line Tools (geprueft 18.08.2026:
# "no such module 'XCTest'"). Laeuft vor dem Einzelinstanz-Schutz, sonst wuerde
# er sich neben der laufenden App beenden und faelschlich Erfolg melden.
echo "==> Selbsttest"
if ! "$APP/Contents/MacOS/MeetingBlitz" --selftest; then
    echo "    ABGEBROCHEN: Link-Erkennung ist kaputt (siehe oben)."
    exit 1
fi

echo "==> Done: $APP"
echo "    Starten:      open \"$PWD/$APP\""
echo "    Installieren: cp -R \"$PWD/$APP\" /Applications/"
