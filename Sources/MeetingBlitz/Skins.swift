import AppKit
import SwiftUI

/// Which visual family the flying object is drawn in. `classic` is the
/// original Canvas-drawn U-Boot (`SubmarineView`, no assets needed); the other
/// two load one of the 27 pre-made SVG motifs from the app bundle.
enum SkinStyle: String, CaseIterable, Identifiable {
    case classic, playful, photoreal
    var id: String { rawValue }

    /// Folder name under `Resources/Skins/` (matches the design asset export).
    /// `nil` for `.classic`, which never touches disk.
    var folder: String? {
        switch self {
        case .classic:   return nil
        case .playful:   return "verspielt"
        case .photoreal: return "fotoreal"
        }
    }

    var label: String {
        switch self {
        case .classic:   return L.t("Klassisch", "Classic")
        case .playful:   return L.t("Verspielt", "Playful")
        case .photoreal: return L.t("Fotoreal", "Photoreal")
        }
    }
}

/// Where a motif "lives" — decides which dramatic entrance it gets: water
/// motifs jump out of the sea (`SeaSplash` spray), air motifs burst out of a
/// cloud (`CloudBurst`), Runde 72. Both share the same jump-arc mechanic, only
/// the launch-point panel differs (20.08.2026, Rückmeldung: ein Kampfjet/
/// Helikopter/UFO/Zeppelin/Rakete kommt nicht aus dem Meer).
enum SkinElement: Hashable {
    case water, air
}

/// One selectable flying-object motif. `id`/`slug` are the same string (the
/// file's basename without extension, e.g. "01-narco-sub") — kept as two
/// fields so `id` can serve SwiftUI's `Identifiable` while `slug` stays the
/// explicit "this is a filename" name at call sites.
struct Skin: Identifiable, Hashable {
    let id: String
    let slug: String
    let nameDE: String
    let nameEN: String
    let element: SkinElement

    var name: String { L.t(nameDE, nameEN) }

    init(_ slug: String, _ nameDE: String, _ nameEN: String, _ element: SkinElement) {
        self.id = slug
        self.slug = slug
        self.nameDE = nameDE
        self.nameEN = nameEN
        self.element = element
    }

    /// All 27 motifs, in the fixed numbering from the design export
    /// (`~/.claude/design/meetingblitz-skins/{verspielt,fotoreal}/NN-slug.svg`).
    /// Wasser/Luft-Einteilung folgt der festgelegten Liste vom 20.08.2026.
    static let all: [Skin] = [
        Skin("01-narco-sub", "Narco-U-Boot", "Narco Sub", .water),
        Skin("02-typhoon", "Typhoon-Klasse", "Typhoon Class", .water),
        Skin("03-u96", "U-96", "U-96", .water),
        Skin("04-yellow-submarine", "Gelbes U-Boot", "Yellow Submarine", .water),
        Skin("05-nautilus", "Nautilus", "Nautilus", .water),
        Skin("06-alvin", "Alvin", "Alvin", .water),
        Skin("07-triton", "Triton", "Triton", .water),
        Skin("08-ente", "Ente", "Duck", .water),
        Skin("09-pottwal", "Pottwal", "Sperm Whale", .water),
        Skin("10-hai", "Hai", "Shark", .water),
        Skin("11-orca", "Orca", "Orca", .water),
        Skin("12-oktopus", "Oktopus", "Octopus", .water),
        Skin("13-delfin", "Delfin", "Dolphin", .water),
        Skin("14-schildkroete", "Schildkröte", "Turtle", .water),
        Skin("15-kugelfisch", "Kugelfisch", "Pufferfish", .water),
        Skin("16-papierboot", "Papierboot", "Paper Boat", .water),
        Skin("17-rakete", "Rakete", "Rocket", .air),
        Skin("18-ufo", "UFO", "UFO", .air),
        Skin("19-zeppelin", "Zeppelin", "Zeppelin", .air),
        Skin("20-nessie", "Nessie", "Nessie", .water),
        Skin("21-finnwal", "Finnwal", "Fin Whale", .water),
        Skin("22-ohio", "Ohio-Klasse", "Ohio Class", .water),
        Skin("23-u48", "U-48", "U-48", .water),
        Skin("24-klasse-212a", "Klasse 212A", "Class 212A", .water),
        Skin("25-f22-raptor", "F-22 Raptor", "F-22 Raptor", .air),
        Skin("26-eurofighter", "Eurofighter", "Eurofighter", .air),
        Skin("27-uh60-blackhawk", "UH-60 Black Hawk", "UH-60 Black Hawk", .air),
    ]

    static let byID: [String: Skin] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

/// Loads a skin's SVG straight off disk via `NSImage(contentsOf:)`, which
/// renders it vector-sharp on macOS 26 (CSS animations inside the SVG do not
/// run, that is accepted — see SKIN-SPEC.md). Cached so a flying banner or
/// the settings grid never re-reads the same file every frame.
@MainActor
final class Skins {
    static let shared = Skins()
    private var cache: [String: NSImage] = [:]

    /// `nil` on any failure (missing bundle resource, unreadable file, no
    /// style folder for `.classic`) — callers fall back to the classic
    /// Canvas submarine, never crash.
    func image(for skin: Skin, style: SkinStyle) -> NSImage? {
        guard let folder = style.folder else { return nil }
        let key = "\(folder)/\(skin.slug)"
        if let cached = cache[key] { return cached }
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = resourceURL
            .appendingPathComponent("Skins", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("\(skin.slug).svg")
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[key] = image
        return image
    }
}
