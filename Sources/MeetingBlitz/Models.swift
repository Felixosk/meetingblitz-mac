import SwiftUI

/// "50m" / "1h 50m" / "2h", hours+minutes so nobody has to divide 110 by 60
/// in their head (Runde 38).
func hmLabel(_ minutes: Int) -> String {
    let m = max(0, minutes)
    if m < 60 { return "\(m)m" }
    let h = m / 60, rem = m % 60
    return rem == 0 ? "\(h)h" : "\(h)h \(rem)m"
}

/// A calendar the user can include or exclude.
struct CalendarInfo: Identifiable, Hashable {
    let id: String        // EKCalendar.calendarIdentifier
    let title: String
    let color: Color
    /// Account the calendar comes from ("iCloud", a Google address, …). Shown
    /// when picking a target so "Agency" in Google and "Agency" in iCloud are
    /// distinguishable (F11).
    var sourceTitle: String = ""
    /// True for calendars that live on this Mac / in iCloud, false for synced
    /// accounts like Google. Splits the target picker (F11).
    var isAppleAccount: Bool = true
}

/// Where a newly created meeting is written (F11). `.both` writes TWO events
/// sharing one Meet link; the banner path de-duplicates them so only one
/// submarine flies (see `CalendarService.upcomingMeetings`).
enum CreateTarget: String, CaseIterable, Identifiable {
    case google, apple, both
    var id: String { rawValue }
    var usesGoogle: Bool { self != .apple }
    var usesApple: Bool { self != .google }
}

/// How a newly created meeting repeats (Runde 43). Maps to an EKRecurrenceRule;
/// `.none` writes a single event, `.custom` uses the CustomRecurrence spec.
enum RepeatRule: String, CaseIterable, Identifiable {
    case none, daily, weekly, biweekly, monthly, custom
    var id: String { rawValue }

    /// Short label for the picker.
    var label: String {
        switch self {
        case .none:     return L.t("Einmalig", "Once")
        case .daily:    return L.t("Täglich", "Daily")
        case .weekly:   return L.t("Wöchentl.", "Weekly")
        case .biweekly: return L.t("14-tägig", "2 weeks")
        case .monthly:  return L.t("Monatl.", "Monthly")
        case .custom:   return L.t("Benutzerdef.", "Custom")
        }
    }
}

/// A custom recurrence (Runde 43b, Rückmeldung: "jeden zweiten Tag oder jeden Montag,
/// Dienstag"). Every `interval` units; for `.weeks`, only on `weekdays` (empty =
/// same weekday as the start). Weekday ints match EKWeekday (1=Sun … 7=Sat).
struct CustomRecurrence: Equatable {
    enum Unit: String, CaseIterable, Identifiable {
        case days, weeks, months
        var id: String { rawValue }
        var label: String {
            switch self {
            case .days:   return L.t("Tage", "days")
            case .weeks:  return L.t("Wochen", "weeks")
            case .months: return L.t("Monate", "months")
            }
        }
    }
    var unit: Unit = .weeks
    var interval: Int = 1
    var weekdays: Set<Int> = []

    /// Monday-first display order paired with EKWeekday raw values. Computed so
    /// the labels follow a live language switch (a stored let would freeze them).
    static var weekdayOrder: [(label: String, ek: Int)] {
        [(L.t("Mo", "Mo"), 2), (L.t("Di", "Tu"), 3), (L.t("Mi", "We"), 4),
         (L.t("Do", "Th"), 5), (L.t("Fr", "Fr"), 6), (L.t("Sa", "Sa"), 7),
         (L.t("So", "Su"), 1)]
    }

    /// Short human summary for the collapsed row, e.g. "Mo, Di" or "alle 2 Tage".
    var summary: String {
        if unit == .weeks, !weekdays.isEmpty {
            return Self.weekdayOrder.filter { weekdays.contains($0.ek) }
                .map(\.label).joined(separator: ", ")
        }
        let n = max(1, interval)
        return "\(L.t("alle", "every")) \(n) \(unit.label)"
    }
}

/// Which Google account a meeting's Meet link opens as (Runde 43). Stored per
/// meeting title so a weekly series inherits the choice. `.work` resolves to
/// the app-wide routing account (e.g. you@work-domain.example), `.personal`
/// opens Chrome's default profile with no account switch (the browser's current default).
enum MeetAccountChoice: String {
    case work, personal
}

/// One Apple Reminder reduced to what the widget needs (Runde 43, Rückmeldung:
/// „im Kalender habe ich auch Erinnerungen drin stehen, die will ich sehen").
struct ReminderItem: Identifiable, Equatable {
    let id: String
    let title: String
    let due: Date?          // nil = no time component (rare, we only fetch dated ones)
    let hasTime: Bool       // due carries an hour/minute, not just a day
    let color: Color        // owning reminder list colour
    let listTitle: String

    static func == (l: ReminderItem, r: ReminderItem) -> Bool {
        l.id == r.id && l.due == r.due && l.title == r.title
    }

    var isOverdue: Bool {
        guard let due else { return false }
        return due < Date()
    }

    /// "14:30" when the reminder has a time, else "Heute". Overdue keeps the
    /// clock so you see how late it is.
    var timeLabel: String {
        guard let due, hasTime else { return L.t("Heute", "Today") }
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: due)
    }
}

/// One event, reduced to what the UI and the monitor need.
/// What the widget's day picker unfolds into. A whole month is a lot of panel
/// for "which day next week?", so the week is the lighter default option.
enum CalendarViewMode: String, CaseIterable, Identifiable {
    /// Gestuft: erster Klick aufs Datum zeigt die Woche, zweiter den Monat,
    /// dritter schließt wieder. Ein Bedienelement, drei Zustände.
    case stepped, week, month, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stepped: return L.t("Beide", "Both")
        case .week:    return L.t("Woche", "Week")
        case .month:   return L.t("Monat", "Month")
        case .off:     return L.t("Aus", "Off")
        }
    }
    /// `.off` blendet den Auswähler ganz aus: Das Datum im Kopf ist dann
    /// schlichter Text, kein Knopf, kein Pfeil, nichts klappt auf.
    var isEnabled: Bool { self != .off }

    /// Was der erste Klick aufs Datum zeigt.
    var firstStage: CalendarViewMode? {
        switch self {
        case .stepped, .week: return .week
        case .month:          return .month
        case .off:            return nil
        }
    }

    /// Nächste Stufe nach `current`, nil bedeutet zu. Nur `.stepped` hat einen
    /// Zwischenschritt, die anderen schalten direkt wieder zu.
    func nextStage(after current: CalendarViewMode?) -> CalendarViewMode? {
        guard isEnabled else { return nil }
        guard let current else { return firstStage }
        if self == .stepped && current == .week { return .month }
        return nil
    }
}

/// F6: how much the menu-bar item shows. Every option is NARROWER than the
/// full title, never wider — the width budget is what makes macOS throw status
/// items out (Runde 46b).
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case titleAndCountdown, countdownOnly, iconOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .titleAndCountdown: return L.t("Titel", "Title")
        case .countdownOnly:     return L.t("Nur Zeit", "Time only")
        case .iconOnly:          return L.t("Nur Symbol", "Icon only")
        }
    }
}

/// My own answer to an invitation (F3). `.none` covers events with no
/// attendees at all — your own entries — and, deliberately, anything where the
/// current user cannot be identified: never suppress a warning on a guess.
enum MyStatus {
    case none, accepted, declined, tentative
}

struct Meeting: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let isBirthday: Bool
    let calendarTitle: String
    let calendarID: String?     // owning calendar id, for the alert-calendar filter (Runde 40)
    let color: Color            // owning calendar's colour, for the timeline
    let joinURL: URL?
    let contactID: String?      // birthday contact, used from M2 on
    let calendarItemID: String? // to reveal the event in Apple Calendar
    var myStatus: MyStatus = .none   // F3

    static func == (l: Meeting, r: Meeting) -> Bool { l.id == r.id && l.start == r.start }

    var timeLabel: String {
        if isAllDay { return L.t("Ganztägig", "All-day") }
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: start)
    }

    var rangeLabel: String {
        if isAllDay { return L.t("Ganztägig", "All-day") }
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    /// "in 4 min" / "in 2 Std 51 Min" / "läuft", or the English versions.
    var countdownLabel: String {
        let s = start.timeIntervalSinceNow
        if s <= 0 { return L.t("läuft", "now") }
        let mins = Int(s / 60)
        if mins < 60 { return "in \(mins) min" }
        return L.t("in \(mins / 60) Std \(mins % 60) Min", "in \(mins / 60)h \(mins % 60)m")
    }

    /// Titel ohne Buchungs-Rauschen, nur für die Menüleiste (Runde 47b).
    ///
    /// Calendly-Termine heißen etwa „Maximilian S Call - Confirmed". Das
    /// „- Confirmed" sagt nichts und kostet **77pt** von einem Breitenbudget, an
    /// dem das ganze Status-Item hängt (siehe `AppDelegate.maxMenuBarWidth`):
    /// mit Suffix 250pt, ohne 173pt. Also raus damit, statt den NAMEN zu kürzen,
    /// der ist die Information. Im Widget und im Tooltip steht weiter der
    /// Originaltitel.
    var menuBarTitle: String {
        var t = title.trimmingCharacters(in: .whitespaces)
        let noise = [" - Confirmed", " – Confirmed", ", Confirmed", " (Confirmed)",
                     " - Bestätigt", " – Bestätigt", " - Accepted"]
        for n in noise where t.lowercased().hasSuffix(n.lowercased()) {
            t = String(t.dropLast(n.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return t.isEmpty ? title : t
    }

    /// Compact form for the menu-bar label: "Samuel Neumeier Call · 5m".
    /// The full title is kept; the menu bar itself elides if space is tight.
    var menuBarLabel: String {
        let s = start.timeIntervalSinceNow
        if s <= 0 { return menuBarTitle }
        return "\(menuBarTitle) · \(hmLabel(Int(s / 60)))"
    }
}
