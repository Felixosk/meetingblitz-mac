import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Settings (persisted)
    @Published var leadMinutes: Int { didSet { d.set(leadMinutes, forKey: "leadMinutes") } }
    @Published var soundEnabled: Bool { didSet { d.set(soundEnabled, forKey: "soundEnabled") } }
    @Published var animationSeconds: Double { didSet { d.set(animationSeconds, forKey: "animationSeconds") } }
    /// Dramatic entrance when the banner flies in (Runde 6, toggleable; Runde 72:
    /// renamed from "Sprung aus dem Wasser" — jetzt gilt er für BEIDE Elemente,
    /// Wasser springt aus dem Meer, Luft bricht aus einer Wolke hervor, siehe
    /// `currentSkinElement`). UserDefaults-Key bleibt "waterEffect", damit eine
    /// bereits gesetzte Einstellung nicht zurückgesetzt wird.
    @Published var dramaticEntrance: Bool { didSet { d.set(dramaticEntrance, forKey: "waterEffect") } }
    /// Lässt das Flugobjekt über die Kapsel hinausragen, damit es körperlich
    /// davor steht statt darin zu sitzen (Runde 71). Standard aus, weil es nur
    /// hohen Motiven schmeichelt: ein langes flaches U-Boot wird dabei so
    /// breit, dass die Breitengrenze greift und kaum noch etwas übersteht.
    @Published var skinOversize: Bool { didSet { d.set(skinOversize, forKey: "skinOversize") } }
    /// Größe der Banner-KAPSEL (Balken mit Titel und Knöpfen), 24.08.2026.
    ///
    /// WARUM getrennt vom Motiv: Am 20.08. wurde auf die Rückmeldung „das Banner
    /// ist zu klein" EIN Faktor 1.35 eingeführt, der beides zugleich vergrößert
    /// hat. Gemeint war aber nur das TIER, nicht der Balken — der wirkte danach
    /// fett. Seitdem hängen Kapsel und Motiv an zwei Werten: dieser hier regelt
    /// nur die Kapsel, `BannerContentView.motifScale` bleibt davon unberührt,
    /// das Motiv behält also seine Wucht, egal wie schlank der Balken steht.
    /// 1.0 = der Stand vor dem 20.08.
    @Published var bannerScale: Double { didSet { d.set(bannerScale, forKey: "bannerScale") } }
    /// Which flying object shows in the banner (20.08.2026 Skin-Feature).
    /// `.classic` keeps the original Canvas-drawn U-Boot; the other styles
    /// pick one of the 27 SVG motifs below by `skinID`.
    @Published var skinStyle: SkinStyle { didSet { d.set(skinStyle.rawValue, forKey: "skinStyle") } }
    @Published var skinID: String { didSet { d.set(skinID, forKey: "skinID") } }
    /// Ob das Motiv von Banner zu Banner wechselt (23.08.2026).
    @Published var skinRotation: SkinRotation { didSet { d.set(skinRotation.rawValue, forKey: "skinRotation") } }
    /// Welche Motive am Wechsel teilnehmen. **Leer = alle**, dieselbe
    /// Konvention wie bei den Kalendern: ohne sie müsste beim ersten Start eine
    /// Liste aller 27 Kennungen in die Einstellungen geschrieben werden, und
    /// ein später dazukommendes Motiv wäre von Anfang an ausgeschlossen.
    @Published var skinPool: Set<String> { didSet { d.set(Array(skinPool), forKey: "skinPool") } }
    /// The currently selected motif, falling back to the first one if the
    /// stored id is stale (e.g. after an asset rename).
    var currentSkin: Skin { Skin.byID[skinID] ?? Skin.all[0] }

    /// Motive, die am Wechsel teilnehmen, in Rasterreihenfolge.
    var rotationSkins: [Skin] {
        skinPool.isEmpty ? Skin.all : Skin.all.filter { skinPool.contains($0.id) }
    }

    /// Ein Motiv in den Wechsel aufnehmen oder herausnehmen.
    func toggleSkinInPool(_ id: String) {
        // Erste Abwahl schreibt „alle" aus (sonst hiesse leer weiterhin alle und
        // das Abwählen bliebe wirkungslos).
        if skinPool.isEmpty { skinPool = Set(Skin.all.map(\.id)) }
        if skinPool.contains(id) { skinPool.remove(id) } else { skinPool.insert(id) }
        // Gar kein Motiv ist kein sinnvoller Zustand, das Banner braucht eines.
        if skinPool.isEmpty { skinPool = [id] }
    }

    /// Vor jedem Flug das nächste Motiv setzen.
    ///
    /// Bewusst über `skinID` selbst statt über einen zweiten „aktuell
    /// fliegenden"-Wert: Bild, Element (Wasser oder Luft) und Übergröße hängen
    /// alle schon an dieser einen Kennung, und im Einstellungsraster ist danach
    /// zu sehen, was zuletzt geflogen ist.
    func advanceSkinIfRotating() {
        guard skinStyle != .classic else { return }
        if let next = SkinRotationEngine.next(after: skinID, pool: rotationSkins, mode: skinRotation) {
            skinID = next
        }
    }
    /// Whether the CURRENT selection is a water or air motif (Rückmeldung
    /// 20.08.: ein Jet springt nicht aus dem Meer). The classic U-Boot always
    /// counts as water, it has no `Skin` entry of its own.
    var currentSkinElement: SkinElement { skinStyle == .classic ? .water : currentSkin.element }
    // Runde 5 feature toggles.
    @Published var quietMode: Bool {
        didSet {
            d.set(quietMode, forKey: "quietMode")
            // Von Hand ausgeschaltet hebt jede laufende Frist auf.
            if !quietMode { quietUntil = nil }
        }
    }
    /// Ruhe bis zu diesem Zeitpunkt (nil = unbefristet, solange `quietMode` an
    /// ist). Damit lässt sich Ruhe „für 5 Stunden" schalten, ohne dass man sie
    /// später von Hand zurücknehmen muss — genau das vergisst man sonst und
    /// wundert sich tagelang über ausbleibende Banner.
    @Published var quietUntil: Date? {
        didSet {
            d.set(quietUntil?.timeIntervalSince1970 ?? 0, forKey: "quietUntil")
        }
    }

    /// Ruhe für eine Dauer einschalten. `nil` = unbefristet.
    func startQuiet(hours: Double?) {
        quietUntil = hours.map { Date().addingTimeInterval($0 * 3600) }
        quietMode = true
    }

    /// Läuft die Frist ab, schaltet sich die Ruhe selbst wieder aus. Wird vom
    /// Monitor-Takt aufgerufen, nicht per Timer: ein Timer über eine Woche
    /// überlebt weder Ruhezustand noch Neustart.
    func expireQuietIfNeeded() {
        guard quietMode, let until = quietUntil, until <= Date() else { return }
        quietUntil = nil
        quietMode = false
    }

    /// Restlaufzeit als Text für die Einstellungen („noch 4 Std 12 Min").
    var quietRemainingLabel: String? {
        guard quietMode, let until = quietUntil, until > Date() else { return nil }
        return hmLabel(max(1, Int(until.timeIntervalSinceNow / 60)))
    }
    @Published var quietDuringScreenShare: Bool { didSet { d.set(quietDuringScreenShare, forKey: "quietDuringScreenShare") } }
    @Published var autoJoin: Bool { didSet { d.set(autoJoin, forKey: "autoJoin") } }
    @Published var endWarning: Bool { didSet { d.set(endWarning, forKey: "endWarning") } }
    /// Multi-monitor: which screen the sub launches from (index in left→right
    /// order) and which way it travels across the screens (Runde 12). With one
    /// screen these are ignored.
    @Published var crossScreenStartIndex: Int { didSet { d.set(crossScreenStartIndex, forKey: "crossScreenStartIndex") } }
    @Published var crossScreenToRight: Bool { didSet { d.set(crossScreenToRight, forKey: "crossScreenToRight") } }
    /// App-wide UI + invite language ("en"/"de", Runde 35). @Published so every
    /// observing view re-renders live; strings resolve through L.t.
    @Published var appLanguage: String { didSet { d.set(appLanguage, forKey: "appLanguage") } }
    /// Whether the widget shows the "New Meeting" (Google Meet) button (Runde 37,
    /// settings toggle). Only meaningful where Google is configured.
    @Published var showMeetingCreator: Bool { didSet { d.set(showMeetingCreator, forKey: "showMeetingCreator") } }
    /// F11: the one-click "Sofort-Meeting" button in the widget (mint a Meet,
    /// event starts now, room opens). Gated by Google config like the creator.
    @Published var showInstantMeeting: Bool { didSet { d.set(showInstantMeeting, forKey: "showInstantMeeting") } }
    /// F11: where meetings from the FORM are written — Google, Apple, or both.
    @Published var createTarget: CreateTarget {
        didSet {
            d.set(createTarget.rawValue, forKey: "createTarget")
            // Picking a Google side without a target yet: guess it, so the
            // choice works without a second decision. Never hardcoded.
            if createTarget.usesGoogle && googleTargetCalendarID.isEmpty {
                googleTargetCalendarID = calendar.guessGoogleCalendarID() ?? ""
            }
        }
    }
    /// F11: the same choice for the INSTANT button, kept separate on purpose
    /// (Rückmeldung 18.08.): an ad-hoc call has no business in the private
    /// calendar, while a planned meeting usually belongs in both.
    @Published var instantTarget: CreateTarget {
        didSet {
            d.set(instantTarget.rawValue, forKey: "instantTarget")
            if instantTarget.usesGoogle && googleTargetCalendarID.isEmpty {
                googleTargetCalendarID = calendar.guessGoogleCalendarID() ?? ""
            }
        }
    }
    /// F11: which calendar is "the Google calendar" (picked in settings).
    @Published var googleTargetCalendarID: String {
        didSet { d.set(googleTargetCalendarID, forKey: "googleTargetCalendarID") }
    }
    /// F11: the counterpart for the Apple side, so a target is pickable for
    /// BOTH options. Empty = the create form's choice / the system default.
    @Published var appleTargetCalendarID: String {
        didSet { d.set(appleTargetCalendarID, forKey: "appleTargetCalendarID") }
    }
    /// F11: transient error line under the instant button (not persisted).
    @Published var instantError: String?

    // MARK: - Meet account routing (Runde 43)

    /// Open Google Meet links in Chrome as a specific account instead of the
    /// system default browser / default account.
    @Published var meetRoutingEnabled: Bool { didSet { d.set(meetRoutingEnabled, forKey: "meetRoutingEnabled") } }
    /// The "work" account Meet links open as (authuser). Defaults to the
    /// connected Google account (you@work-domain.example).
    @Published var meetRoutingAccount: String { didSet { d.set(meetRoutingAccount, forKey: "meetRoutingAccount") } }
    /// Which Chrome profile directory to use ("Default" for a single
    /// profile). Advanced; not surfaced unless needed.
    @Published var meetChromeProfile: String { didSet { d.set(meetChromeProfile, forKey: "meetChromeProfile") } }
    /// Per-meeting account override keyed by normalised title, so a weekly series
    /// inherits it. Value is a MeetAccountChoice raw value.
    @Published var meetRoutingOverrides: [String: String] {
        didSet { d.set(meetRoutingOverrides, forKey: "meetRoutingOverrides") }
    }

    /// Auto-enable Google Meet transcription for meetings created in MeetingBlitz
    /// (Runde 43). Off by default: needs a Google reconnect for the new scope and
    /// a Workspace edition that supports auto-transcripts (~Business Plus+).
    @Published var autoTranscribe: Bool { didSet { d.set(autoTranscribe, forKey: "autoTranscribe") } }

    /// Show Apple Reminders (due today / overdue) in the widget (Runde 43).
    @Published var showReminders: Bool { didSet { d.set(showReminders, forKey: "showReminders") } }

    /// Während eines laufenden Meetings nur den Countdown in der Menüleiste
    /// zeigen statt „Titel · noch 54m" (Runde 47, Rückmeldung: „wenn ich im Meeting
    /// selber bin, flackert das, ist zu sehen, ist nicht zu sehen").
    /// Grund siehe `AppDelegate.maxMenuBarWidth`: genau dann laufen RecBlitz'
    /// Aufnahme-Pille und die orange Mikrofon-Pille mit, das Breitenbudget der
    /// Menüleiste reißt und macOS wirft unser Item raus und wieder rein.
    @Published var compactMenuBarInMeeting: Bool {
        didSet { d.set(compactMenuBarInMeeting, forKey: "compactMenuBarInMeeting") }
    }

    /// Sprache des Einladungstextes („auto" = wie die App, sonst „de"/„en").
    /// Getrennt von `appLanguage`, weil die App auf Deutsch bedient wird, die
    /// Einladung aber an internationale Empfänger geht (Runde 50). Default
    /// Englisch, das ist der häufigere Fall bei ihm.
    @Published var inviteLanguage: String { didSet { d.set(inviteLanguage, forKey: "inviteLanguage") } }

    /// F1: second time zone under the widget header (e.g. the team back in
    /// Germany). Hides itself while it matches the Mac's own zone.
    @Published var secondZoneEnabled: Bool { didSet { d.set(secondZoneEnabled, forKey: "secondZoneEnabled") } }
    @Published var secondZoneID: String { didSet { d.set(secondZoneID, forKey: "secondZoneID") } }

    /// Beim Erstellen eines Meetings zusätzlich eine .ics-Datei nach ~/Downloads
    /// schreiben (Runde 47). Der Textblock geht wie gehabt in die Zwischenablage.
    @Published var createICSFile: Bool { didSet { d.set(createICSFile, forKey: "createICSFile") } }

    /// Whether the first-run walkthrough has been completed (Runde 56). This app
    /// is an accessory: no dock icon, no window. Without a walkthrough a new user
    /// starts it, sees NOTHING happen, and reasonably concludes it is broken.
    /// Resettable from settings so it can be replayed on a new machine.
    @Published var onboardingDone: Bool {
        didSet { d.set(onboardingDone, forKey: "onboardingDone") }
    }

    /// Global hotkey (⌃⌥M) to open the widget on the active display (Runde 44).
    /// The AppDelegate fills `onHotkeyToggle` to (un)register the Carbon hotkey.
    @Published var hotkeyEnabled: Bool {
        didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled"); onHotkeyToggle?(hotkeyEnabled) }
    }
    var onHotkeyToggle: ((Bool) -> Void)?
    /// F5: die beiden Kürzel, frei belegbar. Das LABEL wird beim Aufnehmen
    /// mitgespeichert, damit keine Rückübersetzung von Tastencodes nötig ist.
    @Published var hotkeyWidgetKey: Int { didSet { d.set(hotkeyWidgetKey, forKey: "hotkeyWidgetKey") } }
    @Published var hotkeyWidgetMods: Int { didSet { d.set(hotkeyWidgetMods, forKey: "hotkeyWidgetMods") } }
    @Published var hotkeyWidgetLabel: String { didSet { d.set(hotkeyWidgetLabel, forKey: "hotkeyWidgetLabel") } }
    @Published var hotkeyJoinKey: Int { didSet { d.set(hotkeyJoinKey, forKey: "hotkeyJoinKey") } }
    @Published var hotkeyJoinMods: Int { didSet { d.set(hotkeyJoinMods, forKey: "hotkeyJoinMods") } }
    @Published var hotkeyJoinLabel: String { didSet { d.set(hotkeyJoinLabel, forKey: "hotkeyJoinLabel") } }
    /// Kürzel, die das System schon belegt hat (nicht persistiert).
    @Published var hotkeyConflict: String?
    /// Mirrors the real SMAppService state so the checkbox reflects reality
    /// (Runde 4 bug: the toggle never turned blue because nothing re-rendered).
    @Published var launchAtLogin: Bool = false
    @Published var selectedCalendarIDs: Set<String> {
        didSet { d.set(Array(selectedCalendarIDs), forKey: "selectedCalendarIDs") }
    }
    /// Which calendars actually trigger the U-Boot banner + blink (Runde 40).
    /// Separate from the display selection above: the user sees a shared calendar in
    /// the list but doesn't want a banner for it. EMPTY = "all alert" (default,
    /// preserves old behaviour); the first un-check materialises the full set.
    @Published var alertCalendarIDs: Set<String> {
        didSet { d.set(Array(alertCalendarIDs), forKey: "alertCalendarIDs") }
    }
    /// Which calendars may contribute BIRTHDAYS (Runde 55). The case that drove
    /// this: someone else tracks their family's birthdays in a calendar that is
    /// shared into your view, so the widget showed them with 🎂 and a call button
    /// for people you are never going to ring. Separate from the two sets above
    /// because their real, timed meetings should still show. EMPTY = "all",
    /// same convention as alertCalendarIDs.
    @Published var birthdayCalendarIDs: Set<String> {
        didSet { d.set(Array(birthdayCalendarIDs), forKey: "birthdayCalendarIDs") }
    }
    /// When on, the row's × hides EVERY occurrence of that title in that calendar,
    /// not just today's (Runde 55). A yearly birthday hidden with the old
    /// occurrence key came straight back next year.
    @Published var hidePermanently: Bool {
        didSet { d.set(hidePermanently, forKey: "hidePermanently") }
    }
    /// Titles hidden for good, keyed "calendarID|lowercased title" (see above).
    /// Deliberately NOT date-pruned, that is the whole point.
    @Published var hiddenTitleKeys: Set<String> {
        didSet { d.set(Array(hiddenTitleKeys), forKey: "hiddenTitleKeys") }
    }
    /// Birthdays marked as "already called", keyed "yyyy-MM-dd|eventID".
    /// Past days are pruned on launch, the state only matters on the day itself.
    @Published var calledBirthdayKeys: Set<String> {
        didSet { d.set(Array(calledBirthdayKeys), forKey: "calledBirthdayKeys") }
    }
    /// Meetings hidden from MeetingBlitz via the row's × (Runde 27). Hidden ≠
    /// deleted: the event stays in the calendar, it just stops appearing in the
    /// widget and stops triggering banners/blinks. Keyed
    /// "yyyy-MM-dd|id@startEpoch" (occurrence-unique), past days pruned on launch.
    @Published var hiddenMeetingKeys: Set<String> {
        didSet { d.set(Array(hiddenMeetingKeys), forKey: "hiddenMeetingKeys") }
    }

    // Live status
    @Published var calendarAuthorized = false
    @Published var remindersAuthorized = false
    @Published var reminders: [ReminderItem] = []
    @Published var nextMeeting: Meeting?
    /// The meeting running RIGHT NOW (today, timed). Wins in the menu bar,
    /// "upcoming" is future-only, so during a call the bar went blank (Runde 26).
    @Published var currentMeeting: Meeting?
    @Published var agenda: [Meeting] = []
    @Published var availableCalendars: [CalendarInfo] = []
    /// Which day the panel shows (F2, Runde 58). Was an Int offset capped at a
    /// week; now any date, so the month grid can jump anywhere. Banners, the
    /// start blink and the menu bar always run on the REAL today regardless —
    /// that separation lives in `MeetingMonitor.tick` and must stay intact.
    @Published var selectedDay: Date = Calendar.current.startOfDay(for: Date()) {
        didSet {
            if !Calendar.current.isDate(selectedDay, inSameDayAs: oldValue) { monitor?.tickNow() }
        }
    }
    /// Days between today and the shown day (negative = past). Only for labels
    /// like "Morgen", never for fetching.
    var dayOffset: Int {
        Calendar.current.dateComponents([.day],
            from: Calendar.current.startOfDay(for: Date()), to: selectedDay).day ?? 0
    }
    var showsToday: Bool { Calendar.current.isDateInToday(selectedDay) }
    /// F2: ob das Monatsraster im Widget aufgeklappt ist. Liegt hier statt als
    /// View-State, damit `--demo-month` es für Screenshots öffnen kann und das
    /// Widget es beim Öffnen sicher zurücksetzt.
    /// Was der Auswähler gerade zeigt: nil = zu, sonst Woche oder Monat.
    /// Dreistufig statt auf/zu, damit ein Klick aufs Datum durchschalten kann
    /// (Wunsch 19.08.: „1 mal klicken Woche, 2 mal klicken Monat").
    @Published var gridDisplay: CalendarViewMode? {
        didSet {
            // Einen Runloop später: SwiftUI hat den neuen Inhalt hier noch
            // nicht gelayoutet, sofortiges Messen liefert die alte Höhe.
            DispatchQueue.main.async { WidgetPanelController.shared.refreshSize(animated: true) }
        }
    }
    var monthGridOpen: Bool { gridDisplay != nil }

    /// Ein Klick aufs Datum: zu → Woche → (Monat) → zu, je nach Einstellung.
    func advanceGrid() {
        gridDisplay = calendarViewMode.nextStage(after: gridDisplay)
    }
    /// Ob der Auswähler eine Woche oder einen ganzen Monat zeigt.
    @Published var calendarViewMode: CalendarViewMode {
        didSet {
            d.set(calendarViewMode.rawValue, forKey: "calendarViewMode")
            // Ausgeschaltet, während er offen stand: sonst bliebe ein Raster
            // stehen, das sich nicht mehr schließen lässt. Bei „nur Monat"
            // eine offene Wochenansicht mitziehen, damit die Einstellung
            // sofort sichtbar greift.
            if !calendarViewMode.isEnabled { gridDisplay = nil }
            else if gridDisplay != nil, calendarViewMode != .stepped {
                gridDisplay = calendarViewMode.firstStage
            }
        }
    }
    func showToday() { selectedDay = Calendar.current.startOfDay(for: Date()) }
    func stepDay(_ by: Int) {
        selectedDay = Calendar.current.date(byAdding: .day, value: by, to: selectedDay) ?? selectedDay
    }

    /// P7: first day of the week for every month grid (1 = Sunday … 7 =
    /// Saturday). Defaults to the system setting, so a US machine starts on
    /// Sunday without anyone touching it.
    @Published var firstWeekday: Int { didSet { d.set(firstWeekday, forKey: "firstWeekday") } }

    /// F3: hide declined meetings entirely instead of showing them struck
    /// through. They never warn either way.
    @Published var hideDeclined: Bool { didSet { d.set(hideDeclined, forKey: "hideDeclined") } }
    /// F4: how long the banner's snooze button postpones (was a fixed 2).
    @Published var snoozeMinutes: Int { didSet { d.set(snoozeMinutes, forKey: "snoozeMinutes") } }
    /// F6: how much the menu bar shows.
    @Published var menuBarStyle: MenuBarStyle { didSet { d.set(menuBarStyle.rawValue, forKey: "menuBarStyle") } }
    /// P3: only list events that have a join link.
    @Published var onlyWithLink: Bool { didSet { d.set(onlyWithLink, forKey: "onlyWithLink") } }
    /// P3: drop events that already ended from the day's list.
    @Published var hidePastEvents: Bool { didSet { d.set(hidePastEvents, forKey: "hidePastEvents") } }
    /// P1: stille Systemmeldung, wenn das Banner durch Ruhe-Modus oder
    /// Bildschirmfreigabe unterdrückt wird. Sonst verpasst man den Termin ganz.
    @Published var quietNotifications: Bool { didSet { d.set(quietNotifications, forKey: "quietNotifications") } }
    /// Warnung im Erstellen-Formular, wenn der Zeitraum schon belegt ist.
    @Published var warnOnConflicts: Bool { didSet { d.set(warnOnConflicts, forKey: "warnOnConflicts") } }
    /// Freitextzeile („fr 16 uhr call mit chris") im Erstellen-Formular.
    @Published var quickAddEnabled: Bool { didSet { d.set(quickAddEnabled, forKey: "quickAddEnabled") } }

    // Menu-bar "meeting is starting now" blink (point 7).
    @Published var blinkActive = false
    @Published var blinkOn = false
    @Published var blinkText = L.t("Meeting jetzt", "Meeting now")   // Runde 5: also "ending"
    private var blinkTimer: Timer?
    /// Zaehler fuer startMeetingBlink. Steht hier und NICHT als lokale `var` in
    /// der Methode, weil das Timer-Closure sonst eine lose veraenderliche
    /// Variable ueber die Isolationsgrenze in `Task { @MainActor }` reicht:
    /// Swift 6.3 lehnt das ab ("sending 'ticks' risks causing data races"),
    /// Swift 6.2 laesst es noch durch. Als Property von AppState (ohnehin
    /// @MainActor) wandert stattdessen `self` hinein, was erlaubt ist.
    /// Der Ablauf ist unveraendert: gleiche Zaehlung, gleiche Abbruchbedingung.
    private var blinkTicks = 0

    let calendar = CalendarService()
    let presenter = BannerPresenter()
    private(set) var monitor: MeetingMonitor!
    private let d = UserDefaults.standard

    init() {
        // Hinweis für spätere Bundle-ID-Wechsel: Jede Bundle-ID hat ihre eigene
        // Defaults-Domain. Ein Wechsel setzt alle Einstellungen, die
        // Kalenderauswahl und die Ausgeblendet-Marker zurück, sofern man sie
        // nicht einmalig per `d.persistentDomain(forName: <alte id>)`
        // herüberzieht.

        leadMinutes = d.object(forKey: "leadMinutes") as? Int ?? 5
        soundEnabled = d.object(forKey: "soundEnabled") as? Bool ?? true
        dramaticEntrance = d.object(forKey: "waterEffect") as? Bool ?? true
        skinOversize = d.object(forKey: "skinOversize") as? Bool ?? false
        // Standard 1.0 = schlanker Balken. Wer die fette Variante vom 20.08.
        // mochte, stellt in den Einstellungen auf Groß.
        bannerScale = d.object(forKey: "bannerScale") as? Double ?? 1.0
        skinStyle = d.string(forKey: "skinStyle").flatMap(SkinStyle.init(rawValue:)) ?? .classic
        skinID = d.string(forKey: "skinID") ?? Skin.all[0].id
        skinRotation = d.string(forKey: "skinRotation").flatMap(SkinRotation.init(rawValue:)) ?? .off
        skinPool = Set(d.stringArray(forKey: "skinPool") ?? [])
        quietMode = d.object(forKey: "quietMode") as? Bool ?? false
        let qu = d.double(forKey: "quietUntil")
        quietUntil = qu > 0 ? Date(timeIntervalSince1970: qu) : nil
        quietDuringScreenShare = d.object(forKey: "quietDuringScreenShare") as? Bool ?? true
        autoJoin = d.object(forKey: "autoJoin") as? Bool ?? false
        endWarning = d.object(forKey: "endWarning") as? Bool ?? true
        crossScreenStartIndex = d.object(forKey: "crossScreenStartIndex") as? Int ?? 0
        crossScreenToRight = d.object(forKey: "crossScreenToRight") as? Bool ?? true
        // Erststart folgt der Systemsprache: deutsches System zeigt Deutsch,
        // alles andere Englisch. Vorher stand hier hart "en", ein deutscher
        // Nutzer bekam also eine englische App, bis er es selbst umstellte.
        // Eine einmal getroffene Wahl gewinnt weiterhin.
        let systemIsGerman = (Locale.preferredLanguages.first ?? "en").hasPrefix("de")
        appLanguage = d.string(forKey: "appLanguage")
            ?? d.string(forKey: "shareLanguage")
            ?? (systemIsGerman ? "de" : "en")
        showMeetingCreator = d.object(forKey: "showMeetingCreator") as? Bool ?? true
        showInstantMeeting = d.object(forKey: "showInstantMeeting") as? Bool ?? true
        // Neu ab F11-Erweiterung: drei Ziele statt eines Schalters. Der alte
        // Bool wird einmalig übernommen, damit eine bestehende Wahl nicht kippt.
        let formTarget = d.string(forKey: "createTarget").flatMap(CreateTarget.init(rawValue:))
            ?? (d.bool(forKey: "preferGoogleCalendar") ? .google : .apple)
        createTarget = formTarget
        // Ohne eigene Wahl folgt der Sofort-Knopf dem Formular, dann ändert
        // sich für bestehende Installationen nichts.
        instantTarget = d.string(forKey: "instantTarget").flatMap(CreateTarget.init(rawValue:))
            ?? formTarget
        googleTargetCalendarID = d.string(forKey: "googleTargetCalendarID") ?? ""
        appleTargetCalendarID = d.string(forKey: "appleTargetCalendarID") ?? ""
        meetRoutingEnabled = d.object(forKey: "meetRoutingEnabled") as? Bool ?? true
        // Default the routing account to the connected Google account, so it
        // works out of the box the first time after the update.
        meetRoutingAccount = d.string(forKey: "meetRoutingAccount")
            ?? d.string(forKey: "googleAccountEmail") ?? ""
        meetChromeProfile = d.string(forKey: "meetChromeProfile") ?? "Default"
        meetRoutingOverrides = (d.object(forKey: "meetRoutingOverrides") as? [String: String]) ?? [:]
        autoTranscribe = d.object(forKey: "autoTranscribe") as? Bool ?? false
        showReminders = d.object(forKey: "showReminders") as? Bool ?? true
        compactMenuBarInMeeting = d.object(forKey: "compactMenuBarInMeeting") as? Bool ?? true
        createICSFile = d.object(forKey: "createICSFile") as? Bool ?? true
        inviteLanguage = d.string(forKey: "inviteLanguage") ?? "en"
        secondZoneEnabled = d.object(forKey: "secondZoneEnabled") as? Bool ?? true
        secondZoneID = d.string(forKey: "secondZoneID") ?? "Europe/Berlin"
        firstWeekday = d.object(forKey: "firstWeekday") as? Int ?? Calendar.current.firstWeekday
        calendarViewMode = d.string(forKey: "calendarViewMode")
            .flatMap(CalendarViewMode.init(rawValue:)) ?? .stepped
        hideDeclined = d.object(forKey: "hideDeclined") as? Bool ?? false
        snoozeMinutes = d.object(forKey: "snoozeMinutes") as? Int ?? 2
        menuBarStyle = d.string(forKey: "menuBarStyle").flatMap(MenuBarStyle.init(rawValue:)) ?? .titleAndCountdown
        onlyWithLink = d.object(forKey: "onlyWithLink") as? Bool ?? false
        hidePastEvents = d.object(forKey: "hidePastEvents") as? Bool ?? false
        quietNotifications = d.object(forKey: "quietNotifications") as? Bool ?? true
        warnOnConflicts = d.object(forKey: "warnOnConflicts") as? Bool ?? true
        quickAddEnabled = d.object(forKey: "quickAddEnabled") as? Bool ?? true
        hotkeyEnabled = d.object(forKey: "hotkeyEnabled") as? Bool ?? true
        hotkeyWidgetKey = d.object(forKey: "hotkeyWidgetKey") as? Int ?? Int(HotKeyManager.defaultKeyCode)
        hotkeyWidgetMods = d.object(forKey: "hotkeyWidgetMods") as? Int ?? Int(HotKeyManager.defaultModifiers)
        hotkeyWidgetLabel = d.string(forKey: "hotkeyWidgetLabel") ?? HotKeyManager.defaultLabel
        hotkeyJoinKey = d.object(forKey: "hotkeyJoinKey") as? Int ?? Int(HotKeyManager.defaultJoinKeyCode)
        hotkeyJoinMods = d.object(forKey: "hotkeyJoinMods") as? Int ?? Int(HotKeyManager.defaultJoinModifiers)
        hotkeyJoinLabel = d.string(forKey: "hotkeyJoinLabel") ?? HotKeyManager.defaultJoinLabel
        selectedCalendarIDs = Set(d.object(forKey: "selectedCalendarIDs") as? [String] ?? [])
        alertCalendarIDs = Set(d.object(forKey: "alertCalendarIDs") as? [String] ?? [])
        birthdayCalendarIDs = Set(d.object(forKey: "birthdayCalendarIDs") as? [String] ?? [])
        // Bestehende Installationen haben den Einstieg nie gesehen und brauchen
        // ihn auch nicht: Wer schon Kalender ausgewählt hat, ist eingerichtet.
        onboardingDone = d.object(forKey: "onboardingDone") as? Bool
            ?? d.bool(forKey: "calendarsInitialized")
        hidePermanently = d.object(forKey: "hidePermanently") as? Bool ?? false
        hiddenTitleKeys = Set(d.object(forKey: "hiddenTitleKeys") as? [String] ?? [])

        // Keep only today's (and future) "called"/"hidden" marks; string compare
        // works because the key prefix is yyyy-MM-dd.
        let todayPrefix = Self.dayString(Date())
        calledBirthdayKeys = Set((d.object(forKey: "calledBirthdayKeys") as? [String] ?? [])
            .filter { $0.prefix(10) >= todayPrefix })
        hiddenMeetingKeys = Set((d.object(forKey: "hiddenMeetingKeys") as? [String] ?? [])
            .filter { $0.prefix(10) >= todayPrefix })

        // Flight duration: a steady, readable 9s. One-time normalisation of the
        // earlier 6s (too fast) and 12s (looked frozen mid-screen) defaults.
        var flight = d.object(forKey: "animationSeconds") as? Double ?? 9.0
        if !d.bool(forKey: "flightSpeedMigratedV3") {
            if flight < 6 || flight > 10 { flight = 9 }
            d.set(flight, forKey: "animationSeconds")
            d.set(true, forKey: "flightSpeedMigratedV3")
        }
        animationSeconds = flight

        monitor = MeetingMonitor(state: self)
    }

    func start() {
        refreshLaunchAtLogin()
        // Runde 56: Beim ALLERERSTEN Start NICHT von allein nach Berechtigungen
        // fragen. Sonst stehen zwei Systemdialoge auf dem Schirm, bevor die App
        // ein einziges Wort erklärt hat, von einem Programm, das der Nutzer
        // nirgends sieht (kein Fenster, kein Dock-Symbol). Wer da reflexhaft
        // „Nicht erlauben" klickt, ist erledigt: macOS fragt kein zweites Mal,
        // und `requestFullAccessToEvents` liefert danach stumm false. Den Dialog
        // löst deshalb der Knopf im Einstiegsfenster aus, im richtigen Moment.
        if onboardingDone {
            Task { await requestCalendarAccess() }
            if showReminders { Task { await requestRemindersAccess() } }
        }
        monitor.start()
    }

    /// Nach dem Einstieg: holt nach, was `start()` beim Erstlauf ausgelassen hat.
    func startDeferredAccessRequests() {
        Task { await requestCalendarAccess() }
        if showReminders { Task { await requestRemindersAccess() } }
    }

    // MARK: - Join per Tastenkürzel (F5)

    /// ⌃⌥J: ins LAUFENDE Meeting, sonst ins nächste. Der laufende Call hat
    /// Vorrang — drückt man das Kürzel mitten drin, will man dort hinein und
    /// nicht in den Termin danach. Ohne Link öffnet sich das Widget, damit der
    /// Druck nie folgenlos verpufft.
    func joinCurrentOrNext() {
        if let c = currentMeeting, c.joinURL != nil { MeetingLauncher.join(c); return }
        if let n = nextMeeting, n.joinURL != nil { MeetingLauncher.join(n); return }
        WidgetPanelController.shared.toggle(state: self, statusButton: nil,
                                            anchorToMouseScreen: true)
    }

    // MARK: - Sofort-Meeting (F11)

    /// One click: mint a Meet link, drop a 30-minute event starting NOW (full
    /// minute) into the target calendar, then open the room itself. Reuses the
    /// existing create path, so the clipboard invite and the optional
    /// auto-transcribe behave exactly like the form.
    func startInstantMeeting() {
        guard !GoogleService.shared.busy else { return }
        instantError = nil
        // Lazy guess: covers the preference arriving WITHOUT the didSet
        // (defaults import, fresh machine). Imperative context, so mutating
        // here is safe, unlike in the computed target below.
        if instantTarget.usesGoogle && googleTargetCalendarID.isEmpty {
            googleTargetCalendarID = calendar.guessGoogleCalendarID() ?? ""
        }
        let now = Date()
        // Round DOWN to the minute, the calendar should say 14:23, not 14:23:47.
        let start = now.addingTimeInterval(
            -now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
        let title = L.t("Sofort-Meeting", "Instant meeting")
        // Google gewählt, aber kein Kalender ermittelbar: lieber sichtbar
        // abbrechen als den Termin still nur im Apple-Kalender anzulegen.
        if instantTarget.usesGoogle && googleTargetCalendarID.isEmpty {
            instantError = L.t("Kein Google-Kalender gefunden. In den Einstellungen unter Google einen wählen.",
                               "No Google calendar found. Pick one in Settings → Google.")
            return
        }
        Task {
            let ok = await GoogleService.shared.createAppleMeeting(
                title: title, start: start, minutes: 30,
                calendarIDs: calendarIDs(for: instantTarget),
                autoTranscribe: autoTranscribe, makeICS: false,
                calendarService: calendar)
            if ok {
                monitor.tickNow()   // agenda/timeline pick it up immediately
                // Through the launcher, NOT NSWorkspace: the Chrome profile +
                // authuser routing (Runde 43) must apply, or the room opens as
                // the wrong signed-in account.
                if let link = GoogleService.shared.lastMeetLink,
                   let url = URL(string: link) {
                    MeetingLauncher.open(url, title: title)
                }
            } else {
                instantError = GoogleService.shared.lastError
            }
        }
    }

    /// Target calendars for one creation route (F11). One entry per calendar
    /// that should receive the event, so `.both` returns two. A nil entry means
    /// "the system default calendar". Never empty.
    func calendarIDs(for target: CreateTarget) -> [String?] {
        var ids: [String?] = []
        if target.usesGoogle, !googleTargetCalendarID.isEmpty {
            ids.append(googleTargetCalendarID)
        }
        if target.usesApple {
            let stored = d.string(forKey: "createCalendarID") ?? ""
            ids.append(appleTargetCalendarID.isEmpty ? (stored.isEmpty ? nil : stored)
                                                     : appleTargetCalendarID)
        }
        return ids.isEmpty ? [nil] : ids
    }

    /// Ziele des Formulars („Neues Meeting").
    var effectiveCreateCalendarIDs: [String?] { calendarIDs(for: createTarget) }

    // MARK: - Launch at login (Runde 4 fix)

    func refreshLaunchAtLogin() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("Launch-at-login toggle failed: \(error)") }
        // Reflect the real resulting status (may be .enabled or .requiresApproval).
        refreshLaunchAtLogin()
    }

    func requestCalendarAccess() async {
        calendarAuthorized = await calendar.requestAccess()
        if calendarAuthorized {
            let known = Set(availableCalendars.map(\.id))
            availableCalendars = calendar.allCalendars()
            // First run: include every calendar; the user prunes (e.g. a shared one) in settings.
            if !d.bool(forKey: "calendarsInitialized") {
                selectedCalendarIDs = Set(availableCalendars.map(\.id))
                d.set(true, forKey: "calendarsInitialized")
            } else {
                // Runde 56: NEU hinzugekommene Kalender erben „an".
                //
                // Alle drei Mengen folgen der Konvention „leer = alle". Sobald
                // der Nutzer aber EINEN Haken wegnimmt, wird die volle Menge
                // festgeschrieben, und ein Kalender, den er danach einhängt
                // (neues Arbeitskonto, nachgezogenes iCloud-Abo), steht in
                // keiner der Mengen und bleibt für immer still. Ohne Fehler,
                // ohne Hinweis. Genau das würde sonst jeder Klick im Einstieg
                // auslösen.
                let fresh = Set(availableCalendars.map(\.id)).subtracting(known)
                if !fresh.isEmpty {
                    if !selectedCalendarIDs.isEmpty { selectedCalendarIDs.formUnion(fresh) }
                    if !alertCalendarIDs.isEmpty { alertCalendarIDs.formUnion(fresh) }
                    if !birthdayCalendarIDs.isEmpty { birthdayCalendarIDs.formUnion(fresh) }
                }
            }
            monitor.tickNow()
        }
    }

    func toggleCalendar(_ id: String) {
        if selectedCalendarIDs.contains(id) { selectedCalendarIDs.remove(id) }
        else { selectedCalendarIDs.insert(id) }
        monitor.tickNow()
    }

    // MARK: - Alert calendars (banner + blink, Runde 40)

    /// True if this calendar should fire the banner/blink. Empty set = all.
    func isAlertCalendar(_ id: String?) -> Bool {
        alertCalendarIDs.isEmpty || (id.map { alertCalendarIDs.contains($0) } ?? true)
    }
    func isAlertCalendar(_ m: Meeting) -> Bool { isAlertCalendar(m.calendarID) }

    func toggleAlertCalendar(_ id: String) {
        // Materialise "all" into an explicit set on the first customisation, so
        // un-checking one calendar keeps every other one alerting.
        if alertCalendarIDs.isEmpty {
            alertCalendarIDs = Set(availableCalendars.map(\.id))
        }
        if alertCalendarIDs.contains(id) { alertCalendarIDs.remove(id) }
        else { alertCalendarIDs.insert(id) }
        monitor.tickNow()
    }

    // MARK: - Birthday calendars (Runde 55)

    /// True if this calendar's birthdays belong in the widget. Empty set = all.
    func isBirthdayCalendar(_ id: String?) -> Bool {
        birthdayCalendarIDs.isEmpty || (id.map { birthdayCalendarIDs.contains($0) } ?? true)
    }

    /// The gate the monitor applies: only birthdays are affected, so un-checking
    /// a shared calendar drops its birthdays while its real meetings stay.
    func showsBirthday(_ m: Meeting) -> Bool {
        !m.isBirthday || isBirthdayCalendar(m.calendarID)
    }

    func toggleBirthdayCalendar(_ id: String) {
        if birthdayCalendarIDs.isEmpty {
            birthdayCalendarIDs = Set(availableCalendars.map(\.id))
        }
        if birthdayCalendarIDs.contains(id) { birthdayCalendarIDs.remove(id) }
        else { birthdayCalendarIDs.insert(id) }
        monitor.tickNow()
    }

    func announce(_ meeting: Meeting, pinnedDocked: Bool = false) {
        // Vor dem Aufbau, nicht danach: `currentSkinElement` unten entscheidet
        // über Sprung und Startpanel und muss zum neuen Motiv passen. Beim
        // angedockten Wiederzeigen NICHT wechseln, das ist derselbe Termin.
        if !pinnedDocked { advanceSkinIfRotating() }
        // Runde 72: "Dramatischer Auftritt" wirkt jetzt für BEIDE Elemente —
        // diese eine Stelle steuert sowohl die Sprung-Phase als auch welches
        // Panel BannerPresenter an der Startstelle aufsetzt (SeaSplash für
        // Wasser, CloudBurst für Luft, siehe FlightVM.entranceElement).
        presenter.present(meeting, leadMinutes: leadMinutes, seconds: animationSeconds,
                          playSound: soundEnabled && !pinnedDocked,
                          dramaticEntrance: dramaticEntrance, element: currentSkinElement,
                          pinnedDocked: pinnedDocked)
    }

    /// Runde 5: whether an automatic lead-time banner should be held back.
    /// Manual quiet mode always suppresses; screen-share suppression is best
    /// effort (macOS only exposes its own Screen Sharing/Remote, not Zoom/Meet).
    /// The Test-Banner and Snooze deliberately bypass this.
    var bannersSuppressed: Bool {
        if quietMode { return true }
        if quietDuringScreenShare && ScreenShareDetector.isSharing() { return true }
        return false
    }

    func showTestBanner(pinnedDocked: Bool = false) {
        let m = Meeting(id: "test-\(Int(Date().timeIntervalSince1970))", title: L.t("Test-Meeting", "Test meeting"),
                        start: Date().addingTimeInterval(Double(leadMinutes) * 60),
                        end: Date().addingTimeInterval(Double(leadMinutes) * 60 + 1800),
                        isAllDay: false, isBirthday: false, calendarTitle: "Test",
                        calendarID: nil,
                        color: Color(hex: 0x2EC7A0),
                        joinURL: URL(string: "https://meet.google.com/test-demo"), contactID: nil,
                        calendarItemID: nil)
        announce(m, pinnedDocked: pinnedDocked)
    }

    /// Kalenderdatei für einen BESTEHENDEN Termin (Runde 48, Rückmeldung: die .ics
    /// soll es nicht nur beim Erstellen geben). Schreibt sie nach ~/Downloads
    /// UND legt sie als DATEI in die Zwischenablage, in WhatsApp oder Mail
    /// eingefügt wird daraus ein Anhang, kein Pfad-Text.
    ///
    /// Beschreibt bewusst nur DIESEN Termin, nicht die ganze Serie: geteilt wird
    /// „dieses Meeting", und die Serienregel des Originals kennt unser Meeting-
    /// Modell gar nicht (sie lebt in EventKit).
    @discardableResult
    func exportICS(_ m: Meeting) -> URL? {
        // Runde 50: als Notiz NUR der Link. Zeitangaben stehen maschinenlesbar
        // in der Datei, doppelt als Text wären sie nur Ballast.
        let link = m.joinURL?.absoluteString
        do {
            let url = try ICSExport.write(title: m.title, start: m.start, end: m.end, link: link)
            ICSExport.copyToPasteboard(url)
            return url
        } catch {
            NSLog("ICS-Export fehlgeschlagen: \(error)")
            return nil
        }
    }

    /// Reveal an event in Apple Calendar (point 4). Falls back to just opening
    /// Calendar if the per-event deep link is unavailable.
    func openInCalendar(_ meeting: Meeting) {
        if let id = meeting.calendarItemID,
           let url = URL(string: "ical://ekevent/\(id)?method=show&options=more") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "ical://") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Birthday "already called" tracking (Runde 3)

    private static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func birthdayKey(_ m: Meeting) -> String {
        "\(dayString(m.start))|\(m.id)"
    }

    func isBirthdayCalled(_ m: Meeting) -> Bool {
        calledBirthdayKeys.contains(Self.birthdayKey(m))
    }

    // MARK: - Hide meetings from MeetingBlitz (Runde 27)

    private static func hideKey(_ m: Meeting) -> String {
        "\(dayString(m.start))|\(m.id)@\(Int(m.start.timeIntervalSince1970))"
    }

    /// Key for "hide this for good" (Runde 55). Calendar id is part of it on
    /// purpose: the same title in your own calendar must stay visible, and a
    /// generic title like "Call" shouldn't wipe every calendar at once.
    private static func titleHideKey(_ m: Meeting) -> String {
        let title = m.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(m.calendarID ?? "")|\(title)"
    }

    func isHidden(_ m: Meeting) -> Bool {
        hiddenMeetingKeys.contains(Self.hideKey(m))
            || hiddenTitleKeys.contains(Self.titleHideKey(m))
    }

    /// Hide from the widget + all alerts. The calendar event is untouched,
    /// deliberately NOT a real delete. With `hidePermanently` on, this covers
    /// every future occurrence of the title instead of just this one.
    func hideMeeting(_ m: Meeting) {
        if hidePermanently {
            hiddenTitleKeys.insert(Self.titleHideKey(m))
        } else {
            hiddenMeetingKeys.insert(Self.hideKey(m))
        }
        monitor.tickNow()
    }

    /// Undo for the widget's "Rückgängig" chip (Runde 30). Drops both key kinds,
    /// so the chip works regardless of which mode was active at hide time.
    func unhideMeeting(_ m: Meeting) {
        hiddenMeetingKeys.remove(Self.hideKey(m))
        hiddenTitleKeys.remove(Self.titleHideKey(m))
        monitor.tickNow()
    }

    /// Escape hatch for a stray click: bring every hidden meeting back.
    func unhideAll() {
        hiddenMeetingKeys.removeAll()
        hiddenTitleKeys.removeAll()
        monitor.tickNow()
    }

    /// Count behind the settings button, so it reflects both hide kinds.
    var hiddenCount: Int { hiddenMeetingKeys.count + hiddenTitleKeys.count }

    func toggleBirthdayCalled(_ m: Meeting) {
        let key = Self.birthdayKey(m)
        if calledBirthdayKeys.contains(key) { calledBirthdayKeys.remove(key) }
        else { calledBirthdayKeys.insert(key) }
    }

    /// Open/close the floating settings side panel (Runde 3: settings live
    /// beside the widget, not inside it), docked to the widget's frame.
    func toggleSettingsPanel() {
        SettingsPanelController.shared.toggle(state: self, anchor: WidgetPanelController.shared.frame)
    }

    /// Open/close the "Neues Meeting" panel (Runde 27c), docked like settings.
    func toggleCreatePanel() {
        CreatePanelController.shared.toggle(state: self, anchor: WidgetPanelController.shared.frame)
    }

    /// F9: Öffnet das Erstellen-Formular, ohne es bei erneutem Aufruf wieder
    /// zuzuklappen — ein `meetingblitz://create` darf nie zufällig schließen.
    func openCreatePanel() {
        if !CreatePanelController.shared.isOpen { toggleCreatePanel() }
    }

    /// F9: Freitext, mit dem das Formular beim Öffnen vorbelegt wird.
    @Published var pendingQuickAdd: String?

    func copyLink(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    // MARK: - Meet account routing (Runde 43)

    private static func normTitle(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The per-meeting account choice, if the user set one (else nil = follow
    /// the global default).
    func meetChoice(forTitle title: String?) -> MeetAccountChoice? {
        guard let title, let raw = meetRoutingOverrides[Self.normTitle(title)] else { return nil }
        return MeetAccountChoice(rawValue: raw)
    }

    /// The work account Meet links open as: the explicit setting, else the
    /// connected Google account (so routing works even if Google was connected
    /// only after first launch and never touched the field).
    var effectiveMeetAccount: String {
        meetRoutingAccount.isEmpty ? (GoogleService.shared.accountEmail ?? "") : meetRoutingAccount
    }

    /// Resolve how a Meet link for this meeting should open.
    func meetRouting(forTitle title: String?) -> MeetingLauncher.Route {
        let work = effectiveMeetAccount
        switch meetChoice(forTitle: title) {
        case .personal:
            return .chrome(authuser: nil)                 // default profile account
        case .work:
            return .chrome(authuser: work.isEmpty ? nil : work)
        case nil:
            // Global default: route to the work account when enabled + set.
            guard meetRoutingEnabled, !work.isEmpty else { return .systemDefault }
            return .chrome(authuser: work)
        }
    }

    /// Remember (or clear) the account a meeting title opens as.
    func setMeetChoice(_ choice: MeetAccountChoice?, forTitle title: String) {
        let key = Self.normTitle(title)
        guard !key.isEmpty else { return }
        if let choice { meetRoutingOverrides[key] = choice.rawValue }
        else { meetRoutingOverrides.removeValue(forKey: key) }
    }

    /// The single entry point every join button uses.
    func join(_ meeting: Meeting) { MeetingLauncher.join(meeting) }

    /// Flash the menu-bar label when a meeting begins (point 7) or, in Runde 5,
    /// when the current meeting is about to end with another right after.
    func startMeetingBlink(text: String = L.t("Meeting jetzt", "Meeting now"), ticksTotal: Int = 16) {
        blinkTimer?.invalidate()
        blinkText = text
        blinkActive = true
        blinkOn = true
        blinkTicks = 0
        let t = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.blinkTicks += 1
                self.blinkOn.toggle()
                if self.blinkTicks >= ticksTotal {
                    self.blinkTimer?.invalidate()
                    self.blinkTimer = nil
                    self.blinkActive = false
                    self.blinkOn = false
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t
    }

    /// Snooze a banner: show the same meeting's banner again after `minutes`
    /// (Runde 5). Bypasses quiet mode, the user explicitly asked to be nudged.
    func snooze(_ meeting: Meeting, minutes: Int = 2) {
        let t = Timer(timeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.announce(meeting) }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    /// F6: nur das Symbol zeigen heißt NICHT, die Information zu verlieren —
    /// der volle Text landet dann im Tooltip (`menuBarTooltip`). Das Blinken
    /// zum Meeting-Start bleibt in jedem Stil, das ist Sicherheitsfunktion.
    var menuBarText: String? {
        menuBarStyle == .iconOnly ? nil : menuBarString(style: menuBarStyle)
    }

    /// Immer der VOLLE Text, egal welcher Anzeigestil eingestellt ist.
    var menuBarTooltip: String? { menuBarString(style: .titleAndCountdown) }

    private func menuBarString(style: MenuBarStyle) -> String? {
        guard calendarAuthorized else { return L.t("Zugriff nötig", "Access needed") }
        // A running call wins: show it with the remaining time.
        if let c = currentMeeting {
            let mins = max(1, Int(c.end.timeIntervalSinceNow / 60))
            let left = L.t("noch \(hmLabel(mins))", "\(hmLabel(mins)) left")
            return style == .countdownOnly ? left : "\(c.menuBarTitle) · \(left)"
        }
        guard let m = nextMeeting else { return nil }
        // Menu bar announces TODAY only: once the day's last call is done it
        // returns to the plain icon instead of already showing tomorrow's
        // meeting (Runde 25). Banners/blink are unaffected.
        let endOfToday = Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 3600)
        guard m.start < endOfToday else { return nil }
        return m.menuBarLabel
    }

    // MARK: - Apple Reminders (Runde 43)

    /// Ask for Reminders access (separate TCC grant from Calendars) and load the
    /// list. Called on launch when the feature is on, and when the user flips the
    /// settings toggle.
    func requestRemindersAccess() async {
        remindersAuthorized = await calendar.requestRemindersAccess()
        if remindersAuthorized { await refreshReminders() }
    }

    /// Reload today's + overdue reminders into `reminders` (published → the
    /// widget updates). Cheap; called from the monitor tick and on store change.
    func refreshReminders() async {
        guard showReminders, remindersAuthorized else {
            if !reminders.isEmpty { reminders = [] }
            return
        }
        let fresh = await calendar.dueReminders()
        if fresh != reminders { reminders = fresh }   // avoid needless re-renders
    }

    /// Mark a reminder done from the widget and drop it from the list.
    func completeReminder(_ item: ReminderItem) {
        calendar.completeReminder(id: item.id)
        reminders.removeAll { $0.id == item.id }
    }

    /// M2: open the birthday person's card in Contacts, calling/FaceTime is one
    /// click from there. The addressbook:// scheme needs no Contacts permission.
    func openBirthdayContact(_ m: Meeting) {
        guard let id = m.contactID,
              let esc = id.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let url = URL(string: "addressbook://\(esc)") else { return }
        NSWorkspace.shared.open(url)
    }
}
