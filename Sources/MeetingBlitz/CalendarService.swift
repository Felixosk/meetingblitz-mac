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
        let mapped = store.events(matching: pred)
            .filter { $0.status != .canceled && !$0.isAllDay && $0.startDate != nil && $0.startDate > now }
            .map(Self.map)
            .sorted { $0.start < $1.start }
        // Same collapse as the agenda: an event living in two calendars must
        // warn ONCE. Critical since the create target can be "both" (F11), and
        // it also covers an invite that landed in a shared calendar as well.
        // Overlapping DIFFERENT meetings keep their own warning (the app's core
        // differentiator) — the key includes the title and the exact start.
        var seen = Set<String>()
        return (mapped + DryCreate.fakeMeetings.filter { $0.start > now && $0.start < end }).sorted { $0.start < $1.start }
            .filter { m in
            seen.insert("\(m.title.lowercased())|\(Int(m.start.timeIntervalSince1970))").inserted
        }
    }

    /// Everything happening on one day (today + `offset` days) from the selected
    /// calendars, all-day included, for the dropdown agenda. Ongoing events are
    /// kept. Exact duplicates (e.g. a birthday that appears in two calendars)
    /// are collapsed.
    func dayAgenda(offset: Int = 0, selected ids: Set<String>) -> [Meeting] {
        let day = Calendar.current.date(byAdding: .day, value: offset,
                                        to: Calendar.current.startOfDay(for: Date())) ?? Date()
        return dayAgenda(for: day, selected: ids)
    }

    /// Runde 113: welche Tage in [from, to) mindestens einen Termin haben (für die Punkte im Raster).
    /// Eine Abfrage, ganztägig und mit Uhrzeit, ohne Geburtstage; mehrtägige zählen an jedem Tag.
    func daysWithEvents(from: Date, to: Date, selected ids: Set<String>) -> Set<Date> {
        guard isAuthorized else { return [] }
        let cals = selectedCalendars(ids)
        guard !cals.isEmpty else { return [] }
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: cals)
        let spans = store.events(matching: pred)
            .filter { $0.calendar?.type != .birthday }
            .map { (start: $0.startDate ?? from, end: $0.endDate ?? $0.startDate ?? from) }
        return Self.coveredDays(spans, from: from, to: to)
    }

    /// Rein rechnend (testbar): jeder Kalendertag in [from, to), den ein Zeitraum berührt. Ende exakt um 0:00 zählt nicht mehr.
    nonisolated static func coveredDays(_ spans: [(start: Date, end: Date)], from: Date, to: Date, calendar cal: Calendar = .current) -> Set<Date> {
        var out = Set<Date>()
        for sp in spans {
            var d = cal.startOfDay(for: max(sp.start, from))
            let last = min(sp.end, to)
            while d < last && d < to {
                out.insert(d)
                guard let n = cal.date(byAdding: .day, value: 1, to: d) else { break }
                d = n
            }
            if sp.end <= sp.start, sp.start >= from, sp.start < to { out.insert(cal.startOfDay(for: sp.start)) }
        }
        return out
    }

    /// Same, for an arbitrary date (F2: the month grid can pick any day).
    func dayAgenda(for date: Date, selected ids: Set<String>) -> [Meeting] {
        guard isAuthorized else { return [] }
        let cals = selectedCalendars(ids)
        guard !cals.isEmpty else { return [] }
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        // "Tonight" window: timed events starting after midnight, up to 04:00,
        // still belong to this day's view (the timeline extends that far).
        let nightEnd = cal.date(byAdding: .hour, value: 4, to: endOfDay) ?? endOfDay
        store.refreshSourcesIfNecessary()   // deletions/moves show up immediately
        let pred = store.predicateForEvents(withStart: startOfDay, end: nightEnd, calendars: cals)
        let mapped = (store.events(matching: pred)
            .filter { $0.status != .canceled }
            .map(Self.map) + DryCreate.fakeMeetings)   // Runde 122b: nur im Testmodus, sonst leer
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



    /// Zeitraum-Auswertung über die ANGEZEIGTEN Kalender.
    ///
    /// Ganztägige und Geburtstage bleiben draußen: „Julia in Lisbon" über drei
    /// Tage würde die Stundenzahl sprengen und nichts über Calls aussagen.
    /// Termine werden auf den Zeitraum GEKAPPT, sonst zählt ein Termin, der in
    /// den Sonntag hineinreicht, mit voller Länge in die Woche.
    /// `groupBy` steuert die Balken: `.day` für die Woche, `.weekOfYear` für den
    /// Monat. Die Balken decken den GANZEN Zeitraum ab, auch die Tage, die noch
    /// kommen — eine Woche mit drei leeren Balken am Ende sagt etwas aus.
    /// Runde 111 (Fund 5): Minuten der VEREINIGTEN Intervalle (Überlappungen zählen einmal).
    static func unionMinutes(_ iv: [(Date, Date)]) -> Int {
        var total: TimeInterval = 0
        var cur: (Date, Date)?
        for x in iv.sorted(by: { $0.0 < $1.0 }) {
            if let c = cur, x.0 <= c.1 { cur = (c.0, max(c.1, x.1)) }
            else { if let c = cur { total += c.1.timeIntervalSince(c.0) }; cur = x }
        }
        if let c = cur { total += c.1.timeIntervalSince(c.0) }
        return Int((total / 60).rounded())
    }

    func stats(from: Date, to: Date, selected ids: Set<String>,
               groupBy: Calendar.Component = .day) -> MeetingStats {
        let empty = MeetingStats(count: 0, callCount: 0, minutes: 0, callMinutes: 0, busiestDay: nil)
        guard isAuthorized else { return empty }
        let cals = selectedCalendars(ids)
        guard !cals.isEmpty else { return empty }

        let pred = store.predicateForEvents(withStart: from, end: to, calendars: cals)
        let events = store.events(matching: pred)
            .filter { $0.status != .canceled && !$0.isAllDay }
            .map(Self.map)
            .filter { !$0.isBirthday }

        var count = 0, callCount = 0, minutes = 0, callMinutes = 0
        var perDay: [Date: Int] = [:]
        var perBucket: [Date: (Int, Int)] = [:]
        let cal = Calendar.current
        func bucket(_ d: Date) -> Date {
            switch groupBy {
            case .day:   return cal.startOfDay(for: d)
            case .month: return cal.dateInterval(of: .month, for: d)?.start ?? cal.startOfDay(for: d)
            default:     return cal.dateInterval(of: .weekOfYear, for: d)?.start ?? cal.startOfDay(for: d)
            }
        }
        // Runde 111 (Fund 5): Minuten pro TAG als vereinigte Intervalle (Überlappungen zählen nicht doppelt),
        // mehrtägige Termine werden auf ihre Tage verteilt. Ein Tag hat nie mehr als 24 h.
        var dayAll: [Date: [(Date, Date)]] = [:]
        var dayCall: [Date: [(Date, Date)]] = [:]
        for m in events {
            let s = max(m.start, from), e = min(m.end, to)
            guard e > s else { continue }
            count += 1
            let isCall = m.joinURL != nil
            if isCall { callCount += 1 }
            var cur = s
            while cur < e {
                let day = cal.startOfDay(for: cur)
                let next = cal.date(byAdding: .day, value: 1, to: day) ?? e
                let seg = min(e, next)
                dayAll[day, default: []].append((cur, seg))
                if isCall { dayCall[day, default: []].append((cur, seg)) }
                cur = seg
            }
        }
        for (day, iv) in dayAll {
            let mins = Self.unionMinutes(iv)
            let calls = Self.unionMinutes(dayCall[day] ?? [])
            perDay[day] = mins
            minutes += mins; callMinutes += calls
            var b = perBucket[bucket(day)] ?? (0, 0)
            b.0 += mins; b.1 += calls
            perBucket[bucket(day)] = b
        }
        var busiest: (String, Int)?
        if let top = perDay.max(by: { $0.value < $1.value }), top.value > 0 {
            busiest = (L.date(top.key, "EEEEMMMd"), top.value)
        }

        // Balken über den ganzen Zeitraum aufspannen, damit die Achse stabil
        // bleibt und leere Tage sichtbar sind.
        let f = DateFormatter(); f.locale = L.locale
        // „Mo/Di/Mi" statt „M/D/M": ein Buchstabe ist mehrdeutig (Montag und
        // Mittwoch, Dienstag und Donnerstag). Beim Jahr passen bei 12 Balken
        // nur Einzelbuchstaben, dort trägt die Reihenfolge die Verständlichkeit.
        // Runde 111 (Fund 3): Wochen-Balken nur die Tageszahl (kein deutscher Punkt), lokalisiert.
        f.setLocalizedDateFormatFromTemplate(groupBy == .day ? "EEEEEE" : (groupBy == .month ? "LLLLL" : "d"))
        var bars: [StatBar] = []
        var cursor = bucket(from)
        let now = Date()
        var i = 0
        // Tages- und Monatsraster spannen IMMER den vollen Zeitraum auf, auch
        // über `to` hinaus: die noch leeren Tage bis Sonntag bzw. die Monate bis
        // Dezember sind selbst eine Aussage. Vorher endete die Reihe bei „jetzt"
        // und zeigte mittwochs nur 3 Balken.
        let end: Date
        switch groupBy {
        case .day:   end = cal.date(byAdding: .day, value: 7, to: bucket(from)) ?? to
        case .month: end = cal.date(byAdding: .year, value: 1, to: bucket(from)) ?? to
        default:     end = to
        }
        while cursor < end, i < 40 {
            let v = perBucket[cursor] ?? (0, 0)
            let step: Calendar.Component = groupBy == .day ? .day : (groupBy == .month ? .month : .weekOfYear)
            let next = cal.date(byAdding: step, value: 1, to: cursor) ?? cursor
            bars.append(StatBar(id: i, label: f.string(from: cursor),
                                minutes: v.0, callMinutes: v.1,
                                isNow: cursor <= now && now < next))
            cursor = next; i += 1
        }
        return MeetingStats(count: count, callCount: callCount,
                            minutes: minutes, callMinutes: callMinutes,
                            busiestDay: busiest, bars: bars)
    }

    /// Termine, die sich mit dem geplanten Zeitraum überschneiden (Kollisions-
    /// Warnung beim Erstellen). Ganztägige und Geburtstage zählen NICHT — die
    /// überschneiden sich per Definition mit allem und wären nur Rauschen.
    /// Läuft der Termin über Mitternacht, wird auch der Folgetag geprüft.
    func conflicts(start: Date, minutes: Int, selected ids: Set<String>) -> [Meeting] {
        guard isAuthorized, minutes > 0 else { return [] }
        let end = start.addingTimeInterval(Double(minutes) * 60)
        let cal = Calendar.current
        var pool = dayAgenda(for: start, selected: ids)
        if !cal.isDate(start, inSameDayAs: end) {
            pool += dayAgenda(for: end, selected: ids)
        }
        var seen = Set<String>()
        return pool.filter { m in
            guard !m.isAllDay, !m.isBirthday else { return false }
            guard m.start < end, m.end > start else { return false }   // echte Überlappung
            return seen.insert("\(m.id)|\(m.start.timeIntervalSince1970)").inserted
        }
        .sorted { $0.start < $1.start }
    }

    /// Write a new event into an Apple calendar (Runde 27: created meetings
    /// live in the Apple calendar; Google only mints the Meet link, which rides
    /// along as the event URL + note). `calendarID` picks the target (Runde 28);
    /// nil or stale falls back to the system default calendar.
    ///
    /// Runde 78 (MCP): `timeZone`, `location` und `notes` sind zusaetzliche,
    /// optionale Felder fuer per Claude angelegte Termine. Gibt die
    /// `eventIdentifier` zurueck, damit der Aufrufer (z. B. `delete_event`)
    /// spaeter genau DIESEN Termin wiederfindet.
    @discardableResult
    func createEvent(title: String, start: Date, end: Date, url: URL?, calendarID: String?,
                     recurrence: RepeatRule = .none, custom: CustomRecurrence? = nil,
                     timeZone: TimeZone? = nil, location: String? = nil, notes: String? = nil) throws -> String {
        guard isAuthorized else { throw NSError(domain: "MeetingBlitz", code: 1,
            userInfo: [NSLocalizedDescriptionKey: L.t("Kein Kalender-Zugriff.", "No calendar access.")]) }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        if let timeZone { event.timeZone = timeZone }
        if let location, !location.isEmpty { event.location = location }
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
        // F11: Google's CalDAV tends to drop the URL property on the way up, so
        // for a CalDAV target the link additionally rides in the notes. iCloud
        // is CalDAV too but keeps URLs, and doubling it there would bring back
        // the Runde-29 duplicate. Runde 78: eine mitgegebene eigene Notiz wird
        // dazugehaengt, nicht ueberschrieben, sonst waere ein MCP-Termin mit
        // Meet-Link und eigenem Notiztext eines der beiden los.
        var noteParts: [String] = []
        if let notes, !notes.isEmpty { noteParts.append(notes) }
        if let u = url, cal.source?.sourceType == .calDAV,
           cal.source?.title.localizedCaseInsensitiveContains("icloud") != true {
            noteParts.append(u.absoluteString)
        }
        if !noteParts.isEmpty { event.notes = noteParts.joined(separator: "\n\n") }
        try store.save(event, span: .thisEvent)
        return event.eventIdentifier ?? ""
    }

    /// Termine ueber ALLE Kalender im Zeitraum, ungefiltert von der Anzeige-
    /// Auswahl (Runde 78, MCP `list_events`): Claude soll sehen koennen, was
    /// wirklich im Kalender steht, nicht nur, was das Widget gerade zeigt.
    /// Zusatzfelder (Nachtrag 21.09.) gegenueber dem normalen `Meeting`:
    /// `isRecurring`, `calendarWritable`, `hasAttendees`, `iAmOrganizer`: die
    /// braucht Claude, um VOR einem `move_event`-Versuch schon zu wissen, ob
    /// er ueberhaupt klappen kann.
    func mcpEventsInRange(from: Date, to: Date) -> [MCPEventInfo] {
        guard isAuthorized, to > from else { return [] }
        store.refreshSourcesIfNecessary()
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: pred)
            .filter { $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                MCPEventInfo(
                    id: e.eventIdentifier ?? "",
                    title: (e.title?.isEmpty == false) ? e.title! : L.t("Termin", "Event"),
                    start: e.startDate, end: e.endDate ?? e.startDate,
                    calendarTitle: e.calendar?.title ?? "",
                    joinURL: Self.findJoinURL(e),
                    isRecurring: e.hasRecurrenceRules,
                    calendarWritable: e.calendar?.allowsContentModifications ?? false,
                    hasAttendees: !(e.attendees?.isEmpty ?? true),
                    iAmOrganizer: e.organizer?.isCurrentUser ?? true)
            }
    }

    /// Runde 111b (B4): Rückgängig findet den Termin auch ohne Kennung (CalDAV vergibt nach dem Sync neue, Runde 83):
    /// Titel + Start ±60 s in den Zielkalendern. Gibt die Zahl gelöschter Termine zurück.
    @discardableResult
    func deleteEvents(title: String, start: Date, calendarIDs: [String?]) -> Int {
        guard isAuthorized else { return 0 }
        let cals: [EKCalendar]? = {
            let ids = calendarIDs.compactMap { $0 }
            let all = ids.compactMap { store.calendar(withIdentifier: $0) }
            return all.isEmpty ? nil : all
        }()
        let pred = store.predicateForEvents(withStart: start.addingTimeInterval(-60), end: start.addingTimeInterval(120), calendars: cals)
        var n = 0
        for e in store.events(matching: pred) where e.title == title && abs(e.startDate.timeIntervalSince(start)) <= 60 {
            if (try? store.remove(e, span: .thisEvent)) != nil { n += 1 }
        }
        return n
    }

    /// Loescht EINEN Termin per Kennung (Runde 78, MCP `delete_event`). Der
    /// Aufrufer prueft VORHER, ob dieser Termin ueberhaupt ueber Claude
    /// angelegt wurde (siehe `MCPCreatedStore`): diese Funktion selbst kennt
    /// diese Regel nicht, sie loescht, was man ihr gibt.
    /// `wholeSeries` (Runde 88): beim Zurückrollen einer gerade angelegten
    /// Serie die GANZE Serie entfernen, nicht nur das erste Vorkommen.
    func deleteEvent(id: String, wholeSeries: Bool = false) throws {
        guard isAuthorized else { throw NSError(domain: "MeetingBlitz", code: 1,
            userInfo: [NSLocalizedDescriptionKey: L.t("Kein Kalender-Zugriff.", "No calendar access.")]) }
        guard let event = store.event(withIdentifier: id) else {
            throw NSError(domain: "MeetingBlitz", code: 3,
                userInfo: [NSLocalizedDescriptionKey: L.t("Termin nicht gefunden.", "Event not found.")])
        }
        try store.remove(event, span: wholeSeries ? .futureEvents : .thisEvent)
    }

    /// Verschiebt EIN Vorkommen eines Termins (Nachtrag 21.09., MCP
    /// `move_event`). Gilt fuer ALLE Termine in beschreibbaren Kalendern, nicht
    /// nur fuer per MCP angelegte. Das ist Absicht laut Plan, anders als bei
    /// `delete_event`. `occurrenceStart` grenzt bei Serien auf GENAU das Vorkommen
    /// ein, das `list_events` gemeldet hat (EventKit teilt sich die
    /// `eventIdentifier` ueber alle Vorkommen einer Serie).
    /// Immer `span: .thisEvent`, die Serie selbst wird nie verschoben.
    /// `newEnd` nil bedeutet „dieselbe Dauer wie bisher", der Aufrufer muss
    /// die alte Dauer dafuer nicht selbst vorher abfragen.
    @discardableResult
    func moveEvent(id: String, occurrenceStart: Date?, newStart: Date, newEnd: Date?,
                   timeZone: TimeZone?) throws -> (title: String, calendarTitle: String, oldStart: Date, oldEnd: Date, newEnd: Date) {
        guard isAuthorized else { throw NSError(domain: "MeetingBlitz", code: 1,
            userInfo: [NSLocalizedDescriptionKey: L.t("Kein Kalender-Zugriff.", "No calendar access.")]) }
        let event: EKEvent
        if let occurrenceStart {
            // Enges Fenster um das gemeldete Vorkommen, +/- 1 Tag reicht fuer
            // jede Zeitzonen-Differenz aus, die hier vorkommen kann.
            let cal = Calendar.current
            let windowStart = cal.date(byAdding: .day, value: -1, to: occurrenceStart) ?? occurrenceStart
            let windowEnd = cal.date(byAdding: .day, value: 1, to: occurrenceStart) ?? occurrenceStart
            let pred = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
            guard let found = store.events(matching: pred).first(where: {
                $0.eventIdentifier == id && abs($0.startDate.timeIntervalSince(occurrenceStart)) < 60
            }) else {
                throw NSError(domain: "MeetingBlitz", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    L.t("Dieses Vorkommen wurde nicht gefunden.", "This occurrence was not found.")])
            }
            event = found
        } else {
            guard let e = store.event(withIdentifier: id) else {
                throw NSError(domain: "MeetingBlitz", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: L.t("Termin nicht gefunden.", "Event not found.")])
            }
            event = e
        }
        guard event.calendar?.allowsContentModifications == true else {
            throw NSError(domain: "MeetingBlitz", code: 5, userInfo: [NSLocalizedDescriptionKey:
                L.t("Dieser Kalender ist nicht beschreibbar.", "This calendar is not writable.")])
        }
        // Nicht-Organisator + Teilnehmer: eine Verschiebung kaeme bei den
        // anderen gar nicht an, lieber vorher klar sagen als still ins Leere
        // schreiben.
        if let attendees = event.attendees, !attendees.isEmpty, event.organizer?.isCurrentUser == false {
            throw NSError(domain: "MeetingBlitz", code: 6, userInfo: [NSLocalizedDescriptionKey:
                L.t("Du bist nicht Organisator dieses Termins, eine Verschiebung würde die anderen Teilnehmer nicht erreichen.",
                    "You are not the organizer of this event, moving it would not reach the other attendees.")])
        }
        let oldStart = event.startDate ?? newStart
        let oldEnd = event.endDate ?? newStart
        let title = (event.title?.isEmpty == false) ? event.title! : L.t("Termin", "Event")
        let calTitle = event.calendar?.title ?? ""
        // Dauer erhalten, wenn der Aufrufer keine neue mitgibt.
        let duration = oldEnd.timeIntervalSince(oldStart)
        let resolvedEnd = newEnd ?? newStart.addingTimeInterval(max(0, duration))
        event.startDate = newStart
        event.endDate = resolvedEnd
        if let timeZone { event.timeZone = timeZone }
        try store.save(event, span: .thisEvent)
        return (title, calTitle, oldStart, oldEnd, resolvedEnd)
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
                                color: Color(cgColor: $0.cgColor ?? .init(gray: 0.5, alpha: 1)),
                                sourceTitle: $0.source?.title ?? "",
                                isAppleAccount: Self.isAppleAccount($0)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The system default target (used until the user picks one).
    var defaultCalendarID: String? {
        guard isAuthorized else { return nil }
        return (store.defaultCalendarForNewEvents
                ?? store.calendars(for: .event).first(where: { $0.allowsContentModifications }))?.calendarIdentifier
    }

    /// F11: does this calendar live on the Mac / in iCloud (Apple side), or in a
    /// synced account like Google? iCloud speaks CalDAV too, hence the name check.
    static func isAppleAccount(_ c: EKCalendar) -> Bool {
        switch c.source?.sourceType {
        case .local, .subscribed, .birthdays, .mobileMe: return true
        case .calDAV: return c.source?.title.localizedCaseInsensitiveContains("icloud") == true
        default: return false     // .exchange and anything new: treat as an account
        }
    }

    /// F11: best guess for "the Google calendar". A synced Google account names
    /// its MAIN calendar after the address, so an "@" in the title is the
    /// strongest hint; secondary and shared calendars of the same account only
    /// serve as a fallback. Nothing is hardcoded, the user confirms in settings
    /// (the picker shows each calendar's account).
    func guessGoogleCalendarID() -> String? {
        guard isAuthorized else { return nil }
        let candidates = store.calendars(for: .event).filter {
            $0.allowsContentModifications
                && $0.source?.sourceType == .calDAV
                && $0.source?.title.localizedCaseInsensitiveContains("icloud") != true
        }
        return (candidates.first { $0.title.contains("@") }
                ?? candidates.first { ($0.source?.title ?? "").contains("@") }
                ?? candidates.first)?.calendarIdentifier
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
            calendarItemID: e.calendarItemIdentifier,
            myStatus: myStatus(e),
            hasGuests: !(e.attendees?.isEmpty ?? true)
        )
    }

    /// F3: my own answer to the invitation. `isCurrentUser` is unreliable on
    /// some CalDAV accounts, so anything we cannot identify stays `.none` and
    /// keeps warning — one banner too many beats a missed meeting.
    private static func myStatus(_ e: EKEvent) -> MyStatus {
        guard let me = e.attendees?.first(where: { $0.isCurrentUser }) else { return .none }
        switch me.participantStatus {
        case .declined:  return .declined
        case .accepted:  return .accepted
        case .tentative: return .tentative
        default:         return .none
        }
    }

    /// Look for a video-call link in the usual fields, preferring known
    /// providers. Since F7 the provider table lives in `JoinLink` (50+ services
    /// instead of five) and is covered by `--selftest`.
    private static func findJoinURL(_ e: EKEvent) -> URL? {
        JoinLink.best(explicit: e.url, texts: [e.location, e.notes, e.url?.absoluteString])
    }
}
