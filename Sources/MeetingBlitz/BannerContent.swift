import SwiftUI
import AppKit

/// Shared state for one announcement across all its screen panels.
@MainActor
final class FlightVM: ObservableObject {
    @Published var docked = false
    /// Read every frame by the banner's `TimelineView(.animation)`, so they are
    /// plain vars (no @Published storm): the presenter writes them each tick and
    /// the timeline picks up the current value on its own.
    var emergeT: Double = 0   // 0 = text hidden during the launch, 1 = settled/legible
    var tilt: Double = 0      // submarine tilt in degrees, follows the jump arc's tangent
    var facingLeft = false    // mirror the sub when the flight travels right→left
    /// Global (screen-coordinate) origin of the virtual banner box. The windows
    /// never move (Runde 21), every screen's stationary band renders the capsule
    /// at this shared position, so it slides seamlessly across display bezels.
    var globalX: CGFloat = 0
    var globalY: CGFloat = 0

    let meeting: Meeting
    let title: String
    let subtitle: String
    let hasLink: Bool
    /// Whether this flight gets a dramatic entrance at all (Runde 72, was
    /// `waterEffect` — now applies to both elements, see `entranceElement`).
    let dramaticEntrance: Bool
    /// Which entrance panel to show when `dramaticEntrance` is on: `.water`
    /// gets the SeaSplash, `.air` gets the CloudBurst (see `BannerPresenter`).
    let entranceElement: SkinElement
    var onCopy: () -> Void = {}
    var onJoin: () -> Void = {}
    var onCloseTap: () -> Void = {}
    var onDetails: () -> Void = {}
    var onSnooze: () -> Void = {}

    init(meeting: Meeting, title: String, subtitle: String, hasLink: Bool,
         dramaticEntrance: Bool = true, entranceElement: SkinElement = .water) {
        self.meeting = meeting
        self.title = title
        self.subtitle = subtitle
        self.hasLink = hasLink
        self.dramaticEntrance = dramaticEntrance
        self.entranceElement = entranceElement
    }
}

/// Classic Hermite smoothstep, clamped. Eases the capsule fading in during the
/// back half of the emerge.
private func smoothstep(_ x: Double, _ a: Double, _ b: Double) -> Double {
    let t = min(1, max(0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

/// The banner: a submarine (or another skin) that leaps out of the sea — or,
/// for air motifs, bursts out of a cloud — in an arc, then cruises left→right.
/// This view fills the whole (transparent) panel; `Flight` moves the panel
/// along the jump arc and drives `emergeT`/`tilt`/`docked` on the shared
/// `FlightVM`. The sea/cloud entrance effect is a SEPARATE stationary panel
/// (`SeaSplash` or `CloudBurst`, Runde 72).
///
/// Runde 9: the capsule stays upright (text always readable); the leap is sold by
/// the panel's arc motion plus the submarine tilting along the arc's tangent,
/// rotating the whole wide text box looked heavy and clipped.
/// Runde 6b: the capsule is a DETERMINISTIC ocean gradient, not a behind-window
/// blur (a blur in this never-active accessory panel fell back to a black slab).
struct BannerContentView: View {
    @ObservedObject var vm: FlightVM
    /// The hosting band's fixed position (AppKit coords): its left edge and TOP
    /// edge. The view maps the shared global position into band-local offsets.
    let bandOriginX: CGFloat
    let bandTopY: CGFloat

    /// Gesamtskalierung des Banners (20.08.2026, Rückmeldung "das ganze Banner
    /// ist zu klein"). EIN Faktor statt zwanzig Einzelzahlen: multipliziert die
    /// komplette Kapsel (Icon, Schrift, Buttons, Innenabstände) UND die
    /// Flugbahn-Geometrie unten, die von der Kapselgröße abhängt (Panelbox,
    /// Splash-Ansatzpunkt, reservierte Docking-Breite). Ändert NUR die Größe,
    /// nicht das Timing/Gefühl des Fluges (Sprungdauer/-höhe bleiben unten in
    /// BannerPresenter unangetastet).
    static let scale: CGFloat = 1.35

    // Virtual banner-box geometry (the moving region the capsule lives in).
    // Wide/tall enough for the DOCKED capsule (buttons) + the raised sub + ×.
    static let panelW: CGFloat = 640 * scale
    static let panelH: CGFloat = 132 * scale
    static let capsuleLeading: CGFloat = 18 * scale
    static let capsuleTop: CGFloat = 42 * scale
    /// Capsule strip used for hover-docking + the detail popover.
    static let capsuleZone: CGFloat = 118 * scale
    /// Reserved width for the DOCKED capsule (buttons out) so it never clamps
    /// off-screen — used both for the hover-dock clamp and the detail popover
    /// clamp (Runde 9/19). Was a bare "560" in two places; now one constant
    /// that scales with everything else.
    static let dockedWidthEstimate: CGFloat = 560 * scale

    var body: some View {
        TimelineView(.animation) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            let bubble = now.truncatingRemainder(dividingBy: 1.4) / 1.4

            CapsuleView(vm: vm, bubble: bubble, now: now)
                .padding(.leading, Self.capsuleLeading)
                .padding(.top, Self.capsuleTop)
                // Band-local position of the virtual box (SwiftUI y grows down,
                // AppKit y grows up, hence the flip against the band's top).
                .offset(x: vm.globalX - bandOriginX,
                        y: bandTopY - (vm.globalY + Self.panelH))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The info pill itself (submarine + text, plus the docked action buttons).
/// `fixedSize` so it is only as wide as its content.
private struct CapsuleView: View {
    @ObservedObject var vm: FlightVM
    let bubble: Double
    let now: Double

    /// Kurzname für den globalen Banner-Maßstab (Rückmeldung 20.08.: "das
    /// ganze Banner ist zu klein"). JEDE Größe hier unten geht durch `s`, damit
    /// Icon, Schrift, Buttons und Abstände gemeinsam wachsen statt nur die
    /// Hülle — sonst sieht es aus wie eine leere Kapsel mit kleinem Inhalt.
    private var s: CGFloat { BannerContentView.scale }

    var body: some View {
        HStack(spacing: 12 * s) {
            flyingObject
                .shadow(color: Color(hex: 0x2EC7A0).opacity(0.6), radius: 9 * s)
                .offset(y: -6 * s)
                // Nose follows the jump arc's tangent (nose-up climbing, nose-down
                // on the way down); flips sign when mirrored. Small idle bob on top.
                .rotationEffect(.degrees((vm.facingLeft ? 1 : -1) * vm.tilt + sin(now * 2.2) * 2))
            VStack(alignment: .leading, spacing: 2 * s) {
                Text(vm.title)
                    .font(.system(size: 15 * s, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                Text(vm.subtitle)
                    .font(.system(size: 12 * s))
                    .foregroundStyle(Color(hex: 0xEAF6F2))
                    .shadow(color: .black.opacity(0.30), radius: 1, y: 0.5)
            }
            if vm.docked {
                Divider().frame(height: 26 * s).overlay(Color.white.opacity(0.18))
                // F4: zeigt die eingestellte Dauer statt fester „2 min".
                actionButton("moon.zzz.fill", "\(AppState.shared.snoozeMinutes) min") { vm.onSnooze() }
                if vm.hasLink {
                    actionButton("doc.on.doc", "Copy") { vm.onCopy() }
                    actionButton("video.fill", L.t("Beitreten", "Join"), filled: true) { vm.onJoin() }
                }
            } else if vm.hasLink {
                // Runde 56: Im Flug verrät sonst nichts, dass zu diesem Termin
                // ein Videocall gehört, die Knöpfe zum Kopieren und Beitreten
                // erscheinen erst beim Andocken, und wer das nicht weiß, zeigt
                // nie mit der Maus hin. Das Kamerasymbol ist der Hinweis darauf.
                Image(systemName: "video.fill")
                    .font(.system(size: 13 * s))
                    .foregroundStyle(Color(hex: 0xEAF6F2).opacity(0.8))
                    .shadow(color: .black.opacity(0.30), radius: 1, y: 0.5)
                    .padding(.leading, 2 * s)
            }
        }
        .padding(.leading, 12 * s)
        .padding(.trailing, (vm.docked ? 14 : 20) * s)
        .padding(.vertical, 11 * s)
        .background(
            // Deterministic ocean gradient, clearly teal, never a black slab.
            RoundedRectangle(cornerRadius: 19 * s, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hex: 0x18A9B4), Color(hex: 0x0A4E58)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        // A hairline rim in a TEAL tint (not the old near-white stroke, which
        // showed as bright "white corners"), just enough to define the edge.
        .overlay(
            RoundedRectangle(cornerRadius: 19 * s, style: .continuous)
                .strokeBorder(Color(hex: 0x2EC7A0).opacity(0.30), lineWidth: 1 * s)
        )
        .contentShape(RoundedRectangle(cornerRadius: 19 * s, style: .continuous))
        .onTapGesture { vm.onDetails() }
        .overlay(alignment: .topTrailing) { closeButton }
        // No drop shadow, it read as a black bar/cut under the pill (mehrfach gemeldet).
        // The saturated teal fill carries enough contrast on its own.
        .fixedSize()
        .animation(.easeInOut(duration: 0.18), value: vm.docked)
    }

    /// The mascot itself: the classic Canvas-drawn U-Boot, or one of the 27
    /// SVG skins the user picked in Settings → Banner → Flugobjekt. Falls
    /// cleanly back to the classic sub if the chosen skin can't be loaded
    /// (missing bundle resource etc.) — never crashes, never shows nothing.
    ///
    /// Runde 20.08. (2. Rückmeldung): ein fester quadratischer Rahmen
    /// zwängte breite Motive (F-22 ~4,15:1) per aspectRatio(.fit) auf einen
    /// dünnen Streifen. Jetzt folgt die Breite dem echten Seitenverhältnis der
    /// geladenen SVG (`image.size`, das die SVGs korrekt liefern), Höhe fix,
    /// gedeckelt auf `skinMaxWidth` — jenseits davon schrumpft die Höhe
    /// mit, nie eine Verzerrung.
    @ViewBuilder
    private var flyingObject: some View {
        let state = AppState.shared
        if state.skinStyle != .classic,
           let image = Skins.shared.image(for: state.currentSkin, style: state.skinStyle) {
            let size = skinFrameSize(for: image)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .scaleEffect(x: vm.facingLeft ? -1 : 1, y: 1)   // mirror when flying left
        } else {
            SubmarineView(bubblePhase: bubble)
                .scaleEffect(x: vm.facingLeft ? -1.32 * s : 1.32 * s, y: 1.32 * s)   // mirror when flying left
                .frame(width: 62 * s, height: 54 * s)
        }
    }

    /// Zielhöhe für jedes Skin-Motiv (gleiche Bildwucht für alle 27), Breite
    /// = Höhe × Seitenverhältnis, gedeckelt auf `skinMaxWidth`. Beide Werte
    /// hängen am globalen Banner-Maßstab `s`, damit sie mitwachsen, wenn der
    /// Maßstab sich ändert.
    private func skinFrameSize(for image: NSImage) -> CGSize {
        let targetHeight = 54 * s
        let maxWidth = 160 * s
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return CGSize(width: targetHeight, height: targetHeight) }
        let aspect = w / h
        let width = targetHeight * aspect
        if width <= maxWidth { return CGSize(width: width, height: targetHeight) }
        return CGSize(width: maxWidth, height: maxWidth / aspect)   // width capped → height gives way, never stretched
    }

    private var closeButton: some View {
        CornerCloseButton(help: L.t("Banner schließen, der Termin bleibt, nur die Anzeige geht weg",
                                    "Close the banner, the event stays, only this display goes away"),
                          scale: s) {
            vm.onCloseTap()
        }
    }

    private func actionButton(_ icon: String, _ label: String, filled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4 * s) {
                Image(systemName: icon).font(.system(size: 11 * s))
                Text(label).font(.system(size: 12 * s, weight: .medium))
            }
            .padding(.horizontal, 10 * s).padding(.vertical, 6 * s)
            .background(filled ? Color(hex: 0x2EC7A0) : Color.white.opacity(0.14))
            .foregroundStyle(filled ? Color(hex: 0x06231C) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 9 * s, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail popover (point 7)

/// Small always-on-top panel with the meeting's details, shown when the user
/// clicks the docked banner (which stays visible above it, Runde 19). Closes
/// ONLY via its × or after join/calendar, never on an outside click.
/// `onClosed` lets the owning Flight go down together with it.
@MainActor
final class DetailPopover {
    static let shared = DetailPopover()
    private var panel: NSPanel?
    var onClosed: (() -> Void)?

    func show(meeting: Meeting, below bannerFrame: CGRect, clampedTo screenFrame: CGRect,
              onClosed: (() -> Void)? = nil) {
        close()
        self.onClosed = onClosed
        let host = FirstMouseHostingView(rootView: MeetingDetailView(meeting: meeting) { [weak self] in self?.close() })
        let size = host.fittingSize
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host

        var x = bannerFrame.midX - size.width / 2
        x = min(max(x, screenFrame.minX + 12), screenFrame.maxX - size.width - 12)
        let y = max(bannerFrame.minY - 8 - size.height, screenFrame.minY + 12)
        panel.setFrameOrigin(CGPoint(x: x, y: y))
        panel.orderFrontRegardless()
        self.panel = panel
        // Deliberately NO outside-click dismissal (Runde 19): a stray click made
        // the popover vanish ("verklickt und weg"). It closes ONLY via its ×,
        // or after Beitreten/Kalender, which fulfil its purpose.
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        let cb = onClosed
        onClosed = nil
        cb?()
    }
}

/// Content of the detail popover: title, time range, live countdown and the
/// meeting actions.
private struct MeetingDetailView: View {
    let meeting: Meeting
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.trailing, 14)   // clear of the corner ×
                Text(meeting.calendarTitle.isEmpty ? meeting.rangeLabel : "\(meeting.rangeLabel) · \(meeting.calendarTitle)")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x9AA0B4))
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(meeting.countdownLabel)
                    .font(.system(size: 18, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(hex: 0x8EE6C8))
            }

            HStack(spacing: 8) {
                if let url = meeting.joinURL {
                    pillButton("video.fill", L.t("Beitreten", "Join"), filled: true) {
                        MeetingLauncher.open(url, title: meeting.title); onClose()
                    }
                    pillButton("doc.on.doc", copied ? L.t("Kopiert ✓", "Copied ✓") : L.t("Link kopieren", "Copy link")) {
                        AppState.shared.copyLink(url)
                        copied = true
                    }
                }
                pillButton("calendar", L.t("Kalender", "Calendar")) {
                    AppState.shared.openInCalendar(meeting); onClose()
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        // Same design language as the banner capsule: radius 19 + teal hairline
        // + the identical corner × poking over the top-right edge.
        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color(hex: 0x181928).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(Color(hex: 0x2EC7A0).opacity(0.30), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            CornerCloseButton(help: L.t("Schließen", "Close"), action: onClose)
        }
        .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 4)
        .padding(16)   // room for the shadow inside the borderless panel
    }

    private func pillButton(_ icon: String, _ label: String, filled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(filled ? Color(hex: 0x2EC7A0) : Color.white.opacity(0.08))
            .foregroundStyle(filled ? Color(hex: 0x08130E) : Color(hex: 0x8EE6C8))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
