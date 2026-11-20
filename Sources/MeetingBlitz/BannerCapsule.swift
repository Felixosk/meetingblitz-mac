import SwiftUI
import AppKit

// MARK: - Banner: Liquid Glass (L2) + Auftauchen (A9)  (Runde 117, 20.11.2026)
//
// Gewählt wurde aus den Varianten L1-L5 / A1-A9 diese gewählt: Look "Liquid Glass,
// Blau als Tönung" und Animation "Auftauchen" (Kasten baut sich von links auf,
// dann taucht das Motiv auf, beim Gehen zieht sich der Kasten zusammen). Der
// Rest ist gelöscht. Es gibt nur noch zwei Demo-Hilfen (Umgebungsvariablen):
//
//   MB_BANNER_AUTODOCK="3.2,2.2"  nur für Videos: dockt nach 3,2 s für 2,2 s an,
//                                 als läge die Maus darauf (kein Klick, keine Maus)
//   MB_BANNER_BACKDROP=1          nur Demo: ruhige Tapete hinter dem Banner

enum BannerDemo {
    static let autodock: (start: Double, length: Double)? = {
        guard let raw = ProcessInfo.processInfo.environment["MB_BANNER_AUTODOCK"] else { return nil }
        let p = raw.split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? (p[0], p[1]) : nil
    }()
}

// MARK: Kurven

enum BannerCurve {
    static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
    static func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let t = clamp01((x - a) / (b - a)); return t * t * (3 - 2 * t)
    }
    static func easeInCubic(_ x: Double) -> Double { let t = clamp01(x); return t * t * t }
}

// MARK: - Der Balken

/// Der Banner-Balken: Liquid Glass mit blauer Tönung, das Motiv ragt über die
/// linke Kante. Folgt Hell/Dunkel und der Glas-Einstellung wie alle Fenster.
struct BannerCapsule: View {
    @ObservedObject var vm: FlightVM
    let now: Double
    let bubble: Double
    @Environment(\.colorScheme) private var scheme
    @AppStorage(Look.glassKey) private var glassRaw = Look.Glass.normal.rawValue

    private var s: CGFloat { BannerContentView.capsuleScale }
    private var dark: Bool { scheme == .dark }

    // Titel und Uhrzeit stehen vorne: das Motiv ist kleiner als früher und
    // ragt über die linke Kante hinaus, statt den Text nach rechts zu schieben.
    // Runde 122d (Rückmeldung 20.11.: "Objekt zu klein, muss größer sein"): 75×150 -> 110×280 pt (Höhe +47 %, lange Motive bis +87 % breiter).
    // Der Platz im Balken (`slotWidth`) wächst mit, der Text rückt nach rechts und wird nie verdeckt.
    private var motifHeight: CGFloat { 110 * s }
    private var motifMaxWidth: CGFloat { 280 * s }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20 * s, style: .continuous) }

    var body: some View {
        barContent
            .opacity(vm.contentAlpha)
            .blur(radius: vm.contentBlur)
            .offset(y: vm.contentDY)
            .padding(.leading, 12 * s)
            .padding(.trailing, (vm.docked ? 12 : 18) * s)
            .padding(.vertical, 10 * s)
            .background(
                GeometryReader { g in
                    // Der Balken wächst in echter Breite (nicht gestreckt), damit die
                    // runden Enden rund bleiben. Kleinste Form = Kreis.
                    let h = g.size.height * vm.barH
                    let w = max(h, g.size.width * vm.barW)
                    glass(tint: Theme.blue.opacity(dark ? 0.30 : 0.16))
                        .frame(width: w, height: h)
                        .frame(width: g.size.width, height: g.size.height, alignment: .leading)
                }
                .opacity(vm.bgAlpha)
            )
            .contentShape(shape)
            .onTapGesture { vm.onDetails() }
            .overlay(alignment: .topTrailing) {
                CornerCloseButton(help: L.t("Banner schließen, der Termin bleibt, nur die Anzeige geht weg",
                                            "Close the banner, the event stays, only this display goes away"),
                                  scale: s) { vm.onCloseTap() }
                    .opacity(vm.contentAlpha)
            }
            .overlay(alignment: .leading) { motifLayer }
            .fixedSize()
            .animation(.spring(response: 0.36, dampingFraction: 0.84), value: vm.docked)
    }

    // MARK: Inhalt

    private var barContent: some View {
        HStack(spacing: 10 * s) {
            Color.clear.frame(width: slotWidth, height: 1)
            VStack(alignment: .leading, spacing: 2 * s) {
                Text(vm.title).font(.system(size: 15 * s, weight: .semibold)).foregroundStyle(Theme.label)
                    .lineLimit(1)
                Text(vm.subtitle).font(.system(size: 12 * s).monospacedDigit()).foregroundStyle(Theme.muted)
            }
            trailingControls
        }
    }

    @ViewBuilder private var trailingControls: some View {
        if vm.docked {
            Rectangle().fill(Theme.line).frame(width: 1, height: 24 * s)
            buttons
        } else if vm.hasLink {
            Image(systemName: "video.fill").font(.system(size: 12 * s)).foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder private var buttons: some View {
        pill("moon.zzz.fill", "\(AppState.shared.snoozeMinutes) min", primary: false) { vm.onSnooze() }
        if vm.hasLink {
            pill("doc.on.doc", L.t("Kopieren", "Copy"), primary: false) { vm.onCopy() }
            pill("video.fill", L.t("Beitreten", "Join"), primary: true) { vm.onJoin() }
        }
    }

    /// Knöpfe wie im Theme: Beitreten = blauer Hauptknopf, Rest = graue Füllung.
    private func pill(_ icon: String, _ label: String, primary: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4 * s) {
                Image(systemName: icon).font(.system(size: 11 * s, weight: .semibold))
                Text(label).font(.system(size: 12 * s, weight: .semibold))
            }
            .padding(.horizontal, 10 * s).padding(.vertical, 6 * s)
            .foregroundStyle(primary ? Theme.onBlue : Theme.label)
            .background(Capsule().fill(primary ? Theme.blue : Theme.fillStrong))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Glas

    /// Gleiches Glas wie `ThemeGlass` (Widget), nur in Balkenform.
    @ViewBuilder private func glass(tint: Color) -> some View {
        let clear = glassRaw == Look.Glass.clear.rawValue
        let wash = Theme.glassWashInactive * (clear ? 0.5 : 1) * (dark ? 1 : 1.7)
        if #available(macOS 26.0, *) {
            (dark ? Color.black : Color.white).opacity(wash)
                .clipShape(shape)
                .glassEffect(Glass.regular.tint(tint), in: shape)
                .overlay(ThemeEdge(radius: 20 * s))
                .shadow(color: .black.opacity(dark ? 0.35 : 0.22), radius: 12 * s, y: 5 * s)   // Runde 118: weicher Schatten nur unter dem Glas
        } else {
            VisualEffectBackground(material: .menu)
                .clipShape(shape)
                .overlay(shape.fill(tint))
                .overlay(ThemeEdge(radius: 20 * s))
                .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        }
    }

    // MARK: Motiv

    private var motifImage: NSImage? {
        let state = AppState.shared
        guard state.skinStyle != .classic else { return nil }
        return Skins.shared.image(for: state.currentSkin, style: state.skinStyle)
    }

    private var motifSize: CGSize {
        let h = motifHeight
        guard let img = motifImage, img.size.width > 0, img.size.height > 0 else {
            return CGSize(width: h * 62 / 54, height: h)
        }
        let aspect = img.size.width / img.size.height
        let w = h * aspect
        return w <= motifMaxWidth ? CGSize(width: w, height: h) : CGSize(width: motifMaxWidth, height: motifMaxWidth / aspect)
    }

    /// Platz im Balken für das Motiv: gut ein Viertel ragt über die linke Kante.
    private var slotWidth: CGFloat { motifSize.width * 0.72 }
    private var motifLead: CGFloat { 12 * s - motifSize.width * 0.28 }

    @ViewBuilder private var motifView: some View {
        let size = motifSize
        if let img = motifImage {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .scaleEffect(x: vm.facingLeft ? -1 : 1, y: 1)
        } else {
            let k = size.height / 54
            SubmarineView(bubblePhase: bubble)
                .scaleEffect(x: (vm.facingLeft ? -1.32 : 1.32) * k, y: 1.32 * k)
                .frame(width: 62 * k, height: 54 * k)
        }
    }

    /// Bläschen beim Auftauchen: Wasser-Motive steigen von unten, Luft-Motive sinken von oben.
    @ViewBuilder private var popExtras: some View {
        if vm.rise > 0.001 && vm.rise < 1 {
            let f = vm.rise
            ForEach(0..<6, id: \.self) { i in
                let x = CGFloat([-22, -8, 6, 18, -14, 26][i]) * s
                let delay = Double(i) * 0.08
                let p = min(1, max(0, (f - delay) / 0.75))
                Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1)
                    .background(Circle().fill(Color.white.opacity(0.15)))
                    .frame(width: CGFloat([6, 4, 7, 5, 3, 4][i]) * s, height: CGFloat([6, 4, 7, 5, 3, 4][i]) * s)
                    .offset(x: x + CGFloat(sin(p * 9 + Double(i))) * 3, y: (vm.entranceElement == .water ? 30 - 70 * p : -30 + 60 * p) * s)
                    .opacity(p > 0 ? (1 - p) * min(1, p * 8) : 0)
            }
        }
    }

    private var motifLayer: some View {
        ZStack {
            popExtras
            motifView
                .shadow(color: .black.opacity(dark ? 0.35 : 0.18), radius: 5 * s, y: 3 * s)
                .rotationEffect(.degrees((vm.facingLeft ? 1 : -1) * max(-vm.tiltMax, min(vm.tiltMax, vm.tilt))
                                         + sin(now * 2.2) * 1.5))
                .scaleEffect(vm.motifPop)
                .blur(radius: vm.motifBlur)
                .opacity(vm.motifAlpha)
        }
        .offset(x: (vm.facingLeft ? 1 : -1) * vm.capsuleLag + vm.motifDX, y: -5 * s + vm.motifDY)
        .padding(.leading, motifLead)
        .allowsHitTesting(false)
    }
}

// MARK: - Auftritt und Abgang (vom Presenter je Frame aufgerufen)
//
// Federn = Apples eigenes Feder-Modell (`Spring`, dasselbe wie SwiftUI `.spring`),
// hier aber Bild für Bild aus der Wanduhr berechnet, im Takt des Bildschirms
// (CADisplayLink im Presenter). So laufen Balken, Motiv und Flug auf EINER Uhr,
// keine zweite Animationsschleife. Der Balken wächst in echter Breite.

@MainActor
enum BannerMotion {
    typealias C = BannerCurve
    static let enterDuration = 2.3
    static let exitDuration = 0.95

    /// Feder 0 → 1 nach Apples Modell. `response` = Dauer einer Schwingung,
    /// `damping` 1 = ohne Überschwingen, kleiner = mehr Federn.
    static func sp(_ t: Double, _ response: Double, _ damping: Double) -> Double {
        guard t > 0 else { return 0 }
        return Spring(response: response, dampingRatio: damping).value(target: 1.0, initialVelocity: 0.0, time: t)
    }

    static func resetMorph(_ vm: FlightVM) {
        vm.bgAlpha = 1; vm.contentAlpha = 1; vm.contentBlur = 0; vm.contentDY = 0
        vm.motifDX = 0; vm.motifDY = 0; vm.motifAlpha = 1; vm.motifPop = 1; vm.motifBlur = 0
        vm.barW = 1; vm.barH = 1; vm.rise = 0
    }

    /// Schrift kommt weich: von unscharf und 4 pt tiefer zu scharf.
    private static func text(_ vm: FlightVM, _ t: Double, _ a: Double, _ b: Double) {
        let k = C.smooth(t, a, b)
        vm.contentAlpha = k
        vm.contentBlur = CGFloat(6 * (1 - k))
        vm.contentDY = CGFloat(4 * (1 - k))
    }

    /// Auftauchen: Kasten wächst von links, dann steigt das Wasser-Motiv 34 pt von
    /// unten auf (Luft-Motive sinken von oben), mit Bläschen. Rückgabe `true` = fertig.
    static func enter(_ vm: FlightVM, t: Double) -> Bool {
        if t >= enterDuration { resetMorph(vm); vm.tilt = 0; return true }
        vm.bgAlpha = C.smooth(t, 0, 0.14)
        vm.barW = CGFloat(sp(t, 0.95, 0.88))
        vm.barH = CGFloat(0.88 + 0.12 * sp(t, 0.6, 0.7))
        text(vm, t, 0.55, 0.95)
        let u = t - 0.95
        let fromBelow: CGFloat = vm.entranceElement == .water ? 1 : -1
        vm.motifPop = u > 0 ? 1 : 0
        vm.motifDY = fromBelow * 34 * CGFloat(1 - sp(u, 0.60, 0.58))
        vm.motifDX = 0
        vm.motifAlpha = C.smooth(u, 0, 0.18)
        vm.rise = u > 0 ? C.clamp01(u / 1.1) : 0
        vm.tilt = u > 0 ? 7 * exp(-3.5 * u) * sin(8 * u) : 0
        return false
    }

    /// Abgang: Schrift aus, Kasten zieht sich bis zum Kreis am Motiv zusammen, das
    /// Motiv taucht ab (Wasser) bzw. steigt weg (Luft) und zieht davon.
    static func exit(_ vm: FlightVM, t: Double, dir: CGFloat) -> Bool {
        if t >= exitDuration { return true }
        let k = C.smooth(t, 0, 0.18)
        vm.contentAlpha = 1 - k
        vm.contentBlur = CGFloat(4 * k)
        vm.barW = CGFloat(1 - C.easeInCubic((t - 0.08) / 0.45))
        vm.barH = CGFloat(1 - 0.4 * C.smooth(t, 0.15, 0.5))
        vm.bgAlpha = 1 - C.smooth(t, 0.40, 0.55)
        let f = CGFloat(C.easeInCubic((t - 0.40) / 0.55))
        let down: CGFloat = vm.entranceElement == .water ? 1 : -1
        vm.motifDY = down * 70 * f
        vm.motifDX = dir * 120 * f
        vm.motifAlpha = 1 - C.smooth(t, 0.70, 0.95)
        vm.rise = t > 0.35 ? C.clamp01((t - 0.35) / 0.6) : 0
        return false
    }
}

// MARK: - Demo-Tapete (nur MB_BANNER_BACKDROP, für Fotos und Videos)

@MainActor
enum BannerBackdrop {
    static var panel: NSPanel?
    static func show() {
        guard let sf = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame ?? NSScreen.main?.frame else { return }
        let rect = CGRect(x: sf.minX, y: sf.maxY - 760, width: sf.width, height: 760)
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)   // Bänder landen per isFloatingPanel auf .floating
        p.collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.isOpaque = true
        p.hasShadow = false
        let host = NSHostingView(rootView: BackdropView().frame(width: rect.width, height: rect.height))
        host.frame = CGRect(origin: .zero, size: rect.size)
        p.contentView = host
        p.orderFrontRegardless()
        panel = p
    }
}

private struct BackdropView: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        ZStack {
            LinearGradient(colors: dark ? [Color(hex: 0x10172A), Color(hex: 0x1E1B3A)]
                                        : [Color(hex: 0xDCE7F7), Color(hex: 0xF3E6EE)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(hex: dark ? 0x2457C5 : 0x8DB6F5)).frame(width: 620).blur(radius: 120).offset(x: -420, y: 40)
            Circle().fill(Color(hex: dark ? 0x7A3E9D : 0xF2B8D2)).frame(width: 520).blur(radius: 120).offset(x: 380, y: -60)
            Circle().fill(Color(hex: dark ? 0xC2632F : 0xFFD9A8)).frame(width: 380).blur(radius: 110).offset(x: 80, y: 240)
            // Ein Fenster-Rand quer dahinter, damit man das Glas wirklich sieht.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(dark ? Color(hex: 0x23252D) : Color.white)
                .frame(width: 520, height: 300)
                .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<6) { i in
                            RoundedRectangle(cornerRadius: 4).fill(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                                .frame(width: CGFloat([380, 300, 420, 260, 340, 200][i]), height: 12)
                        }
                    }.padding(28)
                }
                .offset(x: 120, y: 30)
        }
        .drawingGroup()
    }
}
