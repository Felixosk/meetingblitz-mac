import SwiftUI

/// Das Schließkreuz in der oberen rechten Ecke einer schwebenden Fläche,
/// Banner-Kapsel und Detail-Popover (Runde 56).
///
/// Vorher stand derselbe Block zweimal wörtlich im Code. Zwei Kopien derselben
/// Optik driften garantiert auseinander, sobald jemand eine davon anfasst; ein
/// gemeinsamer Baustein ist die einzige Art, „sieht überall gleich aus"
/// dauerhaft zu halten statt es einmalig herzustellen.
///
/// BEWUSST NICHT VEREINHEITLICHT: das × in den Agenda-Zeilen des Widgets. Es
/// tut etwas anderes (blendet EINEN Termin aus, zweistufig mit roter Warnstufe),
/// steht in einer hellen Liste statt auf einer dunklen Fläche und erscheint nur
/// beim Überfahren. Gleiches Aussehen für ungleiche Bedeutung wäre keine
/// Einheitlichkeit, sondern eine Verwechslungsgefahr.
struct CornerCloseButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Klarer Kontrast: weißes Kreuz auf dunkler Scheibe, kein blasser
            // Ring, Ring plus gedimmtes Kreuz wirkte auf dem Türkis matschig.
            Image(systemName: "xmark")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 15, height: 15)
                .background(Circle().fill(Color.black.opacity(0.40)))
        }
        .buttonStyle(.plain)
        .offset(x: 1, y: -4)   // ragt leicht über die abgerundete Ecke
        .help(help)
    }
}
