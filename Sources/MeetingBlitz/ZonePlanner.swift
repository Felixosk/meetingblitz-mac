import SwiftUI
import AppKit

/// Deckel für die Zonenliste (Runde 87). Der Controller des Termin-Fensters
/// setzt `cap` aus der echten Fensterhöhe, der Planer meldet die zuletzt
/// gezeichnete Listenhöhe zurück (ohne Neuzeichnen auszulösen).
@MainActor
final class ZoneListFit: ObservableObject {
    static let shared = ZoneListFit()
    @Published var cap: CGFloat = .greatestFiniteMagnitude
    var listHeight: CGFloat = 0
    /// Runde 110: Deckel für die Kalenderliste (scrollt erst, wenn das Fenster sonst höher als der Bildschirm würde).
    @Published var calCap: CGFloat = .greatestFiniteMagnitude
    /// Natürliche Höhe der Kalenderliste, 0 = zu.
    var calNatural: CGFloat = 0
    func reset() { cap = .greatestFiniteMagnitude; listHeight = 0; calCap = .greatestFiniteMagnitude; calNatural = 0 }
}

/// Zeitzonen-Abschnitt im Termin-Fenster (Runde 86/87). Aufklappbar, zugeklappt
/// eine Zeile („11:00 Nicosia · 17:00 Manila"). Offen: eine Zeile pro Zone mit
/// Schieber über den Tag DIESER Zone. Bindet direkt an den Terminbeginn des
/// Formulars, deshalb laufen Schieber, Monatsraster und Uhrzeit-Feld
/// automatisch in beide Richtungen mit.
///
/// Höhe: die Zonenliste steht in einer FESTEN Höhe (Runde-14-Lektion:
/// ScrollView braucht eine feste Höhe, sonst fällt sie auf 0). Höchstens 4,5
/// Zeilen, beim Suchen 3,5, und nie mehr als `listCap`: den rechnet das
/// Termin-Fenster aus der Bildschirmhöhe aus (13-Zoll-MacBook ≈ 900 pt).
struct ZonePlanner: View {
    @Binding var start: Date
    let minutes: Int
    var listCap: CGFloat = .greatestFiniteMagnitude
    @ObservedObject var book = ZoneBook.shared
    // Runde 110: @State (AppStorage animiert nicht, siehe CreatePanel); gespeichert per onChange.
    @State private var open = UserDefaults.standard.bool(forKey: "zonePlanner.open")
    /// Nur damit die Ansicht bei einem Wechsel der Einladungssprache neu
    /// zeichnet (12 h / 24 h folgt ihr).
    @AppStorage("inviteLanguage") private var inviteLanguage = "en"

    @State private var adding = false
    @State private var query = ""
    @State private var hovered: String?
    @State private var hoverClear: DispatchWorkItem?
    @State private var renaming: String?
    @State private var renameText = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool

    static let rowHeight: CGFloat = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // Runde 110: ThemeFold (bleibt im Baum). Beschnitten wird nur der Inhalt, NICHT die
            // Kopfzeile (deren Hover-Fläche ragt 8 pt über die Spalte).
            ThemeFold(isOpen: open, gap: Theme.s8) {
                VStack(alignment: .leading, spacing: Theme.s8) { content }
            }
        }
        .onChange(of: open) { _, v in UserDefaults.standard.set(v, forKey: "zonePlanner.open") }
        .onReceive(NotificationCenter.default.publisher(for: ZonePlanner.demoCommand)) { n in
            if let cmd = n.object as? String { runDemo(cmd) }
        }
    }

    /// Testschalter `--demo-create` (Runde 86): steuert den Abschnitt über
    /// dieselben Wege wie Klick und Schieber, damit Bildschirmfotos ohne
    /// Maus entstehen. Im normalen Betrieb sendet niemand diese Meldung.
    static let demoCommand = Notification.Name("ZonePlannerDemoCommand")

    private func runDemo(_ cmd: String) {
        let parts = cmd.split(separator: " ").map(String.init)
        switch parts.first {
        case "open": open = true
        case "close": open = false; adding = false; query = ""
        case "start" where parts.count == 2:
            if let off = Double(parts[1]) { start = Self.nextQuarterHour().addingTimeInterval(off * 3600) }
        case "drag" where parts.count == 3:
            if let tz = TimeZone(identifier: parts[1]), let m = Int(parts[2]) {
                start = ZoneMath.move(start, toLocalMinutes: m, in: tz)
            }
        case "search": adding = true; query = parts.dropFirst().joined(separator: " ")
        case "add" where parts.count == 2: book.add(parts[1]); adding = false; query = ""
        case "remove" where parts.count == 2: book.remove(parts[1])
        case "tick" where parts.count == 3: book.setOn(parts[1], parts[2] == "on")
        case "rename" where parts.count >= 2:
            renaming = parts[1]; renameText = parts.dropFirst(2).joined(separator: " ")
        case "renamedone": commitRename()
        default: break
        }
    }

    // MARK: Kopf

    private var header: some View {
        ThemeDisclosureRow(title: L.t("Zeitzonen", "Time zones"), value: summary, isOpen: open) {
            withAnimation(Theme.fold) { open.toggle() }
            if !open { adding = false; query = ""; renaming = nil }
        }
        .help(summaryItems.joined(separator: "\n"))
    }

    /// Alle angehakten Städte zur gewählten Zeit (ohne die eigene Zone).
    private var summaryItems: [String] {
        book.saved.filter(\.on).compactMap { z in
            TimeZone(identifier: z.id).map { "\(book.name(z.id)) \(Self.uiHM(start, $0))" }
        }
    }

    /// Zugeklappt: "Berlin 08:45 · Manila 15:45"; bei mehr als zwei Städten
    /// "Berlin 08:45 · Manila 15:45 · +2" (alle stehen im Tooltip).
    private var summary: String {
        let list = summaryItems
        if list.isEmpty { return L.t("nur deine Zeitzone", "Only your time zone") }
        if list.count <= 2 { return list.joined(separator: " · ") }
        return list.prefix(2).joined(separator: " · ") + " · +\(list.count - 2)"
    }

    // MARK: Inhalt

    @ViewBuilder private var content: some View {
        HStack(spacing: Theme.s8) {
            ThemeTextRow(title: L.t("Jetzt", "Now"), icon: "arrow.counterclockwise", accent: true, fullWidth: false, compact: true) {
                start = Self.nextQuarterHour()
            }
            // Runde 99: „+ Zone" ist ein eigener Knopf in der offenen Fläche
            // (hier kommen auch die abgehakten Städte zurück), nicht in der Kopfzeile.
            ThemeTextRow(title: "+ " + L.t("Zone", "Zone"), accent: true, fullWidth: false, compact: true) {
                adding.toggle(); if !adding { query = "" }
            }
            Spacer()
        }
        .themeRowList()

        // Runde 90: nur die eigene Zone und die angehakten sind sichtbar. Die
        // anderen stehen in der „+ Zone"-Liste, Haken setzen holt sie zurück.
        let rows = book.rows.filter { $0.on || book.isOwn($0.id) }
        let ideal = min(CGFloat(rows.count), adding ? 3 : 4) * Self.rowHeight
        // Runde 92: greift der Deckel, nur GANZE Zeilen zeigen (keine halbe
        // Zeile ohne Schieber); die halbe Zeile als Scroll-Hinweis gibt es nur
        // ohne Deckel.
        let listH: CGFloat = {
            guard listCap < ideal else { return ideal }
            let capRows = max(1, (listCap / Self.rowHeight).rounded(.down))
            return min(ideal, capRows * Self.rowHeight)
        }()
        ScrollView {
            VStack(spacing: 0) {
                ForEach(rows) { z in row(z) }
            }
        }
        .scrollIndicators(.visible)
        .frame(height: listH)
        // Runde 100: kein Fade-Rand mehr; wenn die Liste scrollt, endet sie mit einer dünnen Linie.
        .overlay(alignment: .bottom) {
            if listH < CGFloat(rows.count) * Self.rowHeight - 1 {
                Rectangle().fill(Theme.line).frame(height: 1).allowsHitTesting(false)
            }
        }
        .onAppear { ZoneListFit.shared.listHeight = open ? listH : 0 }
        .onChange(of: listH) { _, h in ZoneListFit.shared.listHeight = open ? h : 0 }
        .onChange(of: open) { _, o in ZoneListFit.shared.listHeight = o ? listH : 0 }
        .onDisappear { ZoneListFit.shared.listHeight = 0 }

        addZone
    }

    // MARK: Zeile

    private func row(_ z: SavedZone) -> some View {
        let tz = TimeZone(identifier: z.id) ?? .current
        let own = book.isOwn(z.id)
        let name = book.name(z.id)
        // Runde 90 (Savvy): Name links, Uhrzeit rechts groß, EINE Infozeile
        // (UTC, „x h vor", Tag), darunter der Schieber.
        let info = "\(ZoneNames.flag(z.id)) \(ZoneNames.utcLabel(tz, at: start))"
            + (own ? "" : " · \(ZoneNames.relativeLabel(tz, own: .current, at: start))")
            + " · \(Self.dayLabel(start, tz))"
        return VStack(alignment: .leading, spacing: Theme.s4) {
            HStack(alignment: .center, spacing: Theme.s8) {
                // Immer 16 pt Platz links (Haken oder leer beim eigenen Ort), damit
                // alle Namen und Infozeilen untereinander stehen.
                if own {
                    Image(systemName: "location.fill")
                        .font(.theme(.small)).foregroundStyle(Theme.muted)
                        .frame(width: Theme.s16, height: Theme.s16)
                        .help(L.t("Deine Zeitzone", "Your time zone"))
                } else {
                    Toggle("", isOn: Binding(get: { z.on }, set: { book.setOn(z.id, $0) }))
                        .toggleStyle(ThemeCheckStyle()).labelsHidden()
                }
                if renaming == z.id {
                    // Runde 120: Feld so hoch wie die Zeile (28), mittig, 10-pt-Ecken rundum,
                    // ✓ bestätigt (Enter), ✕ bricht ab (Esc).
                    HStack(spacing: Theme.s4) {
                        TextField(ZoneNames.name(z.id), text: $renameText)
                            .textFieldStyle(.plain)
                            .font(.theme(.normal))
                            .focused($renameFocused)
                            .onSubmit(commitRename)
                            .onExitCommand { renaming = nil }
                            .onAppear { renameFocused = true }
                        Button(action: commitRename) {
                            Image(systemName: "checkmark").font(.theme(.small, .bold))
                                .foregroundStyle(Theme.blue)
                                .frame(width: 22, height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel(L.t("Bestätigen", "Confirm"))
                        .help(L.t("Bestätigen (Enter)", "Confirm (Return)"))
                        Button { renaming = nil } label: {
                            Image(systemName: "xmark").font(.theme(.small, .semibold))
                                .foregroundStyle(Theme.muted)
                                .frame(width: 22, height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel(L.t("Abbrechen", "Cancel"))
                        .help(L.t("Abbrechen (Esc)", "Cancel (Esc)"))
                    }
                    .padding(.leading, Theme.s8).padding(.trailing, Theme.s4)
                    .frame(height: Theme.iconButtonSize)
                    .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
                    .frame(maxWidth: Theme.formWidth / 2)
                } else {
                    Text(name).font(.theme(.normal, .semibold)).lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture { renaming = z.id; renameText = name }
                        .help(L.t("Klicken: eigenen Namen geben", "Click to rename"))
                }
                if own {
                    Text(L.t("du", "you"))
                        .font(.theme(.small, .semibold)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, Theme.s4)
                        .background(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous).fill(Theme.fill))
                }
                if renaming != z.id {
                    // Fester Platz, nur beim Überfahren sichtbar (Geometrie ändert sich nie).
                    ThemeIconButton(systemName: "pencil") { renaming = z.id; renameText = name }
                        .opacity(hovered == z.id ? 1 : 0)
                        .animation(nil, value: hovered)
                        .help(L.t("Eigenen Namen geben", "Rename"))
                }
                Spacer(minLength: Theme.s4)
                Text(Self.uiHM(start, tz)).font(.theme(.normal, .semibold).monospacedDigit())
                    .lineLimit(1)
            }
            // Infozeile. Runde 101: kein ✕ mehr, Entfernen nur im Rechtsklick-Menü.
            HStack(spacing: Theme.s8) {
                Text(info)
                    .font(.theme(.small)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, Theme.s24)
            DaySlider(value: ZoneMath.localMinutes(start, in: tz), name: name,
                      timeText: Self.uiHM(start, tz)) { target in
                start = ZoneMath.move(start, toLocalMinutes: target, in: tz)
            }
            .frame(height: Theme.sliderHeight)
            .drawingGroup()
        }
        .padding(.vertical, Theme.s4)
        .frame(height: Self.rowHeight)
        .contextMenu {
            Button(L.t("Umbenennen", "Rename")) { renaming = z.id; renameText = name }
            if !own { Button(L.t("Entfernen", "Remove"), role: .destructive) { book.remove(z.id) } }
        }
        // Runde 120: Hover = die ganze Zeile (auch Stift, Schieber). Fortlaufend gemeldet, und das
        // Ausblenden kommt verzögert, damit ein kurzes Verlieren (Stift/Schieber) nichts flackern lässt.
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active: hoverClear?.cancel(); hoverClear = nil; if hovered != z.id { hovered = z.id }
            case .ended:
                hoverClear?.cancel()
                let w = DispatchWorkItem { if hovered == z.id { hovered = nil } }
                hoverClear = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
            }
        }
        .overlay(alignment: .bottom) { ThemeDivider() }
    }

    private func commitRename() {
        if let id = renaming { book.rename(id, to: renameText) }
        renaming = nil
    }

    // MARK: Zone hinzufügen

    @ViewBuilder private var addZone: some View {
        if adding {
            VStack(alignment: .leading, spacing: Theme.s4) {
                TextField(L.t("Stadt oder Zone, z. B. Dubai, EST", "City or zone, e.g. Dubai, EST"), text: $query)
                    .textFieldStyle(ThemeFieldStyle())
                    .focused($searchFocused)
                    .onExitCommand { adding = false; query = "" }
                    .onSubmit {
                        if let first = hits.first { book.add(first); adding = false; query = "" }
                    }
                let found = self.hits
                ScrollView {
                    VStack(spacing: 0) {
                        if found.isEmpty {
                            Text(L.t("Nichts gefunden", "Nothing found"))
                                .font(.theme(.small)).foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.s8)
                        }
                        ForEach(found, id: \.self) { id in
                            let tz = TimeZone(identifier: id) ?? .current
                            ThemeTextRow(title: "\(ZoneNames.flag(id)) \(ZoneNames.name(id))",
                                         trailing: "\(Self.uiHM(start, tz)) · \(ZoneNames.utcLabel(tz, at: start))") {
                                book.add(id); adding = false; query = ""
                            }
                        }
                    }
                }
                .frame(height: CGFloat(min(max(found.count, 1), 5)) * 22 + 4)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
                ThemeTextRow(title: L.t("Abbrechen", "Cancel")) { adding = false; query = "" }
                    .themeRowList()
            }
            .onAppear { searchFocused = true }
        }
    }

    /// Treffer der „+ Zone"-Liste: erst die gespeicherten, aber nicht angehakten
    /// Städte (die Auswahl), dann die Suche über alle Zonen.
    private var hits: [String] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let hidden = book.saved.filter { !$0.on && !book.isOwn($0.id) }.map(\.id).filter { id in
            q.isEmpty || book.name(id).lowercased().contains(q) || id.lowercased().contains(q)
        }
        let shown = Set(book.rows.filter { $0.on || book.isOwn($0.id) }.map { ZoneNames.canonical($0.id) })
        let more = ZoneNames.search(query, excluding: shown.union(hidden.map(ZoneNames.canonical)), limit: 12)
        return hidden + more
    }

    // MARK: Formatierung

    /// Uhrzeit in der Zone. 24 h oder 12 h nach der EINLADUNGSSPRACHE, damit
    /// Planer und verschickter Text dieselbe Schreibweise zeigen (Runde 87).
    static func hm(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.timeZone = tz
        f.locale = L.inviteLocale
        f.dateFormat = L.inviteIsDE ? "HH:mm" : "h:mm a"
        return f.string(from: d)
    }

    /// Uhrzeit für die ANZEIGE: Sprache der App und 12/24 h des Systems
    /// (Runde 92). `hm` bleibt nur für den Einladungstext und dessen Vorschau.
    static func uiHM(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.locale = L.locale
        f.dateFormat = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: L.locale) ?? "HH:mm"
        return f.string(from: d)
    }

    private static func dayLabel(_ d: Date, _ tz: TimeZone) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.locale = L.locale
        f.dateFormat = L.t("EE d. MMM", "EE, MMM d")
        return f.string(from: d)
    }

    static func nextQuarterHour() -> Date {
        Date(timeIntervalSinceReferenceDate: ceil(Date().timeIntervalSinceReferenceDate / 900) * 900)
    }
}

/// Schieber über einen Ortstag (0–24 Uhr) im Stil der Zeitzonen-Planer:
/// Nacht blau, Tag gelb, Arbeitszeit 9–18 hell. Rastet auf 15 Minuten.
/// Mit Tastatur/VoiceOver: ±15 Minuten pro Schritt (Runde 87).
private struct DaySlider: View {
    let value: Int                 // Minuten seit Mitternacht, Ortszeit
    let name: String
    let timeText: String
    let onChange: (Int) -> Void


    var body: some View {
        GeometryReader { g in
            let thumb: CGFloat = Theme.knobSize
            let usable = max(1, g.size.width - thumb)
            let x = CGFloat(value) / 1440 * usable
            ZStack(alignment: .topLeading) {
                Capsule().fill(Theme.dayNight).frame(height: Theme.trackHeight)
                    .padding(.horizontal, thumb / 2).offset(y: Theme.s4)
                // Ticks 6 / 12 / 18 unter dem Balken (Runde 90, wie Savvy).
                ForEach([6, 12, 18], id: \.self) { h in
                    Text("\(h)").font(.theme(.small)).foregroundStyle(Theme.muted)
                        .position(x: thumb / 2 + usable * CGFloat(h) / 24, y: Theme.s16 + Theme.s4)
                }
                // Normaler weißer runder Knopf, keine Schiffchen.
                Circle()
                    .fill(Theme.knob)
                    .shadow(color: Theme.shadow, radius: 2, y: 1)
                    .frame(width: thumb, height: thumb)
                    .offset(x: x, y: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let frac = min(max((v.location.x - thumb / 2) / usable, 0), 1)
                let slot = min(95, Int((frac * 96).rounded()))
                if slot * 15 != value { onChange(slot * 15) }
            })
        }
        .accessibilityElement()
        .accessibilityLabel(L.t("Uhrzeit in \(name)", "Time in \(name)"))
        .accessibilityValue(timeText)
        .accessibilityAdjustableAction { dir in
            let step = (value / 15) * 15
            switch dir {
            case .increment: onChange(min(step + 15, 1425))
            case .decrement: onChange(max(value % 15 == 0 ? step - 15 : step, 0))
            @unknown default: break
            }
        }
    }
}

extension AppState {
    /// Zustand vor `--demo-create`, damit der Testlauf nichts hinterlässt,
    /// auch wenn er vorzeitig endet (Runde 87: vorher nur am Drehbuchende).
    nonisolated(unsafe) private static var demoSnapshot: (open: Any?, zones: Any?, invite: Any?, lang: Any?, extra: [String: Any?])?

    /// Einmal beim Start des Testschalters aufrufen.
    static func snapshotDemoSettings() {
        let d = UserDefaults.standard
        demoSnapshot = (d.object(forKey: "zonePlanner.open"), d.object(forKey: ZoneBook.key),
                        d.object(forKey: "inviteLanguage"), d.object(forKey: "appLanguage"),
                        Dictionary(uniqueKeysWithValues: ["create.monthOpen", "create.moreOpen", "create.lastRepeat", "mailInviteEnabled", "copyInviteOnCreate", "createICSFile", "mailAttachICS", "mailSubjectEN", "mailSubjectDE", "mailBodyEN", "mailBodyDE", "inviteTextEN", "inviteTextDE", "settingsTab", "settingsTabMigrated", "settingsScrollTo", "panelTopLeft_create", "panelTopLeft_settings", "panelTopLeftV2_create", "panelTopLeftV2_settings", "formCalendarID"].map { ($0, d.object(forKey: $0)) }))
    }

    /// Stellt den Zustand von vorher wieder her. Mehrfach aufrufbar.
    nonisolated static func restoreDemoSettings() {
        guard let s = demoSnapshot else { return }
        let d = UserDefaults.standard
        func put(_ v: Any?, _ k: String) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
        put(s.open, "zonePlanner.open"); put(s.zones, ZoneBook.key); put(s.invite, "inviteLanguage"); put(s.lang, "appLanguage")
        for (k, v) in s.extra { put(v, k) }
        d.synchronize()
    }

    /// Drehbuch für `--demo-create <ordner>` (Runde 86). Jeder Schritt geht
    /// über `ZonePlanner.runDemo` bzw. `CreatePane`, danach ein Foto des
    /// Termin-Fensters per `screencapture -l`. Legt KEINEN Termin an,
    /// stellt die Einstellungen wieder her und beendet sich.
    static func runCreateDemo(outDir: String, prefix: String) {
        let steps96: [(String?, String?)] = [
            ("tick Asia/Manila on", nil), ("tick Europe/Berlin on", nil),
            ("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("close", "02_standard"),
            ("create:quick fr 10-12 call mit chris", "03_tippen_aktiv"), ("create:quickclear", nil),
            ("create:timeedit", "04_uhrzeit_bearbeiten"), ("create:timecancel", nil),
            ("create:month on", "05_monat_offen"),
            ("open", nil), ("create:more on", nil), ("create:invite on", "02b_alles_offen"),
        ]
        let steps97: [(String?, String?)] = [
            ("tick Asia/Manila on", nil), ("tick Europe/Berlin on", nil),
            ("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("close", "02_standard"),
            ("create:more on", nil), ("create:invite on", "03_mehr_offen"),
        ]
        let steps99: [(String?, String?)] = [
            ("tick Asia/Manila on", nil), ("tick Europe/Berlin on", nil),
            ("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("close", "04_zonen_zu"),
            ("open", "05_zonen_offen"), ("search dub", "06_zone_hinzufuegen"),
        ]
        let steps100: [(String?, String?)] = [
            ("tick Asia/Manila on", nil), ("tick Europe/Berlin on", nil),
            ("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("close", "02_termin_zu"),
            ("create:quick fr 10-12 call mit chris", "03_tippfeld_offen"), ("create:quickclear", nil),
            ("open", "04_zonen_offen"),
        ]
        // Runde 108: Höhe beim Uhrzeit-Schieben über einen belegten Termin.
        let steps108: [(String?, String?)] = [
            ("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("close", nil),
            ("create:settime 13:00", "01_frei"), ("create:settime 15:00", "02_belegt"),
            ("create:settime 15:30", "03_belegt"), ("create:settime 17:00", "04_frei"),
            ("create:more on", "05_mehr_auf"), ("create:invite on", "06_einladung_auf"),
            ("create:month on", "07_monat_auf"), ("open", "08_zonen_auf"),
            ("create:calendar on", "08b_kalender_auf"),
            ("close", nil), ("create:calendar off", nil), ("create:month off", nil), ("create:invite off", nil), ("create:more off", "09_alles_zu"),
        ]
        // Runde 109: Klappen messen (Schritt 1). Jede Klappe auf und zu.
        let steps109d: [(String?, String?)] = [
            ("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("create:calendar off", nil), ("close", nil),
            ("lang en", nil), ("create:settime 13:00", nil),
            ("create:duration 15", "d15"), ("create:duration 30", "d30"), ("create:duration 45", "d45"),
            ("create:duration 60", "d60"), ("create:duration 90", "d90"), ("create:duration 20", "d20_freitext"),
            ("lang de", nil), ("create:duration 45", "d45_de"),
        ]
        let steps109m: [(String?, String?)] = [
            ("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("create:calendar off", nil), ("close", nil),
            ("lang en", nil), ("create:settime 13:00", "m0_vorher"),
        ] + Array(repeating: (Optional("create:settime 13:00"), Optional<String>.none), count: 7) + [("create:settime 13:00", "m1_nachher")]
        // Runde 109: Reihenfolge, „Danach“, Belegt, Dauer. DE und EN.
        let steps109: [(String?, String?)] = [
            ("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("create:calendar off", nil), ("close", nil),
            ("lang en", nil),
            ("create:settime 13:00", "01_en_zu"), ("create:settime 15:00", "02_en_belegt"),
            ("create:settime 17:00", "03_en_frei_danach"), ("create:settime 23:30", "04_en_rest_frei"),
            ("lang de", nil), ("create:settime 13:00", "05_de_zu"), ("create:settime 15:00", "06_de_belegt"),
            ("create:settime 23:30", "07_de_rest_frei"),
            ("create:settime 13:00", nil), ("open", nil), ("create:month on", nil), ("create:more on", nil), ("create:invite on", nil), ("create:calendar on", "08_de_alles_offen"),
            ("lang en", "09_en_alles_offen"),
        ]
        let steps109g: [(String?, String?)] = [
            ("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("create:calendar off", nil), ("close", nil),
            ("lang en", nil), ("create:mail on", nil), ("create:settime 13:00", "g01_en_leer"),
            ("create:guest anna@kunde.com", "g02_en_gueltig"), ("create:guest kaputt", nil), ("create:wait", "g03_en_ungueltig"),
            ("create:guest", nil), ("lang de", nil), ("create:guest anna@kunde.com", "g04_de_gueltig"),
            ("create:guest a@b.co kaputt", nil), ("create:wait", "g05_de_ungueltig"),
            ("create:mail off", "g06_mail_aus"),
            ("create:mail on", nil), ("create:more on", nil), ("create:calendar on", nil), ("create:invite on", "g07_alles_offen"),
            ("settings:google", "S01_einstellungen_google"), ("settings:mailtext", "S02_einstellungen_mailtext"), ("settings:cal", "S03_kalenderliste"),
        ]
        // Runde 109c: Fenster offen halten für Messungen von außen (burst.sh / tool).
        let steps109h: [(String?, String?)] = [("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("create:calendar off", nil), ("close", nil), ("lang \(ProcessInfo.processInfo.environment["MB_DEMO_LANG"] ?? "en")", nil)]
            + Array(repeating: (Optional("create:wait"), Optional<String>.none), count: 400)
        let steps109f: [(String?, String?)] = [
            ("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("create:calendar off", nil), ("close", nil),
            ("create:settime 13:00", "01_zu"),
            ("open", "02_zonen_auf"), ("close", "03_zonen_zu"),
            ("create:month on", "04_monat_auf"), ("create:month off", "05_monat_zu"),
            ("create:more on", "06_mehr_auf"), ("create:invite on", "07_einladung_auf"),
            ("create:invite off", "08_einladung_zu"), ("create:more off", "09_mehr_zu"),
            ("create:calendar on", "10_kalender_auf"), ("create:calendar off", "11_kalender_zu"),
        ]
        // Runde 111b: alle 8 Kombinationen der Schalter, Mail ansehen, Kopierter Text.
        var steps111b: [(String?, String?)] = [("lang \(ProcessInfo.processInfo.environment["MB_DEMO_LANG"] ?? "en")", nil), ("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("create:calendar off", nil), ("close", nil)]
        for (i, c) in ["-", "m", "t", "i", "mt", "mi", "ti", "mti"].enumerated() {
            steps111b.append(("create:chips \(c)", "chips_\(i)_\(c)"))
        }
        steps111b += [("create:chips mt", nil), ("create:mailpreview on", "mail_ansehen"), ("create:mailpreview off", nil),
                      ("create:more on", nil), ("create:invite on", "kopierter_text"), ("create:invite off", nil), ("create:more off", nil)]
        // Runde 113: Eingabefeld-Erkennung (create:entry <Text>) mit Fotos; "Hand gewinnt" per settime.
        let steps113: [(String?, String?)] = [
            ("lang \(ProcessInfo.processInfo.environment["MB_DEMO_LANG"] ?? "en")", nil),
            ("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("create:calendar off", nil), ("close", nil),
            ("create:entry fri 10-12 call with chris", "entry_1"),
            ("create:entry morgen 14 uhr standup 45 min", "entry_2"),
            ("create:entry Call 2", "entry_3"),
            ("create:entry fr 10 call", "entry_4"),
            ("create:entry 17:00 dubai sync", "entry_5"),
            ("create:entry call at 3pm", "entry_6"),
            ("create:entry fr 10 call", nil), ("create:settime 11:00", nil), ("create:entry fr 10 call ", "entry_7_hand"),
            ("create:entryclear", nil)]
        // Runde 113 Schritt 4: "Nach dem Erstellen" (Tabelle B3), Fotos aller Zeilen.
        let steps113b: [(String?, String?)] = [
            ("lang \(ProcessInfo.processInfo.environment["MB_DEMO_LANG"] ?? "en")", nil),
            ("create:month off", nil), ("create:more off", nil), ("create:calendar off", nil), ("close", nil),
            ("create:chips -", "after_0_alle_aus"),
            ("create:chips t", "after_1_text"),
            ("create:chips t,i", "after_2_text_ics"),
            ("create:chips i", "after_3_ics"),
            ("create:chips -", nil), ("create:guest anna@kunde.com", "after_4_mail"),
            ("create:chips m,t", "after_5_mail_text"),
            ("create:guest anna@kunde.com, bob@kunde.com", "after_6_zwei"),
            ("create:guest anna@", "after_7_ungueltig"),
            ("create:guest anna@kunde.com", nil), ("create:mailpreview on", "after_8_mailvorschau"),
            ("create:invite on", "after_9_textvorschau"),
            ("create:invite off", nil), ("create:guest sehr.lange.adresse.fuer.einen.gast@sehr-lange-firma.example.com", "after_10_lang"),
            ("create:guest ", nil)]
        // Runde 112: zwei angehakte Zonen, alles zu (Video: Zeitzonen auf/zu mit echter Listenhöhe).
        let steps112: [(String?, String?)] = [("lang \(ProcessInfo.processInfo.environment["MB_DEMO_LANG"] ?? "en")", nil), ("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("create:calendar off", nil),
                                               ("close", nil), ("tick Asia/Manila on", nil), ("tick Asia/Dubai on", nil), ("tick Europe/London on", nil), ("tick America/New_York on", nil)]
        // Runde 119: mehrere Gäste, Vorschau bearbeitet.
        let g5 = "anna@kunde.com,ben@firma.de,carla@studio.io,dirk@agentur.eu,eva@verlag.org"
        let steps119: [(String?, String?)] = [
            ("lang \(ProcessInfo.processInfo.environment["MB_DEMO_LANG"] ?? "en")", nil),
            ("create:month off", nil), ("create:more off", nil), ("create:invite off", nil), ("create:calendar off", nil), ("close", nil),
            ("create:guest anna@kunde.com", "g1"),
            ("create:guest anna@kunde.com,ben@firma.de,carla@studio.io", "g3"),
            ("create:guest \(g5)", "g5"),
            ("create:guest anna@kunde.com,kaputt", "bad"),
            ("create:guest anna@kunde.com,ben@firma.de", nil), ("create:mailpreview on", "mail_plain"),
            ("create:mailedit", "mail_edit"), ("create:mailpreview off", nil), ("create:reset", nil),
            ("create:invite on", "text_plain"), ("create:textedit", "text_edit"), ("create:invite off", nil), ("create:reset", nil),
            ("create:guest ", nil)]
        let demoSet = ProcessInfo.processInfo.environment["MB_DEMO_SET"]
        let steps: [(String?, String?)] = demoSet == "r119" ? steps119 : demoSet == "r113b" ? steps113b : demoSet == "r113" ? steps113 : demoSet == "r112" ? steps112 : demoSet == "r111b" ? steps111b : demoSet == "r109h" ? steps109h : demoSet == "r109g" ? steps109g : demoSet == "r109m" ? steps109m : demoSet == "r109d" ? steps109d : demoSet == "r109f" ? steps109f : demoSet == "r109" ? steps109 : demoSet == "r108" ? steps108 : demoSet == "r100" ? steps100 : demoSet == "r99" ? steps99 : demoSet == "r97" ? steps97 : demoSet == "r96" ? steps96 : [
            ("close", "01_zu"),
            ("open", "02_offen"),
            ("tick Asia/Manila on", nil),
            ("drag Asia/Manila 1020", "03_manila_auf_17_gezogen"),
            ("drag Asia/Manila 90", "04_ueber_mitternacht"),
            ("search dub", "05_suche_dub"),
            ("search a", "05b_suche_viele_treffer"),
            ("add Asia/Dubai", "06_dubai_dazu"),
            ("tick Asia/Manila on", "07_manila_im_call"),
            ("rename Asia/Nicosia Limassol", "09_umbenennen"),
            ("renamedone", "10_umbenannt"),
            ("lang en", "11_app_englisch"),
            ("create:repeat", "12_wiederholung_offen"),
        ]
        if ProcessInfo.processInfo.environment["MB_DEMO_FAKE_EVENTS"] != nil {
            func at(_ h: Int, _ m: Int) -> Date { Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date())! }
            func mk(_ t: String, _ s: Date, _ e: Date) -> Meeting {
                Meeting(id: t, title: t, start: s, end: e, isAllDay: false, isBirthday: false, calendarTitle: "Demo",
                        calendarID: nil, color: .blue, joinURL: nil, contactID: nil, calendarItemID: nil)
            }
            CreatePane.demoCalendars = [("Clients", "iCloud"), ("Work", "iCloud"), ("Private", "iCloud"), ("me@example.com", "Google"), ("Shared", "iCloud")].enumerated().map {
                CalendarInfo(id: "demo\($0.offset)", title: $0.element.0, color: .blue, sourceTitle: $0.element.1, isAppleAccount: $0.element.1 == "iCloud")
            }
            CreatePane.demoMeetings = [mk("Standup", at(10, 0), at(10, 30)), mk("Design review", at(15, 0), at(16, 0)),
                                       mk("Team sync", at(18, 30), at(19, 0))]
        }
        func shot(_ name: String) {
            let isS = name.hasPrefix("S")
            guard let w = NSApp.windows.first(where: { $0.isVisible && (isS ? SettingsPanelController.shared.owns($0) : CreatePanelController.shared.owns($0)) }) else { return }
            // MB_EXTERNAL_SHOT: das Foto macht ein äußeres Skript (der Aufruf von
            // screencapture aus der App heraus wird von macOS zeitweise blockiert).
            let external = ProcessInfo.processInfo.environment["MB_EXTERNAL_SHOT"] != nil
            if !external {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l", String(w.windowNumber), "\(outDir)/\(prefix)\(name).png"]
                try? p.run(); p.waitUntilExit()
            }
            let f = w.frame
            print("shot \(prefix)\(name) wid=\(w.windowNumber) " + String(format: "%.0f×%.0f at y=%.0f", f.width, f.height, f.minY)
                  + " erlaubt \(Int(CreatePanelController.shared.availableFrameHeight)) pt")
            fflush(stdout)
        }
        /// Testschalter `MB_FOLD_LOG=<datei>`: nach jedem Klapp-Befehl 400 ms lang
        /// alle 16 ms Fensterrahmen + y der ersten Formularzeile in die Datei.
        /// (Datei statt NSLog, Fallstrick 12.)
        func foldProbe(_ cmd: String, label: String) {
            guard let path = ProcessInfo.processInfo.environment["MB_FOLD_LOG"] else { return }
            let isFold = cmd == "open" || cmd == "close" || ["month", "more", "calendar", "invite"].contains { cmd.hasPrefix("create:\($0) ") }
            guard isFold else { return }
            let t0 = Date()
            var lines = ["# \(label)  cmd=\(cmd)"]
            var n = 0
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(16))
            timer.setEventHandler {
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                if let w = NSApp.windows.first(where: { $0.isVisible && CreatePanelController.shared.owns($0) }) {
                    let f = w.frame
                    let first = RowProbe.rows["create"]?.first
                    let last = RowProbe.rows["create"]?.last
                    lines.append(String(format: "%4d ms  top=%.0f h=%.0f  firstRowY=%.1f lastRowY=%.1f", ms, f.maxY, f.height, first?.minY ?? -1, last?.minY ?? -1))
                }
                n += 1
                if ms >= 400 {
                    timer.cancel()
                    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write((lines.joined(separator: "\n") + "\n").data(using: .utf8)!); try? h.close() }
                    else { try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
                }
            }
            timer.resume()
        }
        func run(_ i: Int) {
            guard i < steps.count else {
                // Runde 112: MB_DEMO_KEEP=1 lässt die Fenster nach dem Drehbuch stehen (Video-Tests); beendet wird per Signal/15 min.
                if ProcessInfo.processInfo.environment["MB_DEMO_KEEP"] != nil { print("demo keep"); fflush(stdout); return }
                restoreDemoSettings()
                print("demo done"); fflush(stdout); exit(0)
            }
            if let cmd = steps[i].0 {
                foldProbe(cmd, label: steps[i].1 ?? cmd)
                if cmd.hasPrefix("invite ") {
                    AppState.shared.inviteLanguage = String(cmd.dropFirst(7))
                } else if cmd.hasPrefix("lang ") {
                    AppState.shared.appLanguage = String(cmd.dropFirst(5))
                } else if cmd.hasPrefix("settings:") {
                    // Runde 109: Einstellungen für Fotos (Reiter Google, optional zum Mailtext).
                    CreatePanelController.shared.close()
                    UserDefaults.standard.set(3, forKey: "settingsTab")
                    if cmd == "settings:mailtext" { UserDefaults.standard.set("mailText", forKey: "settingsScrollTo") }
                    if cmd == "settings:cal" { UserDefaults.standard.set("targetCal", forKey: "settingsScrollTo") }
                    SettingsPanelController.shared.close()
                    AppState.shared.toggleSettingsPanel()
                } else if cmd.hasPrefix("create:") {
                    NotificationCenter.default.post(name: CreatePane.demoCommand, object: String(cmd.dropFirst(7)))
                } else {
                    NotificationCenter.default.post(name: ZonePlanner.demoCommand, object: cmd)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let n = steps[i].1 { shot(n) }
                let hold = ProcessInfo.processInfo.environment["MB_EXTERNAL_SHOT"] != nil && steps[i].1 != nil
                DispatchQueue.main.asyncAfter(deadline: .now() + (hold ? 1.5 : 0)) { run(i + 1) }
            }
        }
        run(0)
    }
}
