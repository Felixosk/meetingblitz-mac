import Foundation

/// Runde 113 (B1): Wer gewinnt, das Feld oder die Hand? Reine Logik ohne Oberfläche, damit `--selftest` sie prüft.
///
/// Uhrzeit, Tag, Dauer und Zeitzone haben je eine Quelle. Das Feld setzt einen Wert nur, solange dessen Quelle nicht
/// `.manual` ist. Von Hand ändern setzt `.manual`. Ändert sich der Teil im Feld (anderer Text), gewinnt das Feld
/// wieder. Wird der Teil gelöscht und die Quelle ist `.field`, geht der Wert auf den Stand VOR der ersten Übernahme zurück.
struct EntryState {
    enum Part: Hashable { case time, day, duration, zone }
    enum Source { case field, manual }

    var day: Date
    var minutesOfDay: Int
    var duration: Int
    var zoneID: String?
    private(set) var source: [Part: Source] = [:]
    private var baseline: [Part: Any] = [:]
    /// Text des Teils im Feld, wie er beim letzten `apply` stand (nil = nicht da).
    private(set) var lastText: [Part: String] = [:]

    init(day: Date, minutesOfDay: Int, duration: Int, zoneID: String? = nil) {
        self.day = day; self.minutesOfDay = minutesOfDay; self.duration = duration; self.zoneID = zoneID
    }

    func sourceOf(_ p: Part) -> Source { source[p] ?? .field }

    /// Feld → Werte. `text` ist der Feldtext, `scan` das Ergebnis dazu.
    mutating func apply(scan: QuickScan, text: String) {
        func token(_ kind: QuickScan.Kind) -> String? {
            guard let t = scan.tokens.first(where: { $0.kind == kind }),
                  let r = Range(t.range, in: text) else { return nil }
            return String(text[r])
        }
        // Uhrzeit
        handle(.time, present: scan.hour != nil ? (token(.time) ?? "auto") : nil,
               set: { st in st.minutesOfDay = (scan.hour ?? 0) * 60 + scan.minute },
               remember: { $0.minutesOfDay }, restore: { st, v in st.minutesOfDay = v as! Int })
        // Tag
        handle(.day, present: scan.day != nil ? (token(.day) ?? "auto") : nil,
               set: { st in if let d = scan.day { st.day = d } },
               remember: { $0.day }, restore: { st, v in st.day = v as! Date })
        // Dauer
        handle(.duration, present: scan.minutes != nil ? (token(.duration) ?? token(.time) ?? "auto") : nil,
               set: { st in if let m = scan.minutes { st.duration = max(5, m) } },
               remember: { $0.duration }, restore: { st, v in st.duration = v as! Int })
        // Zone
        handle(.zone, present: scan.zoneID != nil ? (token(.zone) ?? "auto") : nil,
               set: { st in st.zoneID = scan.zoneID },
               remember: { $0.zoneID as Any }, restore: { st, v in st.zoneID = v as? String })
    }

    private mutating func handle(_ p: Part, present: String?, set: (inout EntryState) -> Void,
                                 remember: (EntryState) -> Any, restore: (inout EntryState, Any) -> Void) {
        if let now = present {
            if lastText[p] != now { source[p] = .field }          // Regel 3: der Teil im Feld hat sich geändert
            if sourceOf(p) == .field {                             // Regel 1
                if lastText[p] == nil { baseline[p] = remember(self) }
                set(&self)
            }
            if lastText[p] == nil && sourceOf(p) == .manual { baseline[p] = baseline[p] ?? remember(self) }
            lastText[p] = now
        } else if lastText[p] != nil {
            lastText[p] = nil
            if sourceOf(p) == .field, let b = baseline[p] { restore(&self, b) }   // Regel 4
            baseline[p] = nil
            source[p] = nil
        }
    }

    /// Von Hand geändert (Pfeile, Mausrad, Klick, Ziehen, Dauer-Leiste, Schieber): Quelle wird `.manual` (Regel 2).
    mutating func manualTime(_ minutes: Int) { minutesOfDay = minutes; source[.time] = .manual }
    mutating func manualDay(_ d: Date) { day = d; source[.day] = .manual }
    mutating func manualDuration(_ m: Int) { duration = m; source[.duration] = .manual }
    mutating func manualZone(_ id: String?) { zoneID = id; source[.zone] = .manual }
}

/// Runde 114 (Punkt 3): Wird der Block von Hand gezogen, wird der erkannte Zeit-/Dauer-Teil IM FELD ersetzt
/// ("3pm" -> "7am"), damit nie zwei Wahrheiten da stehen. Rein rechnend (testbar).
enum EntryRewrite {
    private static let rangeRE = try! NSRegularExpression(
        pattern: #"^(\d{1,2})(?::(\d{2}))?(\s*(?:uhr|h|am|pm)?)(\s*(?:-|–|bis|to|until)\s*)(\d{1,2})(?::(\d{2}))?(\s*(?:uhr|h|am|pm)?)$"#,
        options: [.caseInsensitive])

    private static func fmt(_ minutes: Int, old: String) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        let hh = m / 60, mm = m % 60
        let lower = old.lowercased()
        let hadColon = lower.contains(":")
        let mmText = (mm != 0 || hadColon) ? String(format: ":%02d", mm) : ""
        if lower.contains("am") || lower.contains("pm") || lower.contains("a.m.") || lower.contains("p.m.") {
            let h12 = hh % 12 == 0 ? 12 : hh % 12
            let space = old.range(of: #"\d\s+[aApP]"#, options: .regularExpression) != nil ? " " : ""
            var suf = hh < 12 ? "am" : "pm"
            if old.contains("AM") || old.contains("PM") { suf = suf.uppercased() }
            return "\(h12)\(mmText)\(space)\(suf)"
        }
        if let r = old.range(of: #"\s*(uhr|h)\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            return "\(hh)\(mmText)\(old[r])"
        }
        return hadColon ? String(format: "%d:%02d", hh, mm) : (mm == 0 ? "\(hh)" : String(format: "%d:%02d", hh, mm))
    }

    /// Neuer Text für einen erkannten Zeit-Teil. `start` = Beginn, `minutes` = Dauer (für Bereiche wie "10-12").
    static func timeToken(old: String, start: Int, minutes: Int) -> String {
        let ns = NSRange(old.startIndex..., in: old)
        if let m = rangeRE.firstMatch(in: old, options: [], range: ns) {
            func g(_ i: Int) -> String { Range(m.range(at: i), in: old).map { String(old[$0]) } ?? "" }
            let a = g(1) + (g(2).isEmpty ? "" : ":" + g(2)) + g(3)
            let b = g(5) + (g(6).isEmpty ? "" : ":" + g(6)) + g(7)
            let aNew = fmt(start, old: a), bNew = fmt(start + minutes, old: b.isEmpty ? a : b)
            return aNew + g(4) + bNew
        }
        return fmt(start, old: old)
    }

    /// Ersetzt im Feldtext die erkannten Teile. nil = nichts zu ersetzen (kein Teil, oder Zeitzone im Spiel).
    static func rewrite(text: String, scan: QuickScan, start: Int?, minutes: Int?) -> String? {
        guard scan.zoneID == nil else { return nil }
        var out = text as NSString
        var changed = false
        // Von hinten nach vorn, damit die Bereiche gültig bleiben.
        for t in scan.tokens.sorted(by: { $0.range.location > $1.range.location }) {
            guard NSMaxRange(t.range) <= out.length else { continue }
            let old = out.substring(with: t.range)
            var new: String?
            switch t.kind {
            case .time:
                if let s = start { new = timeToken(old: old, start: s, minutes: minutes ?? 30) }
            case .duration:
                if let m = minutes { new = "\(m) min" }
            default: break
            }
            if let n = new, n != old { out = out.replacingCharacters(in: t.range, with: n) as NSString; changed = true }
        }
        return changed ? (out as String) : nil
    }

    static func failures() -> [String] {
        var f: [String] = []
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 11))!
        let cases: [(String, Int, Int, String)] = [
            ("call tomorrow 3pm", 7 * 60, 30, "call tomorrow 7am"),
            ("call tomorrow 3 pm", 19 * 60 + 30, 30, "call tomorrow 7:30 pm"),
            ("call fr 15:00", 7 * 60, 30, "call fr 7:00"),
            ("call morgen 15 uhr", 9 * 60, 30, "call morgen 9 uhr"),
            ("fri 10-12 call", 7 * 60, 120, "fri 7-9 call"),
            ("fri 10 call", 8 * 60 + 15, 30, "fri 8:15 call"),
        ]
        for (text, start, dur, want) in cases {
            let sc = QuickAdd.scan(text, now: now, calendar: cal, zones: [:])
            guard let got = rewrite(text: text, scan: sc, start: start, minutes: dur) else { f.append("Ersetzen „\(text)“: nichts ersetzt"); continue }
            if got != want { f.append("Ersetzen „\(text)“: „\(got)“ statt „\(want)“"); continue }
            // Zwei Wahrheiten verboten: der neue Text muss GENAU die gezogene Zeit ergeben.
            let sc2 = QuickAdd.scan(got, now: now, calendar: cal, zones: [:])
            if (sc2.hour ?? -1) * 60 + sc2.minute != start { f.append("Ersetzen „\(text)“: neuer Text liest \(String(describing: sc2.hour)):\(sc2.minute), gezogen \(start / 60):\(start % 60)") }
        }
        let z = QuickAdd.scan("17:00 dubai sync", now: now, calendar: cal, zones: ["dubai": "Asia/Dubai"])
        if rewrite(text: "17:00 dubai sync", scan: z, start: 480, minutes: 30) != nil { f.append("Ersetzen: mit Zeitzone darf nicht ersetzt werden") }
        let d = QuickAdd.scan("sync 45 min", now: now, calendar: cal, zones: [:])
        if rewrite(text: "sync 45 min", scan: d, start: nil, minutes: 60) != "sync 60 min" { f.append("Ersetzen: Dauer 45 min -> 60 min") }
        return f
    }
}

enum EntryStateTests {
    static func failures() -> [String] {
        var f: [String] = []
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 19, hour: 11))!
        let base = cal.startOfDay(for: now)
        func scan(_ t: String) -> QuickScan { QuickAdd.scan(t, now: now, calendar: cal, zones: [:]) }

        // scan-Fälle: (Text, Arten in Reihenfolge, Titel, Dauer)
        let cases: [(String, [QuickScan.Kind], String, Int?)] = [
            ("fri 10-12 call with chris", [.day, .time], "call with chris", 120),
            ("morgen 14 uhr standup 45 min", [.day, .time, .duration], "standup", 45),
            ("Call 2", [], "Call 2", nil),
            ("fr 10 call", [.day, .time], "call", nil),
            ("call at 3pm", [.time], "call", nil),
            ("morgen call", [.day], "call", nil),
            ("call mit anna 45 min", [.duration], "call mit anna", 45),
        ]
        for (t, kinds, title, mins) in cases {
            let s = scan(t)
            if s.tokens.map(\.kind) != kinds { f.append("scan „\(t)“: Arten \(s.tokens.map(\.kind)) statt \(kinds)") }
            if s.title != title { f.append("scan „\(t)“: Titel „\(s.title)“ statt „\(title)“") }
            if s.minutes != mins { f.append("scan „\(t)“: Dauer \(String(describing: s.minutes)) statt \(String(describing: mins))") }
            // Positionen: jeder Teil liegt im Original und ist nicht leer.
            for tk in s.tokens {
                if Range(tk.range, in: t) == nil || tk.range.length == 0 { f.append("scan „\(t)“: Bereich ungültig") }
            }
        }
        // „fr 10-12": der markierte Zeit-Teil ist wirklich "10-12"
        let s1 = scan("fri 10-12 call with chris")
        if let tk = s1.tokens.first(where: { $0.kind == .time }), let r = Range(tk.range, in: "fri 10-12 call with chris") {
            if String("fri 10-12 call with chris"[r]) != "10-12" { f.append("scan: Zeit-Bereich sitzt nicht auf „10-12“") }
        }
        // Zone: „17:00 dubai sync"
        let zs = QuickAdd.scan("17:00 dubai sync", now: now, calendar: cal, zones: ["dubai": "Asia/Dubai"])
        if zs.tokens.map(\.kind) != [.time, .zone] || zs.title != "sync" || zs.zoneID != "Asia/Dubai" {
            f.append("scan „17:00 dubai sync“: \(zs.tokens.map(\.kind)) · „\(zs.title)“ · \(zs.zoneID ?? "-")")
        }

        // Regeln
        var st = EntryState(day: base, minutesOfDay: 9 * 60, duration: 30)
        func apply(_ t: String) { st.apply(scan: scan(t), text: t) }
        apply("fr 10 call")
        if st.minutesOfDay != 600 { f.append("Regel: Feld setzt 10:00, ist \(st.minutesOfDay)") }
        st.manualTime(660)
        apply("fr 10 call")
        if st.minutesOfDay != 660 { f.append("Regel 1: Hand (11:00) muss bei unverändertem Text bleiben, ist \(st.minutesOfDay)") }
        if st.sourceOf(.time) != .manual { f.append("Regel 2: Quelle muss manual sein") }
        apply("fr 12 call")
        if st.minutesOfDay != 720 { f.append("Regel 3: neuer Text „12“ muss gewinnen, ist \(st.minutesOfDay)") }
        apply("call")
        if st.minutesOfDay != 9 * 60 { f.append("Regel 4: Teil gelöscht → Baseline 9:00, ist \(st.minutesOfDay)") }
        // Gelöscht, aber Hand → bleibt stehen
        var st2 = EntryState(day: base, minutesOfDay: 9 * 60, duration: 30)
        st2.apply(scan: scan("fr 10 call"), text: "fr 10 call")
        st2.manualTime(900)
        st2.apply(scan: scan("call"), text: "call")
        if st2.minutesOfDay != 900 { f.append("Regel 4b: manual bleibt stehen, ist \(st2.minutesOfDay)") }
        // Runde 113: Tage mit Terminen (Punkte im Raster)
        let d0 = base, d1 = cal.date(byAdding: .day, value: 1, to: d0)!, d2 = cal.date(byAdding: .day, value: 2, to: d0)!
        let d3 = cal.date(byAdding: .day, value: 3, to: d0)!
        let spans: [(start: Date, end: Date)] = [
            (d0.addingTimeInterval(36000), d0.addingTimeInterval(39600)),   // 10-11 an Tag 0
            (d1, d2),                                                       // ganztägig Tag 1 (endet 0:00 Tag 2)
            (d1.addingTimeInterval(82800), d3.addingTimeInterval(3600)),    // 23:00 Tag 1 bis 1:00 Tag 3 = Tage 1,2,3
        ]
        let got = CalendarService.coveredDays(spans, from: d0, to: d3, calendar: cal)
        if got != [d0, d1, d2] { f.append("coveredDays: \(got.count) Tage statt 3 (Tag0, Tag1, Tag2, Ende bei bis=d3 ausgeschlossen)") }
        if CalendarService.coveredDays([(d1, d2)], from: d0, to: d3, calendar: cal) != [d1] { f.append("coveredDays: ganztägig endet 0:00 zählt am Folgetag mit") }
        return f
    }
}
