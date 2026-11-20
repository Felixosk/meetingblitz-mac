import Foundation

/// Runde 120: Das Sofort-Meeting (Blitz) geht IMMER und NUR in den Google-Kalender
/// des verbundenen Google-Kontos, nie in iCloud/Apple und nie in die Wahl aus dem
/// Termin-Fenster. Runde 125: das Konto steht nicht mehr fest im Code, es ist die
/// Adresse, mit der Google in den Einstellungen verbunden ist (`googleAccountEmail`).
/// Reine Logik, damit `--selftest` sie ohne Kalender prüfen kann.
enum InstantTarget {
    /// Adresse des verbundenen Google-Kontos, leer wenn Google nicht verbunden ist.
    static var account: String {
        UserDefaults.standard.string(forKey: "googleAccountEmail")?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Kalender-ID des Google-Kalenders von `account`, sonst nil (dann wird nichts angelegt).
    static func pick(from calendars: [CalendarInfo], account: String = account) -> String? {
        guard !account.isEmpty else { return nil }
        let hits = calendars.filter {
            !$0.isAppleAccount
                && ($0.sourceTitle.localizedCaseInsensitiveContains(account)
                    || $0.title.localizedCaseInsensitiveContains(account))
        }
        return (hits.first { $0.title.localizedCaseInsensitiveCompare(account) == .orderedSame }
                ?? hits.first { $0.title.localizedCaseInsensitiveContains(account) }
                ?? hits.first)?.id
    }

    static func failures() -> [String] {
        var out: [String] = []
        func cal(_ id: String, _ title: String, _ src: String, apple: Bool) -> CalendarInfo {
            CalendarInfo(id: id, title: title, color: .gray, sourceTitle: src, isAppleAccount: apple)
        }
        let account = "me@example.com"
        let list = [
            cal("ic", "Work", "iCloud", apple: true),
            cal("other", "Private", "other@example.org", apple: false),
            cal("g2", "Team", account, apple: false),
            cal("g1", account, account, apple: false),
        ]
        if pick(from: list, account: account) != "g1" { out.append("Sofort-Ziel: erwartet Google-Hauptkalender g1, bekommen \(pick(from: list, account: account) ?? "nil")") }
        // Nur iCloud/anderes Konto vorhanden: nie Apple, lieber nichts.
        if pick(from: [list[0], list[1]], account: account) != nil { out.append("Sofort-Ziel: ohne Google-Konto muss nil kommen (nie Apple)") }
        // Ein iCloud-Kalender, der die Adresse nur im Titel trägt, zählt nicht.
        if pick(from: [cal("ic2", account, "iCloud", apple: true)], account: account) != nil { out.append("Sofort-Ziel: iCloud-Kalender darf nie gewählt werden") }
        // Ohne verbundenes Google-Konto (leere Adresse) nie raten.
        if pick(from: list, account: "") != nil { out.append("Sofort-Ziel: ohne Google-Konto muss nil kommen") }
        return out
    }
}
