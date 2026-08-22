import AppKit

/// `meetingblitz://` als Automations-Schnittstelle (F9).
///
/// Warum ein URL-Schema und nicht App Intents oder AppleScript: die Metadaten
/// für App Intents extrahiert nur ein Xcode-Build, hier wird per SwiftPM mit
/// den Command Line Tools gebaut. Ein klassisches AppleScript-Wörterbuch wäre
/// für den Zweck zu viel Gerüst. Ein URL-Schema kann dagegen JEDER aufrufen:
/// Kurzbefehle („URL öffnen"), Raycast, Terminal (`open "meetingblitz://show"`),
/// ein Streamdeck.
///
/// Unterstützt:
///   meetingblitz://show           Widget öffnen
///   meetingblitz://join-next      laufendes Meeting, sonst das nächste
///   meetingblitz://instant        Sofort-Meeting erstellen und beitreten
///   meetingblitz://create?text=…  Erstellen-Formular mit Freitext vorbelegen
///   meetingblitz://settings       Einstellungen öffnen
///   meetingblitz://rescue         Fenster zurückholen (siehe PanelRescue)
///
/// `settings` und `rescue` sind zusätzlich der einzige Weg, das Verhalten von
/// außen zu PRÜFEN: Ein Klick im Menü lässt sich nicht fernauslösen, ohne der
/// Shell Bedienungshilfen-Rechte zu geben, ein `open "meetingblitz://settings"`
/// dagegen schon, auch aus einer Vollbild-App heraus.
extension Notification.Name {
    /// `meetingblitz://restart` → der AppDelegate startet neu. Über eine
    /// Meldung, weil nur er den Neustart kennt und `URLScheme` ihn nicht
    /// erreicht.
    static let meetingBlitzRestart = Notification.Name("MeetingBlitzRestart")
}

@MainActor
enum URLScheme {
    /// Die letzten Aufrufe, damit die Diagnose zeigen kann, ob etwas ankam.
    private(set) static var recent: [String] = []

    static func handle(_ url: URL, statusButton: NSStatusBarButton?) {
        guard url.scheme?.lowercased() == "meetingblitz" else { return }
        // host ODER erster Pfadteil: „meetingblitz://show" und
        // „meetingblitz:///show" sollen beide gehen.
        let action = (url.host ?? url.pathComponents.first { $0 != "/" } ?? "").lowercased()
        recent.append(url.absoluteString)
        if recent.count > 5 { recent.removeFirst() }
        // Ohne Protokoll ist von außen nicht zu sehen, ob ein Aufruf ankam und
        // wie er verstanden wurde — die Panels sind bei laufender Arbeit kaum
        // zuverlässig zu fotografieren.
        HintWindow.log("url \(action) ← \(url.absoluteString)")

        let state = AppState.shared
        switch action {
        case "show":
            WidgetPanelController.shared.toggle(state: state, statusButton: statusButton,
                                                anchorToMouseScreen: true)
        case "join-next", "join":
            state.joinCurrentOrNext()
        case "instant", "instant-meeting":
            state.startInstantMeeting()
        case "create", "new":
            // BEWUSST nur vorbelegen, nicht anlegen: eine URL kann jede App
            // feuern. Zwischen fremdem Aufruf und einem Termin im Kalender
            // bleibt ein Klick des Nutzers.
            let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "text" }?.value
            state.pendingQuickAdd = text
            state.openCreatePanel()
        case "settings", "preferences":
            state.toggleSettingsPanel()
        case "rescue", "bring-back":
            PanelRescue.bringBack(state: state, statusButton: statusButton)
        case "restart":
            // Derselbe Weg wie der Menüeintrag. Als URL, weil ein Menüklick von
            // außen nicht auslösbar ist und der Neustart sonst ungetestet bliebe
            // (und weil es ein Notausgang aus dem Terminal ist, wenn die
            // Oberfläche der App hängt).
            NotificationCenter.default.post(name: .meetingBlitzRestart, object: nil)
        default:
            break   // Unbekanntes still ignorieren, nicht mit Fehlern nerven
        }
    }
}
