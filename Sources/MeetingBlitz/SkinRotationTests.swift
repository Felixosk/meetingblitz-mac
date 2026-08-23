import Foundation

/// Selbsttest des Motivwechsels (23.08.2026), Teil von `--selftest`.
///
/// Geprüft wird `SkinRotationEngine`, nicht `AppState`: dort hängen die Werte
/// an den echten Nutzereinstellungen, ein Test würde sie verstellen.
enum SkinRotationTests {

    /// Drei Motive reichen für jede Aussage hier und halten die Erwartungen
    /// lesbar. Echte Kennungen, damit der Test bei einer Umbenennung auffällt.
    private static var pool: [Skin] { Array(Skin.all.prefix(3)) }

    static func failures() -> [String] {
        var out: [String] = []
        let ids = pool.map(\.id)
        guard ids.count == 3 else { return ["SkinRotation: weniger als 3 Motive im Bundle"] }

        // Der Reihe nach: einmal rundherum und wieder von vorn.
        var cur = ids[0]
        for expected in [ids[1], ids[2], ids[0]] {
            let next = SkinRotationEngine.next(after: cur, pool: pool, mode: .sequence)
            if next != expected { out.append("Reihenfolge: nach \(cur) kam \(next ?? "nil"), erwartet \(expected)") }
            cur = next ?? cur
        }

        // Fester Modus wechselt nie.
        if SkinRotationEngine.next(after: ids[0], pool: pool, mode: .off) != nil {
            out.append("Fester Modus hat trotzdem gewechselt")
        }

        // Ein einzelnes Motiv im Topf: nichts zu wechseln, auch nicht zufällig.
        for mode in [SkinRotation.sequence, .random] {
            if SkinRotationEngine.next(after: ids[0], pool: [pool[0]], mode: mode) != nil {
                out.append("Ein-Motiv-Auswahl (\(mode.rawValue)) hat gewechselt")
            }
        }

        // Zufall: nie zweimal dasselbe hintereinander, und immer aus dem Topf.
        // 200 Ziehungen, damit ein seltener Fehlgriff nicht durchrutscht.
        var current = ids[0]
        for _ in 0..<200 {
            guard let next = SkinRotationEngine.next(after: current, pool: pool, mode: .random) else {
                out.append("Zufall lieferte nichts, obwohl 3 Motive im Topf sind")
                break
            }
            if next == current { out.append("Zufall wiederholte \(current) direkt"); break }
            if !ids.contains(next) { out.append("Zufall lieferte \(next), das nicht im Topf ist"); break }
            current = next
        }

        // Unbekannte aktuelle Kennung (Motiv wurde aus dem Topf genommen):
        // muss beim ersten weitermachen statt zu stolpern.
        if SkinRotationEngine.next(after: "gibt-es-nicht", pool: pool, mode: .sequence) != ids[0] {
            out.append("Unbekannte Kennung führte nicht zum ersten Motiv")
        }

        return out
    }
}
