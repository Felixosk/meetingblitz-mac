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
    @State private var createHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if state.calendarAuthorized {
                // Runde 56: Zeitachse IMMER zeigen, auch an Tagen ohne getimte
                // Termine (Rückmeldung: „warum schaut der nächste Tag nicht so aus
                // wie der heutige?"). Vorher fiel sie an solchen Tagen weg,
                // das Widget sah kaputt aus und sprang beim Tageswechsel in
                // der Höhe. Eine leere Achse trägt außerdem eine Information:
                // an diesem Tag ist nichts eingeplant.
                TimelineStrip(meetings: state.agenda.filter { !$0.isAllDay },
                              day: Calendar.current.date(byAdding: .day, value: state.dayOffset, to: Date()) ?? Date(),
                              showNow: state.dayOffset == 0) { state.openInCalendar($0) }
                agenda
                if state.showReminders && !state.reminders.isEmpty { remindersSection }
            } else {
                Button(L.t("Kalender-Zugriff erlauben", "Allow calendar access")) {
                    Task { await state.requestCalendarAccess() }
                }
                .buttonStyle(.borderedProminent)
                // Runde 56: Der Knopf darüber ist nach einer Ablehnung ein
                // Blindgänger, macOS zeigt den Dialog genau einmal, danach
                // liefert requestFullAccessToEvents stumm false zurück. Ohne
                // diesen Ausweg klickt der Nutzer auf etwas, das sichtbar
                // nichts tut, und die App bleibt für ihn kaputt.
                Button(L.t("Systemeinstellungen öffnen", "Open System Settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                Text(L.t("Hast du „Nicht erlauben“ geklickt, fragt macOS kein zweites Mal. Dann hier den Haken bei MeetingBlitz setzen.",
                         "If you clicked “Don't Allow”, macOS won't ask again. Tick MeetingBlitz there instead."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // "New Meeting" needs Google config (hidden without a Google config, Runde 36)
            // AND the settings toggle on (Runde 37).
            if google.hasConfig && state.showMeetingCreator { createButton }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .background(GeometryReader { g in
            Color.clear.preference(key: PanelSizeKey.self, value: g.size)
        })
        .onPreferenceChange(PanelSizeKey.self) { size in
            if size != .zero { onSize?(size) }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            // Day switcher (Runde 3): browse up to a week ahead.
            Button { state.dayOffset = max(0, state.dayOffset - 1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
            }
            .disabled(state.dayOffset == 0)
            .opacity(state.dayOffset == 0 ? 0.3 : 1)
            // Runde 56: EINZEILIG erzwingen. „Morgen · Samstag, 15. August" ist
            // deutlich länger als „Freitag, 14. August"; ohne Zeilenlimit bricht
            // der Titel um, der Kopf wird höher und alles darunter rutscht mit.
            // Genau das war die Meldung „der Titel bleibt nicht auf derselben Höhe".
            // Lieber minimal skalieren als umbrechen.
            Text(dayTitle)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Button { state.dayOffset = min(7, state.dayOffset + 1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            }
            .disabled(state.dayOffset == 7)
            .opacity(state.dayOffset == 7 ? 0.3 : 1)
            Spacer()
            // Countdown only while the next meeting is still TODAY, "in 16 Std"
            // for tomorrow's first call is noise (Runde 28).
            if let m = state.nextMeeting, m.start < Self.endOfToday {
                Text(m.countdownLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .buttonStyle(.borderless)
    }

    /// Full-width "Neues Meeting" button (Runde 31/32). Glassy tinted look,
    /// translucent accent + hairline + top sheen, accent label, instead of a
    /// solid slab ("glasy, apple-like"). Hand-painted: system styles AND real
    /// materials both render lifeless in this never-key panel (Runde-6/14
    /// Gotchas), explicit SwiftUI fills keep their colour.
    private var createButton: some View {
        Button { state.toggleCreatePanel() } label: {
            Label(L.t("Neues Meeting", "New Meeting"), systemImage: "video.badge.plus")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    // OPAQUE saturated accent so the translucent panel material
                    // (behindWindow) can't wash it out over a white window
                    // behind it (Runde 39). Glass sheen keeps it from
                    // looking like a flat slab.
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(
                            colors: [Color.accentColor.opacity(createHovered ? 1.0 : 0.95),
                                     Color.accentColor.opacity(createHovered ? 0.92 : 0.82)],
                            startPoint: .top, endPoint: .bottom))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(LinearGradient(
                                    colors: [Color.white.opacity(0.28), .clear],
                                    startPoint: .top, endPoint: .center))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.white.opacity(0.20), lineWidth: 0.5)
                        )
                        .shadow(color: Color.accentColor.opacity(0.25), radius: 3, y: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { createHovered = $0 }
        .hint(L.t("Legt einen Termin mit fertigem Google-Meet-Link an, Einladungstext landet in der Zwischenablage", "Creates an event with a ready Google Meet link, the invite text goes to your clipboard"), id: "create")
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
                VStack(alignment: .leading, spacing: 2) {
                    if state.agenda.isEmpty {
                        Text(L.t("Keine Termine heute", "No events today"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(state.agenda) { m in
                            AgendaRow(meeting: m,
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
                        }
                    }
                    if let h = lastHidden {
                        HStack(spacing: 6) {
                            Text(L.t("„\(h.title)“ ausgeblendet", "“\(h.title)” hidden"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button(L.t("Rückgängig", "Undo")) {
                                state.unhideMeeting(h)
                                withAnimation(.easeInOut(duration: 0.16)) { lastHidden = nil }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .buttonStyle(.borderless)
                            .foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 6).padding(.top, 4)
                        .transition(.opacity)
                    }
                }
                // Runde 56: Mindesthöhe für vier Zeilen. Ohne sie schrumpft das
                // Widget an einem Tag mit wenigen Terminen sichtbar zusammen und
                // wächst beim Zurückblättern wieder, was bei jedem Tageswechsel
                // wie ein Sprung wirkt (Rückmeldung: „es sollte alles gleich bleiben,
                // nur keine Infos drinnen"). Nach oben wächst es weiterhin frei,
                // alle Termine bleiben sichtbar (Runde 33).
                .frame(minHeight: 108, alignment: .top)
            }
        }
    }

    /// Apple Reminders due today / overdue (Runde 43). A separate block under the
    /// agenda, reminders have due times but aren't meetings. The circle marks
    /// one done (it then drops out of the list on the next refresh).
    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "checklist").font(.system(size: 10, weight: .semibold))
                Text(L.t("Erinnerungen", "Reminders"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.top, 2)
            ForEach(state.reminders) { r in
                ReminderRow(item: r) { state.completeReminder(r) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button { state.toggleSettingsPanel() } label: {
                Label(L.t("Einstellungen", "Settings"), systemImage: "gearshape")
            }
            .hint(L.t("Vorlaufzeit, Kalenderauswahl, Autostart und mehr", "Lead time, calendar selection, launch at login and more"), id: "settings")
            Spacer()
            Button(L.t("Beenden", "Quit")) { NSApp.terminate(nil) }
        }
        .font(.system(size: 12))
        .buttonStyle(.borderless)
    }

    private var dayTitle: String {
        let date = Calendar.current.date(byAdding: .day, value: state.dayOffset, to: Date()) ?? Date()
        let f = DateFormatter()
        f.locale = L.locale
        f.dateFormat = L.t("EEEE, d. MMMM", "EEEE, MMMM d")
        let s = f.string(from: date)
        return state.dayOffset == 1 ? L.t("Morgen · \(s)", "Tomorrow · \(s)") : s
    }

}

/// One agenda line. The whole row opens the event in Apple Calendar; the copy
/// and join buttons act on the meeting link without opening it.
private struct AgendaRow: View {
    let meeting: Meeting
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
    @State private var hovering = false
    /// Kurzes Häkchen nach dem .ics-Export (Runde 48), ohne Rückmeldung weiß
    /// man nicht, ob der Klick etwas getan hat.
    @State private var icsDone = false
    /// Two-step hide (Runde 30): first × click arms, second click hides.
    /// Leaving the row (or 2.5s) disarms.
    @State private var hideArmed = false

    private var isPast: Bool { meeting.end < Date() && !meeting.isAllDay && !meeting.isBirthday }


    var body: some View {
        HStack(spacing: 8) {
            if meeting.isBirthday {
                Text("🎂").font(.system(size: 12))
            } else {
                Circle().fill(meeting.color).frame(width: 8, height: 8)
            }
            Text(meeting.isBirthday || meeting.isAllDay ? "" : meeting.timeLabel)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: meeting.isBirthday || meeting.isAllDay ? 0 : 42, alignment: .leading)
            Text(meeting.title)
                .font(.system(size: 12, weight: isNext ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            if meeting.isBirthday {
                // M2: jump straight to the person in Contacts to place the call.
                if meeting.contactID != nil {
                    Button { onCallContact() } label: {
                        Image(systemName: "phone.arrow.up.right")
                            .foregroundStyle(Color.accentColor)
                    }
                    .hint(L.t("Öffnet die Person in den Kontakten, damit du sie direkt anrufen kannst", "Opens the person in Contacts so you can call them"), id: "call-\(meeting.id)")
                    .rowHint(L.t("Öffnet die Person in den Kontakten zum Anrufen", "Opens the person in Contacts to call them"))
                }
                Button { onToggleCalled() } label: {
                    Image(systemName: birthdayCalled ? "checkmark.circle.fill" : "phone")
                        .foregroundStyle(birthdayCalled ? Color.green : Color.secondary)
                }
                .rowHint(birthdayCalled ? L.t("Schon angerufen, klicken setzt es zurück", "Already called, click to reset")
                                       : L.t("Abhaken, wenn du angerufen hast", "Tick once you have called"))
                .hint(birthdayCalled ? L.t("Schon angerufen, klicken setzt es zurück", "Already called, click to reset")
                                     : L.t("Abhaken, sobald du angerufen hast (gilt nur für heute)", "Tick once you have called (today only)"), id: "called-\(meeting.id)")
            }
            if !meeting.isAllDay, !meeting.isBirthday, meeting.end > Date() {
                Text(meeting.countdownLabel)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !meeting.isAllDay, !meeting.isBirthday {
                // Kalenderdatei (Runde 48): gibt es für JEDEN Termin, auch ohne
                // Meet-Link, die .ics ist unabhängig vom Videocall nützlich.
                Button {
                    guard onICS() else { return }
                    withAnimation(.easeInOut(duration: 0.14)) { icsDone = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        withAnimation(.easeInOut(duration: 0.2)) { icsDone = false }
                    }
                } label: {
                    Image(systemName: icsDone ? "checkmark.circle.fill" : "calendar.badge.plus")
                        .foregroundStyle(icsDone ? Color.green : Color.secondary)
                }
                .hint(L.t("Speichert den Termin als .ics in ~/Downloads und legt ihn als Datei in die Zwischenablage, in WhatsApp oder Mail eingefügt wird ein Anhang daraus", "Saves the event as .ics in ~/Downloads and puts it on the clipboard as a file, paste it into WhatsApp or Mail and it becomes an attachment"), id: "ics-\(meeting.id)")
                    .rowHint(L.t("Termin als Datei sichern und kopieren", "Save the event as a file and copy it"))
            }
            if !meeting.isAllDay, !meeting.isBirthday, let url = meeting.joinURL {
                Button { onCopy(url) } label: { Image(systemName: "doc.on.doc") }
                    .hint(L.t("Kopiert den Videokonferenz-Link in die Zwischenablage", "Copies the video call link to your clipboard"), id: "copy-\(meeting.id)")
                    .rowHint(L.t("Kopiert den Link zum Videocall", "Copies the video call link"))
                Button { onJoin(url) } label: { Image(systemName: "video.fill") }
                    .hint(L.t("Öffnet den Videocall direkt im Browser", "Opens the video call in your browser"), id: "join-\(meeting.id)")
                    .rowHint(L.t("Öffnet den Videocall im Browser", "Opens the video call in your browser"))
            }
            // Hide from MeetingBlitz (Runde 27): hover-only ×, fixed slot so the
            // row doesn't shift. NOT a calendar delete, the event stays.
            // Runde 30: two-step, first click arms ("Ausblenden?"), second hides.
            Button {
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
            } label: {
                // Same glyph, same slot, arming only recolours it, so the row
                // never shifts (Runde 32: the text capsule pushed things
                // apart).
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(hideArmed ? Color.red : Color.secondary)
                    .scaleEffect(hideArmed ? 1.15 : 1)
            }
            // Reihenfolge zählt: `.help` MUSS nach `.opacity` kommen. Andernfalls
            // hängt der Tooltip an der durchsichtigen Ebene darunter und macOS
            // zeigt ihn nicht, genau dieses × war deshalb das einzige Symbol im
            // Widget ohne Erklärung.
            .opacity(hovering || hideArmed ? 1 : 0)
            .rowHint(hideArmed ? L.t("Nochmal klicken, dann ist der Termin hier weg",
                                     "Click again and the event disappears from here")
                               : L.t("Blendet den Termin nur hier aus, im Kalender bleibt er",
                                     "Hides the event here only, it stays in your calendar"))
            .hint(hideArmed ? L.t("Nochmal klicken, dann ist der Termin hier weg",
                                  "Click again and the event disappears from here")
                            : L.t("Blendet den Termin nur in MeetingBlitz aus, im Kalender bleibt er stehen",
                                  "Hides the event in MeetingBlitz only, it stays in your calendar"),
                  id: "hide-\(meeting.id)")
        }
        .font(.system(size: 11))
        .buttonStyle(.borderless)
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(hovering ? Color.primary.opacity(0.08)
                  : isNext ? Color.accentColor.opacity(0.10) : .clear))
        .opacity(isPast ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .onHover { h in
            hovering = h
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
        HStack(spacing: 8) {
            Button(action: onComplete) {
                Image(systemName: hovering ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(hovering ? Color.green : item.color)
            }
            .buttonStyle(.borderless)
            .hint(L.t("Hakt die Erinnerung ab, wirkt auch in der Erinnerungen-App", "Completes the reminder, also applies in the Reminders app"), id: "rem-\(item.id)")

            Text(item.title)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(item.isOverdue ? Color.red : Color.primary)
            Spacer(minLength: 4)
            Text(item.timeLabel)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(item.isOverdue ? Color.red.opacity(0.9) : .secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A compact MeetingBar-style timeline of the displayed day's timed meetings,
/// with a live "now" marker. Tapping a block opens that event in Apple Calendar.
private struct TimelineStrip: View {
    let meetings: [Meeting]
    let day: Date         // the day the panel is showing (dayOffset applied)
    let showNow: Bool     // false when browsing another day (Morgen-Ansicht)
    let onTap: (Meeting) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let (lo, hi) = bounds()
            let span = max(1, hi.timeIntervalSince(lo))

            ZStack(alignment: .topLeading) {
                // Track
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 22).offset(y: 16)

                // Hour ticks + labels (regular 2-h grid, only up to midnight)
                let dayEnd = lo.addingTimeInterval(24 * 3600)
                ForEach(hourMarks(lo, min(hi, dayEnd)), id: \.timeIntervalSinceReferenceDate) { d in
                    let x = w * (d.timeIntervalSince(lo) / span)
                    Rectangle().fill(Color.primary.opacity(0.10))
                        .frame(width: 1, height: 22).offset(x: x, y: 16)
                    Text(hourLabel(d)).font(.system(size: 9))
                        .foregroundStyle(.secondary).offset(x: x + 2, y: 0)
                }

                // Overnight zone: a clear midnight divider, then HOURLY marks
                // (1, 2, 3) so a block running until 01:00 visibly ends at "1"
                // instead of dying unlabelled at the axis edge (Runde 22f).
                if hi > dayEnd {
                    let mx = w * (dayEnd.timeIntervalSince(lo) / span)
                    Rectangle().fill(Color.primary.opacity(0.30))
                        .frame(width: 1.5, height: 26).offset(x: mx, y: 14)
                    Text("0").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary).offset(x: mx + 2, y: 0)
                    ForEach(1..<4, id: \.self) { h in
                        let d = dayEnd.addingTimeInterval(Double(h) * 3600)
                        if d < hi {
                            let x = w * (d.timeIntervalSince(lo) / span)
                            Rectangle().fill(Color.primary.opacity(0.10))
                                .frame(width: 1, height: 22).offset(x: x, y: 16)
                            Text("\(h)").font(.system(size: 9))
                                .foregroundStyle(.secondary).offset(x: x + 2, y: 0)
                        }
                    }
                }

                // Meeting blocks
                ForEach(meetings) { m in
                    let x0 = w * (clampToSpan(m.start, lo, hi).timeIntervalSince(lo) / span)
                    let x1 = w * (clampToSpan(m.end, lo, hi).timeIntervalSince(lo) / span)
                    let blockW = max(6, x1 - x0)
                    Button { onTap(m) } label: {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(m.color.opacity(0.9))
                            .frame(width: blockW, height: 16)
                            .overlay(alignment: .leading) {
                                // Full title, truncated with "…" to the block width.
                                if blockW > 30 {
                                    Text(m.title)
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .padding(.horizontal, 4)
                                        .frame(width: blockW, alignment: .leading)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .hint("\(m.timeLabel)  \(m.title)", id: "tl-\(m.id)")
                    .offset(x: x0, y: 19)
                }

                // Now marker (only on the real today)
                if showNow {
                    let nx = w * (min(max(0, Date().timeIntervalSince(lo)), span) / span)
                    Rectangle().fill(Color.blue).frame(width: 2, height: 30).offset(x: nx, y: 12)
                }
            }
        }
        .frame(height: 42)
    }

    private func bounds() -> (Date, Date) {
        // Always the FULL displayed day (00:00 onward), the axis never drifts
        // back to yesterday. If a meeting runs past midnight, the axis extends
        // just far enough to show it, capped at 04:00 next morning (Runde 22b).
        let lo = Calendar.current.startOfDay(for: day)
        let dayEnd = lo.addingTimeInterval(24 * 3600)
        var hi = dayEnd
        if let latestEnd = meetings.map(\.end).max(), latestEnd > dayEnd {
            // Round the latest end UP to the hour, then add 1 h head-room so the
            // block visibly ends BEFORE the axis edge (a block flush with the
            // edge read as "cut off at midnight"). Capped at 04:00.
            let rounded = ceil(latestEnd.timeIntervalSince(lo) / 3600) * 3600 + 3600
            hi = lo.addingTimeInterval(min(rounded, 28 * 3600))
        }
        return (lo, hi)
    }

    private func hourMarks(_ lo: Date, _ hi: Date) -> [Date] {
        let cal = Calendar.current
        let totalHours = hi.timeIntervalSince(lo) / 3600
        let step = totalHours > 9 ? 2 : 1
        var marks: [Date] = []
        var t = lo
        while t < hi {
            marks.append(t)
            t = cal.date(byAdding: .hour, value: step, to: t) ?? hi
        }
        return marks
    }

    private func hourLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "H"
        return f.string(from: d)
    }

    private func clampToSpan(_ d: Date, _ lo: Date, _ hi: Date) -> Date {
        min(max(d, lo), hi)
    }
}
