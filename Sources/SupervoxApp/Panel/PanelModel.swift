import Observation

/// Une pastille de mode en haut du panneau.
public struct ModeChip: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    /// Les quatre modes fixes de cette étape, dans l'ordre d'affichage. Aucun mode personnalisé.
    public static let fixed: [ModeChip] = [
        ModeChip(id: "dictee-brute", title: "Dictée brute"),
        ModeChip(id: "dictee-nettoyee", title: "Dictée nettoyée"),
        ModeChip(id: "prompt", title: "Prompt"),
        ModeChip(id: "entretien", title: "Entretien"),
    ]

    /// Mode retenu quand le dernier mode enregistré n'existe plus.
    public static let fallbackID = "dictee-brute"
}

/// D'où vient un avis. L'ordre des cas est l'ordre d'affichage.
public enum NoticeOrigin: Int, CaseIterable, Comparable, Sendable {
    /// Le fichier de réglages n'a pas pu être repris au lancement.
    case settingsLoad
    /// Le raccourci global n'a pas pu être enregistré.
    case hotKey
    /// Échap n'a pas pu être réservé pendant que le panneau est ouvert.
    case escape
    /// La dernière sauvegarde des réglages a échoué.
    case save

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// État du panneau : ouvert ou fermé, mode choisi. Ne connaît ni AppKit ni le disque.
@MainActor @Observable
public final class PanelModel {
    public let modes: [ModeChip]
    public private(set) var isOpen = false
    public private(set) var selectedModeID: String

    /// Libellé du raccourci global effectivement enregistré, `nil` s'il n'y en a aucun.
    public var hotKeyLabel: String?
    /// Avis à montrer à l'utilisateur, un par origine.
    public private(set) var notices: [NoticeOrigin: String] = [:]

    /// Pose l'avis de cette origine, ou l'efface avec `nil`. Les autres origines ne bougent pas.
    public func setNotice(_ text: String?, for origin: NoticeOrigin) {
        notices[origin] = text
    }

    /// Les avis, dans l'ordre des origines.
    public var noticeLines: [String] { notices.sorted { $0.key < $1.key }.map(\.value) }

    /// Appelé à chaque ouverture, avant l'affichage : l'état des permissions y est relu.
    @ObservationIgnored public var onOpen: (@MainActor () -> Void)?
    /// Appelé quand l'utilisateur change de mode, avec le nouvel identifiant, pour qu'il soit sauvé.
    @ObservationIgnored public var onModeChanged: (@MainActor (String) -> Void)?

    /// `lastModeID` vient des réglages ; un identifiant inconnu retombe sur la dictée brute.
    public init(lastModeID: String) {
        modes = ModeChip.fixed
        selectedModeID = modes.contains { $0.id == lastModeID } ? lastModeID : ModeChip.fallbackID
    }

    /// Réservé à `PanelController`, qui montre et cache la fenêtre en même temps.
    func toggle() {
        isOpen.toggle()
        if isOpen { onOpen?() }
    }

    func close() {
        isOpen = false
    }

    /// Un identifiant inconnu est ignoré ; le mode déjà choisi n'est pas un changement.
    public func select(_ id: String) {
        guard id != selectedModeID, modes.contains(where: { $0.id == id }) else { return }
        selectedModeID = id
        onModeChanged?(id)
    }
}
