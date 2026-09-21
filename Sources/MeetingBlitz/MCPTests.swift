import Foundation

/// Selbsttest fuer das Zeit-/Zonen-Parsing des MCP-Zugangs (Runde 78), laeuft
/// ueber `MeetingBlitz --selftest` wie `JoinLinkTests`/`QuickAddTests`. Reine
/// Rechnerei, kein EventKit, deshalb hier pruefbar statt nur per echtem Termin.
enum MCPTests {
    static func failures() -> [String] {
        var out: [String] = []

        func expectUTC(_ what: String, raw: String, timezone: String?, wantHour: Int, wantMinute: Int) {
            do {
                let d = try MCPTools.parseTime(raw, timezone: timezone)
                let cal = Calendar(identifier: .gregorian)
                var utc = cal
                utc.timeZone = TimeZone(identifier: "UTC")!
                let h = utc.component(.hour, from: d), m = utc.component(.minute, from: d)
                if h != wantHour || m != wantMinute {
                    out.append("\(what): erwartet \(wantHour):\(String(format: "%02d", wantMinute)) UTC, "
                              + "bekommen \(h):\(String(format: "%02d", m)) UTC")
                }
            } catch {
                out.append("\(what): unerwarteter Fehler \(error)")
            }
        }

        // "2026-10-02T15:00" + Europe/Berlin (im Oktober noch Sommerzeit,
        // UTC+2) muss 13:00Z ergeben.
        expectUTC("Wandzeit Berlin", raw: "2026-10-02T15:00", timezone: "Europe/Berlin",
                  wantHour: 13, wantMinute: 0)
        // Dieselbe Wandzeit, aber Asia/Nicosia (im Oktober noch EEST, UTC+3):
        // 12:00Z.
        expectUTC("Wandzeit Nicosia", raw: "2026-10-02T15:00", timezone: "Asia/Nicosia",
                  wantHour: 12, wantMinute: 0)
        // Ohne Zone faellt es auf TimeZone.current zurueck. Nicht auf einen
        // festen Erwartungswert pruefbar (haengt vom Testrechner ab), also nur:
        // es wirft nicht und liefert irgendeinen Wert.
        do { _ = try MCPTools.parseTime("2026-10-02T15:00", timezone: nil) }
        catch { out.append("Wandzeit ohne Zone: unerwarteter Fehler \(error)") }

        // ISO MIT Offset schlaegt eine mitgegebene timezone (die Angabe
        // gewinnt gegen die Zusatzinformation, nicht umgekehrt).
        expectUTC("ISO mit Offset schlaegt timezone",
                  raw: "2026-10-02T15:00:00+05:00", timezone: "Europe/Berlin",
                  wantHour: 10, wantMinute: 0)
        expectUTC("ISO mit Z ignoriert timezone",
                  raw: "2026-10-02T15:00:00Z", timezone: "Europe/Berlin",
                  wantHour: 15, wantMinute: 0)

        // Ungueltige Zone wirft, wird NIE still ignoriert.
        do {
            _ = try MCPTools.parseTime("2026-10-02T15:00", timezone: "Nirgendwo/Erfunden")
            out.append("ungueltige Zone: haette werfen muessen, hat aber einen Wert geliefert")
        } catch is MCPTimeError { /* erwartet */ }
        catch { out.append("ungueltige Zone: falscher Fehlertyp \(error)") }

        out += MCPCreatedStoreTests.run()

        return out
    }
}
