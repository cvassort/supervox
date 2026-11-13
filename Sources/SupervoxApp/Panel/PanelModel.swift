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

/// État du panneau : ouvert ou fermé, mode choisi. Ne connaît ni AppKit ni le disque.
@MainActor @Observable
public final class PanelModel {
    public let modes: [ModeChip]
    public private(set) var isOpen = false
    public private(set) var selectedModeID: String

    /// Libellé du raccourci global effectivement enregistré, `nil` s'il n'y en a aucun.
    public var hotKeyLabel: String?
    /// Une ligne à montrer à l'utilisateur (réglages illisibles, raccourci refusé…), ou `nil`.
    public var notice: String?

    /// Appelé à chaque ouverture, avant l'affichage : l'état des permissions y est relu.
    @ObservationIgnored public var onOpen: (@MainActor () -> Void)?
    /// Appelé quand l'utilisateur change de mode, avec le nouvel identifiant, pour qu'il soit sauvé.
    @ObservationIgnored public var onModeChanged: (@MainActor (String) -> Void)?

    /// `lastModeID` vient des réglages ; un identifiant inconnu retombe sur la dictée brute.
    public init(lastModeID: String) {
        modes = ModeChip.fixed
        selectedModeID = modes.contains { $0.id == lastModeID } ? lastModeID : ModeChip.fallbackID
    }

    public func toggle() {
        isOpen.toggle()
        if isOpen { onOpen?() }
    }

    public func close() {
        isOpen = false
    }

    /// Un identifiant inconnu est ignoré ; le mode déjà choisi n'est pas un changement.
    public func select(_ id: String) {
        guard id != selectedModeID, modes.contains(where: { $0.id == id }) else { return }
        selectedModeID = id
        onModeChanged?(id)
    }
}
