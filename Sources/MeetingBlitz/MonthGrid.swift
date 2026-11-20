import SwiftUI

/// Hand-drawn month calendar in the Apple Calendar look (Runde 29): full panel
/// width, round accent selection, today tinted, chevrons + "•" (jump back to
/// today) in the header. Keeps the time-of-day of `selection`.
///
/// Lives in its own file since F2 (Runde 58): the create form and the widget's
/// day switcher share it, and a second copy would drift apart. `firstWeekday`
/// follows the app setting (P7) instead of the hardcoded Monday it had while it
/// was private to the create form.
struct MonthGrid: View {
    @Binding var selection: Date
    /// 1 = Sunday … 7 = Saturday, like `Calendar.firstWeekday`.
    var firstWeekday: Int = 2
    /// Called after a day was picked. The widget uses it to fold the grid away
    /// again — without it the calendar just sits there and the way back is
    /// invisible (Rückmeldung 18.08.: „wie komme ich wieder back da?").
    var onPick: (() -> Void)?
    /// Week or whole month. A month is a lot of panel for "which day next
    /// week?", so the week is the lighter option.
    var mode: CalendarViewMode = .month
    /// Switch between week and month right here. Without it you are stuck in
    /// whichever mode the settings say (Rückmeldung 18.08.: „wie kann ich dann
    /// den Monat sehen?"), and the settings are two panels away.
    var onToggleMode: (() -> Void)?
    /// Runde 110: Widget-Raster klappt auf/zu, ohne aus dem Baum zu verschwinden.
    var isOpen: Bool = true
    /// Runde 113: vergangene Tage abgedunkelt, Tage mit Terminen mit Punkt (Termin-Fenster).
    var dimPast: Bool = false
    var eventDays: Set<Date> = []
    /// Meldet den sichtbaren Zeitraum [von, bis), damit der Aufrufer die Punkte mit einer Abfrage lädt.
    var onRange: ((Date, Date) -> Void)? = nil

    /// A day inside the shown period. Paging moves this, picking a day does not
    /// — that keeps browsing and choosing separate.
    @State private var localAnchor: Date
    /// Runde 110b (U2): Das Widget führt den Anker selbst (sein Kopf zeigt den Monat und blättert).
    var externalAnchor: Binding<Date>? = nil
    private var anchorB: Binding<Date> { externalAnchor ?? $localAnchor }
    private var anchor: Date { anchorB.wrappedValue }
    /// Ohne eigenen Kopf (Widget) beginnt der Raster mit `topGap` Luft.
    var showsHeader: Bool = true
    var topGap: CGFloat = Theme.s8

    init(selection: Binding<Date>, firstWeekday: Int = 2, mode: CalendarViewMode = .month, onPick: (() -> Void)? = nil,
         onToggleMode: (() -> Void)? = nil, isOpen: Bool = true,
         anchor: Binding<Date>? = nil, showsHeader: Bool = true, topGap: CGFloat = Theme.s8,
         dimPast: Bool = false, eventDays: Set<Date> = [], onRange: ((Date, Date) -> Void)? = nil) {
        self.dimPast = dimPast
        self.eventDays = eventDays
        self.onRange = onRange
        self.isOpen = isOpen
        self.externalAnchor = anchor
        self.showsHeader = showsHeader
        self.topGap = topGap
        _selection = selection
        self.firstWeekday = firstWeekday
        self.mode = mode
        self.onPick = onPick
        self.onToggleMode = onToggleMode
        _localAnchor = State(initialValue: selection.wrappedValue)
    }

    private var cal: Calendar {
        var c = Calendar.current
        c.firstWeekday = firstWeekday
        return c
    }

    /// Runde 110: `isOpen` = ganzer Baustein auf/zu (Widget); alles ist FLACH in eigenen Folds
    /// (ein Fold im Fold meldet dem äußeren sofort die Zielhöhe und springt).
    var body: some View {
        let weeks = monthWeeks()
        let r = anchorRow(weeks)
        let month = mode == .month
        VStack(spacing: 0) {
            ThemeFold(isOpen: isOpen && showsHeader, gap: 0) {
                VStack(spacing: 0) {
            HStack(spacing: Theme.s8) {
                // Monat + Jahr tragen die ganze Orientierung des Rasters, im
                // Widget sitzen sie zwischen zwei anderen Blöcken. Deshalb hier
                // klar sichtbar statt als Beiwerk (Rückmeldung 18.08.: „würde
                // das nicht direkt checken, dass das der Monat ist").
                if let toggle = onToggleMode {
                    // Titel als Umschalter, wie im iPhone-Kalender: Woche
                    // aufklappen zum Monat, Monat einklappen zur Woche.
                    ThemeTextRow(title: monthTitle, trailingIcon: mode == .week ? "chevron.down" : "chevron.up",
                                 weight: .bold, fullWidth: false, action: toggle)
                        .themeRowList()
                        .layoutPriority(1)
                        .transaction { $0.animation = nil }   // Runde 110: Titeltext tauscht hart, keine Geisterschrift
                        .help(mode == .week ? L.t("Ganzen Monat zeigen", "Show the whole month")
                                            : L.t("Nur die Woche zeigen", "Show just the week"))
                } else {
                    Text(monthTitle)
                        .font(.theme(.normal, .bold)).foregroundStyle(Theme.label)
                }
                Spacer()
                // [Heute] ‹ ›: derselbe Text-Knopf wie im Widget-Kopf, Platz links
                // reserviert, damit die Pfeile nebeneinander bleiben.
                let todayShown = cal.startOfDay(for: selection) == cal.startOfDay(for: Date())
                    && gridDays().contains(cal.startOfDay(for: Date()))
                // Runde 110c: "Heute" nimmt nur Platz, wenn es sichtbar ist (die Kapsel steht rechtsbündig und
                // springt nicht); so passt auch "28. September – 4. October" in den Titel.
                if !todayShown {
                    ThemeTextRow(title: L.t("Heute", "Today"), accent: true, fullWidth: false) { jumpToToday() }
                        .fixedSize()
                        .help(L.t("Zu heute springen", "Jump to today"))
                }
                ThemeNavCapsule(onBack: { step(-1) }, onForward: { step(1) })
                if onPick != nil {
                    // Sichtbarer Rückweg. Ein zweiter Klick auf das Datum oben
                    // tut dasselbe, aber das sieht man dem Raster nicht an.
                    ThemeIconButton(systemName: "xmark") { onPick?() }
                        .help(L.t("Kalender schließen", "Close the calendar"))
                }
            }
            .buttonStyle(.borderless)

                }
                .padding(.top, Theme.s4)
            }
            ThemeFold(isOpen: isOpen, gap: showsHeader ? Theme.s8 : topGap) {
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, d in
                    Text(d)
                        .font(.theme(.small, .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                }
            }

            }
            ThemeFold(isOpen: isOpen && month, gap: Theme.s4, edge: .bottom) {
                weekRows(Array(weeks[..<r])).padding(.top, Theme.s8)
            }
            ThemeFold(isOpen: isOpen, gap: 0) {
                weekRows([weeks[r]])
                    .padding(.top, month ? 0 : Theme.s8)
                    .padding(.bottom, month ? 0 : Theme.s4)
            }
            ThemeFold(isOpen: isOpen && month, gap: Theme.s4) {
                weekRows(Array(weeks[(r + 1)...])).padding(.bottom, Theme.s4)
            }
        }
        .onAppear { reportRange() }
        .onChange(of: anchor) { _, _ in reportRange() }
        .onChange(of: mode) { _, _ in reportRange() }
        // Runde 113: springt die Auswahl aus dem gezeigten Zeitraum (z. B. durch das Eingabefeld), blättert das Raster mit.
        .onChange(of: selection) { _, new in
            guard externalAnchor == nil else { return }
            let d = cal.startOfDay(for: new)
            if !gridDays().contains(d) { localAnchor = new }
        }
    }

    private func reportRange() {
        guard let onRange else { return }
        let days = mode == .week ? gridDays() : monthWeeks().flatMap { $0 }
        guard let f = days.first, let l = days.last, let e = cal.date(byAdding: .day, value: 1, to: l) else { return }
        onRange(f, e)
    }

    private func weekRows(_ weeks: [[Date]]) -> some View {
        let today = cal.startOfDay(for: Date())
        let selectedDay = cal.startOfDay(for: selection)
        return VStack(spacing: Theme.s4) {
            ForEach(weeks.indices, id: \.self) { w in
                HStack(spacing: 0) {
                    ForEach(weeks[w], id: \.timeIntervalSinceReferenceDate) { day in
                        // In der Wochenansicht gehören alle sieben Tage dazu, da gibt
                        // es keinen ausgegrauten Nachbarmonat.
                        let inMonth = mode == .week
                            || cal.isDate(day, equalTo: anchor, toGranularity: .month)
                        let isSelected = day == selectedDay
                        let isToday = day == today
                        let isPast = dimPast && day < today
                        Button { pick(day) } label: {
                            Text("\(cal.component(.day, from: day))")
                                .font(.theme(.normal, isSelected || isToday ? .semibold : .regular))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, minHeight: Theme.iconButton)
                                .background(
                                    Circle()
                                        .fill(isSelected ? Theme.blue : .clear)
                                        .frame(width: Theme.iconButton, height: Theme.iconButton)
                                )
                                // Heute ohne Auswahl: weißer Ring (Blau = ausgewählt).
                                .overlay(Circle().strokeBorder(isToday && !isSelected ? Theme.label : .clear, lineWidth: 1)
                                    .frame(width: Theme.iconButton, height: Theme.iconButton))
                                .overlay {
                                    if eventDays.contains(day) {
                                        Circle().fill(isSelected ? Theme.onBlue.opacity(0.8) : Theme.muted)
                                            .frame(width: 4, height: 4).offset(y: 8)
                                    }
                                }
                                .foregroundStyle(isSelected ? Theme.onBlue
                                                 : inMonth ? Theme.label : Theme.faint)
                                .opacity(isPast && !isSelected ? 0.45 : 1)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 6 Wochen des Monats vom Anker, jede Zeile 7 Tage ab dem ersten Wochentag.
    private func monthWeeks() -> [[Date]] {
        guard let first = cal.dateInterval(of: .month, for: anchor)?.start,
              let gridStart = cal.dateInterval(of: .weekOfYear, for: first)?.start
        else { return Array(repeating: [], count: 6) }
        let days = (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
        return (0..<6).map { Array(days[($0 * 7)..<($0 * 7 + 7)]) }
    }

    private func anchorRow(_ weeks: [[Date]]) -> Int {
        let a = cal.startOfDay(for: anchor)
        return weeks.firstIndex { $0.contains(a) } ?? 0
    }

    /// Weekday headers in the app's language, rotated to `firstWeekday`. Two
    /// letters keeps the columns as narrow as the hand-written list they replace
    /// ("Mo/Di/…", "Mo/Tu/…").
    private var weekdaySymbols: [String] {
        let f = DateFormatter()
        f.locale = L.locale
        let syms = f.shortStandaloneWeekdaySymbols ?? []   // index 0 = Sunday
        guard syms.count == 7 else { return [] }
        let shift = max(0, min(6, firstWeekday - 1))
        return (Array(syms[shift...]) + Array(syms[..<shift])).map { String($0.prefix(2)) }
    }

    /// Month: 6 fixed weeks starting on the week's first day on/before the 1st,
    /// a stable-height grid that always shows the neighbour-month fringe like
    /// Apple Calendar. Week: just the seven days around the anchor.
    private func gridDays() -> [Date] {
        if mode == .week {
            guard let start = cal.dateInterval(of: .weekOfYear, for: anchor)?.start else { return [] }
            return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        }
        guard let first = cal.dateInterval(of: .month, for: anchor)?.start,
              let gridStart = cal.dateInterval(of: .weekOfYear, for: first)?.start
        else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private func pick(_ day: Date) {
        // Keep the chosen clock time, swap the calendar day.
        let t = cal.dateComponents([.hour, .minute], from: selection)
        selection = cal.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0,
                             second: 0, of: day) ?? day
        anchorB.wrappedValue = day
        // Tag gewählt heißt fertig: das Raster klappt weg und gibt die Agenda
        // des Tages frei, wie ein normaler Datumsauswähler.
        onPick?()
    }

    /// Eine Periode weiter oder zurück: Woche oder Monat, je nach Modus.
    private func step(_ by: Int) {
        anchorB.wrappedValue = MonthGridMath.step(anchor, mode: mode, by: by, firstWeekday: firstWeekday)
    }

    private func jumpToToday() {
        pick(cal.startOfDay(for: Date()))
    }

    private var monthTitle: String { MonthGridMath.title(anchor, mode: mode, firstWeekday: firstWeekday) }

}


/// Runde 110b (U2): Titel und Blättern des Rasters, auch vom Widget-Kopf aus nutzbar.
enum MonthGridMath {
    static func cal(_ firstWeekday: Int) -> Calendar { var c = Calendar.current; c.firstWeekday = firstWeekday; return c }

    static func step(_ anchor: Date, mode: CalendarViewMode, by: Int, firstWeekday: Int) -> Date {
        let unit: Calendar.Component = mode == .week ? .weekOfYear : .month
        return cal(firstWeekday).date(byAdding: unit, value: by, to: anchor) ?? anchor
    }

    /// Monat + Jahr, in der Wochenansicht der Zeitraum der Woche.
    static func title(_ anchor: Date, mode: CalendarViewMode, firstWeekday: Int) -> String {
        let cal = cal(firstWeekday)
        guard mode == .week,
              let start = cal.dateInterval(of: .weekOfYear, for: anchor)?.start,
              let end = cal.date(byAdding: .day, value: 6, to: start) else {
            return L.date(anchor, "LLLLyyyy")
        }
        // Runde 111 (Fund 3): lokalisierter Zeitraum, EN "Nov 16 – 22", DE "16.–22. Nov."
        return L.dateRange(start, end)
    }
}
