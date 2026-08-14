import SwiftUI
import AppKit

/// "Neues Meeting" lives in its own floating panel (Runde 27c): the inline card
/// inside the widget pushed timeline + agenda down ("nimmt viel zu viel Platz
/// weg"), the widget stays untouched and the + button opens this panel instead,
/// same mechanics as the settings panel (titled utility, key from the start so
/// the text field has focus and accents render).
@MainActor
final class CreatePanelController {
    static let shared = CreatePanelController()
    private var panel: NSPanel?
    /// Merkt sich, wohin das Panel gezogen wird (Runde 47h). `window.delegate`
    /// ist weak, also muss der Controller den Recorder halten.
    private var moveRecorder: PanelMoveRecorder?
    /// Widget-Frame vom Öffnen, fürs Nach-Platzieren im ersten resize (47i).
    private var anchorRect: CGRect?

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle(state: AppState, anchor: CGRect?) {
        if let p = panel, p.isVisible { close(); return }

        GoogleService.shared.resetCreateFeedback()

        // Runde 47j ZURÜCKGENOMMEN (siehe PROGRESS): der randlose Milchglas-Look
        // machte die Panels unklickbar. Wieder das bewährte titled Utility-Panel.
        let hosting = CreateHostingView(rootView: CreatePane(
            state: state,
            onClose: { Task { @MainActor in CreatePanelController.shared.close() } },
            onSize: { size in
                Task { @MainActor in CreatePanelController.shared.resize(to: size) }
            }))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = L.t("Neues Meeting", "New Meeting")
        p.isReleasedWhenClosed = false
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false   // key from the start → focus + accents
        p.contentView = hosting

        // Runde 47g/47h/47i: gemerkte Position gewinnt, sonst neben das Widget.
        // ⚠️ `fittingSize` ist hier oft noch (0, 24), SwiftUI hat den Inhalt
        // beim Erstellen noch nicht ausgelegt (gemessen, /tmp/mb_panel.log,
        // 47i). Mit Breite 0 rechnet „links daneben" die LINKE Kante dorthin,
        // wo das Panel nach dem Aufwachsen das Widget überdeckt. Deshalb: hier
        // nur grob platzieren, die endgültige Platzierung macht das erste
        // resize() mit der ECHTEN Größe.
        anchorRect = anchor
        let panelSize = p.frame.size
        p.setFrameOrigin(PanelDock.savedOrigin(panelSize: panelSize, id: "create")
                         ?? PanelDock.origin(panelSize: panelSize, anchor: anchor))
        p.makeKeyAndOrderFront(nil)
        // Position merken, sobald das Panel gezogen wird (Runde 47h). Startet
        // SUSPENDIERT: bis die Erstplatzierung durch ist, ist jede Bewegung
        // programmatisch und darf nicht als „gezogen" gespeichert werden.
        let recorder = PanelMoveRecorder(id: "create")
        recorder.suspended = true
        p.delegate = recorder
        moveRecorder = recorder
        panel = p
        // Runde 47i(2): Die endgültige Platzierung passiert im NÄCHSTEN
        // Runloop-Durchlauf. Grund: `fittingSize` ist beim Erstellen noch ~0
        // (Phantom), und die echte Größe kommt über ZWEI mögliche Wege,
        // AppKits preferredContentSize-Auto-Resize ODER unseren onSize-
        // Callback. Der „beim ersten resize neu platzieren"-Ansatz verfehlte
        // den ersten Weg: dort hat das Fenster schon echte Breite, bevor
        // resize() je läuft. Ein async-Hop deckt beide ab.
        DispatchQueue.main.async { [weak self] in self?.finishInitialPlacement() }
    }

    func resize(to contentSize: CGSize) {
        guard let p = panel, p.isVisible, contentSize.width > 1 else { return }
        let frameSize = p.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)).size
        let old = p.frame
        // Erstplatzierung noch offen (Recorder suspendiert)? Dann mit der
        // frischen Größe direkt richtig platzieren, nicht warten.
        if moveRecorder?.suspended == true {
            let origin = PanelDock.savedOrigin(panelSize: frameSize, id: "create")
                ?? PanelDock.origin(panelSize: frameSize, anchor: anchorRect)
            p.setFrame(CGRect(origin: origin, size: frameSize), display: true)
            moveRecorder?.suspended = false
            return
        }
        if abs(frameSize.height - old.height) < 1, abs(frameSize.width - old.width) < 1 { return }
        moveRecorder?.suspended = true
        do {
            // Normales Wachsen/Schrumpfen (Abschnitt klappt auf): Oberkante
            // bleibt stehen, clampY hält das Panel im sichtbaren Bereich
            // (Runde 47g).
            var y = old.maxY - frameSize.height
            if let vf = PanelDock.visibleFrame(containing: old) {
                y = PanelDock.clampY(y, height: frameSize.height, vf: vf)
            }
            p.setFrame(CGRect(x: old.minX, y: y.rounded(), width: frameSize.width, height: frameSize.height),
                       display: true)
        }
        moveRecorder?.suspended = false
    }

    /// Endgültige Erstplatzierung, sobald das Panel seine echte Größe hat
    /// (Runde 47i(2)). Läuft einen Runloop nach dem Öffnen; falls resize()
    /// schneller war (suspended schon false), tut sie nichts.
    private func finishInitialPlacement() {
        guard let p = panel, p.isVisible, moveRecorder?.suspended == true else { return }
        let size = p.frame.size
        guard size.width > 50 else { return }   // immer noch Phantom → resize() übernimmt
        p.setFrameOrigin(PanelDock.savedOrigin(panelSize: size, id: "create")
                         ?? PanelDock.origin(panelSize: size, anchor: anchorRect))
        moveRecorder?.suspended = false
    }

    func close() {
        panel?.delegate = nil
        moveRecorder = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Lets the widget's dismiss monitor keep both open on clicks in here.
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === panel }
}

/// First click must land even though the accessory app is rarely "active".
private final class CreateHostingView: NSHostingView<CreatePane> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    required init(rootView: CreatePane) { super.init(rootView: rootView) }
    @objc required dynamic init?(coder: NSCoder) { fatalError("not used") }
}

private struct CreateSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// The create form: title, start, duration → one click writes the event into
/// the Apple calendar with a fresh Meet link (copied to the clipboard).
struct CreatePane: View {
    @ObservedObject var state: AppState
    @ObservedObject var google = GoogleService.shared
    /// Ersetzt den weggefallenen Schließen-Knopf der Titelleiste (Runde 47j).
    var onClose: (@Sendable () -> Void)? = nil
    var onSize: (@Sendable (CGSize) -> Void)? = nil

    @State private var newTitle = ""
    @State private var newStart = Self.nextQuarterHour()
    @State private var newMinutes = 30
    /// Repeat rule (Runde 43): `.none` writes a single event, otherwise a series.
    @State private var newRepeat: RepeatRule = .none
    @State private var repeatOpen = false
    /// Custom recurrence spec, used when `newRepeat == .custom` (Runde 43b).
    @State private var customRec = CustomRecurrence()
    /// Which account this meeting's Meet link opens as (Runde 43), remembered by
    /// title so a weekly series inherits it.
    @State private var newAccount: MeetAccountChoice = .work
    /// Target Apple calendar (Runde 28): remembered across meetings; empty →
    /// system default. The picker expands inline, a .menu picker would hang in
    /// this nonactivating panel (Runde-13-Gotcha).
    @AppStorage("createCalendarID") private var chosenCalendarID = ""
    @State private var calendarListOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let link = google.lastMeetLink {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L.t("Termin erstellt · Details kopiert", "Event created · details copied"))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(google.lastShareText ?? link, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help(L.t("Titel + Zeit + Meet-Link nochmal kopieren",
                                  "Copy title + time + Meet link again"))
                }
                Text(link)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                // Kalenderdatei (Runde 47): liegt in ~/Downloads. „Kopieren" legt
                // die DATEI in die Zwischenablage, in WhatsApp/Mail eingefügt
                // wird daraus ein Anhang, kein Pfad-Text.
                if let ics = google.lastICSURL {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(ics.lastPathComponent)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { ICSExport.copyToPasteboard(ics) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help(L.t("Kalenderdatei kopieren, in den Chat einfügen = Anhang",
                                      "Copy the calendar file, paste into a chat as an attachment"))
                        Button { ICSExport.revealInFinder(ics) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
                            .help(L.t("Im Finder zeigen (~/Downloads)", "Show in Finder (~/Downloads)"))
                    }
                }
                if let note = google.lastArtifactNote {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "text.bubble").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button(L.t("Noch einen erstellen", "Create another")) {
                    google.resetCreateFeedback()
                    newTitle = ""
                    newStart = Self.nextQuarterHour()
                }
                .font(.system(size: 12)).buttonStyle(.borderless)
            } else if !google.isConnected {
                // Runde 48: abgelaufene Sitzung beim Namen nennen statt „einmal
                // verbinden", sonst wirkt es wie ein Erstsetup, obwohl es der
                // 7-Tage-Ablauf des Testing-Modus ist.
                Text(google.needsReconnect
                     ? L.t("Google-Verbindung abgelaufen. Einmal neu verbinden, dann geht es weiter.",
                           "Google session expired. Reconnect once and you're good.")
                     : L.t("Einmal mit Google verbinden, danach erstellt MeetingBlitz Termine mit automatischem Meet-Link.",
                           "Connect Google once, MeetingBlitz then creates events with an automatic Meet link."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(google.busy ? L.t("Verbinde…", "Connecting…") : L.t("Mit Google verbinden", "Connect Google")) {
                    Task { await google.connect() }
                }
                .disabled(google.busy)
            } else {
                // Title a touch bigger so it reads as THE title (Runde 30).
                TextField(L.t("Titel (z. B. Call mit Anna)", "Title (e.g. Call with Anna)"), text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))

                // Runde 47f: KEIN Scrollbereich mehr. Der Versuch (47c–47e) hat
                // dreimal hintereinander Layout-Ärger produziert, zu kleine
                // gemessene Höhe, unten verankerter Inhalt, überstehende Breite.
                // Das Formular passt ohne die beiden doppelten Toggles in jedem
                // Zustand auf den Bildschirm (~650pt normal, ~850pt mit
                // aufgeklappter Wiederholung UND Kalenderliste, bei ~1140pt
                // sichtbarer Höhe), also braucht es keins. Der Button steht
                // dadurch wieder direkt unter der letzten Zeile.
                // Falls das Panel je wieder zu hoch wird (kleinerer Screen als
                // gemeldet), stehen die drei Gotchas des Scroll-Versuchs in
                // PROGRESS.md Runde 47c–47e.
                formFields

                Divider()
                createButton
                Text(state.createICSFile
                     ? L.t("Meet-Link hängt am Termin · .ics landet in ~/Downloads",
                           "Meet link attached · .ics saved to ~/Downloads")
                     : L.t("Meet-Link hängt automatisch am Termin",
                           "Meet link is attached automatically"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = google.lastError {
                Text(err).font(.system(size: 10)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 288)
        .background(GeometryReader { g in
            Color.clear.preference(key: CreateSizeKey.self, value: g.size)
        })
        .onPreferenceChange(CreateSizeKey.self) { size in
            if size != .zero { onSize?(size) }
        }
    }

    // MARK: - Formular (scrollender Teil)

    /// Alles zwischen Titelfeld und Erstellen-Button.
    @ViewBuilder private var formFields: some View {
        Group {
                // Custom month grid (Runde 29): the AppKit .graphical picker
                // rendered as a squashed grey box ("katastrophal"), this one
                // fills the panel width in the Apple Calendar look.
                MonthGrid(selection: $newStart)

                HStack(spacing: 6) {
                    Text(L.t("Uhrzeit", "Time")).font(.system(size: 12))
                    Spacer()
                    // .stepperField: inline, digits directly typeable.
                    DatePicker("", selection: $newStart, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.stepperField)
                }
                // Slot list always in full view (Runde 30), no chevron.
                TimeSlotList(selection: $newStart)

                HStack {
                    Text(L.t("Dauer", "Duration")).font(.system(size: 12))
                    Text("min").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $newMinutes) {
                        Text("15").tag(15)
                        Text("30").tag(30)
                        Text("45").tag(45)
                        Text("60").tag(60)
                        Text("90").tag(90)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }

                // Repeat (Runde 43): inline expander, 5 options don't fit a
                // segmented control, and a .menu picker hangs in this panel.
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { repeatOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(L.t("Wiederholung", "Repeat")).font(.system(size: 12)).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: newRepeat == .none ? "arrow.right" : "arrow.trianglehead.2.clockwise")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        Text(newRepeat == .custom ? customRec.summary : newRepeat.label)
                            .font(.system(size: 12)).lineLimit(1)
                        Image(systemName: repeatOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                if repeatOpen {
                    VStack(spacing: 1) {
                        ForEach(RepeatRule.allCases) { rule in
                            Button {
                                newRepeat = rule
                                withAnimation(.easeInOut(duration: 0.16)) { repeatOpen = false }
                            } label: {
                                HStack {
                                    Text(rule.label).font(.system(size: 12))
                                    Spacer()
                                    if rule == newRepeat {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 3).padding(.horizontal, 6)
                                .background(RoundedRectangle(cornerRadius: 5)
                                    .fill(rule == newRepeat ? Color.accentColor.opacity(0.14) : .clear))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    .transition(.opacity)
                }
                if newRepeat == .custom { customBuilder }

                // Which account the Meet link opens as (Runde 43). "Arbeit" =
                // you@work-domain.example via authuser, "Privat" = Chrome's
                // default account. Remembered by title, so a series inherits it.
                HStack {
                    Text(L.t("Öffnen als", "Open as")).font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $newAccount) {
                        Text(L.t("Arbeit", "Work")).tag(MeetAccountChoice.work)
                        Text(L.t("Privat", "Personal")).tag(MeetAccountChoice.personal)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }

                // Target calendar: current choice as a row, tap → inline list of
                // writable calendars (expands the panel; remembered via defaults).
                let writable = state.calendar.writableCalendars()
                let currentID = currentCalendarID
                let current = writable.first { $0.id == currentID }
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { calendarListOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(L.t("Kalender", "Calendar")).font(.system(size: 12)).foregroundStyle(.primary)
                        Spacer()
                        Circle().fill(current?.color ?? .gray).frame(width: 8, height: 8)
                        Text(current?.title ?? L.t("Standard", "Default"))
                            .font(.system(size: 12)).lineLimit(1)
                        Image(systemName: calendarListOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                if calendarListOpen {
                    // Same look & scroll behaviour as the time list (Runde 32).
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(writable) { c in
                                Button {
                                    chosenCalendarID = c.id
                                    withAnimation(.easeInOut(duration: 0.16)) { calendarListOpen = false }
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle().fill(c.color).frame(width: 8, height: 8)
                                        Text(c.title).font(.system(size: 12)).lineLimit(1)
                                        Spacer()
                                        if c.id == currentID {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 3).padding(.horizontal, 6)
                                    .background(RoundedRectangle(cornerRadius: 5)
                                        .fill(c.id == currentID ? Color.accentColor.opacity(0.14) : .clear))
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    // FIXED height, a scroll view has no intrinsic height and
                    // collapses to zero in fitting-size panels (Runde-14-Gotcha).
                    .frame(height: min(CGFloat(writable.count) * 25 + 4, 92))
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    .transition(.opacity)
                }

                // Sprache der Einladung direkt beim Erstellen umschaltbar
                // (Runde 51, Rückmeldung: „dass ich hier noch schnell einspannen kann,
                // Englisch oder Deutsch"). Bindet bewusst an DIESELBE Einstellung
                // wie die Einstellungen-Seite: eine Wahrheit statt eines zweiten,
                // unsichtbaren Pro-Meeting-Zustands. Wer hier umschaltet, ändert
                // damit auch den Standard fürs nächste Mal.
                HStack {
                    Text(L.t("Einladung", "Invite")).font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $state.inviteLanguage) {
                        Text("EN").tag("en")
                        Text("DE").tag("de")
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }

                // Runde 47d: Die Toggles für .ics und Auto-Transkript sind hier
                // RAUS. Beides sind app-weite Einstellungen (Settings → Google),
                // sie standen doppelt und haben das Formular künstlich verlängert.
                // Was passiert, sagt jetzt die Zeile unter dem Erstellen-Button.
        }
    }

    // MARK: - Fuß (steht immer sichtbar unter dem Formular)

    private var createButton: some View {
        Button {
            // Remember the account choice by the title the event gets, so
            // the join button + a weekly series open the right account.
            let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            state.setMeetChoice(newAccount, forTitle: t.isEmpty ? "Meeting" : t)
            Task {
                if await google.createAppleMeeting(title: newTitle, start: newStart,
                                                   minutes: newMinutes,
                                                   calendarID: currentCalendarID,
                                                   recurrence: newRepeat,
                                                   custom: newRepeat == .custom ? customRec : nil,
                                                   autoTranscribe: state.autoTranscribe,
                                                   makeICS: state.createICSFile,
                                                   calendarService: state.calendar) {
                    state.monitor.tickNow()   // show it in agenda/timeline right away
                }
            }
        } label: {
            HStack(spacing: 6) {
                if google.busy { ProgressView().controlSize(.small) }
                Text(google.busy ? L.t("Erstelle…", "Creating…")
                                 : L.t("Erstellen & Link kopieren", "Create & copy link"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(google.busy)
    }

    /// Zielkalender: die eigene Wahl, sonst der Systemstandard. Wird vom
    /// Formular UND vom Erstellen-Button gebraucht, deshalb hier zentral.
    private var currentCalendarID: String? {
        chosenCalendarID.isEmpty ? state.calendar.defaultCalendarID : chosenCalendarID
    }

    /// Custom recurrence editor (Runde 43b): "every N days/weeks/months", plus
    /// weekday chips for the weekly case ("jeden Montag, Dienstag").
    private var customBuilder: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L.t("Alle", "Every")).font(.system(size: 12))
                Stepper(value: $customRec.interval, in: 1...30) {
                    Text("\(customRec.interval)").font(.system(size: 12).monospacedDigit())
                }
                .fixedSize()
                Picker("", selection: $customRec.unit) {
                    ForEach(CustomRecurrence.Unit.allCases) { u in Text(u.label).tag(u) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            if customRec.unit == .weeks {
                HStack(spacing: 4) {
                    ForEach(CustomRecurrence.weekdayOrder, id: \.ek) { day in
                        let on = customRec.weekdays.contains(day.ek)
                        Button {
                            if on { customRec.weekdays.remove(day.ek) }
                            else { customRec.weekdays.insert(day.ek) }
                        } label: {
                            Text(day.label)
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 30, height: 24)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(on ? Color.accentColor : Color.primary.opacity(0.08)))
                                .foregroundStyle(on ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(L.t("Keine Auswahl = am Wochentag des Termins.",
                         "None selected = on the event's own weekday."))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .transition(.opacity)
    }

    /// Default start for a new meeting: the next quarter-hour from now.
    private static func nextQuarterHour() -> Date {
        Date(timeIntervalSinceReferenceDate:
                ceil(Date().timeIntervalSinceReferenceDate / 900) * 900)
    }
}

/// Hand-drawn month calendar in the Apple Calendar look (Runde 29): full panel
/// width, Monday-first, round accent selection, today tinted, chevrons + "•"
/// (jump back to today) in the header. Keeps the time-of-day of `selection`.
private struct MonthGrid: View {
    @Binding var selection: Date
    @State private var shownMonth: Date

    init(selection: Binding<Date>) {
        _selection = selection
        let cal = Calendar.current
        _shownMonth = State(initialValue:
            cal.dateInterval(of: .month, for: selection.wrappedValue)?.start
            ?? cal.startOfDay(for: selection.wrappedValue))
    }

    private var cal: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2   // Monday, like Apple Calendar in DE
        return c
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                Text(monthTitle)
                    .font(.system(size: 13, weight: .semibold))
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
            }
            .buttonStyle(.borderless)

            HStack(spacing: 0) {
                ForEach(L.isDE ? ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
                               : ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"], id: \.self) { d in
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
                    let inMonth = cal.isDate(day, equalTo: shownMonth, toGranularity: .month)
                    let isSelected = day == selectedDay
                    let isToday = day == today
                    Button { pick(day) } label: {
                        Text("\(cal.component(.day, from: day))")
                            .font(.system(size: 11.5, weight: isSelected || isToday ? .semibold : .regular))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: 20)
                            .background(
                                Circle()
                                    .fill(isSelected ? Color.accentColor
                                          : isToday ? Color.accentColor.opacity(0.18) : .clear)
                                    .frame(width: 20, height: 20)
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

    /// 6 fixed weeks starting at the Monday on/before the 1st, a stable-height
    /// grid that always shows the neighbour-month fringe like Apple Calendar.
    private func gridDays() -> [Date] {
        guard let first = cal.dateInterval(of: .month, for: shownMonth)?.start,
              let gridStart = cal.dateInterval(of: .weekOfYear, for: first)?.start
        else { return [] }
        return (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private func pick(_ day: Date) {
        // Keep the chosen clock time, swap the calendar day.
        let t = cal.dateComponents([.hour, .minute], from: selection)
        selection = cal.date(bySettingHour: t.hour ?? 9, minute: t.minute ?? 0,
                             second: 0, of: day) ?? day
        if !cal.isDate(day, equalTo: shownMonth, toGranularity: .month) {
            shownMonth = cal.dateInterval(of: .month, for: day)?.start ?? shownMonth
        }
    }

    private func step(_ by: Int) {
        shownMonth = cal.date(byAdding: .month, value: by, to: shownMonth) ?? shownMonth
    }

    private func jumpToToday() {
        let today = cal.startOfDay(for: Date())
        shownMonth = cal.dateInterval(of: .month, for: today)?.start ?? shownMonth
        pick(today)
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = L.locale
        f.dateFormat = "LLLL yyyy"
        return f.string(from: shownMonth)
    }
}

/// Scrollable quarter-hour picker (Runde 29/30: always in full view),
/// pre-scrolled to the current selection; a tap just picks, the list stays.
private struct TimeSlotList: View {
    @Binding var selection: Date

    var body: some View {
        let cal = Calendar.current
        let current = cal.component(.hour, from: selection) * 4
            + cal.component(.minute, from: selection) / 15
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(0..<96, id: \.self) { slot in
                        let label = String(format: "%02d:%02d", slot / 4, (slot % 4) * 15)
                        Button {
                            selection = cal.date(bySettingHour: slot / 4, minute: (slot % 4) * 15,
                                                 second: 0, of: selection) ?? selection
                        } label: {
                            HStack {
                                Text(label).font(.system(size: 12).monospacedDigit())
                                Spacer()
                                if slot == current {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(slot == current ? Color.accentColor.opacity(0.14) : .clear))
                        }
                        .buttonStyle(.borderless)
                        .id(slot)
                    }
                }
            }
            // FIXED height (scroll views collapse in fitting-size panels).
            .frame(height: 92)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .onAppear { proxy.scrollTo(current, anchor: .center) }
        }
    }
}
