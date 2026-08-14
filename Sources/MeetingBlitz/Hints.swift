import SwiftUI
import AppKit

/// Erklärtexte für die Symbole im Widget (Runde 56).
///
/// GESCHICHTE, damit das niemand zurückbaut: SwiftUIs Hover ist in diesem
/// nonactivating Panel VIERMAL gescheitert. (1) `.help()` erscheint an den
/// Zeilen-Symbolen schlicht nie. (2) `onHover` feuerte mit veralteten
/// Tracking-Flächen, die Maus stand beim Enter ~190pt neben dem Symbol.
/// (3) Eine Hover-Fläche HINTER dem Knopf bekommt gar keine Ereignisse.
/// (4) Auch `onContinuousHover` meldete Positionen aus denselben veralteten
/// Flächen. Das Panel verschiebt und vergrößert sich nach dem Öffnen selbst
/// (Phantom-Fitting-Size, Runde 47), und AppKits Tracking zieht nicht mit.
///
/// DESHALB: Hover in Eigenregie. Jedes Symbol REGISTRIERT nur seine Fläche
/// (GeometryReader, Fensterkoordinaten). Der Maus-Monitor des Widgets, dieselbe
/// Technik, mit der das Widget zuverlässig auf Klicks daneben reagiert, meldet
/// jede Bewegung an `HintWindow`, das selbst den Treffer rechnet. Kein
/// AppKit-Tracking, keine veralteten Flächen.
@MainActor
final class HintSpots {
    static let shared = HintSpots()

    struct Spot {
        let text: String
        /// Fläche in SwiftUI-`.global`-Koordinaten des Widget-Fensters
        /// (Ursprung oben links, y nach unten).
        let rect: CGRect
    }

    private(set) var spots: [String: Spot] = [:]

    func set(_ id: String, text: String, rect: CGRect) {
        let known = spots[id]
        spots[id] = Spot(text: text, rect: rect)
        // Nur echte Änderungen loggen, der 30s-Re-Render der Agenda würde
        // sonst identische Zeilen stapeln.
        if known?.rect != rect {
            HintWindow.log("spot \(id) rect=\(rect) widget=\(WidgetPanelController.shared.frame ?? .zero)")
        }
    }

    func remove(_ id: String) { spots.removeValue(forKey: id) }
    func clear() { spots.removeAll() }
}

extension View {
    /// Erklärt ein Bedienelement per System-Tooltip. Wo macOS ihn zeigt (etwa
    /// am „Neues Meeting"-Knopf), ist er ein Bonus; die Zeilen-Symbole laufen
    /// über `rowHint`.
    func hint(_ text: String, id: String) -> some View {
        self.help(text)
    }

    /// Registriert die Fläche dieses Elements für die selbstgebaute
    /// Hover-Erklärung. Anzeige und Treffer-Rechnung übernimmt `HintWindow`,
    /// gespeist vom Maus-Monitor des Widgets.
    func rowHint(_ text: String) -> some View {
        modifier(RowHintModifier(text: text))
    }
}

private struct RowHintModifier: ViewModifier {
    let text: String
    @State private var spotID = UUID().uuidString

    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear
                .onAppear { HintSpots.shared.set(spotID, text: text, rect: g.frame(in: .global)) }
                .onChange(of: g.frame(in: .global)) { _, new in
                    HintSpots.shared.set(spotID, text: text, rect: new)
                }
                .onDisappear { HintSpots.shared.remove(spotID) }
        })
    }
}
