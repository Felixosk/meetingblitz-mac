import Foundation
import EventKit
import SwiftUI

/// EventKit wrapper: access, calendar list, and event queries restricted to the
/// calendars the user selected. Main-actor only (EKEventStore is not Sendable).
@MainActor
final class CalendarService {
    private let store = EKEventStore()

    func requestAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
        do { return try await store.requestFullAccessToEvents() }
        catch { return false }
    }

    var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    // MARK: - Reminders (Runde 43)

    func requestRemindersAccess() async -> Bool {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return true }
        do { return try await store.requestFullAccessToReminders() }
        catch { return false }
    }

    var isRemindersAuthorized: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    /// How far back an overdue reminder may be and still show. An unbounded
    /// window dragged in ancient forgotten reminders (Runde 43c: a
    /// 4-months-overdue "Flug ein checken" surfaced). 7 days keeps recent misses
    /// like "yesterday 22:00" while dropping the cruft.
    private static let overdueWindowDays = 7

    /// Incomplete reminders due from a few days ago up to the end of today, i.e.
    /// due today plus *recently* overdue. Sorted overdue-first, then by due time.
    func dueReminders() async -> [ReminderItem] {
        guard isRemindersAuthorized else { return [] }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let endOfToday = cal.date(byAdding: .day, value: 1, to: today)
        let start = cal.date(byAdding: .day, value: -Self.overdueWindowDays, to: today)
        let pred = store.predicateForIncompleteReminders(
            withDueDateStarting: start, ending: endOfToday, calendars: nil)
        // Map to our Sendable struct INSIDE the completion, EKReminder is not
        // Sendable, so it must not cross the continuation back to the main actor.
        let items: [ReminderItem] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: pred) { reminders in
                cont.resume(returning: (reminders ?? []).map(Self.mapReminder))
            }
        }
        return items.sorted { lhs, rhs in
            switch (lhs.due, rhs.due) {
            case let (l?, r?): return l < r
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return lhs.title < rhs.title
            }
        }
    }

    /// Mark a reminder complete by its identifier and persist.
    func completeReminder(id: String) {
        guard let item = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        item.isCompleted = true
        try? store.save(item, commit: true)
    }

    nonisolated private static func mapReminder(_ r: EKReminder) -> ReminderItem {
        let comps = r.dueDateComponents
        let hasTime = comps?.hour != nil || comps?.minute != nil
        let due = comps.flatMap { Calendar.current.date(from: $0) }
        return ReminderItem(
            id: r.calendarItemIdentifier,
            title: (r.title?.isEmpty == false) ? r.title! : L.t("Erinnerung", "Reminder"),
            due: due,
            hasTime: hasTime,
            color: Color(cgColor: r.calendar?.cgColor ?? .init(gray: 0.5, alpha: 1)),
            listTitle: r.calendar?.title ?? "")
    }

    func allCalendars() -> [CalendarInfo] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event)
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: Color(cgColor: $0.cgColor ?? .init(gray: 0.5, alpha: 1))) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func selectedCalendars(_ ids: Set<String>) -> [EKCalendar] {
        store.calendars(for: .event).filter { ids.isEmpty || ids.contains($0.calendarIdentifier) }
    }

    /// Future, timed meetings from the selected calendars, sorted by start.
    /// All-day events are excluded (they are not "the next call").
    func upcomingMeetings(selected ids: Set<String>, horizonHours: Int = 24) -> [Meeting] {
        guard isAuthorized else { return [] }
        let cals = selectedCalendars(ids)
        guard !cals.isEmpty else { return [] }
        let now = Date()
        let end = Calendar.current.date(byAdding: .hour, value: horizonHours, to: now) ?? now
        let pred = store.predicateForEvents(withStart: now, end: end, calendars: cals)
        return store.events(matching: pred)
            .filter { $0.status != .canceled && !$0.isAllDay && $0.startDate != nil && $0.startDate > now }
            .map(Self.map)
            .sorted { $0.start < $1.start }
    }

    /// Everything happening on one day (today + `offset` days) from the selected
    /// calendars, all-day included, for the dropdown agenda. Ongoing events are
    /// kept. Exact duplicates (e.g. a birthday that appears in two calendars)
    /// are collapsed.
    func dayAgenda(offset: Int = 0, selected ids: Set<String>) -> [Meeting] {
        guard isAuthorized else { return [] }
        let cals = selectedCalendars(ids)
        guard !cals.isEmpty else { return [] }
        let cal = Calendar.current
        let startOfDay = cal.date(byAdding: .day, value: offset,
                                  to: cal.startOfDay(for: Date())) ?? cal.startOfDay(for: Date())
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        // "Tonight" window: timed events starting after midnight, up to 04:00,
        // still belong to this day's view (the timeline extends that far).
        let nightEnd = cal.date(byAdding: .hour, value: 4, to: endOfDay) ?? endOfDay
        store.refreshSourcesIfNecessary()   // deletions/moves show up immediately
        let pred = store.predicateForEvents(withStart: startOfDay, end: nightEnd, calendars: cals)
        let mapped = store.events(matching: pred)
            .filter { $0.status != .canceled }
            .map(Self.map)
            // Timed: only events STARTING this day (or tonight until 04:00),
            // yesterday's overnight spill-overs are noise ("was gestern war,
            // interessiert nicht"). All-day: the day's banners incl. multi-day,
            // but nothing that begins tomorrow.
            .filter { m in
                if m.isAllDay { return m.start < endOfDay }
                return m.start >= startOfDay && m.start < nightEnd
            }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay && !rhs.isAllDay }
                return lhs.start < rhs.start
            }

        // Collapse exact duplicates by title (case-insensitive) + slot.
        var seen = Set<String>()
        return mapped.filter { m in
            let key = "\(m.title.lowercased())|\(m.isAllDay)|\(Int(m.start.timeIntervalSince1970))"
            return seen.insert(key).inserted
        }
    }

    /// Write a new event into an Apple calendar (Runde 27: created meetings
    /// live in the Apple calendar; Google only mints the Meet link, which rides
    /// along as the event URL + note). `calendarID` picks the target (Runde 28);
    /// nil or stale falls back to the system default calendar.
    func createEvent(title: String, start: Date, end: Date, url: URL?, calendarID: String?,
                     recurrence: RepeatRule = .none, custom: CustomRecurrence? = nil) throws {
        guard isAuthorized else { throw NSError(domain: "MeetingBlitz", code: 1,
            userInfo: [NSLocalizedDescriptionKey: L.t("Kein Kalender-Zugriff.", "No calendar access.")]) }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        // URL only, mirroring it into the notes showed the link twice in
        // Apple Calendar (Runde 29).
        event.url = url
        if let rule = Self.recurrenceRule(for: recurrence, custom: custom) { event.recurrenceRules = [rule] }
        let chosen = calendarID.flatMap { id in
            store.calendars(for: .event).first { $0.calendarIdentifier == id && $0.allowsContentModifications }
        }
        guard let cal = chosen ?? store.defaultCalendarForNewEvents
                ?? store.calendars(for: .event).first(where: { $0.allowsContentModifications }) else {
            throw NSError(domain: "MeetingBlitz", code: 2,
                userInfo: [NSLocalizedDescriptionKey: L.t("Kein beschreibbarer Kalender gefunden.",
                                                          "No writable calendar found.")])
        }
        event.calendar = cal
        try store.save(event, span: .thisEvent)
    }

    /// Build an EKRecurrenceRule for the create form's repeat choice. Weekly and
    /// biweekly are both `.weekly` with interval 1 / 2; open-ended (no end date).
    /// `.custom` reads the CustomRecurrence spec (every N days/weeks/months, and
    /// specific weekdays for the weekly case).
    private static func recurrenceRule(for r: RepeatRule, custom: CustomRecurrence?) -> EKRecurrenceRule? {
        switch r {
        case .none:     return nil
        case .daily:    return EKRecurrenceRule(recurrenceWith: .daily,   interval: 1, end: nil)
        case .weekly:   return EKRecurrenceRule(recurrenceWith: .weekly,  interval: 1, end: nil)
        case .biweekly: return EKRecurrenceRule(recurrenceWith: .weekly,  interval: 2, end: nil)
        case .monthly:  return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .custom:
            let c = custom ?? CustomRecurrence()
            let every = max(1, c.interval)
            switch c.unit {
            case .days:
                return EKRecurrenceRule(recurrenceWith: .daily, interval: every, end: nil)
            case .months:
                return EKRecurrenceRule(recurrenceWith: .monthly, interval: every, end: nil)
            case .weeks:
                let days = c.weekdays.sorted()
                    .compactMap { EKWeekday(rawValue: $0) }
                    .map { EKRecurrenceDayOfWeek($0) }
                if days.isEmpty {
                    return EKRecurrenceRule(recurrenceWith: .weekly, interval: every, end: nil)
                }
                return EKRecurrenceRule(recurrenceWith: .weekly, interval: every,
                                        daysOfTheWeek: days, daysOfTheMonth: nil,
                                        monthsOfTheYear: nil, weeksOfTheYear: nil,
                                        daysOfTheYear: nil, setPositions: nil, end: nil)
            }
        }
    }

    /// Calendars new events may go into (read-only ones like holidays or
    /// subscriptions are useless as a target), for the create form's picker.
    func writableCalendars() -> [CalendarInfo] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title,
                                color: Color(cgColor: $0.cgColor ?? .init(gray: 0.5, alpha: 1))) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The system default target (used until the user picks one).
    var defaultCalendarID: String? {
        guard isAuthorized else { return nil }
        return (store.defaultCalendarForNewEvents
                ?? store.calendars(for: .event).first(where: { $0.allowsContentModifications }))?.calendarIdentifier
    }

    private static func map(_ e: EKEvent) -> Meeting {
        let title = (e.title?.isEmpty == false) ? e.title! : L.t("Termin", "Event")
        let isBirthday = e.calendar?.type == .birthday
            || title.range(of: "geburtstag", options: .caseInsensitive) != nil
            || title.range(of: "birthday", options: .caseInsensitive) != nil
        return Meeting(
            id: e.eventIdentifier ?? "\(e.startDate.timeIntervalSince1970)-\(title)",
            title: title,
            start: e.startDate,
            end: e.endDate ?? e.startDate,
            isAllDay: e.isAllDay,
            isBirthday: isBirthday,
            calendarTitle: e.calendar?.title ?? "",
            calendarID: e.calendar?.calendarIdentifier,
            color: Color(cgColor: e.calendar?.cgColor ?? .init(gray: 0.5, alpha: 1)),
            joinURL: findJoinURL(e),
            contactID: e.birthdayContactIdentifier,
            calendarItemID: e.calendarItemIdentifier
        )
    }

    /// Look for a video-call link in the usual fields, preferring known providers.
    private static func findJoinURL(_ e: EKEvent) -> URL? {
        if let u = e.url, isMeetingLink(u) { return u }
        let text = [e.location, e.notes, e.url?.absoluteString].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty else { return e.url }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let urls = detector?.matches(in: text, options: [], range: range).compactMap { $0.url } ?? []
        return urls.first(where: isMeetingLink) ?? urls.first ?? e.url
    }

    private static func isMeetingLink(_ u: URL) -> Bool {
        let h = (u.host ?? "").lowercased()
        return h.contains("meet.google") || h.contains("zoom") || h.contains("teams.microsoft")
            || h.contains("webex") || h.contains("whereby")
    }
}
