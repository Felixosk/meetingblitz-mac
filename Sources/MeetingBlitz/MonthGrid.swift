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
    /// Compact mode for the widget: slightly tighter rows, since it sits above
    /// a full agenda rather than in a roomy form.
    var compact: Bool = false
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

    /// A day inside the shown period. Paging moves this, picking a day does not
    /// — that keeps browsing and choosing separate.
    @State private var anchor: Date

    init(selection: Binding<Date>, firstWeekday: Int = 2, compact: Bool = false,
         mode: CalendarViewMode = .month, onPick: (() -> Void)? = nil,
         onToggleMode: (() -> Void)? = nil) {
        _selection = selection
        self.firstWeekday = firstWeekday
        self.compact = compact
        self.mode = mode
        self.onPick = onPick
        self.onToggleMode = onToggleMode
        _anchor = State(initialValue: selection.wrappedValue)
    }

    private var cal: Calendar {
        var c = Calendar.current
        c.firstWeekday = firstWeekday
        return c
    }

    var body: some View {
        VStack(spacing: compact ? 3 : 5) {
            HStack(spacing: 10) {
                // Monat + Jahr tragen die ganze Orientierung des Rasters, im
                // Widget sitzen sie zwischen zwei anderen Blöcken. Deshalb hier
                // klar sichtbar statt als Beiwerk (Rückmeldung 18.08.: „würde
                // das nicht direkt checken, dass das der Monat ist").
                if let toggle = onToggleMode {
                    // Titel als Umschalter, wie im iPhone-Kalender: Woche
                    // aufklappen zum Monat, Monat einklappen zur Woche.
                    Button(action: toggle) {
                        HStack(spacing: 4) {
                            Text(monthTitle)
                                .font(.system(size: 13, weight: .bold))
                            Image(systemName: mode == .week ? "chevron.down" : "chevron.up")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .help(mode == .week ? L.t("Ganzen Monat zeigen", "Show the whole month")
                                        : L.t("Nur die Woche zeigen", "Show just the week"))
                } else {
                    Text(monthTitle)
                        .font(.system(size: 13, weight: .bold))
                }
                Spacer()
                Button { step(-1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                }
                Button { jumpToToday() } label: {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                }
                .help(L.t("Zu heute springen", "Jump to today"))
                Button { step(1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                if onPick != nil {
                    // Sichtbarer Rückweg. Ein zweiter Klick auf das Datum oben
                    // tut dasselbe, aber das sieht man dem Raster nicht an.
                    Button { onPick?() } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .help(L.t("Kalender schließen", "Close the calendar"))
                }
            }
            .buttonStyle(.borderless)

            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, d in
                    Text(d)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            let today = cal.startOfDay(for: Date())
            let selectedDay = cal.startOfDay(for: selection)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
                      spacing: 2) {
                ForEach(gridDays(), id: \.timeIntervalSinceReferenceDate) { day in
                    // In der Wochenansicht gehören alle sieben Tage dazu, da gibt
                    // es keinen ausgegrauten Nachbarmonat.
                    let inMonth = mode == .week
                        || cal.isDate(day, equalTo: anchor, toGranularity: .month)
                    let isSelected = day == selectedDay
                    let isToday = day == today
                    Button { pick(day) } label: {
                        Text("\(cal.component(.day, from: day))")
                            .font(.system(size: 11.5, weight: isSelected || isToday ? .semibold : .regular))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: compact ? 18 : 20)
                            .background(
                                Circle()
                                    .fill(isSelected ? Color.accentColor
                                          : isToday ? Color.accentColor.opacity(0.18) : .clear)
                                    .frame(width: compact ? 18 : 20, height: compact ? 18 : 20)
                            )
                            .foregroundStyle(isSelected ? Color.white
                                             : isToday ? Color.accentColor
                                             : inMonth ? Color.primary : Color.secondary.opacity(0.45))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 2)
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
        anchor = day
        // Tag gewählt heißt fertig: das Raster klappt weg und gibt die Agenda
        // des Tages frei, wie ein normaler Datumsauswähler.
        onPick?()
    }

    /// Eine Periode weiter oder zurück: Woche oder Monat, je nach Modus.
    private func step(_ by: Int) {
        let unit: Calendar.Component = mode == .week ? .weekOfYear : .month
        anchor = cal.date(byAdding: unit, value: by, to: anchor) ?? anchor
    }

    private func jumpToToday() {
        pick(cal.startOfDay(for: Date()))
    }

    /// Monat + Jahr, in der Wochenansicht der Zeitraum der Woche.
    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = L.locale
        guard mode == .week,
              let start = cal.dateInterval(of: .weekOfYear, for: anchor)?.start,
              let end = cal.date(byAdding: .day, value: 6, to: start) else {
            f.dateFormat = "LLLL yyyy"
            return f.string(from: anchor)
        }
        // „18. – 24. August", über einen Monatswechsel hinweg „30. Aug – 5. Sep".
        let sameMonth = cal.isDate(start, equalTo: end, toGranularity: .month)
        f.dateFormat = sameMonth ? "d." : L.t("d. MMM", "MMM d")
        let a = f.string(from: start)
        f.dateFormat = sameMonth ? L.t("d. MMMM", "MMMM d") : L.t("d. MMM", "MMM d")
        return "\(a) – \(f.string(from: end))"
    }
}
