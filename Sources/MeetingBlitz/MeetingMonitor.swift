import Foundation
import EventKit
import AppKit

/// Polls the selected calendars on a timer and fires a banner for EACH meeting
/// as it crosses the lead-time threshold, independently of whether another
/// meeting is running. That per-event trigger is the core differentiator over
/// tools that only ever surface the single longest event. It also flashes the
/// menu bar the moment a meeting actually starts.
@MainActor
final class MeetingMonitor {
    private unowned let state: AppState
    private var timer: Timer?
    private var alertedKeys: Set<String> = []   // lead-time banner fired
    private var startedKeys: Set<String> = []   // start blink fired
    private var autoJoinedKeys: Set<String> = [] // auto-join opened (Runde 5)
    private var endWarnedKeys: Set<String> = []  // end-of-meeting warning blinked (Runde 5)

    init(state: AppState) {
        self.state = state
    }

    func start() {
        // Re-evaluate every 20s. Cheap: two EventKit queries.
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // React to external calendar edits immediately.
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func tickNow() { tick() }

    private func tick() {
        guard state.calendarAuthorized else { return }
        let ids = state.selectedCalendarIDs
        // Two filters (Runde 40): DISPLAY = selected calendars, not hidden (the
        // widget list/timeline). ALERT = display ∩ alert-calendars (banner, blink,
        // menu bar, auto-join). So a shared calendar can show in the list but never
        // fire a banner.
        // Runde 55 adds the birthday gate to BOTH: a foreign calendar's birthdays
        // are dropped entirely, while its timed meetings pass through untouched.
        let display: (Meeting) -> Bool = { [state] in !state.isHidden($0) && state.showsBirthday($0) }
        let alert: (Meeting) -> Bool = { [state] in
            !state.isHidden($0) && state.showsBirthday($0) && state.isAlertCalendar($0)
        }

        // Alert-relevant future meetings (drives nextMeeting, banner, auto-join).
        let upcoming = state.calendar.upcomingMeetings(selected: ids).filter(alert)
        // Today, once, display list and its alert-only subset.
        let todayDisplay = state.calendar.dayAgenda(offset: 0, selected: ids).filter(display)
        let todayAlert = todayDisplay.filter { state.isAlertCalendar($0) }

        let now = Date()
        state.nextMeeting = upcoming.first
        // The call running right now (timed, no birthdays), for the menu bar.
        // Menu bar follows ALERT calendars too (a colleague's running call is noise).
        state.currentMeeting = todayAlert.first {
            !$0.isAllDay && !$0.isBirthday && $0.start <= now && $0.end > now
        }
        state.agenda = state.dayOffset == 0
            ? todayDisplay
            : state.calendar.dayAgenda(offset: state.dayOffset, selected: ids).filter(display)

        // --- Lead-time banner: fire once per occurrence inside the window. ---
        let lead = Double(state.leadMinutes) * 60
        for meeting in upcoming {
            let secondsUntil = meeting.start.timeIntervalSinceNow
            let key = alertKey(for: meeting)
            if secondsUntil > 0, secondsUntil <= lead, !alertedKeys.contains(key) {
                // Runde 5: hold back while quiet / screen sharing, but DON'T mark
                // it done, retry next tick so it still fires once un-suppressed.
                if state.bannersSuppressed { continue }
                alertedKeys.insert(key)
                state.announce(meeting)
            }
        }
        alertedKeys.formIntersection(Set(upcoming.map(alertKey(for:))))

        // --- Auto-join (Runde 5, opt-in): open the link ~10s before start. ---
        if state.autoJoin {
            for meeting in upcoming {
                guard let url = meeting.joinURL else { continue }
                let secondsUntil = meeting.start.timeIntervalSinceNow
                let key = alertKey(for: meeting)
                if secondsUntil <= 10, secondsUntil > -30, !autoJoinedKeys.contains(key) {
                    autoJoinedKeys.insert(key)
                    _ = url   // routing uses the meeting title (per-account override)
                    MeetingLauncher.join(meeting)
                }
            }
            autoJoinedKeys.formIntersection(Set(upcoming.map(alertKey(for:))))
        }

        // --- End-of-meeting warning (Runde 5): blink 5 min before the current
        // meeting ends IF another meeting follows right after. ---
        if state.endWarning {
            if let current = todayAlert.first(where: { !$0.isAllDay && $0.start <= now && $0.end > now }),
               let next = upcoming.first {
                let secToEnd = current.end.timeIntervalSince(now)
                let followsRightAfter = next.start >= current.end.addingTimeInterval(-60)
                    && next.start <= current.end.addingTimeInterval(300)
                let key = "end@\(Int(current.end.timeIntervalSince1970))"
                if followsRightAfter, secToEnd > 0, secToEnd <= 300, !endWarnedKeys.contains(key) {
                    endWarnedKeys.insert(key)
                    state.startMeetingBlink(text: L.t("Meeting endet", "Meeting ending"), ticksTotal: 10)
                }
            }
            endWarnedKeys.formIntersection(Set(todayAlert.map { "end@\(Int($0.end.timeIntervalSince1970))" }))
        }

        // --- Start blink: flash the menu bar as a meeting begins. ---
        for meeting in todayAlert where !meeting.isAllDay {
            let sinceStart = -meeting.start.timeIntervalSinceNow
            let key = alertKey(for: meeting)
            if sinceStart >= 0, sinceStart < 60, !startedKeys.contains(key) {
                startedKeys.insert(key)
                state.startMeetingBlink()
            }
        }
        startedKeys.formIntersection(Set(todayAlert.map(alertKey(for:))))

        // --- Apple Reminders (Runde 43): keep the widget's list fresh. ---
        if state.showReminders, state.remindersAuthorized {
            Task { await state.refreshReminders() }
        }
    }

    /// Occurrence-unique key: EKEvent.eventIdentifier repeats across the
    /// occurrences of a recurring event, so the start time disambiguates them.
    private func alertKey(for meeting: Meeting) -> String {
        "\(meeting.id)@\(Int(meeting.start.timeIntervalSince1970))"
    }
}
