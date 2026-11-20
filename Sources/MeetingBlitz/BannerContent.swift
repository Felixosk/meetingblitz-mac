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
    /// Overlapping Action (Runde 70): wie weit das Flugobjekt der Kapsel gerade
    /// vorauseilt, in Punkten. Der Presenter rechnet dafür eine Feder gegen die
    /// aktuelle Fluggeschwindigkeit, die Kapsel selbst bleibt starr.
    var capsuleLag: CGFloat = 0
    var facingLeft = false    // mirror the sub when the flight travels right→left
    // Auftritt/Abgang (BannerMotion in BannerCapsule.swift). Alle neutral = fertiger Banner.
    var bgAlpha: Double = 1
    var contentAlpha: Double = 1
    var contentBlur: CGFloat = 0, contentDY: CGFloat = 0
    var motifDX: CGFloat = 0, motifDY: CGFloat = 0
    var motifAlpha: Double = 1, motifPop: CGFloat = 1, motifBlur: CGFloat = 0
    var tiltMax: Double = 10
    /// Echte Breite/Höhe des Kastens (0..1) und die Bläschen beim Auftauchen.
    var barW: CGFloat = 1, barH: CGFloat = 1
    var rise: Double = 0
    /// Global (screen-coordinate) origin of the virtual banner box. The windows
    /// never move (Runde 21), every screen's stationary band renders the capsule
    /// at this shared position, so it slides seamlessly across display bezels.
    var globalX: CGFloat = 0
    var globalY: CGFloat = 0

    let meeting: Meeting
    let title: String
    let subtitle: String
    let hasLink: Bool
    /// Wasser-Motive tauchen von unten auf, Luft-Motive sinken von oben (BannerMotion).
    let entranceElement: SkinElement
    var onCopy: () -> Void = {}
    var onJoin: () -> Void = {}
    var onCloseTap: () -> Void = {}
    var onDetails: () -> Void = {}
    var onSnooze: () -> Void = {}

    init(meeting: Meeting, title: String, subtitle: String, hasLink: Bool,
         entranceElement: SkinElement = .water) {
        self.meeting = meeting
        self.title = title
        self.subtitle = subtitle
        self.hasLink = hasLink
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

    /// 🚨 DREI MASSSTÄBE, BEWUSST GETRENNT (24.08.2026). Vorher war es einer.
    ///
    /// Am 20.08. kam die Rückmeldung „das Banner ist zu klein", und daraufhin
    /// vergrößerte EIN Faktor 1.35 alles zugleich. Gemeint war aber nur das
    /// TIER — der Balken wirkte danach fett („es ging da eher ums Tier, nicht
    /// den Balken", 24.08.). Wer hier wieder zusammenlegt, baut genau diesen
    /// Fehler nach.
    ///
    /// `capsuleScale` — nur der Balken: Schrift, Knöpfe, Innenabstände, Radius.
    /// Steht in den Einstellungen, Standard 1.0 = Stand vor dem 20.08.
    @MainActor static var capsuleScale: CGFloat { CGFloat(AppState.shared.bannerScale) }

    /// `motifScale` — nur das Flugobjekt. Fix, damit das Tier seine Wucht
    /// behält, egal wie schlank der Balken eingestellt ist. Entspricht dem
    /// bisherigen Gesamtfaktor, das Motiv sieht also aus wie gewohnt.
    static let motifScale: CGFloat = 1.35

    /// `geometryScale` — die Fensterbox und die Flugbahn. Nimmt das MAXIMUM
    /// beider Maßstäbe: die Box muss das größere von beiden fassen. Nähme sie
    /// nur `capsuleScale`, würde ein großes Motiv bei schlankem Balken oben
    /// abgeschnitten, weil das Panel der Fensterrahmen ist und nicht mitwächst.
    @MainActor static var geometryScale: CGFloat { max(capsuleScale, motifScale) }

    // Virtual banner-box geometry (the moving region the capsule lives in).
    // Wide/tall enough for the DOCKED capsule (buttons) + the raised sub + ×.
    @MainActor static var panelW: CGFloat { 640 * geometryScale }
    @MainActor static var panelH: CGFloat { 132 * geometryScale }
    @MainActor static var capsuleLeading: CGFloat { 18 * geometryScale }
    @MainActor static var capsuleTop: CGFloat { 42 * geometryScale }
    /// Capsule strip used for hover-docking + the detail popover.
    @MainActor static var capsuleZone: CGFloat { 118 * geometryScale }
    /// Reserved width for the DOCKED capsule (buttons out) so it never clamps
    /// off-screen — used both for the hover-dock clamp and the detail popover
    /// clamp (Runde 9/19). Was a bare "560" in two places; now one constant
    /// that scales with everything else.
    @MainActor static var dockedWidthEstimate: CGFloat { 560 * geometryScale }

    var body: some View {
        TimelineView(.animation) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            let bubble = now.truncatingRemainder(dividingBy: 1.4) / 1.4

            BannerCapsule(vm: vm, now: now, bubble: bubble)
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
        panel.hasShadow = Theme.systemShadow
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
/// meeting actions. Runde 117: Glas wie alle Fenster (folgt Hell/Dunkel und der
/// Glas-Einstellung), Theme-Knöpfe, rundes ✕ auf der Ecke, kein Türkis mehr.
private struct MeetingDetailView: View {
    let meeting: Meeting
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.theme(.normal, .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(2)
                    .padding(.trailing, Theme.s16)   // Abstand zum ✕
                Text(meeting.calendarTitle.isEmpty ? meeting.rangeLabel : "\(meeting.rangeLabel) · \(meeting.calendarTitle)")
                    .font(.theme(.small))
                    .foregroundStyle(Theme.muted)
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(meeting.countdownLabel)
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.blue)
            }

            HStack(spacing: Theme.s8) {
                if let url = meeting.joinURL {
                    detailButton("video.fill", L.t("Beitreten", "Join"), primary: true) {
                        MeetingLauncher.open(url, title: meeting.title); onClose()
                    }
                    detailButton("doc.on.doc", copied ? L.t("Kopiert ✓", "Copied ✓") : L.t("Link kopieren", "Copy link"), primary: false) {
                        AppState.shared.copyLink(url)
                        copied = true
                    }
                }
                detailButton("calendar", L.t("Kalender", "Calendar"), primary: false) {
                    AppState.shared.openInCalendar(meeting); onClose()
                }
            }
        }
        .padding(Theme.s16)
        .frame(width: 430, alignment: .leading)
        .background(ThemeGlass())
        .themeCloseCorner { onClose() }
        .padding(Theme.stageInset)   // durchsichtige Bühne rundum, wie bei den anderen Fenstern
    }

    /// Gleiche Knöpfe wie im Banner: Beitreten = blau, Rest = graue Füllung mit Textfarbe
    /// (der Theme-Zweitknopf hat weiße Schrift und wäre im Hell-Modus kaum lesbar).
    private func detailButton(_ icon: String, _ label: String, primary: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .padding(.horizontal, 12).frame(height: Theme.iconButtonSize + 4)
            .foregroundStyle(primary ? Theme.onBlue : Theme.label)
            .background(Capsule().fill(primary ? Theme.blue : Theme.fillStrong))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
