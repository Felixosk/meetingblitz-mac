import Foundation

/// Selbsttest Runde 88: Auto-Beitreten, Nachholen nach dem Aufwachen,
/// Zurückrollen bei „beide Kalender". Reine Regeln, kein Kalender.
enum MonitorTests {
    static func failures() -> [String] {
        var out: [String] = []
        // Auto-Beitreten: 10 s vorher bis 30 s danach. Ein gerade begonnener
        // Termin (−15 s) muss noch zählen, vorher war er schon aus der Liste.
        for (s, want) in [(11.0, false), (10.0, true), (0.0, true), (-15.0, true), (-29.0, true), (-30.0, false)] {
            if MonitorRules.autoJoinDue(secondsUntil: s) != want {
                out.append("Auto-Beitreten bei \(s) s: erwartet \(want)")
            }
        }
        // Einmal-Timer: Beginn in 35 s → wecken in 25 s (= 10 s vorher).
        if MonitorRules.autoJoinWakeDelay([35, 300]) != 25 { out.append("Auto-Beitreten: Weckzeit für 35 s falsch") }
        if MonitorRules.autoJoinWakeDelay([300]) != nil { out.append("Auto-Beitreten: weckt zu früh (300 s)") }
        if MonitorRules.autoJoinWakeDelay([5]) != nil { out.append("Auto-Beitreten: weckt für einen Termin im Fenster") }
        // Nachholen nach dem Aufwachen: 2 min nach Beginn ja, 11 min nein,
        // vorbei nein, noch nicht begonnen nein.
        if !MonitorRules.catchUpDue(sinceStart: 120, ended: false) { out.append("Aufwachen: 2 min nach Beginn kein Banner") }
        if MonitorRules.catchUpDue(sinceStart: 660, ended: false) { out.append("Aufwachen: 11 min nach Beginn noch Banner") }
        if MonitorRules.catchUpDue(sinceStart: 120, ended: true) { out.append("Aufwachen: Banner für beendeten Termin") }
        if MonitorRules.catchUpDue(sinceStart: -60, ended: false) { out.append("Aufwachen: Banner vor Beginn") }
        // „Beide Kalender": zweite Hälfte scheitert → erste wird gelöscht.
        struct Boom: Error {}
        var deleted: [String] = []
        do {
            _ = try GoogleService.writeAll(["apple", "google"],
                                           create: { t in if t == "google" { throw Boom() }; return "id-\(t ?? "")" },
                                           rollback: { deleted.append($0) })
            out.append("Beide Kalender: Fehler der zweiten Hälfte wurde verschluckt")
        } catch {
            if deleted != ["id-apple"] { out.append("Beide Kalender: erste Hälfte nicht zurückgerollt (\(deleted))") }
        }
        if (try? GoogleService.writeAll([nil, "x"], create: { "id-\($0 ?? "std")" }, rollback: { _ in })) != ["id-std", "id-x"] {
            out.append("Beide Kalender: Normalfall liefert nicht beide Kennungen")
        }
        out += GoogleLoginTests.failures()
        return out
    }
}
