import SwiftUI
import AppKit
import ServiceManagement

/// Reports the panel content's laid-out size so the window can track it.
private struct PanelSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// The dropdown panel content. Background, corner radius and shadow come from
/// the hosting NSVisualEffectView panel (Runde 6), painting a SwiftUI material
/// here rendered as a flat dark slab in the inactive accessory app and cost the
/// text its subpixel smoothing.
struct MenuPanel: View {
    @ObservedObject var state: AppState
    @ObservedObject var google = GoogleService.shared
    var onSize: (@Sendable (CGSize) -> Void)? = nil

    /// Last meeting hidden via the row ×, powers the inline "Rückgängig" chip
    /// (Runde 30). Resets whenever the widget reopens (fresh view state).
    @State private var lastHidden: Meeting?
    /// Runde 93: Die Hero-Wahl hängt an der Uhrzeit (läuft / startet gleich).
    @State private var now = Date()
    /// Gemessene Höhe je Terminzeile, für die Scroll-Grenze (Runde 77).
    @State private var rowHeights: [String: CGFloat] = [:]
    /// F2: month grid folded out under the header (lives in AppState so the
    /// demo flag can open it and the widget resets it on open).
    private var monthOpen: Bool { state.monthGridOpen }
    @State private var lastGridMode: CalendarViewMode = .week
    /// Runde 110b (U2): Anker des Rasters (der Widget-Kopf zeigt den Zeitraum und blättert).
    @State private var gridAnchor = Date()
    @State private var heroIcsDone = false
    @ObservedObject private var widgetLayout = WidgetLayout.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s16) {
            VStack(alignment: .leading, spacing: 0) {   // Runde 110b: Kopf + Raster ein Block (Raster ist immer im Baum, Höhe 0 = kein 16-pt-Spalt)
                header
                monthGrid
            }
            secondZone

            if state.calendarAuthorized {
                // Runde 56: Zeitachse IMMER zeigen, auch an Tagen ohne getimte
                // Termine (Rückmeldung: „warum schaut der nächste Tag nicht so aus
                // wie der heutige?"). Vorher fiel sie an solchen Tagen weg,
                // das Widget sah kaputt aus und sprang beim Tageswechsel in
                // der Höhe. Eine leere Achse trägt außerdem eine Information:
                // an diesem Tag ist nichts eingeplant.
                hero
                agenda
                VStack(alignment: .leading, spacing: Theme.s8) {
                    ThemeSectionTitle(L.t("Tagesverlauf", "Day timeline"))
                    DayStrip(meetings: dayAgenda.filter { !$0.isAllDay },
                                  day: state.selectedDay,
                                  showNow: state.showsToday) { state.openInCalendar($0) }
                }
                allDayGroup
                if state.showReminders && !state.reminders.isEmpty { remindersSection }
            } else {
                ThemePrimaryButton(title: L.t("Kalender-Zugriff erlauben", "Allow calendar access")) {
                    Task { await state.requestCalendarAccess() }
                }
                // Runde 56: Der Knopf darüber ist nach einer Ablehnung ein
                // Blindgänger, macOS zeigt den Dialog genau einmal, danach
                // liefert requestFullAccessToEvents stumm false zurück. Ohne
                // diesen Ausweg klickt der Nutzer auf etwas, das sichtbar
                // nichts tut, und die App bleibt für ihn kaputt.
                ThemeTextRow(title: L.t("Systemeinstellungen öffnen", "Open System Settings"), accent: true) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Text(L.t("Hast du „Nicht erlauben“ geklickt, fragt macOS kein zweites Mal. Dann hier den Haken bei MeetingBlitz setzen.",
                         "If you clicked “Don't Allow”, macOS won't ask again. Tick MeetingBlitz there instead."))
                    .font(.theme(.small)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ThemeDivider()
            footer
        }
        .padding(EdgeInsets(top: 14, leading: Theme.s16, bottom: Theme.s16, trailing: Theme.s16))   // Runde 104: kein ✕ im Widget (Menüleisten-Fenster); Runde 110: Kopf-Mittellinie y = 28
        .frame(width: Theme.widgetWidth)
        .background(ThemeGlass())
        .themeCloseCorner { if ProcessInfo.processInfo.environment["MB_DEMO_WIDGET"] != nil { print("widget-x-klick"); fflush(stdout) }; WidgetPanelController.shared.close() }   // Runde 110: auch das Widget bekommt das ✕
        .padding(Theme.stageInset)   // Runde 110: durchsichtige Bühne; gemeldet wird die Fenstergröße
        .fixedSize(horizontal: false, vertical: true)   // Runde 113c (Fehler 7): natürliche Höhe messen, nicht die vom Fenster vorgeschlagene (sonst bleibt das Fenster beim Aufklappen zu klein)
        // Runde 110b: onGeometryChange statt Preference (feuerte im Widget nicht), gemeldet wird die natürliche Fenstergröße.
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            if size.width > 1 { onSize?(size) }
        }
        .frame(height: widgetLayout.height, alignment: .top)   // Runde 110b: feste Fensterhöhe (ohne Animation gesetzt), Inhalt oben verankert
        .ignoresSafeArea()
        // Runde 77: Tag gewechselt oder Termine dazugekommen → Fenster neu
        // vermessen. Der GeometryReader oben kann das NICHT melden, die
        // Inhaltsansicht klebt per autoresizingMask an der Panelhöhe und meldet
        // immer die alte Höhe. Nachgemessen wurde bisher nur beim Kalender-
        // Aufklappen, also blieb das Widget auf der Höhe von HEUTE stehen und
        // die Knöpfe lagen über den letzten Terminen von morgen (Meldung 14.09.:
        // „ich kann die morgen alle gar nicht sehen"). Einen Runloop später,
        // vorher ist der neue Inhalt noch nicht gelayoutet.
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { now = $0 }
        .onChange(of: layoutSignature) {
            DispatchQueue.main.async { WidgetPanelController.shared.refreshSize() }
        }
    }

    /// Alles, was die Höhe des Widgets verändert, außer dem Kalender-Raster
    /// (das misst beim Klappen selbst und animiert dabei).
    private var layoutSignature: String {
        let rows = state.agenda.map { "\($0.id)@\($0.start.timeIntervalSince1970)" }
        let rems = state.showReminders ? state.reminders.map(\.id) : []
        return [state.selectedDay.description, rows.joined(separator: ","),
                rems.joined(separator: ","), lastHidden?.id ?? "",
                state.instantError ?? "", state.calendarAuthorized ? "a" : "-",
                agendaScrolls ? "s\(state.agendaMaxRows):\(Int(cappedAgendaHeight))" : "", heroKey]
            .joined(separator: "|")
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: Theme.s8) {
            // Runde 90: Titel links, drei runde Knöpfe rechts (zurück, heute,
            // vor), wie im Ton-Menü. EINZEILIG erzwingen (Runde 56): ein langer
            // Titel darf den Kopf nicht höher machen.
            if state.calendarViewMode.isEnabled { dayTitleButton } else { dayTitleText }
            Spacer(minLength: Theme.s4)
            // Ist das Raster offen, hat es eigene Knöpfe: dann hier nur ein leerer
            // Platz gleicher Breite (Titel springt nicht, keine doppelte Navigation).
            // Runde 110: [Heute] + EINE Kapsel ‹ ›; bei offenem Raster ausgeblendet (es hat eigene Knöpfe).
            HStack(spacing: Theme.s8) {
                ThemeTextRow(title: L.t("Heute", "Today"), accent: true, fullWidth: false) {
                    if monthOpen { withAnimation(Theme.fold) { state.gridDisplay = nil } }
                    state.showToday()
                }
                    .frame(width: Theme.s24 * 2 + Theme.s8)
                    .opacity(state.showsToday && !monthOpen ? 0 : 1)
                    .disabled(state.showsToday && !monthOpen)
                // Runde 110b (U2): bei offenem Raster blättern ‹ › das Raster (Woche/Monat), sonst den Tag.
                ThemeNavCapsule(onBack: { if monthOpen { stepGrid(-1) } else { state.stepDay(-1) } },
                                onForward: { if monthOpen { stepGrid(1) } else { state.stepDay(1) } })
            }
        }
        .frame(height: 28)   // Runde 110: Kopfzeile 28 hoch, Mittellinie y = 28 (Oberkante 14)
        .buttonStyle(.borderless)
    }

    /// Datum als Text, wenn der Auswähler ausgeschaltet ist: keine Klickfläche,
    /// kein Pfeil, nichts, was etwas verspricht (Rückmeldung 18.08.: „ich
    /// brauche es nicht").
    private func stepGrid(_ by: Int) {
        gridAnchor = MonthGridMath.step(gridAnchor, mode: state.gridDisplay ?? lastGridMode, by: by, firstWeekday: state.firstWeekday)
    }

    private var dayTitleText: some View {
        Text(dayTitle)
            .font(.theme(.heading, .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Dasselbe als Knopf: öffnet und schließt den Auswähler.
    private var dayTitleButton: some View {
        // IMMER dasselbe Symbol, nur gedreht (Runde 63d: zwei verschieden breite
        // Glyphen ließen die Zeile bei jedem Klick rücken).
        // Runde 110: Datum als Titeltext mit kleinem Pfeil, ohne Kiste und ohne Tooltip; Hover = heller.
        DayTitleButton(title: monthOpen ? MonthGridMath.title(gridAnchor, mode: state.gridDisplay ?? lastGridMode, firstWeekday: state.firstWeekday) : dayTitle, open: monthOpen) {
            withAnimation(Theme.fold) { state.advanceGrid() }
        }
        .hint(monthOpen
              ? L.t("Nochmal klicken schließt den Kalender wieder",
                    "Click again to close the calendar")
              : L.t("Öffnet \(state.calendarViewMode == .week ? "die Woche" : "den Monat") zum Springen auf einen anderen Tag",
                    "Opens the \(state.calendarViewMode == .week ? "week" : "month") to jump to another day"),
              id: "monthgrid")
    }

    /// F2: Monatsraster zum Anspringen eines beliebigen Tages. Bindet auf
    /// `selectedDay`, also wandert nur die ANZEIGE — Banner und Menüleiste
    /// bleiben auf dem echten Heute.
    @ViewBuilder private var monthGrid: some View {
        // Runde 110: bleibt IMMER im Baum, klappt per ThemeFold; `lastGridMode` hält die Stufe beim Zuklappen.
        let shown = state.gridDisplay ?? lastGridMode
        Group {
            MonthGrid(selection: $state.selectedDay,
                      firstWeekday: state.firstWeekday,
                      mode: shown,
                      onPick: { withAnimation(Theme.fold) { state.gridDisplay = nil } },
                      // Umschalter im Titel nur, wenn beide Stufen erlaubt
                      // sind — bei „nur Woche" wäre er ein Versprechen, das
                      // die Einstellung gleich wieder zurücknimmt.
                      onToggleMode: state.calendarViewMode == .stepped ? {
                          withAnimation(Theme.fold) {
                              state.gridDisplay = shown == .week ? .month : .week
                          }
                      } : nil,
                      isOpen: state.gridDisplay != nil,
                      anchor: $gridAnchor, showsHeader: false, topGap: Theme.s16)
                .id(state.appLanguage)
                .onChange(of: state.gridDisplay) { old, v in
                    if let v { lastGridMode = v }
                    if old == nil, v != nil { gridAnchor = state.selectedDay }   // beim Öffnen: Raster startet am gewählten Tag
                }
        }
    }

    // MARK: - Fuß (Runde 93)

    /// "Neues Meeting…" als richtiger Knopf (zweite Stufe, grau), daneben rund
    /// der Blitz für das Sofort-Meeting. Gleiche Bedingungen wie früher: nur mit
    /// Google-Konfiguration und den jeweiligen Schaltern (Runde 36/37, F11).
    @ViewBuilder private var createRow: some View {
        if google.hasConfig && (state.showInstantMeeting || state.showMeetingCreator) {
            VStack(alignment: .leading, spacing: Theme.s4) {
                HStack(spacing: Theme.s8) {
                    if state.showMeetingCreator {
                        // Genau EIN blauer Großknopf: "Beitreten", wenn der Hero einen Link
                        // hat, sonst "Neues Meeting…".
                        ThemePrimaryButton(title: L.t("Neues Meeting…", "New Meeting…"),
                                           style: .primary,   // Runde 109e: immer blau, auch wenn der Hero "Beitreten" zeigt
                                           icon: "video.badge.plus") { state.toggleCreatePanel() }
                            .hint(L.t("Legt einen Termin mit fertigem Google-Meet-Link an, Einladungstext landet in der Zwischenablage", "Creates an event with a ready Google Meet link, the invite text goes to your clipboard"), id: "create")
                    }
                    if state.showInstantMeeting {
                        ThemeIconButton(systemName: google.busy ? "hourglass" : "bolt.fill", label: L.t("Sofort-Meeting", "Instant meeting"), tint: Theme.blue) { state.startInstantMeeting() }
                            .disabled(google.busy)
                            .hint(L.t("Erstellt sofort ein Meeting ab jetzt (30 Min) mit Meet-Link und öffnet den Raum",
                                      "Instantly creates a meeting starting now (30 min) with a Meet link and opens the room"), id: "instant")
                    }
                }
                if let err = state.instantError {
                    ErrorLine(text: err)
                }
            }
        }
    }

    // MARK: - Hero (Runde 93)

    /// Das Wichtigste oben: ein Meeting, das läuft oder gleich startet, sonst das
    /// nächste von heute (Regeln und Selbsttest in `HeroLogic.swift`).
    /// "Läuft jetzt" + "noch 18 min", "Startet gleich" + Countdown, unter 60 min
    /// "24 min", sonst die Uhrzeit groß und "in 9 h 29 min" klein.
    @ViewBuilder private var hero: some View {
        if let st = heroState {
            if let m = st.meeting {
                VStack(alignment: .leading, spacing: Theme.s4) {
                    ThemeSectionTitle(heroCaption(st))
                    Text(m.title)
                        .font(.theme(.title, .bold)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Self.zonesTip(m))
                    heroBig(st, m)
                    if overlappingIDs.contains(Self.rowKey(m)) { OverlapMark() }
                    HStack(spacing: Theme.s8) {
                        if let url = m.joinURL {
                            ThemePrimaryButton(title: L.t("Beitreten", "Join")) { state.join(m) }
                                .hint(L.t("Öffnet den Videocall direkt im Browser", "Opens the video call in your browser"), id: "hero-join")
                            ThemeIconButton(systemName: "link", showHelp: false) { state.copyLink(url) }
                                .rowHint(L.t("Link kopieren", "Copy link"))
                        }
                        ThemeIconButton(systemName: heroIcsDone ? "checkmark" : "doc.on.doc",
                                        tint: heroIcsDone ? Theme.ok : nil, showHelp: false) {
                            guard state.exportICS(m) != nil else { return }
                            withAnimation(.easeInOut(duration: 0.14)) { heroIcsDone = true }
                            Task {
                                try? await Task.sleep(nanoseconds: 1_200_000_000)
                                withAnimation(.easeInOut(duration: 0.2)) { heroIcsDone = false }
                            }
                        }
                        .rowHint(L.t("Termin kopieren", "Copy event"))
                        if m.joinURL == nil { Spacer(minLength: 0) }
                    }
                    .padding(.top, Theme.s4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(L.t("Keine Termine mehr heute", "No more events today"))
                    .font(.theme(.normal)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func heroCaption(_ st: HeroState) -> String {
        switch st {
        case .running: return L.t("Jetzt", "Now")
        case .soon: return L.t("Startet gleich", "Starting soon")
        default: return L.t("Als Nächstes", "Next up")
        }
    }

    /// Runde 99: Titel steht oben (groß), hier nur noch die Zeitangabe.
    /// Unter 60 min der große Countdown, sonst eine Zeile "15:00 – 15:30 · in 1 h 9 min".
    @ViewBuilder private func heroBig(_ st: HeroState, _ m: Meeting) -> some View {
        switch st {
        case .running:
            Text(L.t("Läuft · noch \(Self.durationLabel(m.end.timeIntervalSince(now)))",
                     "Running · \(Self.durationLabel(m.end.timeIntervalSince(now))) left"))
                .font(.theme(.normal, .semibold)).foregroundStyle(Theme.blue).lineLimit(1)
        case .soon:
            HeroCountdown(target: m.start)
            heroRange(m)
        case .next:
            if m.start.timeIntervalSince(now) < 3600 {
                HeroCountdown(target: m.start)
                heroRange(m)
            } else {
                (Text(m.rangeLabel).font(.theme(.normal, .semibold)).foregroundStyle(Theme.blue)
                 + Text(" · " + L.t("in \(Self.durationLabel(m.start.timeIntervalSince(now)))",
                                    "in \(Self.durationLabel(m.start.timeIntervalSince(now)))"))
                    .font(.theme(.normal)).foregroundStyle(Theme.muted))
                    .lineLimit(1).monospacedDigit()
                    .help(Self.zonesTip(m))
            }
        case .none:
            EmptyView()
        }
    }

    private func heroRange(_ m: Meeting) -> some View {
        Text(m.rangeLabel).font(.theme(.normal, .semibold)).foregroundStyle(Theme.blue)
            .lineLimit(1).monospacedDigit().help(Self.zonesTip(m))
    }

    /// "18 min" / "1 h 5 min" / "9 h 29 min".
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let mins = max(0, Int((seconds / 60).rounded(.up)))
        if mins < 60 { return "\(mins) min" }
        return mins % 60 == 0 ? "\(mins / 60) h" : "\(mins / 60) h \(mins % 60) min"
    }

    /// Hat der Hero-Termin einen Videolink (dann ist "Beitreten" der blaue Großknopf)?
    private var heroHasLink: Bool { heroState?.meeting.map(HeroPicker.hasCallLink) ?? false }

    private var heroState: HeroState? {
        guard state.showsToday else { return nil }
        return HeroPicker.pick(dayAgenda, now: now)
    }

    /// Für die Höhenmessung: ändert sich, wenn der Hero eine andere Gestalt bekommt.
    private var heroKey: String {
        guard let st = heroState else { return "-" }
        switch st {
        case .running(let m): return "r\(m.id)"
        case .soon(let m): return "s\(m.id)"
        case .next(let m): return "n\(m.id)\(m.start.timeIntervalSince(now) < 3600 ? "a" : "b")"
        case .none: return "x"
        }
    }

    private func isHero(_ m: Meeting) -> Bool {
        guard let h = heroState?.meeting else { return false }
        return h.id == m.id && h.start == m.start
    }

    /// Runde 97: Zonen-Zeiten nur noch als Tooltip ("Berlin 16:00 · Manila 23:00"),
    /// leer wenn keine Zone angehakt ist. Gilt für Hero und Zeilen der Liste.
    static func zonesTip(_ m: Meeting) -> String {
        guard !m.isAllDay, !m.isBirthday else { return "" }
        let book = ZoneBook.shared
        let parts = book.invitedIDs.compactMap { id -> String? in
            guard let tz = TimeZone(identifier: id) else { return nil }
            return "\(book.name(id)) \(ZonePlanner.uiHM(m.start, tz))"
        }
        return parts.joined(separator: "\n")
    }

    /// Runde 101: Termine, die erst NACH Mitternacht des gezeigten Tages beginnen,
    /// gehören nicht in "heute" (weder Liste noch Verlauf noch Hero).
    private var dayAgenda: [Meeting] {
        let end = Calendar.current.startOfDay(for: state.selectedDay).addingTimeInterval(24 * 3600)
        return state.agenda.filter { $0.isAllDay || $0.isBirthday || $0.start < end }
    }

    /// Termine, die sich mit einem anderen überschneiden (Warnung bleibt, v4).
    private var overlappingIDs: Set<String> {
        let timed = dayAgenda.filter { !$0.isAllDay && !$0.isBirthday && $0.myStatus != .declined }
        var out = Set<String>()
        for (i, a) in timed.enumerated() {
            for b in timed[(i + 1)...] where a.start < b.end && b.start < a.end {
                out.insert("\(a.id)@\(a.start.timeIntervalSince1970)")
                out.insert("\(b.id)@\(b.start.timeIntervalSince1970)")
            }
        }
        return out
    }

    /// F1: second time zone under the header, only while it actually differs
    /// from the Mac's zone (sitting in that zone, the line hides itself).
    @ViewBuilder private var secondZone: some View {
        if state.secondZoneEnabled,
           let tz = TimeZone(identifier: state.secondZoneID),
           tz.secondsFromGMT(for: Date()) != TimeZone.current.secondsFromGMT(for: Date()) {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                HStack(spacing: Theme.s4) {
                    Image(systemName: "globe").font(.theme(.small, .semibold))
                    Text("\(Self.zoneCity(state.secondZoneID)) \(Self.timeString(ctx.date, in: tz)) · \(Self.offsetLabel(tz))")
                }
                .font(.theme(.small)).foregroundStyle(Theme.muted)
            }
            .help(L.t("Uhrzeit deiner zweiten Zeitzone", "Time in your second time zone"))
            .padding(.top, -Theme.s8)   // snuggle under the header line
        }
    }

    /// "1 h zurück" / "6 h vor" gegenüber der eigenen Zone.
    static func offsetLabel(_ tz: TimeZone) -> String {
        let diff = tz.secondsFromGMT(for: Date()) - TimeZone.current.secondsFromGMT(for: Date())
        let h = abs(diff) / 3600, m = (abs(diff) % 3600) / 60
        let amount = m == 0 ? "\(h) h" : "\(h) h \(m) min"
        return diff > 0 ? L.t("\(amount) vor", "\(amount) ahead") : L.t("\(amount) zurück", "\(amount) behind")
    }

    /// "Europe/Berlin" → "Berlin" (zone line + the settings rows).
    static func zoneCity(_ id: String) -> String {
        id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
    }

    private static func timeString(_ date: Date, in tz: TimeZone) -> String {
        return L.time(date, tz)
    }

    private static var endOfToday: Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 3600)
    }

    private var agenda: some View {
        // No scroll, no height cap (Runde 33: "ich will alle Termine sehen"),
        // the panel simply grows with the day via the size preference.
        Group {
            // TimelineView is needed as a re-render trigger: `agenda` only fires
            // @Published on real changes (Meeting == id+start), so the per-row
            // countdowns would otherwise freeze while the panel is open.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                VStack(alignment: .leading, spacing: Theme.s4) {
                    if listed.isEmpty && allDayItems.isEmpty && heroState == nil {
                        Text(L.t("Keine Termine", "No events"))
                            .font(.theme(.normal)).foregroundStyle(Theme.muted)
                            .padding(.vertical, Theme.s4)
                    } else if !listed.isEmpty {
                        ThemeSectionTitle(listTitle).padding(.bottom, Theme.s4)
                        agendaRows
                    }
                    if let h = lastHidden {
                        HStack(spacing: Theme.s8) {
                            Text(L.t("„\(h.title)“ ausgeblendet", "“\(h.title)” hidden"))
                                .font(.theme(.small)).foregroundStyle(Theme.muted)
                                .lineLimit(1)
                            Spacer()
                            ThemeTextRow(title: L.t("Rückgängig", "Undo"), accent: true, fullWidth: false) {
                                state.unhideMeeting(h)
                                withAnimation(.easeInOut(duration: 0.16)) { lastHidden = nil }
                            }
                        }
                        .padding(.top, Theme.s4)
                        .transition(.opacity)
                    }
                }
                // Runde 74b: Mindesthöhe nur noch für den LEEREN Tag.
                //
                // Vorgeschichte: Runde 56 setzte hier fest 108pt (vier Zeilen),
                // damit das Widget beim Durchblättern der Tage nicht springt
                // („es sollte alles gleich bleiben, nur keine Infos drinnen").
                // An einem normalen Tag mit ein bis zwei Terminen steht dadurch
                // dauerhaft ein Loch von ~90pt zwischen Agenda und Knöpfen, und
                // genau das wurde am 23.08. als Fehler gemeldet: „warum ist da
                // so viel freier Raum, das sollte sich doch dynamisch an den
                // Inhalt anpassen".
                //
                // Beide Wünsche sind nicht gleichzeitig zu haben: entweder das
                // Fenster hat immer dieselbe Höhe, oder es passt sich an. Der
                // Ausschlag ging zur Anpassung, weil man den Leerraum JEDEN Tag
                // sieht, den Höhensprung dagegen nur beim Blättern. Der kleine
                // Rest hält den leeren Tag davon ab, auf eine Textzeile
                // zusammenzufallen.
                .frame(minHeight: state.agenda.isEmpty ? 56 : 0, alignment: .top)
            }
        }
    }

    /// Runde 77: Alle Termine auf einer Seite, bis zur eingestellten Zahl
    /// (Standard 10). Erst darüber wird die Liste scrollbar, sonst liefe das
    /// Widget an einem vollen Tag unten aus dem Bildschirm. Rückmeldung 14.09.:
    /// „auf einer Page sieht die ganzen Dinger … mehr als 10 Einträge sollte es
    /// nicht sein und dann muss man scrollen".
    ///
    /// ScrollView hat KEINE eigene Höhe (Gotcha Runde 14), deshalb bekommt sie
    /// die Summe der gemessenen Höhen der ersten N Zeilen. Zeilen sind nicht
    /// gleich hoch (zweizeiliger Countdown), eine feste Zeilenhöhe würde die
    /// letzte sichtbare Zeile anschneiden.
    /// Getimte Termine und To-dos nach Uhrzeit; der Hero-Termin steht oben groß
    /// und wird hier nicht doppelt gezeigt.
    private var listed: [Meeting] {
        dayAgenda.filter { !isHero($0) && !$0.isAllDay && !$0.isBirthday }
    }

    /// Ganztägiges und Geburtstage: eigene kompakte Gruppe ganz unten.
    private var allDayItems: [Meeting] {
        dayAgenda.filter { $0.isAllDay || $0.isBirthday }
    }

    private var listTitle: String {
        guard state.showsToday else { return L.t("Termine", "Events") }
        if listed.contains(where: { $0.end < now }) { return L.t("Heute", "Today") }
        return heroState?.meeting != nil ? L.t("Später heute", "Later today") : L.t("Heute", "Today")
    }

    @ViewBuilder private var allDayGroup: some View {
        if !allDayItems.isEmpty {
            VStack(alignment: .leading, spacing: Theme.s4) {
                ThemeSectionTitle(L.t("Ganztägig", "All day"))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(allDayItems) { m in allDayRow(m) }
                }
                // Runde 102: Zeilen-Hover sitzt s4 INNEN im Kasten (Radius außen − Abstand).
                .padding(.vertical, Theme.s4).padding(.horizontal, Theme.s4)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.fill))
            }
        }
    }

    private func allDayRow(_ m: Meeting) -> some View {
        AgendaRow(meeting: m,
                  overlaps: false,
                  isNext: false,
                  birthdayCalled: m.isBirthday ? state.isBirthdayCalled(m) : false,
                  onOpen: { state.openInCalendar(m) },
                  onCopy: { url in state.copyLink(url) },
                  onICS: { state.exportICS(m) != nil },
                  onJoin: { _ in state.join(m) },
                  onToggleCalled: { state.toggleBirthdayCalled(m) },
                  onCallContact: { state.openBirthdayContact(m) },
                  onHide: {
                      state.hideMeeting(m)
                      withAnimation(.easeInOut(duration: 0.16)) { lastHidden = m }
                  })
    }

    @ViewBuilder private var agendaRows: some View {
        let overlaps = overlappingIDs
        let rows = VStack(alignment: .leading, spacing: Theme.s4) {
            ForEach(listed) { m in
                AgendaRow(meeting: m,
                          overlaps: overlaps.contains(Self.rowKey(m)),
                          isNext: m.id == state.nextMeeting?.id && m.start == state.nextMeeting?.start,
                          birthdayCalled: m.isBirthday ? state.isBirthdayCalled(m) : false,
                          onOpen: { state.openInCalendar(m) },
                          onCopy: { url in state.copyLink(url) },
                          onICS: { state.exportICS(m) != nil },
                          onJoin: { _ in state.join(m) },
                          onToggleCalled: { state.toggleBirthdayCalled(m) },
                          onCallContact: { state.openBirthdayContact(m) },
                          onHide: {
                              state.hideMeeting(m)
                              withAnimation(.easeInOut(duration: 0.16)) { lastHidden = m }
                          })
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                    rowHeights[Self.rowKey(m)] = h
                }
            }
        }
        .themeRowList()
        if agendaScrolls {
            ScrollView(.vertical) { rows }
                .frame(height: cappedAgendaHeight)
        } else {
            rows
        }
    }

    private var agendaScrolls: Bool {
        state.agendaMaxRows > 0 && listed.count > state.agendaMaxRows
    }

    private var cappedAgendaHeight: CGFloat {
        let visible = listed.prefix(state.agendaMaxRows)
        let sum = visible.reduce(CGFloat(0)) { $0 + (rowHeights[Self.rowKey($1)] ?? 40) }
        return (sum + CGFloat(max(visible.count - 1, 0)) * 2).rounded(.up)
    }

    private static func rowKey(_ m: Meeting) -> String {
        "\(m.id)@\(m.start.timeIntervalSince1970)"
    }

    /// Apple Reminders due today / overdue (Runde 43). A separate block under the
    /// agenda, reminders have due times but aren't meetings. The circle marks
    /// one done (it then drops out of the list on the next refresh).
    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack(spacing: Theme.s4) {
                Image(systemName: "checklist").font(.theme(.small, .semibold))
                Text(L.t("Erinnerungen", "Reminders"))
                    .font(.theme(.small, .semibold))
            }
            .foregroundStyle(Theme.muted)
            .padding(.top, Theme.s4)
            VStack(alignment: .leading, spacing: Theme.s4) {
                ForEach(state.reminders) { r in
                    ReminderRow(item: r) { state.completeReminder(r) }
                }
            }
            .themeRowList()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.s8) {
            createRow
            // Unten rechts drei kleine runde Knöpfe, links klein grau der App-Name.
            HStack(spacing: Theme.s8) {
                Text("MeetingBlitz").font(.theme(.small)).foregroundStyle(Theme.muted)
                Spacer(minLength: Theme.s8)
                ThemeIconButton(systemName: "gearshape") { state.toggleSettingsPanel() }
                    .help(L.t("Einstellungen", "Settings"))
                    .hint(L.t("Einstellungen: Vorlaufzeit, Kalenderauswahl, Autostart und mehr", "Settings: lead time, calendar selection, launch at login and more"), id: "settings")
            }
        }
    }

    private var dayTitle: String {
        // Runde 111 (Fund 4): kurz und lokalisiert ("Thu, Nov 19" / "Do., 19. Nov."), wird nie abgeschnitten.
        let s = L.date(state.selectedDay, "EEEMMMd")
        // Seit F2 sind auch vergangene Tage erreichbar, deshalb beide Nachbarn
        // benennen. Weiter entfernte Tage stehen ohnehin mit vollem Datum da.
        switch state.dayOffset {
        case 1:  return L.t("Morgen · \(s)", "Tomorrow · \(s)")
        case -1: return L.t("Gestern · \(s)", "Yesterday · \(s)")
        default: return s
        }
    }

}

/// Countdown zum Start. Lesbar statt "48:00" (sah aus wie 48 Stunden):
/// ab einer Stunde "1 h 12 min", darunter "48 min", in der letzten Minute
/// "42 s". Tickt jede Sekunde (TimelineView), die Einheit steht klein daneben.
private struct HeroCountdown: View {
    let target: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let rem = max(0, Int(target.timeIntervalSince(ctx.date).rounded(.up)))
            HStack(alignment: .lastTextBaseline, spacing: Theme.s4) {
                if rem >= 3600 {
                    big(rem / 3600); unit("h")
                    big((rem % 3600) / 60).padding(.leading, Theme.s4); unit("min")
                } else if rem >= 60 {
                    big((rem + 59) / 60); unit("min")
                } else {
                    big(rem); unit(L.t("Sek", "sec"))
                }
            }
            .lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    private func big(_ n: Int) -> some View {
        Text("\(n)").font(.theme(.big, .bold)).monospacedDigit().foregroundStyle(Theme.blue)
    }
    private func unit(_ t: String) -> some View {
        Text(t).font(.theme(.normal, .semibold)).foregroundStyle(Theme.muted)
    }
}

/// Überschneidungs-Marke: Text, wenn Platz ist, sonst nur das Warnzeichen.
private struct OverlapMark: View {
    var body: some View {
        let tip = L.t("Überschneidet sich mit einem anderen Termin heute", "Overlaps with another event today")
        ViewThatFits(in: .horizontal) {
            Text(L.t("überschneidet", "overlaps"))
                .font(.theme(.small, .semibold))
                .foregroundStyle(Theme.warn)
                .padding(.horizontal, Theme.s8)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.warn, lineWidth: 1))
                .fixedSize()
                .help(tip)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.theme(.small)).foregroundStyle(Theme.warn)
                .help(tip)
        }
    }
}

/// One agenda line. The whole row opens the event in Apple Calendar; the copy
/// and join buttons act on the meeting link without opening it.
private struct AgendaRow: View {
    let meeting: Meeting
    /// Runde 90: überschneidet sich mit einem anderen Termin des Tages.
    var overlaps: Bool = false
    let isNext: Bool
    let birthdayCalled: Bool
    let onOpen: () -> Void
    let onCopy: (URL) -> Void
    /// Schreibt die .ics und meldet, ob es geklappt hat (für das Häkchen).
    let onICS: () -> Bool
    let onJoin: (URL) -> Void
    let onToggleCalled: () -> Void
    let onCallContact: () -> Void
    let onHide: () -> Void
    @State private var hoverReal = false
    private var hovering: Bool { hoverReal || (Theme.demoHover.map { !$0.isEmpty && meeting.title.contains($0) } ?? false) }
    /// Kurzes Häkchen nach dem .ics-Export (Runde 48), ohne Rückmeldung weiß
    /// man nicht, ob der Klick etwas getan hat.
    @State private var icsDone = false
    /// Two-step hide (Runde 30): first × click arms, second click hides.
    /// Leaving the row (or 2.5s) disarms.
    @State private var hideArmed = false

    private var shownTitle: String { meeting.displayTitle }
    private var isPast: Bool { meeting.end < Date() && !meeting.isAllDay && !meeting.isBirthday }
    /// Echtes Meeting (Link oder Gäste): Farbbalken, fetter Titel, blauer Knopf.
    private var isMeetingRow: Bool { HeroPicker.isMeeting(meeting) }
    /// Ganztägig/Geburtstag: kleine einzeilige Variante in der grauen Gruppe.
    private var compact: Bool { meeting.isAllDay || meeting.isBirthday }

    /// Zwei-Schritt-Ausblenden (Runde 30): erster Klick scharf, zweiter blendet aus.
    private func hideTapped() {
        if hideArmed {
            hideArmed = false
            onHide()
        } else {
            withAnimation(.easeInOut(duration: 0.14)) { hideArmed = true }
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation(.easeInOut(duration: 0.14)) { hideArmed = false }
            }
        }
    }

    /// Zweite Zeile: Farbpunkt + Zeit (bei Ganztägigen nur der Text).
    private var subline: some View {
        HStack(spacing: Theme.s4) {
            if meeting.isBirthday {
                Text(L.t("Ganztägig", "All day"))
            } else {
                Circle().fill(meeting.color).frame(width: Theme.dot, height: Theme.dot)
                // Die Uhrzeit wird NIE gekürzt (Fehler Runde 93: "1" statt "11:14 – 11:44").
                Text(meeting.isAllDay ? L.t("Ganztägig", "All day") : meeting.rangeLabel)
                    .monospacedDigit().fixedSize()
                if meeting.joinURL != nil, !meeting.isAllDay {
                    Image(systemName: "video").font(.system(size: 11))   // Runde 111b (B5): Link = kleines Symbol hinter der Zeit
                }
                if overlaps && !isPast { OverlapMark() }
            }
        }
        .font(.theme(.small)).foregroundStyle(Theme.muted)
        .lineLimit(1)
    }

    var body: some View {
        HStack(spacing: Theme.s8) {
            if meeting.isBirthday {
                // Runde 111b (B5): runder Haken links wie in Apples Erinnerungen ("angerufen"), leer = noch nicht.
                Button { onToggleCalled() } label: {
                    Image(systemName: birthdayCalled ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15)).foregroundStyle(birthdayCalled ? Theme.blue : Theme.muted)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(birthdayCalled ? L.t("Angerufen, zurücksetzen", "Called, reset") : L.t("Als angerufen markieren", "Mark as called"))
                .rowHint(birthdayCalled ? L.t("Zurücksetzen", "Reset") : L.t("Als angerufen markieren", "Mark as called"))
                .hint(birthdayCalled ? L.t("Schon angerufen, klicken setzt es zurück", "Already called, click to reset")
                                     : L.t("Abhaken, sobald du angerufen hast (gilt nur für heute)", "Tick once you have called (today only)"), id: "called-\(meeting.id)")
            }
            VStack(alignment: .leading, spacing: Theme.s4) {
                HStack(spacing: Theme.s8) {
                    Text(shownTitle)
                        .font(.theme(compact ? .small : .normal))
                        .lineLimit(2)   // Runde 113c: bis 2 Zeilen, voller Titel im Tooltip (.help der Zeile)
                        // F3: abgesagt = durchgestrichen. Der Termin bleibt sichtbar
                        // (sonst sucht man ihn), warnt aber nicht mehr.
                        .strikethrough(meeting.myStatus == .declined, color: Theme.muted)
                        .foregroundStyle(meeting.myStatus == .declined || (meeting.isBirthday && birthdayCalled) ? Theme.muted : Theme.label)
                    // F3: „vielleicht" ist keine Absage, aber sichtbar unsicher.
                    if meeting.myStatus == .tentative {
                        Text("?")
                            .font(.theme(.small, .bold))
                            .foregroundStyle(Theme.muted)
                            .help(L.t("Du hast mit „Vielleicht\" geantwortet", "You replied “Maybe”"))
                    }
                }
                if !compact { subline }
            }
            Spacer(minLength: Theme.s4)
            if meeting.isBirthday {
                // M2: jump straight to the person in Contacts to place the call.
                if meeting.contactID != nil {
                    Button(L.t("Anrufen", "Call")) { onCallContact() }
                        .font(.theme(.small, .semibold)).buttonStyle(ThemeLinkStyle())
                        .hint(L.t("Öffnet die Person in den Kontakten, damit du sie direkt anrufen kannst", "Opens the person in Contacts so you can call them"), id: "call-\(meeting.id)")
                }
            }
            if !meeting.isAllDay, !meeting.isBirthday, meeting.end > Date(), let url = meeting.joinURL {
                ThemePrimaryButton(title: L.t("Beitreten", "Join"), size: .small) { onJoin(url) }
                .hint(L.t("Öffnet den Videocall direkt im Browser", "Opens the video call in your browser"), id: "join-\(meeting.id)")
            }
            if !meeting.isAllDay, !meeting.isBirthday, let url = meeting.joinURL {
                ThemeIconButton(systemName: "link", showHelp: false) { onCopy(url) }
                    .hint(L.t("Kopiert den Videokonferenz-Link in die Zwischenablage", "Copies the video call link to your clipboard"), id: "copy-\(meeting.id)")
                    .rowHint(L.t("Link kopieren", "Copy link"))
            }
            if !meeting.isAllDay, !meeting.isBirthday {
                // Kalenderdatei (Runde 48): gibt es für JEDEN Termin, auch ohne
                // Meet-Link, die .ics ist unabhängig vom Videocall nützlich.
                ThemeIconButton(systemName: icsDone ? "checkmark" : "doc.on.doc",
                                tint: icsDone ? Theme.ok : nil, showHelp: false) {
                    guard onICS() else { return }
                    withAnimation(.easeInOut(duration: 0.14)) { icsDone = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        withAnimation(.easeInOut(duration: 0.2)) { icsDone = false }
                    }
                }
                .hint(L.t("Speichert den Termin als .ics in ~/Downloads und legt ihn als Datei in die Zwischenablage, in WhatsApp oder Mail eingefügt wird ein Anhang daraus", "Saves the event as .ics in ~/Downloads and puts it on the clipboard as a file, paste it into WhatsApp or Mail and it becomes an attachment"), id: "ics-\(meeting.id)")
                .rowHint(L.t("Termin kopieren", "Copy event"))
            }
            // Runde 100: kein schwebendes ✕ und kein Zusatzknopf mehr. Ausblenden steht
            // im Rechtsklick-Menü ("Hier ausblenden").
        }
        .padding(.leading, Theme.s8)
        .padding(.trailing, Theme.s8).padding(.vertical, compact ? 2 : Theme.s4)
        // Runde 99 (wie Apple-Kalender): Kasten leicht in der Kalenderfarbe getönt,
        // innen ein abgerundeter Farbbalken mit Abstand zum Rand. Vergangene grau.
        .background(RoundedRectangle(cornerRadius: compact ? Theme.inner(inset: Theme.s4) : Theme.radius, style: .continuous)
            // Runde 111b (B5): keine Fläche und kein Balken mehr für Meeting-Zeilen, Fläche nur beim Überfahren.
            .fill(hovering ? Theme.fill : .clear))
        .help(([shownTitle] + [MenuPanel.zonesTip(meeting)]).filter { !$0.isEmpty }.joined(separator: "\n"))
        // Rechtsklick: alles ohne Hover erreichbar (macOS 6.2).
        .contextMenu {
            if !meeting.isAllDay, !meeting.isBirthday, let url = meeting.joinURL {
                Button(L.t("Beitreten", "Join")) { onJoin(url) }
                Button(L.t("Link kopieren", "Copy link")) { onCopy(url) }
            }
            if !meeting.isAllDay, !meeting.isBirthday {
                Button(L.t("Als .ics sichern", "Save as .ics")) { _ = onICS() }
            }
            Button(L.t("Im Kalender öffnen", "Open in Calendar")) { onOpen() }
            Divider()
            Button(L.t("Hier ausblenden", "Hide here")) { onHide() }
        }
        .opacity(isPast ? Theme.pastOpacity : 1)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .onHover { h in
            hoverReal = h
            if !h { hideArmed = false }   // leaving the row disarms the ×
        }
    }
}

/// One reminder line: a tappable completion circle, the title, and its due time
/// (overdue in red). Completing it calls back so the list drops the row.
private struct ReminderRow: View {
    let item: ReminderItem
    let onComplete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.s8) {
            ThemeIconButton(systemName: hovering ? "checkmark" : "circle", tint: hovering ? Theme.ok : item.color,
                            action: onComplete)
            .hint(L.t("Hakt die Erinnerung ab, wirkt auch in der Erinnerungen-App", "Completes the reminder, also applies in the Reminders app"), id: "rem-\(item.id)")

            Text(item.title)
                .font(.theme(.normal))
                .lineLimit(1)
                .foregroundStyle(item.isOverdue ? Theme.danger : Theme.label)
            Spacer(minLength: Theme.s4)
            Text(item.timeLabel)
                .font(.theme(.small).monospacedDigit())
                .foregroundStyle(item.isOverdue ? Theme.danger : Theme.muted)
        }
        .padding(.horizontal, Theme.s8).padding(.vertical, Theme.s4)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .fill(hovering ? Theme.fill : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Runde 110: Datum als Titeltext (15 pt semibold) mit kleinem Pfeil. Keine Kiste, kein Tooltip;
/// beim Überfahren nur heller (85 → 100 %).
struct DayTitleButton: View {
    let title: String
    let open: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.s4) {
                Text(title).font(.theme(.heading, .semibold)).lineLimit(1)
                    .minimumScaleFactor(0.75)   // Runde 111 (Fund 4): nie mit "…" abschneiden
                Image(systemName: "chevron.down").font(.theme(.small, .semibold))
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .frame(width: Theme.s16, height: Theme.s16)   // Runde 110b (U5): fester Rahmen, keine „ᒪ"-Zwischenbilder
            }
            .foregroundStyle(Theme.label.opacity(hover || Theme.demoHover == "title" ? 1 : 0.85))
            .layoutPriority(1)
            .transaction { $0.animation = nil }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
