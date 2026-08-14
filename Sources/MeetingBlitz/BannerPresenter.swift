import AppKit
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

/// One announcement. Runde 9 sequence: `.jumping` (capsule leaps out of the sea
/// along a parabolic arc, sub tilting with the tangent) → `.flying` (cruises
/// toward the far edge with a gentle wog). Hover docks it in place with actions,
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
    private enum Phase { case jumping, flying, docked, exiting }

    private let vm: FlightVM
    private let seconds: Double
    private let laneIndex: Int
    private let pinnedDocked: Bool     // debug: stay docked at centre (--demo-dock)
    private var bands: [NSPanel] = []
    private var splashPanels: [NSPanel] = []
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
    private var waterY: CGFloat = 0    // virtual-box y submerged
    private var cruiseX: CGFloat = 0   // virtual-box x where the cruise begins
    private var cruiseY: CGFloat = 0   // virtual-box y at cruise height
    private var endX: CGFloat = 0      // exit x at the far edge of all screens

    private let panelW = BannerContentView.panelW   // virtual banner box
    private let panelH = BannerContentView.panelH
    private let frameInterval = 1.0 / 60.0
    private let jumpDuration = 1.45    // slower, more graceful arc (Rückmeldung: „2 aber langsam")
    private let jumpDepth: CGFloat = 155   // how far below cruise the launch sits
    private let arcHeight: CGFloat = 70    // overshoot above the straight climb
    private let cruiseWog: CGFloat = 6     // gentle up/down while cruising
    private let wogCount = 2.5

    init(vm: FlightVM, seconds: Double, laneIndex: Int, pinnedDocked: Bool = false) {
        self.vm = vm
        self.seconds = seconds
        self.laneIndex = laneIndex
        self.pinnedDocked = pinnedDocked
        self.phase = pinnedDocked ? .docked : (vm.waterEffect ? .jumping : .flying)
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
            waterY = cruiseY - jumpDepth
            launchX = toRight ? (sf.minX + sf.width * 0.09) : (sf.maxX - sf.width * 0.09 - panelW)
            cruiseX = launchX + dir * (sf.width * 0.06)
            endX = toRight ? allMaxX : (allMinX - panelW)
            let centerX = sf.midX - 272
            vm.facingLeft = !toRight

            // Initial global position of the virtual box.
            if pinnedDocked {
                vm.globalX = centerX; vm.globalY = cruiseY
                dockCenterX = centerX; dockCenterY = cruiseY
            } else if vm.waterEffect {
                vm.globalX = launchX; vm.globalY = waterY
            } else {
                vm.globalX = toRight ? (sf.minX - panelW) : sf.maxX
                vm.globalY = cruiseY
            }

            // Stationary bands: full width of each screen, tall enough for the
            // whole flight (launch depth … arc overshoot). Clipped to the screen;
            // screens the flight band misses get no window.
            let bandBottom = waterY - 30
            let bandTop = cruiseY + panelH + arcHeight + 40
            for screen in screens {
                let f = screen.frame
                let y0 = max(bandBottom, f.minY)
                let y1 = min(bandTop, f.maxY)
                guard y1 - y0 > 40 else { continue }
                bands.append(makeBand(at: CGRect(x: f.minX, y: y0, width: f.width, height: y1 - y0)))
            }
            if vm.waterEffect && !pinnedDocked { splashPanels.append(makeSplash()) }
        }
        startedAt = Date()
        travelStartedAt = startedAt
        lastTickAt = startedAt
        lastX = vm.globalX; lastY = vm.globalY; haveLast = true

        if !splashPanels.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + SplashMetalView.duration + 0.3) { [weak self] in
                Task { @MainActor in self?.closeSplashes() }
            }
        }

        // Driver 1: GCD main-queue timer, 60 fps.
        let src = DispatchSource.makeTimerSource(queue: .main)
        src.schedule(deadline: .now() + frameInterval, repeating: frameInterval)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.tick() }
        }
        src.resume()
        gcdTimer = src

        // Driver 2: common-modes run-loop timer, 30 fps.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        backupTimer = t
    }

    private var gcdTimer: DispatchSourceTimer?
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
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = !pinnedDocked
        let host = FirstMouseHostingView(rootView: BannerContentView(vm: vm, bandOriginX: rect.minX, bandTopY: rect.maxY))
        host.frame = CGRect(origin: .zero, size: rect.size)
        panel.contentView = host
        panel.orderFrontRegardless()
        return panel
    }

    /// Stationary Metal-shader splash at the launch point, ordered in FRONT of
    /// the banner so the spray flies over the leaping capsule.
    private func makeSplash() -> NSPanel {
        // Big panel so droplets never hit the edge (the reference-scale shader
        // keeps them the same size; the extra room just prevents clipping).
        let splashW: CGFloat = 720, splashH: CGFloat = 600
        // Submarine centre on screen at the launch (capsule is top-padded).
        let subScreenX = launchX + BannerContentView.capsuleLeading + 31
        let subMidScreenY = waterY + panelH - BannerContentView.capsuleTop - 27
        let originX = subScreenX - 0.50 * splashW
        let originY = subMidScreenY - 0.333 * splashH
        let panel = NSPanel(contentRect: CGRect(x: originX, y: originY, width: splashW, height: splashH),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // Shader uv is y-DOWN, so the AppKit y-up fraction is flipped.
        let uvOrigin = SIMD2<Float>(Float((subScreenX - originX) / splashW),
                                    Float(1.0 - (subMidScreenY - originY) / splashH))
        let view = SplashMetalView(frame: CGRect(origin: .zero, size: CGSize(width: splashW, height: splashH)),
                                   origin: uvOrigin, amount: 100)
        panel.contentView = view
        panel.orderFrontRegardless()
        view.start()
        return panel
    }

    private func closeSplashes() {
        for p in splashPanels {
            (p.contentView as? SplashMetalView)?.stop()
            p.orderOut(nil); p.contentView = nil
        }
        splashPanels = []
    }

    /// The moving virtual banner box, in global screen coordinates.
    private var virtualFrame: CGRect {
        CGRect(x: vm.globalX, y: vm.globalY, width: panelW, height: panelH)
    }

    private func tick() {
        let now = Date()
        // Both drivers call this; collapse near-simultaneous fires into one frame.
        guard now.timeIntervalSince(lastTickAt) >= frameInterval * 0.5 else { return }
        let dt = min(now.timeIntervalSince(lastTickAt), 0.25)
        lastTickAt = now
        updateHover(now)

        switch phase {
        case .jumping:
            let jt = min(1, now.timeIntervalSince(startedAt) / jumpDuration)
            let e = 1 - (1 - jt) * (1 - jt)                // easeOut: fast off the water, settle
            let arc = arcHeight * sin(.pi * jt)            // parabolic overshoot, 0 at both ends
            vm.globalX = launchX + (cruiseX - launchX) * e
            vm.globalY = waterY + (cruiseY - waterY) * e + arc
            updateTilt(CGPoint(x: vm.globalX, y: vm.globalY))
            if jt >= 1 { phase = .flying; travelStartedAt = now }
        case .flying:
            let te = now.timeIntervalSince(travelStartedAt)
            let progress = te / seconds
            if progress >= 1 { close(); return }
            let eased = readingEase(progress)
            vm.globalX = cruiseX + (endX - cruiseX) * eased
            vm.globalY = cruiseY + cruiseWog * sin(2 * .pi * progress * wogCount)
            updateTilt(CGPoint(x: vm.globalX, y: vm.globalY))
        case .docked:
            let f = approachFactor(0.22, dt)
            vm.globalX = approach(vm.globalX, dockCenterX, f)
            vm.globalY = approach(vm.globalY, dockCenterY, f)
            vm.tilt += (0 - vm.tilt) * 0.25              // level out when docked
        case .exiting:
            let f = approachFactor(0.16, dt)
            vm.globalX = approach(vm.globalX, endX, f)
            vm.tilt += (0 - vm.tilt) * 0.2
            if abs(vm.globalX - endX) <= 4 { close() }
        }
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
                let target = max(-34, min(34, raw * 0.7))
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
        let inside = capsuleHitRect(virtualFrame).contains(mouse)
        for b in bands { b.ignoresMouseEvents = !inside }
        if detailsOpen { return }    // pinned while the detail popover is open
        if inside != mouseInside {
            mouseInside = inside
            hoverChangedAt = now
            if inside, phase == .flying {
                phase = .docked
                vm.docked = true
                // Dock in place, nudged only as far as needed so the widened
                // docked capsule (buttons) stays fully on the cursor's screen.
                if let sf = (NSScreen.screens.first { $0.frame.contains(mouse) })?.frame {
                    let dockedCapsuleW: CGFloat = 560
                    dockCenterX = min(max(vm.globalX, sf.minX + 8), sf.maxX - dockedCapsuleW)
                    dockCenterY = vm.globalY
                } else {
                    dockCenterX = vm.globalX; dockCenterY = vm.globalY
                }
            }
        }
        if !inside, phase == .docked, now.timeIntervalSince(hoverChangedAt) >= 1.0 {
            vm.docked = false
            phase = .exiting
        }
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
        dockCenterX = min(max(vm.globalX, screen.minX + 8), screen.maxX - 560)
        dockCenterY = vm.globalY
        DetailPopover.shared.show(meeting: vm.meeting, below: hit, clampedTo: screen,
                                  onClosed: { [weak self] in self?.close() })
    }

    private func close() {
        guard !closed else { return }
        closed = true
        gcdTimer?.cancel(); gcdTimer = nil
        backupTimer?.invalidate(); backupTimer = nil
        closeSplashes()
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

    func present(_ meeting: Meeting, leadMinutes: Int, seconds: Double, playSound: Bool, water: Bool = true, pinnedDocked: Bool = false) {
        // Runde 56: Der NAME des Termins steht groß, die Vorwarnzeit klein
        // darunter. Vorher war es umgekehrt („Meeting in 2 min" groß), das ist
        // für jedes Banner derselbe Satz und beantwortet ausgerechnet die Frage
        // nicht, für die man hinschaut: WELCHER Termin ist das?
        let lead = L.t("in \(leadMinutes) min", "in \(leadMinutes) min")
        let vm = FlightVM(
            meeting: meeting,
            title: meeting.title,
            subtitle: "\(lead) · \(meeting.timeLabel)",
            hasLink: meeting.joinURL != nil,
            waterEffect: water
        )
        if let url = meeting.joinURL {
            vm.onCopy = { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
            vm.onJoin = { MeetingLauncher.open(url, title: meeting.title) }
        }
        // Snooze: close this banner and re-announce the same meeting in 2 min.
        vm.onSnooze = { AppState.shared.snooze(meeting, minutes: 2) }
        let flight = Flight(vm: vm, seconds: seconds, laneIndex: active.count, pinnedDocked: pinnedDocked)
        flight.onClose = { [weak self, weak flight] in self?.active.removeAll { $0 === flight } }
        active.append(flight)
        flight.start()
        if playSound { (NSSound(named: "Submarine") ?? NSSound(named: "Glass"))?.play() }
    }
}
