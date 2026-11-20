import AppKit
import QuartzCore
import SwiftUI

/// NSHostingView that accepts the first mouse click even while the app is
/// inactive. An accessory (menu-bar) app is inactive most of the time; without
/// this, the first click on a banner button only activates the window and the
/// actual button press is swallowed.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Force transparency: otherwise the hosting view can paint its whole
    // banner-sized frame opaque (a black bar behind the pill).
    override var isOpaque: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

/// One announcement. Runde 117 sequence: `.entering` (Kasten baut sich von links
/// auf, das Motiv taucht auf, siehe `BannerMotion`) → `.flying` (cruises toward
/// the far edge with a gentle wog). Hover docks it in place with actions,
/// a click pins it with the detail popover, the × closes it.
///
/// WINDOW ARCHITECTURE (Runde 21, the definitive fix for the cross-display
/// glitch): the windows NEVER move. Moving one window across a display boundary
/// makes macOS re-assign it to the other display's Space, it clips at the
/// bezel, then POPS over, which read as a flash/glitch. Instead every
/// screen gets a STATIONARY transparent band pinned to itself, and the capsule
/// travels INSIDE the bands (SwiftUI offset driven by a shared global position).
/// At the bezel, band A shows the capsule sliding out exactly while band B shows
/// it sliding in, a seamless hand-over, and no per-tick window moves at all.
///
/// Movement robustness (the banner froze once, so this is deliberate): positions
/// come from the WALL CLOCK, never accumulated per-frame, and two independent
/// timers drive the ticks, a GCD main-queue timer (60 fps) and a run-loop
/// `Timer` in `.common` (30 fps, keeps firing during event tracking / open
/// panels). Hover is POLLED from `NSEvent.mouseLocation`.
@MainActor
final class Flight {
    private enum Phase { case entering, flying, docked, exiting }

    private let vm: FlightVM
    private let seconds: Double
    private let laneIndex: Int
    private let pinnedDocked: Bool     // debug: stay docked at centre (--demo-dock)
    private var bands: [NSPanel] = []
    private var phase: Phase
    private var startedAt = Date()
    private var travelStartedAt = Date()
    private var lastTickAt = Date()
    private var mouseInside = false
    private var detailsOpen = false        // banner pinned while its popover shows
    private var dockCenterX: CGFloat = 0   // docked target (in place, clamped)
    private var dockCenterY: CGFloat = 0
    private var hoverChangedAt = Date()
    private var closed = false
    private var lastX: CGFloat = 0
    private var lastY: CGFloat = 0
    private var haveLast = false
    var onClose: (() -> Void)?

    // Global flight path (screen coordinates), fixed in start().
    private var launchX: CGFloat = 0   // virtual-box x at the submerged launch
    private var cruiseX: CGFloat = 0   // virtual-box x where the cruise begins
    private var cruiseY: CGFloat = 0   // virtual-box y at cruise height
    private var endX: CGFloat = 0      // exit x at the far edge of all screens

    private let panelW = BannerContentView.panelW   // virtual banner box
    private let panelH = BannerContentView.panelH
    private let frameInterval = 1.0 / 60.0
    private let cruiseWog: CGFloat = 6     // gentle up/down while cruising
    private let wogCount = 2.5

    // MARK: Runde 70, Handwerksregeln

    /// Beschleunigter Abgang: ab `exitFrom` (Anteil der Strecke) legt sich
    /// `exitBoost` quadratisch obendrauf, das Banner zieht also zum Schluss an.
    /// Das Ziel darf dabei leicht überschossen werden, es fliegt ohnehin aus
    /// dem Bild.
    private let exitFrom = 0.78
    private let exitBoost = 0.14

    /// Overlapping Action: Wie stark die Kapsel bei Beschleunigung zurückbleibt
    /// (Punkte pro Punkt-pro-Sekunde), plus Federsteifigkeit und Dämpfung ihrer
    /// Rückkehr. Profis lassen ein angehängtes Element 50 bis 150 ms verzögert
    /// folgen, statt es starr mitzuziehen.
    private let lagPerSpeed: CGFloat = 0.030
    private let lagStiffness: CGFloat = 120
    private let lagDamping: CGFloat = 13
    private let lagMax: CGFloat = 34

    /// Laufende Werte der Feder zwischen Objekt und Kapsel.
    private var lagVelocity: CGFloat = 0

    private var flightDir: CGFloat = -1
    private var morphStartedAt = Date()
    private var createdAt = Date()
    private var lastGlobalX: CGFloat = 0
    private var haveLastX = false

    init(vm: FlightVM, seconds: Double, laneIndex: Int, pinnedDocked: Bool = false) {
        self.vm = vm
        self.seconds = seconds
        self.laneIndex = laneIndex
        self.pinnedDocked = pinnedDocked
        self.phase = pinnedDocked ? .docked : .entering
        vm.docked = pinnedDocked
        vm.emergeT = 1
        vm.tilt = 0
        vm.onCloseTap = { [weak self] in self?.close() }
        vm.onDetails = { [weak self] in self?.openDetails() }
        // Snooze first schedules the re-announce (set by the presenter), then
        // closes this banner.
        let scheduleSnooze = vm.onSnooze
        vm.onSnooze = { [weak self] in scheduleSnooze(); self?.close() }
    }

    func start() {
        let screens = NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
        if !screens.isEmpty {
            let toRight = AppState.shared.crossScreenToRight
            let startIdx = min(max(0, AppState.shared.crossScreenStartIndex), screens.count - 1)
            let sf = screens[startIdx].frame
            let allMinX = screens.map { $0.frame.minX }.min() ?? sf.minX
            let allMaxX = screens.map { $0.frame.maxX }.max() ?? sf.maxX
            let dir: CGFloat = toRight ? 1 : -1

            // Path: capsule sits about a third down the start screen; overlapping
            // flights stack downward via laneIndex.
            cruiseY = sf.maxY - sf.height * 0.30 - panelH - CGFloat(laneIndex) * (BannerContentView.capsuleZone + 6)
            launchX = toRight ? (sf.minX + sf.width * 0.09) : (sf.maxX - sf.width * 0.09 - panelW)
            cruiseX = launchX + dir * (sf.width * 0.06)
            endX = toRight ? allMaxX : (allMinX - panelW)
            // 272 was half of an assumed ~544pt docked width; scales with the
            // banner so the pinned/docked debug pose (--demo-dock) centres it.
            let centerX = sf.midX - 272 * BannerContentView.geometryScale
            vm.facingLeft = !toRight

            if pinnedDocked {
                vm.globalX = centerX; vm.globalY = cruiseY
                dockCenterX = centerX; dockCenterY = cruiseY
            } else {
                // Der Banner baut sich an Ort und Stelle auf, dann fliegt er quer.
                vm.globalX = cruiseX; vm.globalY = cruiseY
                _ = BannerMotion.enter(vm, t: 0)
            }
            flightDir = dir

            // Stationary bands: full width of each screen, tall enough for the
            // whole flight (launch depth … arc overshoot). Clipped to the screen;
            // screens the flight band misses get no window.
            // Unten Platz für das Motiv, das von unten auftaucht; oben für die Schräglage.
            let bandBottom = cruiseY - 40
            let bandTop = cruiseY + panelH + 40
            for screen in screens {
                let f = screen.frame
                let y0 = max(bandBottom, f.minY)
                let y1 = min(bandTop, f.maxY)
                guard y1 - y0 > 40 else { continue }
                bands.append(makeBand(at: CGRect(x: f.minX, y: y0, width: f.width, height: y1 - y0)))
            }
        }
        startedAt = Date()
        createdAt = startedAt
        if !pinnedDocked { morphStartedAt = startedAt }
        travelStartedAt = startedAt
        lastTickAt = startedAt
        lastX = vm.globalX; lastY = vm.globalY; haveLast = true

        // Das Aufräumen der Auftritts-Panels hängt jetzt an ihrer verzögerten
        // Erzeugung weiter oben, nicht mehr an dieser Stelle.

        // Treiber 1: der Bildschirmtakt selbst (Runde 70).
        //
        // WARUM NICHT MEHR NUR EIN TIMER: Ein Timer mit 60 Hz läuft NEBEN dem
        // Bildwiederholzyklus, nicht mit ihm. Auf einem 120-Hz-Display fällt
        // jeder zweite Tick zwischen zwei Bilder, unter Last driftet er ohnehin.
        // Das Ergebnis sind winzige, unregelmäßige Sprünge, die man nicht als
        // Fehler benennen kann, die eine Bewegung aber billig aussehen lassen.
        // `CADisplayLink` feuert exakt im Takt des Bildschirms und passt sich
        // ProMotion an. Auf dem Mac gibt es sie seit macOS 14, und genau das
        // ist unsere Mindestversion (Package.swift).
        if let screen = bands.first?.screen ?? NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(displayTick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        // Treiber 2: Runloop-Timer als Netz.
        //
        // Bleibt drin, obwohl der Bildschirmtakt der genauere Weg ist: Der
        // DisplayLink pausiert, wenn sein Bildschirm schläft oder verschwindet
        // (Deckel zu, Monitor abgezogen), und ein Banner, das dann mitten im
        // Flug einfriert, wäre schlimmer als ein paar ungenaue Frames. `tick()`
        // rechnet ohnehin mit echten Zeitstempeln statt mit Frame-Zählern,
        // doppelte Aufrufe im selben Frame filtert es selbst weg.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.backupTicks += 1
                self.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        backupTimer = t
        measureStart = Date()
    }

    /// Callback des Bildschirmtakts. `nonisolated`, weil CADisplayLink einen
    /// nackten @objc-Selector verlangt; der Aufruf kommt garantiert auf dem
    /// Hauptthread, deshalb ist `assumeIsolated` hier zulässig.
    @objc nonisolated private func displayTick() {
        MainActor.assumeIsolated {
            self.displayTicks += 1
            self.tick()
        }
    }

    /// Zähler für `--motion-log`. Ohne Messung ist nicht zu unterscheiden, ob
    /// der Bildschirmtakt wirklich läuft oder ob still nur der 30-Hz-Notnagel
    /// arbeitet: sichtbar wäre in beiden Fällen eine Bewegung, nur eben eine
    /// halb so feine. Ein grüner Build beweist hier gar nichts.
    private var displayTicks = 0
    private var backupTicks = 0
    private var measureStart = Date()

    static var motionLogEnabled: Bool { CommandLine.arguments.contains("--motion-log") }

    private func writeMotionLog() {
        guard Self.motionLogEnabled else { return }
        let secs = Date().timeIntervalSince(measureStart)
        guard secs > 0.4 else { return }
        let line = String(format: "flug %.2fs  bildschirmtakt %d ticks (%.1f/s)  notnagel %d ticks (%.1f/s)\n",
                          secs, displayTicks, Double(displayTicks) / secs,
                          backupTicks, Double(backupTicks) / secs)
        let url = URL(fileURLWithPath: "/tmp/mb_motion.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private var displayLink: CADisplayLink?
    private var backupTimer: Timer?

    /// A stationary, transparent, click-through band pinned to one screen. The
    /// capsule renders inside it at the shared global position. Mouse events are
    /// enabled only while the cursor is over the capsule (see `updateHover`) so
    /// the wide band never swallows clicks meant for windows beneath it.
    private func makeBand(at rect: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        // No .canJoinAllSpaces (it mirrors the window onto every display's
        // Space). Each band lives on its own screen's Space, and never moves.
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // Runde 118: Band wäre Systemschatten um das ganze Motiv (UFO bekäme dunklen Rand); Schatten zeichnet die Kapsel selbst
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = !pinnedDocked
        let host = FirstMouseHostingView(rootView: BannerContentView(vm: vm, bandOriginX: rect.minX, bandTopY: rect.maxY))
        host.frame = CGRect(origin: .zero, size: rect.size)
        panel.contentView = host
        panel.orderFrontRegardless()
        return panel
    }

    /// The moving virtual banner box, in global screen coordinates.
    private var virtualFrame: CGRect {
        CGRect(x: vm.globalX, y: vm.globalY, width: panelW, height: panelH)
    }

    private func tick() {
        let now = Date()
        // Beide Treiber rufen hier herein; fast gleichzeitige Aufrufe zu einem
        // Frame zusammenfassen. Die Schwelle muss DEUTLICH unter dem kürzesten
        // echten Bildabstand liegen: Mit dem alten Wert (halbe 60-Hz-Periode,
        // also 8,3 ms) lag sie exakt auf dem Bildabstand eines 120-Hz-Displays,
        // und der Zeit-Jitter warf dadurch rund jeden vierten Frame weg
        // (gemessen 94 statt 120 Ticks je Sekunde). 1/240 s filtert weiterhin
        // die Doppelaufrufe, lässt aber jedes echte Bild durch.
        guard now.timeIntervalSince(lastTickAt) >= 1.0 / 240.0 else { return }
        let dt = min(now.timeIntervalSince(lastTickAt), 0.25)
        lastTickAt = now
        updateHover(now)

        switch phase {
        case .flying:
            let te = now.timeIntervalSince(travelStartedAt)
            let progress = te / seconds
            if progress >= 1 { close(); return }
            // Abgang (Runde 70): das letzte Stück beschleunigt spürbar aus dem
            // Bild heraus, statt am Rand einfach aufzuhören. Enter und Exit
            // dürfen sich unterscheiden, aber beide brauchen eine Richtung.
            let eased = readingEase(progress) + exitBoost * pow(max(0, progress - exitFrom) / (1 - exitFrom), 2)
            vm.globalX = cruiseX + (endX - cruiseX) * min(1.12, eased)
            vm.globalY = cruiseY + cruiseWog * sin(2 * .pi * progress * wogCount)
            updateTilt(CGPoint(x: vm.globalX, y: vm.globalY))
        case .docked:
            let f = approachFactor(0.22, dt)
            vm.globalX = approach(vm.globalX, dockCenterX, f)
            vm.globalY = approach(vm.globalY, dockCenterY, f)
            vm.tilt += (0 - vm.tilt) * 0.25              // level out when docked
        case .entering:
            if BannerMotion.enter(vm, t: now.timeIntervalSince(morphStartedAt)) {
                phase = .flying
                travelStartedAt = now
            }
        case .exiting:
            vm.globalX = approach(vm.globalX, dockCenterX, approachFactor(0.22, dt))
            if BannerMotion.exit(vm, t: now.timeIntervalSince(morphStartedAt), dir: flightDir) { close(); return }
        }
        updateCapsuleLag(dt)
    }

    /// Overlapping Action (Runde 70): Die Kapsel hängt an einer Feder hinter dem
    /// Flugobjekt, statt starr daran zu kleben. Beschleunigt das Objekt, bleibt
    /// sie kurz zurück und schwingt danach nach; im gleichmäßigen Flug läuft sie
    /// wieder auf. Genau daran erkennt das Auge zwei verbundene Körper statt
    /// eines einzigen steifen Bildes.
    ///
    /// Bewusst hier im Presenter und nicht als SwiftUI-Animation: Die View
    /// zeichnet jeden Frame ohnehin neu (`TimelineView(.animation)`), und eine
    /// zweite, unabhängig laufende Animationsschleife darüber würde mit dieser
    /// um dieselbe Position streiten.
    private func updateCapsuleLag(_ dt: Double) {
        guard dt > 0 else { return }
        let speed: CGFloat = haveLastX ? (vm.globalX - lastGlobalX) / CGFloat(dt) : 0
        lastGlobalX = vm.globalX
        haveLastX = true

        // Ziel-Rücklage wächst mit dem Tempo, entgegen der Flugrichtung.
        let target = max(-lagMax, min(lagMax, -speed * lagPerSpeed))
        // Feder-Dämpfer, halbimplizit integriert: erst Geschwindigkeit aus der
        // Auslenkung, dann dämpfen, dann Position. Stabil auch bei Frame-Rucklern.
        let d = CGFloat(min(dt, 1.0 / 30))
        lagVelocity += (target - vm.capsuleLag) * lagStiffness * d
        lagVelocity -= lagVelocity * lagDamping * d
        vm.capsuleLag += lagVelocity * d
    }

    /// Submarine tilt from the arc's actual tangent (screen delta since last
    /// frame), softened and clamped, then eased toward the target so it never
    /// snaps. AppKit y points up, so dy>0 = climbing → nose up.
    private func updateTilt(_ p: CGPoint) {
        if haveLast {
            let dx = p.x - lastX, dy = p.y - lastY
            if abs(dx) + abs(dy) > 0.02 {
                // Vertical slope only (direction-independent), so it works flying
                // both left and right; the sub mirror handles the facing.
                let raw = atan2(dy, abs(dx)) * 180 / .pi
                let target = max(-vm.tiltMax, min(vm.tiltMax, raw * 0.7))
                vm.tilt += (target - vm.tilt) * 0.30
            }
        }
        lastX = p.x; lastY = p.y; haveLast = true
    }

    private func approach(_ current: CGFloat, _ target: CGFloat, _ f: CGFloat) -> CGFloat {
        current + (target - current) * f
    }

    /// Per-frame approach factor scaled to the actual elapsed time, so the
    /// docking/exit glide has the same speed no matter which driver ticked.
    private func approachFactor(_ perFrame: CGFloat, _ dt: Double) -> CGFloat {
        1 - pow(1 - perFrame, CGFloat(dt / frameInterval))
    }

    /// Linear travel, but eased through the middle so the text is readable,
    /// without ever nearly stopping (small coefficient keeps it clearly moving).
    private func readingEase(_ p: Double) -> Double {
        let e = p + 0.05 * sin(2 * .pi * p)
        return min(1, max(0, e))
    }

    /// The hoverable / clickable region is just the top capsule strip of the
    /// virtual box, the rest is head-room for the tilting sub.
    private func capsuleHitRect(_ f: CGRect) -> CGRect {
        CGRect(x: f.minX, y: f.maxY - BannerContentView.capsuleZone, width: f.width, height: BannerContentView.capsuleZone)
    }

    /// Polled hover: docks IN PLACE while the pointer is over the capsule
    /// (gliding to the screen centre read as a glitch), undocks into the exit
    /// glide one second after it leaves. The bands accept mouse events only
    /// while the cursor is over the capsule, so the wide transparent bands
    /// never swallow clicks meant for windows beneath them.
    private func updateHover(_ now: Date) {
        if pinnedDocked { return }   // debug: never leave the docked pose
        let mouse = NSEvent.mouseLocation
        var inside = capsuleHitRect(virtualFrame).contains(mouse)
        if let ad = BannerDemo.autodock {
            // Nur für Videos: Andocken nach Uhr statt nach Maus, Bänder bleiben durchklickbar.
            let el = now.timeIntervalSince(createdAt)
            inside = el >= ad.start && el < ad.start + ad.length
        } else {
            for b in bands { b.ignoresMouseEvents = !inside }
        }
        if detailsOpen { return }    // pinned while the detail popover is open
        if inside != mouseInside {
            mouseInside = inside
            hoverChangedAt = now
            if inside, phase == .flying {
                phase = .docked
                vm.docked = true
                // Dock in place, nudged only as far as needed so the widened
                // docked capsule (buttons) stays fully on the cursor's screen.
                if BannerDemo.autodock != nil {
                    dockCenterX = vm.globalX; dockCenterY = vm.globalY
                } else if let sf = (NSScreen.screens.first { $0.frame.contains(mouse) })?.frame {
                    dockCenterX = min(max(vm.globalX, sf.minX + 8), sf.maxX - BannerContentView.dockedWidthEstimate)
                    dockCenterY = vm.globalY
                } else {
                    dockCenterX = vm.globalX; dockCenterY = vm.globalY
                }
            }
        }
        if !inside, phase == .docked, now.timeIntervalSince(hoverChangedAt) >= 1.0 {
            vm.docked = false
            beginExit(now)
        }
    }

    /// Abgang an Ort und Stelle: Kasten zieht sich zusammen, Motiv geht (BannerMotion.exit).
    private func beginExit(_ now: Date) {
        phase = .exiting
        morphStartedAt = now
        dockCenterX = vm.globalX; dockCenterY = vm.globalY
    }

    /// Clicking the capsule pins it and shows the details beneath it (Runde 19)
    ///, both stay until the popover's × closes them together.
    private func openDetails() {
        guard !detailsOpen else { return }
        let hit = capsuleHitRect(virtualFrame)
        // Clamp to the screen the banner is on NOW.
        let screen = (NSScreen.screens.first { $0.frame.intersects(hit) })?.frame
            ?? NSScreen.main?.frame ?? hit
        detailsOpen = true
        phase = .docked
        vm.docked = true
        dockCenterX = min(max(vm.globalX, screen.minX + 8), screen.maxX - BannerContentView.dockedWidthEstimate)
        dockCenterY = vm.globalY
        DetailPopover.shared.show(meeting: vm.meeting, below: hit, clampedTo: screen,
                                  onClosed: { [weak self] in self?.close() })
    }

    private func close() {
        guard !closed else { return }
        closed = true
        writeMotionLog()
        displayLink?.invalidate(); displayLink = nil
        backupTimer?.invalidate(); backupTimer = nil
        // Banner-× while the popover is open: both go down together. Safe
        // against recursion, the popover's onClosed re-enters close(), which
        // the `closed` guard above swallows.
        if detailsOpen { detailsOpen = false; DetailPopover.shared.close() }
        for b in bands { b.orderOut(nil); b.contentView = nil }
        bands = []
        onClose?()
    }
}

/// Tracks active flights so overlapping ones stack into separate lanes.
@MainActor
final class BannerPresenter {
    private var active: [Flight] = []

    func present(_ meeting: Meeting, leadMinutes: Int, seconds: Double, playSound: Bool,
                element: SkinElement = .water, pinnedDocked: Bool = false,
                subtitleOverride: String? = nil) {
        // Runde 56: Der NAME des Termins steht groß, die Vorwarnzeit klein
        // darunter. Vorher war es umgekehrt („Meeting in 2 min" groß), das ist
        // für jedes Banner derselbe Satz und beantwortet ausgerechnet die Frage
        // nicht, für die man hinschaut: WELCHER Termin ist das?
        let lead = L.t("in \(leadMinutes) min", "in \(leadMinutes) min")
        let vm = FlightVM(
            meeting: meeting,
            title: meeting.title,
            subtitle: subtitleOverride ?? "\(lead) · \(meeting.timeLabel)",
            hasLink: meeting.joinURL != nil,
            entranceElement: element
        )
        if let url = meeting.joinURL {
            vm.onCopy = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
            vm.onJoin = { MeetingLauncher.open(url, title: meeting.title) }
        }
        // Snooze: close this banner and re-announce the same meeting in 2 min.
        vm.onSnooze = { AppState.shared.snooze(meeting, minutes: AppState.shared.snoozeMinutes) }
        let flight = Flight(vm: vm, seconds: seconds, laneIndex: active.count, pinnedDocked: pinnedDocked)
        flight.onClose = { [weak self, weak flight] in self?.active.removeAll { $0 === flight } }
        active.append(flight)
        flight.start()
        if playSound { (NSSound(named: "Submarine") ?? NSSound(named: "Glass"))?.play() }
    }
}
