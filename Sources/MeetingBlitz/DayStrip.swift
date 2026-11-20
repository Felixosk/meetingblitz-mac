import SwiftUI
import AppKit

/// A compact MeetingBar-style timeline of the displayed day's timed meetings,
/// with a live "now" marker. Tapping a block opens that event in Apple Calendar.
struct DayStrip: View {
    let meetings: [Meeting]
    let day: Date         // the day the panel is showing (dayOffset applied)
    let showNow: Bool     // false when browsing another day (Morgen-Ansicht)
    let onTap: (Meeting) -> Void
    /// Runde 113: im Termin-Fenster der geplante Termin als ziehbarer Block (nil = Widget, unverändert).
    var draft: (start: Date, minutes: Int)? = nil
    var draftTitle: String = ""
    var editable = false
    var onDraftStart: ((Date) -> Void)? = nil
    @State private var grab: CGFloat? = nil
    @State private var lastStep = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let (lo, hi) = bounds()
            let span = max(1, hi.timeIntervalSince(lo))
            let top = Theme.timelineHeight - Theme.timelineTrack

            ZStack(alignment: .topLeading) {
                // Track
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.fill)
                    .frame(height: Theme.timelineTrack).offset(y: top)

                // Hour ticks + labels (regular 2-h grid, only up to midnight)
                let dayEnd = lo.addingTimeInterval(24 * 3600)
                ForEach(hourMarks(lo, min(hi, dayEnd)), id: \.timeIntervalSinceReferenceDate) { d in
                    let x = w * (d.timeIntervalSince(lo) / span)
                    // Runde 99: kein Strich am Anfang/Ende, der Balken beginnt sauber.
                    if x > 2 && x < w - 2 {
                        Rectangle().fill(Theme.line)
                            .frame(width: 1, height: Theme.timelineTrack).offset(x: x, y: top)
                    }
                    Text(hourLabel(d)).font(.theme(.small))
                        .foregroundStyle(Theme.muted).offset(x: x + 2, y: 0)
                }

                // Meeting blocks
                ForEach(meetings) { m in
                    let x0 = w * (clampToSpan(m.start, lo, hi).timeIntervalSince(lo) / span)
                    let x1 = w * (clampToSpan(m.end, lo, hi).timeIntervalSince(lo) / span)
                    let blockW = max(Theme.dot, x1 - x0)
                    Button { onTap(m) } label: {
                        blockShape(m, hi)
                            .fill(editable ? m.color.opacity(0.55) : m.color)
                            .frame(width: blockW, height: Theme.timelineBlock)
                            .overlay(alignment: .leading) {
                                // Full title, truncated with "…" to the block width.
                                // Runde 114 (Punkt 5): Titel nur, wenn er GANZ passt, sonst nur die Farbe (kein "To…").
                                if blockW > Theme.s24 + Theme.s8 {
                                    ViewThatFits(in: .horizontal) {
                                        Text(m.title)
                                            .font(.theme(.small, .semibold))
                                            .foregroundStyle(editable ? Theme.label.opacity(0.9) : Theme.onBlue)
                                            .lineLimit(1).fixedSize()
                                        Color.clear.frame(width: 1, height: 1)
                                    }
                                    .padding(.horizontal, Theme.s4)
                                    .frame(width: blockW, alignment: .leading)
                                }
                            }
                            .clipShape(blockShape(m, hi))
                    }
                    .buttonStyle(.plain)
                    .hint("\(m.timeLabel)  \(m.title)", id: "tl-\(m.id)")
                    .offset(x: x0, y: top + (Theme.timelineTrack - Theme.timelineBlock) / 2)
                }

                // Runde 113: vergangenes abdunkeln (heute links vom Jetzt-Strich, an vergangenen Tagen die ganze Spur).
                if editable {
                    let isPastDay = hi <= Date()
                    let px = isPastDay ? w : (showNow ? w * (min(max(0, Date().timeIntervalSince(lo)), span) / span) : 0)
                    if px > 0 {
                        UnevenRoundedRectangle(topLeadingRadius: Theme.radius, bottomLeadingRadius: Theme.radius,
                                               bottomTrailingRadius: isPastDay ? Theme.radius : 0, topTrailingRadius: isPastDay ? Theme.radius : 0,
                                               style: .continuous)
                            .fill(Theme.dyn(dark: NSColor.black.withAlphaComponent(0.25), light: NSColor.black.withAlphaComponent(0.10))).frame(width: px, height: Theme.timelineTrack).offset(y: top)
                            .allowsHitTesting(false)
                    }
                }

                // Der geplante Termin: blau (oder orange bei Überschneidung), über allen anderen.
                if let d = draft {
                    let dx0 = w * (clampToSpan(d.start, lo, hi).timeIntervalSince(lo) / span)
                    let dx1 = w * (clampToSpan(d.start.addingTimeInterval(Double(d.minutes) * 60), lo, hi).timeIntervalSince(lo) / span)
                    let dw = max(5, dx1 - dx0)
                    let clash = meetings.contains { !$0.isAllDay && !$0.isBirthday && $0.start < d.start.addingTimeInterval(Double(d.minutes) * 60) && $0.end > d.start }
                    RoundedRectangle(cornerRadius: Theme.inner(inset: Theme.s4), style: .continuous)
                        .fill(clash ? Theme.warn : Theme.blue)
                        .overlay(RoundedRectangle(cornerRadius: Theme.inner(inset: Theme.s4), style: .continuous)
                            .strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                        .overlay(alignment: .leading) {
                            if dw > 36 {
                                ViewThatFits(in: .horizontal) {
                                    Text(draftTitle.isEmpty ? L.t("Neu", "New") : draftTitle)
                                        .font(.theme(.small, .semibold)).foregroundStyle(Theme.onBlue).lineLimit(1).fixedSize()
                                    Color.clear.frame(width: 1, height: 1)
                                }
                                .padding(.horizontal, Theme.s4).frame(width: dw, alignment: .leading)
                            }
                        }
                        .frame(width: dw, height: Theme.timelineBlock + 4)
                        .offset(x: dx0, y: top + (Theme.timelineTrack - Theme.timelineBlock - 4) / 2)
                        .allowsHitTesting(false)
                }

                // Now marker (only on the real today)
                if showNow {
                    let nx = w * (min(max(0, Date().timeIntervalSince(lo)), span) / span)
                    Rectangle().fill(Theme.blue).frame(width: 2, height: Theme.timelineTrack + Theme.s8).offset(x: nx, y: top - Theme.s4)
                }
            }
        }
        .frame(height: Theme.timelineHeight)
        .overlay {
            if editable, draft != nil {
                GeometryReader { geo in
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in dragChanged(v, width: geo.size.width) }
                            .onEnded { _ in grab = nil; lastStep = 0 })
                }
            }
        }
        .modifier(ScrollStepper { steps in
            guard editable, let d = draft else { return }
            onDraftStart?(d.start.addingTimeInterval(Double(steps) * 900))
        })
        // Runde 112 (Fund 10/14): Textfassung für Tooltip und VoiceOver.
        .help(timelineText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L.t("Tagesverlauf", "Day timeline"))
        .accessibilityValue(timelineText)
        .accessibilityAdjustableAction { dir in
            guard editable, let d = draft else { return }
            onDraftStart?(d.start.addingTimeInterval(dir == .increment ? 900 : -900))
        }
    }

    /// Ziehen am blauen Block (Raster 15 min) oder Klick auf eine freie Stelle setzt den Beginn dorthin.
    private func dragChanged(_ v: DragGesture.Value, width w: CGFloat) {
        guard let d = draft else { return }
        let (lo, hi) = bounds()
        let span = hi.timeIntervalSince(lo)
        let dx0 = w * (d.start.timeIntervalSince(lo) / span)
        let dx1 = w * (d.start.addingTimeInterval(Double(d.minutes) * 60).timeIntervalSince(lo) / span)
        if grab == nil {
            // Treffer auf dem Block (mit 6 pt Toleranz) = Ziehen mit Versatz, sonst Klick = Beginn dorthin.
            grab = (v.startLocation.x >= dx0 - 6 && v.startLocation.x <= dx1 + 6) ? v.startLocation.x - dx0 : 0
        }
        let x = v.location.x - (grab ?? 0)
        let raw = lo.addingTimeInterval(Double(x / w) * span)
        let t = (raw.timeIntervalSinceReferenceDate / 900).rounded() * 900
        var ns = Date(timeIntervalSinceReferenceDate: t)
        ns = min(max(ns, lo), hi.addingTimeInterval(-Double(d.minutes) * 60))
        if ns != d.start {
            if ns.timeIntervalSince(lo) != Double(lastStep) {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                lastStep = Int(ns.timeIntervalSince(lo))
            }
            onDraftStart?(ns)
        }
    }

    private var timelineText: String {
        if let d = draft {
            let n = meetings.filter { !$0.isAllDay && !$0.isBirthday }.count
            let end = d.start.addingTimeInterval(Double(d.minutes) * 60)
            return L.t("\(n) Termine, geplant \(L.time(d.start))–\(L.time(end))", "\(n) events, planned \(L.time(d.start))–\(L.time(end))")
        }
        return meetings.sorted { $0.start < $1.start }.map { "\($0.timeLabel) \($0.displayTitle)" }.joined(separator: ", ")
    }

    /// Runde 102: Spur 10, Block 4 eingerückt → Radius 6 (konzentrisch); rechts gerade, wenn der Termin über Mitternacht geht.
    private func blockShape(_ m: Meeting, _ hi: Date) -> UnevenRoundedRectangle {
        let r = Theme.inner(inset: Theme.s4), cut = m.end > hi
        return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r,
                                      bottomTrailingRadius: cut ? 0 : r, topTrailingRadius: cut ? 0 : r, style: .continuous)
    }

    private func bounds() -> (Date, Date) {
        // Runde 101: Achse immer fest 0–24, sie wird nie länger. Ein Termin über
        // Mitternacht wird rechts abgeschnitten (gerade Kante = "geht weiter").
        let lo = Calendar.current.startOfDay(for: day)
        return (lo, lo.addingTimeInterval(24 * 3600))
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
        // Runde 111 (Fund 2): wie die Uhrzeiten nach App-Sprache; EN kompakt ("9a", "12p"), DE "9", "12".
        let h = Calendar.current.component(.hour, from: d)
        if L.isDE { return "\(h)" }
        return "\(h % 12 == 0 ? 12 : h % 12)\(h < 12 ? "a" : "p")"
    }

    private func clampToSpan(_ d: Date, _ lo: Date, _ hi: Date) -> Date {
        min(max(d, lo), hi)
    }
}


