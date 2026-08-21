import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// The flying U-Boot mascot, drawn with Canvas (no assets). Nose points right,
/// the way it travels. `bubble` phases the trailing air bubbles.
struct SubmarineView: View {
    var bubblePhase: Double = 0

    private let body_ = Color(hex: 0x2EC7A0)
    private let dark = Color(hex: 0x1D9E79)
    private let glow = Color(hex: 0x8EE6C8)
    private let amber = Color(hex: 0xF0A93B)
    private let ink = Color(hex: 0x0E1220)

    var body: some View {
        Canvas { ctx, _ in
            // Propeller + shaft (back / left)
            var shaft = Path()
            shaft.move(to: CGPoint(x: 9, y: 17)); shaft.addLine(to: CGPoint(x: 5.5, y: 17))
            ctx.stroke(shaft, with: .color(dark), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: 3.2, y: 12, width: 3.4, height: 10)), with: .color(dark))

            // Trailing bubbles
            for i in 0..<3 {
                let p = (bubblePhase + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                let x = 3.5 - p * 3.5
                let y = 17 - (Double(i) - 1) * 5 - p * 2
                let r = 1.4 - p * 0.8
                if r > 0.2 {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(glow.opacity(0.7 - p * 0.5)))
                }
            }

            // Hull
            ctx.fill(Path(roundedRect: CGRect(x: 8, y: 8, width: 33, height: 18), cornerRadius: 9), with: .color(body_))
            // Conning tower
            ctx.fill(Path(roundedRect: CGRect(x: 18, y: 2.5, width: 9, height: 7), cornerRadius: 2.6), with: .color(dark))
            // Periscope
            var peri = Path()
            peri.move(to: CGPoint(x: 23, y: 2.6)); peri.addLine(to: CGPoint(x: 23, y: 0.9))
            peri.addLine(to: CGPoint(x: 26, y: 0.9))
            ctx.stroke(peri, with: .color(glow), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            // Portholes
            ctx.fill(Path(ellipseIn: CGRect(x: 21.4, y: 14.4, width: 5.2, height: 5.2)), with: .color(ink))
            ctx.fill(Path(ellipseIn: CGRect(x: 22.5, y: 15.5, width: 3, height: 3)), with: .color(glow))
            ctx.fill(Path(ellipseIn: CGRect(x: 30, y: 14, width: 6, height: 6)), with: .color(ink))
            ctx.fill(Path(ellipseIn: CGRect(x: 31.1, y: 15.1, width: 3.8, height: 3.8)), with: .color(amber))
        }
        .frame(width: 46, height: 30)
    }
}

/// Tiny deterministic generator so the spray looks the same every time but each
/// droplet still gets a varied angle/speed (no shared global randomness).
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 2862933555777941757 &+ 3037000493 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }
}

/// A soft bell curve, 1 at `center`, 0 by `±width`. Keys the breakthrough spray
/// to the moment the rising sub actually crosses the surface.
func bump(_ t: Double, center: Double, width: Double) -> Double {
    let d = (t - center) / width
    return max(0, 1 - d * d)
}

/// The patch of sea the U-Boot leaps out of (Runde 9). A short-lived, stationary
/// panel at the launch point: an animated wavy surface plus a crown of spray
/// thrown up the instant the sub bursts through, then everything fades. The sub
/// itself lives in the separate, moving banner panel and arcs up over this.
struct SeaSplash: View {
    let startedAt: Date       // drives the crown + the whole-splash fade
    let launchX: CGFloat      // x in this panel where the sub punches out
    static let duration: Double = 1.5

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(startedAt)
            let now = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let teal = Color(hex: 0x2EC7A0)
                let deep = Color(hex: 0x0C5A63)
                let foam = Color(hex: 0xCFF5EA)
                let surface = size.height * 0.5
                let fade = max(0, 1 - t / Self.duration)

                func surfaceY(_ x: CGFloat) -> CGFloat {
                    surface + sin(x / 30 + now * 1.7) * 3 + sin(x / 12 - now * 2.1) * 1.4
                }

                // Water body below the wavy surface.
                var water = Path()
                water.move(to: CGPoint(x: 0, y: surfaceY(0)))
                var x: CGFloat = 0
                while x <= size.width { water.addLine(to: CGPoint(x: x, y: surfaceY(x))); x += 4 }
                water.addLine(to: CGPoint(x: size.width, y: size.height))
                water.addLine(to: CGPoint(x: 0, y: size.height))
                water.closeSubpath()
                ctx.fill(water, with: .linearGradient(
                    Gradient(colors: [teal.opacity(0.42 * fade), deep.opacity(0.68 * fade)]),
                    startPoint: CGPoint(x: 0, y: surface), endPoint: CGPoint(x: 0, y: size.height)))

                // Foam crest.
                var crest = Path()
                crest.move(to: CGPoint(x: 0, y: surfaceY(0)))
                x = 0
                while x <= size.width { crest.addLine(to: CGPoint(x: x, y: surfaceY(x))); x += 4 }
                ctx.stroke(crest, with: .color(foam.opacity(0.7 * fade)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))

                // Launch crown: spray flung up where the sub bursts out, thrown at
                // t≈0 and pulled back down by gravity as it fades.
                let crown = bump(t, center: 0.14, width: 0.55)
                if crown > 0.02 {
                    let by = surfaceY(launchX)
                    var rng = SeededRandom(seed: 91)
                    for i in 0..<26 {
                        let ang = (-158 + 128 * rng.next()) * Double.pi / 180   // fan upward
                        let sp = (22 + 78 * rng.next()) * crown
                        let life = rng.next()
                        let px = launchX + CGFloat(cos(ang)) * sp
                        let py = by + CGFloat(sin(ang)) * sp + 42 * CGFloat(life) * CGFloat(max(0, t))
                        let r = (1.2 + 2.3 * rng.next()) * crown
                        guard r > 0.3 else { continue }
                        let c: Color = i % 3 == 0 ? foam : (i % 3 == 1 ? teal : .white)
                        ctx.fill(Path(ellipseIn: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2)),
                                 with: .color(c.opacity(0.92 * crown)))
                    }
                    let rr = 10 + crown * 40
                    ctx.stroke(Path(ellipseIn: CGRect(x: launchX - rr, y: by - rr * 0.3,
                                                      width: rr * 2, height: rr * 0.6)),
                               with: .color(foam.opacity(0.55 * crown)), style: StrokeStyle(lineWidth: 1.8))
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// The puff of cloud an AIR motif (jet/heli/rocket/UFO/zeppelin) bursts out of
/// (Runde 72, "Dramatischer Auftritt" für Luft-Motive — das Gegenstück zu
/// `SeaSplash`, gleiche Panel-Mechanik und gleiche Gesamtdauer). A loose core
/// of cloud puffs sits at the launch point the whole time; a ring of them gets
/// thrown outward the instant the object punches through and drifts apart as
/// it fades, then everything dissolves together with `duration`.
///
/// TEURE PROJEKTLEKTION: this is drawn with deterministic, opaque fill colours
/// and soft radial gradients — no NSVisualEffectView/behindWindow material.
/// A material blur in a stationary panel that is never the key/active window
/// (like this one, and like the moving banner panels) silently falls back to
/// a solid black slab instead of blurring the desktop underneath.
struct CloudBurst: View {
    let startedAt: Date       // drives the burst + the whole-cloud fade
    let launchX: CGFloat      // x in this panel where the object punches through
    let launchY: CGFloat      // y in this panel where the object punches through
    static let duration: Double = 1.5

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(startedAt)
            Canvas { ctx, _ in
                let fade = max(0, 1 - t / Self.duration)
                guard fade > 0.015 else { return }

                let light = Color(hex: 0xFFFFFF)
                let cloudBody = Color(hex: 0xE8EEF4)
                let shade = Color(hex: 0x98A6B8)

                func puff(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ alpha: Double, _ tint: Color) {
                    guard r > 0.4, alpha > 0.01 else { return }
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .radialGradient(Gradient(colors: [tint.opacity(alpha), tint.opacity(0)]),
                                                   center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
                }

                // Core cluster: a loose cloud mass right at the launch point,
                // present throughout, dissolving together with the overall fade.
                // Fixed seed → same silhouette every time, still irregular.
                var core = SeededRandom(seed: 271)
                var puffs: [(CGFloat, CGFloat, CGFloat)] = []
                for i in 0..<9 {
                    let ang = Double(i) / 9 * 2 * .pi + core.next() * 0.6
                    let dist = 10 + 22 * core.next()
                    let r = 15 + 19 * core.next()
                    puffs.append((launchX + CGFloat(cos(ang) * dist),
                                  launchY + CGFloat(sin(ang) * dist * 0.6),
                                  CGFloat(r)))
                }
                // Shadowed underside first, lighter body on top → a hint of
                // volume instead of a flat smear (also what keeps it legible
                // over a light desktop background, not just a dark one).
                for (x, y, r) in puffs { puff(x, y, r, 0.40 * fade, shade) }
                for (x, y, r) in puffs { puff(x, y - r * 0.15, r * 0.82, 0.66 * fade, cloudBody) }

                // Burst puffs: thrown outward at t≈0 as the object punches
                // through, drifting apart and fading faster than the core —
                // the intended "kurzes Aufwirbeln" (quick swirl-up) look.
                let burst = bump(t, center: 0.10, width: 0.6)
                if burst > 0.02 {
                    var rng = SeededRandom(seed: 88)
                    for i in 0..<16 {
                        let ang = rng.next() * 2 * .pi        // disperses in every direction
                        let sp = (16 + 96 * rng.next()) * burst
                        let life = rng.next()
                        let px = launchX + CGFloat(cos(ang) * sp)
                        let py = launchY + CGFloat(sin(ang) * sp) - CGFloat(18 * life * max(0, t))
                        let r = CGFloat((3 + 11 * rng.next()) * burst)
                        let tint = i % 3 == 0 ? light : cloudBody
                        puff(px, py, r, 0.85 * burst * fade, tint)
                    }
                }

                // Brief bright flash right at the punch-through instant, sells
                // the "breaking out" moment before the puffs are done drifting.
                let flash = bump(t, center: 0.02, width: 0.16)
                if flash > 0.02 {
                    puff(launchX, launchY, 26 + CGFloat(24 * flash), 0.55 * flash, light)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
