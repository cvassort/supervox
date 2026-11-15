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

/// Ce que le bouton « Copier » a donné.
public enum CopyState: Equatable, Sendable {
    case idle
    /// Le presse-papiers a accepté le texte.
    case copied
    /// Il ne l'a pas accepté : le panneau le dit, et jamais « Copié ».
    case failed
}

/// État du panneau : ouvert ou fermé, mode choisi. Ne connaît ni AppKit ni le disque.
@MainActor @Observable
public final class PanelModel {
    public let modes: [ModeChip]
    public private(set) var isOpen = false
    public private(set) var selectedModeID: String

    /// Libellé du raccourci global effectivement enregistré, `nil` s'il n'y en a aucun.
    public var hotKeyLabel: String?
    /// Accueil du premier lancement ; effacé quand le panneau se ferme.
    public var welcome: String?
    /// La dictée telle que la vue la montre ; mise à jour par le contrôleur de dictée.
    public var dictation = DictationViewState()
    /// Le texte de la dernière dictée réussie, que le collage ait réussi ou non : en mémoire seulement, jamais écrit.
    public private(set) var lastTranscript: String?
    /// Ce qu'a donné le dernier clic sur « Copier » ; oublié à la fermeture du panneau, à l'ouverture, au texte suivant et
    /// au début d'une nouvelle dictée.
    public private(set) var copyState = CopyState.idle
    public var transcriptCopied: Bool { copyState == .copied }
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
    /// Ce que fait « Copier » : met le texte entier dans le presse-papiers (par l'insertion, qui tient le presse-papiers) et
    /// rend vrai si le système l'a accepté.
    @ObservationIgnored public var onCopy: (@MainActor (String) -> Bool)?
    /// Appelé quand l'utilisateur change de mode, avec le nouvel identifiant, pour qu'il soit sauvé.
    @ObservationIgnored public var onModeChanged: (@MainActor (String) -> Void)?

    /// `lastModeID` vient des réglages ; un identifiant inconnu retombe sur la dictée brute.
    public init(lastModeID: String) {
        modes = ModeChip.fixed
        selectedModeID = modes.contains { $0.id == lastModeID } ? lastModeID : ModeChip.fallbackID
    }

    /// Un nouveau dernier texte ; vide ou fait d'espaces, il n'y a rien à garder.
    public func setTranscript(_ text: String?) {
        let blank = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        lastTranscript = blank ? nil : text
        copyState = .idle
    }

    /// L'état de la dictée tel que la vue le montre. Une dictée qui commence remet « Copier » à neuf ; un échec ou une
    /// interruption n'y touchent pas (le dernier texte est toujours là).
    public func setDictation(_ state: DictationViewState) {
        dictation = state
        if state.phase.isActive { copyState = .idle }
    }

    /// Le bouton « Copier » : le texte entier, pas la fin que la carte montre.
    public func copyTranscript() {
        guard let lastTranscript, let onCopy else { return }
        copyState = onCopy(lastTranscript) ? .copied : .failed
    }

    /// Réservé à `PanelController`, qui montre et cache la fenêtre en même temps.
    func toggle() {
        isOpen.toggle()
        copyState = .idle
        if isOpen { onOpen?() } else { welcome = nil }
    }

    func close() {
        isOpen = false
        welcome = nil
        copyState = .idle
    }

    /// Un identifiant inconnu est ignoré ; le mode déjà choisi n'est pas un changement.
    public func select(_ id: String) {
        guard id != selectedModeID, modes.contains(where: { $0.id == id }) else { return }
        selectedModeID = id
        onModeChanged?(id)
    }
}
