import Foundation
import SwiftUI

// Runde 86: Zeitzonen-Leiste im Termin-Fenster.
//
// Vorher wurde die Uhrzeit in einer Browser-Erweiterung über mehrere Zonen
// gesucht und dann im Formular von Hand abgetippt. Jetzt steht ein Planer
// direkt im Formular: eine Zeile pro gespeicherter Zone, jede mit einem
// Schieber über IHREN eigenen Tag (0 bis 24 Uhr Ortszeit). Ein Schieber
// bewegt den Terminbeginn für alle.
//
// Rechnen NUR über TimeZone/Calendar, nie mit festen Versätzen: Sommerzeit
// wechselt in Europa, Nordamerika und Südhalbkugel an verschiedenen Tagen.

/// Eine gespeicherte Zone. `on` = „ist im Call", steht im Einladungstext.
struct SavedZone: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var on: Bool
    /// Eigener Anzeigename (Doppelklick auf den Namen, Runde 87). nil = Standard.
    var label: String? = nil
}

/// Anzeigenamen, Flaggen, Suche. Reine Daten, keine Zustände, darum von
/// überall (auch aus dem MCP-Prozess und dem Selbsttest) nutzbar.
enum ZoneNames {

    /// Kennung → Ortsname, wo er der Kennung nicht anzusehen ist oder anders
    /// lauten soll. Bewusst die Hauptstadt der Zone; einen eigenen Ort
    /// (z. B. den Nachbarort) setzt man per Doppelklick als `label`.
    static let alias: [String: String] = [
        "Asia/Nicosia": "Nicosia", "Europe/Nicosia": "Nicosia",
        "Europe/Berlin": "Berlin", "Asia/Manila": "Manila", "Europe/London": "London",
        "Africa/Johannesburg": "Johannesburg", "Europe/Lisbon": "Lisbon",
        "America/Argentina/Buenos_Aires": "Buenos Aires", "Asia/Bangkok": "Bangkok",
        "America/New_York": "New York", "America/Los_Angeles": "Los Angeles",
        "America/Chicago": "Chicago", "America/Denver": "Denver", "Asia/Dubai": "Dubai",
        "Asia/Tokyo": "Tokyo", "Asia/Singapore": "Singapore", "Australia/Sydney": "Sydney",
        "America/Sao_Paulo": "São Paulo", "Europe/Moscow": "Moscow", "Asia/Kolkata": "India",
        "Asia/Calcutta": "India", "America/Mexico_City": "Mexico City", "Europe/Madrid": "Madrid",
        "Europe/Warsaw": "Warsaw", "Asia/Seoul": "Seoul", "Asia/Hong_Kong": "Hong Kong",
        "America/Toronto": "Toronto", "Europe/Istanbul": "Istanbul", "Europe/Athens": "Athens",
        "Europe/Paris": "Paris", "Europe/Rome": "Rome", "Europe/Vienna": "Vienna",
        "Europe/Zurich": "Zurich", "Europe/Amsterdam": "Amsterdam", "Asia/Jakarta": "Jakarta",
        "Asia/Ho_Chi_Minh": "Ho Chi Minh", "Asia/Saigon": "Ho Chi Minh", "Asia/Shanghai": "China",
        "Pacific/Auckland": "Auckland", "Africa/Lagos": "Lagos", "Africa/Cairo": "Cairo",
        "Africa/Nairobi": "Nairobi", "America/Bogota": "Bogotá", "America/Lima": "Lima",
        "America/Santiago": "Santiago", "Asia/Tel_Aviv": "Tel Aviv", "Asia/Jerusalem": "Jerusalem",
    ]

    /// Zusätzliche Suchwörter (beide Sprachen), damit „Moskau" oder „Indien"
    /// auch auf Deutsch gefunden wird.
    private static let keywords: [String: String] = [
        "Europe/Moscow": "moskau", "Asia/Kolkata": "indien kolkata delhi mumbai",
        "America/Mexico_City": "mexiko", "Europe/Warsaw": "warschau", "Asia/Hong_Kong": "hongkong",
        "Asia/Singapore": "singapur", "Europe/Lisbon": "lissabon portugal porto",
        "Asia/Nicosia": "nikosia zypern cyprus limassol larnaca", "Europe/Rome": "rom",
        "Europe/Vienna": "wien", "Europe/Zurich": "zürich", "Asia/Shanghai": "shanghai beijing peking",
        "Africa/Cairo": "kairo", "Europe/Athens": "athen", "America/Sao_Paulo": "sao paulo brasilien",
        "America/Argentina/Buenos_Aires": "argentinien", "Asia/Bangkok": "thailand",
        "Asia/Manila": "philippinen philippines", "Africa/Johannesburg": "südafrika south africa",
    ]

    private static let flags: [String: String] = [
        "Asia/Nicosia": "🇨🇾", "Europe/Nicosia": "🇨🇾", "Europe/Berlin": "🇩🇪", "Asia/Manila": "🇵🇭",
        "Europe/London": "🇬🇧", "Africa/Johannesburg": "🇿🇦", "Europe/Lisbon": "🇵🇹",
        "America/Argentina/Buenos_Aires": "🇦🇷", "Asia/Bangkok": "🇹🇭", "America/New_York": "🇺🇸",
        "America/Los_Angeles": "🇺🇸", "America/Chicago": "🇺🇸", "America/Denver": "🇺🇸",
        "Asia/Dubai": "🇦🇪", "Asia/Tokyo": "🇯🇵", "Asia/Singapore": "🇸🇬", "Australia/Sydney": "🇦🇺",
        "America/Sao_Paulo": "🇧🇷", "Europe/Moscow": "🇷🇺", "Asia/Kolkata": "🇮🇳", "Asia/Calcutta": "🇮🇳",
        "America/Mexico_City": "🇲🇽", "Europe/Madrid": "🇪🇸", "Europe/Warsaw": "🇵🇱", "Asia/Seoul": "🇰🇷",
        "Asia/Hong_Kong": "🇭🇰", "America/Toronto": "🇨🇦", "Europe/Istanbul": "🇹🇷", "Europe/Athens": "🇬🇷",
        "Europe/Paris": "🇫🇷", "Europe/Rome": "🇮🇹", "Europe/Vienna": "🇦🇹", "Europe/Zurich": "🇨🇭",
        "Europe/Amsterdam": "🇳🇱", "Asia/Jakarta": "🇮🇩", "Asia/Ho_Chi_Minh": "🇻🇳", "Asia/Shanghai": "🇨🇳",
        "Pacific/Auckland": "🇳🇿", "Africa/Lagos": "🇳🇬", "Africa/Cairo": "🇪🇬", "Africa/Nairobi": "🇰🇪",
        "America/Bogota": "🇨🇴", "America/Lima": "🇵🇪", "America/Santiago": "🇨🇱",
        "Asia/Jerusalem": "🇮🇱", "Asia/Tel_Aviv": "🇮🇱",
    ]

    /// Gängige Kürzel → Zone. Nur ab drei Buchstaben: „ET", „PT", „CT"
    /// sind im Titel echte Wörter („10 uhr et al", Runde 87). Bewusst eine kurze, eindeutige Liste statt
    /// `TimeZone.abbreviationDictionary` (dort steht z. B. „CAT", das in einem
    /// Titel auch ein Wort sein kann). Das Kürzel meint die ZONE, nicht den
    /// festen Versatz: „3pm EST" im Juli ist 15 Uhr New Yorker Sommerzeit,
    /// so wie Menschen es meinen.
    static let abbreviations: [String: String] = [
        "EST": "America/New_York", "EDT": "America/New_York",
        "CST": "America/Chicago", "CDT": "America/Chicago",
        "MST": "America/Denver", "MDT": "America/Denver",
        "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles",
        "GMT": "Europe/London", "BST": "Europe/London", "UTC": "UTC",
        "CET": "Europe/Berlin", "CEST": "Europe/Berlin", "MEZ": "Europe/Berlin", "MESZ": "Europe/Berlin",
        "EET": "Asia/Nicosia", "EEST": "Asia/Nicosia", "IST": "Asia/Kolkata",
        "PHT": "Asia/Manila", "SGT": "Asia/Singapore", "JST": "Asia/Tokyo",
        "AEST": "Australia/Sydney", "AEDT": "Australia/Sydney", "SAST": "Africa/Johannesburg",
        "ICT": "Asia/Bangkok", "ART": "America/Argentina/Buenos_Aires", "WET": "Europe/Lisbon",
    ]

    /// Kennungen, die dieselbe Zone meinen. Ein Rechner kann „Europe/Nicosia"
    /// melden, gespeichert ist „Asia/Nicosia": ohne das stünde Nicosia doppelt da.
    static func canonical(_ id: String) -> String {
        switch id {
        case "Europe/Nicosia": return "Asia/Nicosia"
        case "Asia/Calcutta": return "Asia/Kolkata"
        case "Asia/Saigon": return "Asia/Ho_Chi_Minh"
        default: return id
        }
    }

    static func name(_ id: String) -> String {
        if let a = alias[id] { return a }
        if id == "UTC" || id == "GMT" { return "UTC" }
        return id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
    }

    static func flag(_ id: String) -> String { flags[id] ?? "🌍" }

    /// „UTC+2", „UTC−3", „UTC+5:30" zum gegebenen Zeitpunkt (Sommerzeit inklusive).
    static func utcLabel(_ tz: TimeZone, at date: Date) -> String {
        let s = tz.secondsFromGMT(for: date)
        let sign = s >= 0 ? "+" : "−"
        let h = abs(s) / 3600, m = (abs(s) % 3600) / 60
        return m == 0 ? "UTC\(sign)\(h)" : "UTC\(sign)\(h):\(String(format: "%02d", m))"
    }

    /// „6 h vor" / „1 h 30 min nach" / „gleiche Zeit" gegenüber der eigenen Zone.
    static func relativeLabel(_ tz: TimeZone, own: TimeZone, at date: Date) -> String {
        let diff = tz.secondsFromGMT(for: date) - own.secondsFromGMT(for: date)
        if diff == 0 { return L.t("gleiche Zeit", "same time") }
        let h = abs(diff) / 3600, m = (abs(diff) % 3600) / 60
        let amount = m == 0 ? "\(h) h" : (h == 0 ? "\(m) min" : "\(h) h \(m) min")
        return diff > 0 ? L.t("\(amount) vor", "\(amount) ahead") : L.t("\(amount) nach", "\(amount) behind")
    }

    /// Suchtreffer über alle bekannten Kennungen, bekannte Städte zuerst.
    static func search(_ query: String, excluding: Set<String>, limit: Int = 12) -> [String] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let ex = Set(excluding.map(canonical))
        var pool: [String] = []
        var seen = Set<String>()
        let known = alias.keys.filter { canonical($0) == $0 }.sorted { name($0) < name($1) }
        for id in known + TimeZone.knownTimeZoneIdentifiers where !seen.contains(canonical(id)) {
            seen.insert(canonical(id)); pool.append(canonical(id))
        }
        if q.isEmpty { return Array(pool.filter { !ex.contains($0) && alias[$0] != nil }.prefix(limit)) }
        let abbr = abbreviations[q.uppercased()]
        return Array(pool.filter { id in
            guard !ex.contains(id) else { return false }
            if id == abbr { return true }
            return name(id).lowercased().contains(q)
                || id.lowercased().replacingOccurrences(of: "_", with: " ").contains(q)
                || (keywords[id]?.contains(q) ?? false)
        }
        .sorted { a, b in (a == abbr ? 0 : 1, alias[a] == nil ? 1 : 0) < (b == abbr ? 0 : 1, alias[b] == nil ? 1 : 0) }
        .prefix(limit))
    }

    /// Wörter, die der Freitext als Zone versteht: Kürzel, Ortsnamen und die
    /// gespeicherten Zonen. Klein geschrieben → Kennung.
    static func quickAddTable(saved: [SavedZone] = ZoneBook.load()) -> [String: String] {
        var t: [String: String] = [:]
        for (id, n) in alias { t[n.lowercased()] = canonical(id) }
        for z in saved {
            t[name(z.id).lowercased()] = canonical(z.id)
            if let l = z.label, !l.isEmpty { t[l.lowercased()] = canonical(z.id) }
        }
        // „ist" (deutsch) und „art" sind im Titel echte Wörter, nicht Zonen.
        for (k, v) in abbreviations where !["IST", "ART"].contains(k) { t[k.lowercased()] = v }
        t["new york"] = "America/New_York"; t["nyc"] = "America/New_York"
        return t
    }
}

/// Rechnerei für die Schieber. Reine Funktionen, testbar.
enum ZoneMath {

    /// Minuten seit Mitternacht in der Zone, 0..<1440.
    static func localMinutes(_ date: Date, in tz: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let c = cal.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Terminbeginn so setzen, dass er in `tz` auf `targetMinutes` steht,
    /// am selben Ortstag. Über `Calendar` statt über einen Minutenabstand:
    /// an einem Umstellungstag (Nicosia 25.10., 02:00 auf 06:00) landete der
    /// Abstand eine Stunde daneben (Runde 87). Nicht existierende Uhrzeiten
    /// (Lücke im Frühjahr) rutschen auf die nächste gültige.
    static func move(_ start: Date, toLocalMinutes target: Int, in tz: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return cal.date(bySettingHour: target / 60, minute: target % 60, second: 0, of: start,
                        matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
            ?? start.addingTimeInterval(Double(target - localMinutes(start, in: tz)) * 60)
    }
}

/// Die gespeicherte Zonenliste. Eigene Zone (`TimeZone.current`) steht immer
/// vorn, ist immer „im Call" und kann nicht entfernt werden.
@MainActor
final class ZoneBook: ObservableObject {
    static let shared = ZoneBook()
    nonisolated static let key = "zonePlanner.zones"

    /// Startliste: nur Zonen, keine Personen, NICHTS angehakt (Runde 87: ein
    /// vorab angehaktes Manila stand sonst in jeder Einladung jedes Nutzers).
    nonisolated static let seed: [SavedZone] = [
        "Europe/London", "Europe/Berlin", "Asia/Nicosia", "Asia/Manila", "Africa/Johannesburg",
        "Europe/Lisbon", "America/Argentina/Buenos_Aires", "Asia/Bangkok",
    ].map { SavedZone(id: $0, on: false) }

    @Published private(set) var saved: [SavedZone]

    private init() { saved = Self.load() }

    nonisolated static func load() -> [SavedZone] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([SavedZone].self, from: data) else { return seed }
        return list.filter { TimeZone(identifier: $0.id) != nil }
    }

    /// Zonen mit Haken außer der eigenen, für den Einladungstext. Liest direkt
    /// aus den Voreinstellungen, damit es auch ohne Hauptthread geht (MCP).
    nonisolated static func invitedIDs(from list: [SavedZone] = load()) -> [String] {
        let own = ZoneNames.canonical(TimeZone.current.identifier)
        return list.filter { $0.on && ZoneNames.canonical($0.id) != own }.map(\.id)
    }

    /// Eigene Namen (Kennung → Name), für Einladung und Anzeige.
    nonisolated static func labels(from list: [SavedZone] = load()) -> [String: String] {
        var d: [String: String] = [:]
        for z in list { if let l = z.label, !l.isEmpty { d[ZoneNames.canonical(z.id)] = l } }
        return d
    }

    /// Anzeigename: eigener Name, sonst der Standard.
    nonisolated static func displayName(_ id: String, labels: [String: String]) -> String {
        labels[ZoneNames.canonical(id)] ?? ZoneNames.name(id)
    }

    var ownID: String { TimeZone.current.identifier }
    var invitedIDs: [String] { Self.invitedIDs(from: saved) }
    var labels: [String: String] { Self.labels(from: saved) }
    func name(_ id: String) -> String { Self.displayName(id, labels: labels) }

    /// Anzeigereihenfolge: eigene Zone zuerst, dann die gespeicherten.
    var rows: [SavedZone] {
        let own = ZoneNames.canonical(ownID)
        return [SavedZone(id: ownID, on: true)] + saved.filter { ZoneNames.canonical($0.id) != own }
    }

    func isOwn(_ id: String) -> Bool { ZoneNames.canonical(id) == ZoneNames.canonical(ownID) }

    func setOn(_ id: String, _ on: Bool) {
        guard !isOwn(id) else { return }
        guard let i = saved.firstIndex(where: { ZoneNames.canonical($0.id) == ZoneNames.canonical(id) }) else { return }
        saved[i].on = on; persist()
    }

    /// Neu dazu (angehakt). Steht sie schon drin, wird sie nur angehakt.
    func add(_ id: String) {
        guard TimeZone(identifier: id) != nil, !isOwn(id) else { return }
        if saved.contains(where: { ZoneNames.canonical($0.id) == ZoneNames.canonical(id) }) { setOn(id, true); return }
        saved.append(SavedZone(id: id, on: true)); persist()
    }

    func remove(_ id: String) {
        guard !isOwn(id) else { return }
        saved.removeAll { $0.id == id }; persist()
    }

    /// Eigener Name; leer = zurück zum Standard. Die eigene Zone bekommt
    /// dafür einen Eintrag in der Liste (ohne Haken, sie ist ohnehin dabei).
    func rename(_ id: String, to label: String) {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (clean.isEmpty || clean == ZoneNames.name(id)) ? nil : clean
        if let i = saved.firstIndex(where: { ZoneNames.canonical($0.id) == ZoneNames.canonical(id) }) {
            saved[i].label = value
        } else if value != nil {
            saved.append(SavedZone(id: id, on: false, label: value))
        }
        persist()
    }

    /// Nach dem Erstellen: „im Call" gilt für DIESEN Call (Runde 87).
    func resetTicks() {
        for i in saved.indices { saved[i].on = false }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
