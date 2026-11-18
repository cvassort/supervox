import SwiftUI

/// Ce qui dit une phrase à VoiceOver. Une couture : le contrôleur du panneau reçoit son annonceur, la réalisation du système par
/// défaut, un double dans les tests (qui ne postent alors aucune annonce réelle).
@MainActor
public protocol AccessibilityAnnouncing {
    func announce(_ text: String)
}

/// La réalisation du système : l'annonce de SwiftUI. Seul endroit de l'application qui la poste (un contrôle de sources le vérifie).
public struct SystemAccessibilityAnnouncer: AccessibilityAnnouncing {
    public init() {}

    public func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}
