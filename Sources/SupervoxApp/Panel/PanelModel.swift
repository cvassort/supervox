import Foundation
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
        ModeChip(id: rawID, title: "Dictée brute"),
        ModeChip(id: cleanedID, title: "Dictée nettoyée"),
        ModeChip(id: promptID, title: "Prompt"),
        ModeChip(id: interviewID, title: "Entretien"),
    ]

    /// Mode retenu quand le dernier mode enregistré n'existe plus.
    public static let fallbackID = rawID
}

/// Les identifiants des modes fixes, écrits ici et nulle part ailleurs dans `Sources/SupervoxApp` (un contrôle de sources le
/// vérifie ; l'outil de rendu des écrans les nomme par ces constantes) : ils sont
/// enregistrés dans `settings.json`, où ils identifient les modes (`AppSettings.modes`).
extension ModeChip {
    public static let rawID = "dictee-brute"
    public static let cleanedID = "dictee-nettoyee"
    public static let promptID = "prompt"
    public static let interviewID = "entretien"
}

/// D'où vient un avis. L'ordre des cas est l'ordre d'affichage.
public enum NoticeOrigin: Int, CaseIterable, Comparable, Sendable {
    /// Le fichier de réglages n'a pas pu être repris au lancement.
    case settingsLoad
    /// Le raccourci global, ou celui d'un mode, n'a pas pu être enregistré ou rétabli (une ligne par raccourci).
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
    /// Les pastilles, dans l'ordre des réglages (`AppSettings.modes`).
    public private(set) var modes: [ModeChip]
    public private(set) var isOpen = false
    public private(set) var selectedModeID: String

    /// Libellé du raccourci global effectivement enregistré, `nil` s'il n'y en a aucun.
    public var hotKeyLabel: String?
    /// Accueil du premier lancement ; effacé quand le panneau se ferme.
    public var welcome: String?
    /// La dictée telle que la vue la montre ; mise à jour par le contrôleur de dictée.
    public var dictation = DictationViewState()
    /// Ce qu'a donné le dernier clic sur « Copier » ; oublié à la fermeture du panneau, à l'ouverture, quand le dernier texte
    /// de la dictée change et au début d'une nouvelle dictée.
    public private(set) var copyState = CopyState.idle
    public var transcriptCopied: Bool { copyState == .copied }
    /// Le panneau a la frappe : c'est la fenêtre clé. Seule source de ce fait (la surface le remonte à chaque prise et perte de
    /// la clé : un clic dans une autre application la lui prend, un clic dans le panneau la lui rend) ; l'aide de la relecture
    /// n'annonce ⌘↩ que s'il est vrai. Faux panneau fermé.
    public var panelHasKeyboard = false
    /// Le champ de relecture a une saisie en attente (touche morte, méthode de saisie : texte marqué). `ReviewTextView` le
    /// remonte. Tant qu'il est vrai, changer de version est sans effet : le champ ne remplacerait pas son texte, et le texte
    /// que le contrôleur croit montrer ne serait plus celui de l'écran.
    public var fieldIsComposing = false
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
    /// Appelé quand l'utilisateur modifie le texte en relecture, avec le texte entier : le contrôleur de dictée le garde.
    @ObservationIgnored public var onDraftChange: (@MainActor (String) -> Void)?
    /// Ce que fait « Coller » : le contrôleur de dictée insère le texte en relecture.
    @ObservationIgnored public var onPaste: (@MainActor () -> Void)?
    /// Ce que fait « Corriger à la voix » : le contrôleur de dictée commence la correction de la relecture.
    @ObservationIgnored public var onCorrect: (@MainActor () -> Void)?
    /// Ce que fait « Terminer » : la consigne est dite.
    @ObservationIgnored public var onFinishCorrection: (@MainActor () -> Void)?
    /// « Version précédente » et son contraire.
    @ObservationIgnored public var onPreviousVersion: (@MainActor () -> Void)?
    @ObservationIgnored public var onNextVersion: (@MainActor () -> Void)?
    /// Appelé quand l'utilisateur change de mode, avec le nouvel identifiant, pour qu'il soit sauvé.
    @ObservationIgnored public var onModeChanged: (@MainActor (String) -> Void)?

    /// `lastModeID` vient des réglages ; un identifiant inconnu retombe sur la dictée brute. `modes` : les pastilles des
    /// réglages ; sans elles, les quatre modes de base.
    public init(lastModeID: String, modes: [ModeChip] = ModeChip.fixed) {
        self.modes = modes
        selectedModeID = modes.contains { $0.id == lastModeID } ? lastModeID : ModeChip.fallbackID
    }

    /// Les pastilles suivent les réglages : ajout, nom, ordre, suppression. Le mode choisi qui n'y est plus devient la dictée
    /// brute, sans que `onModeChanged` soit appelé : ce n'est pas un choix de l'utilisateur, et le fichier de réglages garde
    /// l'ancien identifiant jusqu'au prochain choix.
    public func setModes(_ modes: [ModeChip]) {
        self.modes = modes
        if !modes.contains(where: { $0.id == selectedModeID }) { selectedModeID = ModeChip.fallbackID }
    }

    /// L'état de la dictée tel que la vue le montre. Un nouveau dernier texte, un brouillon modifié, ou une dictée qui commence,
    /// remet « Copier » à neuf ; un échec ou une interruption n'y touchent pas (le dernier texte est toujours là).
    public func setDictation(_ state: DictationViewState) {
        let textChanged = state.lastTranscript != dictation.lastTranscript || state.draft != dictation.draft
        dictation = state
        // Hors relecture le champ n'est plus là : une saisie en attente ne reste pas comptée.
        if state.stage != .review { fieldIsComposing = false }
        if textChanged || state.stage.isActive { copyState = .idle }
    }

    /// Le bouton « Copier » : le texte entier, pas la fin que la carte montre. En relecture, c'est le brouillon que l'on est en
    /// train de corriger ; ailleurs, le dernier texte. Un texte blanc ne se copie pas : rien ne change. Pendant une correction,
    /// rien ne se copie : l'écran montre tantôt le brouillon, tantôt le texte reçu en flux, et on ne copie pas un texte que
    /// l'écran ne montre pas.
    public func copyTranscript() {
        guard !dictation.stage.isCorrecting else { return }
        let text = dictation.stage == .review ? dictation.draft : dictation.lastTranscript
        guard let text, !Self.isBlank(text), let onCopy else { return }
        copyState = onCopy(text) ? .copied : .failed
    }

    /// On peut coller en relecture, quand le brouillon n'est pas blanc.
    public var canPaste: Bool { dictation.stage == .review && !Self.isBlank(dictation.draft) }

    /// « Coller » : ne fait rien si l'on ne peut pas coller.
    public func paste() {
        guard canPaste else { return }
        onPaste?()
    }

    /// L'utilisateur a modifié le texte en relecture. Ignoré hors relecture. La vue montre tout de suite le nouveau texte, le
    /// contrôleur de dictée est prévenu, et « Copier » repart à neuf : le texte n'est plus celui qui a été copié.
    public func editDraft(_ text: String) {
        guard dictation.stage == .review else { return }
        dictation.draft = text
        copyState = .idle
        onDraftChange?(text)
    }

    /// On peut corriger à la voix en relecture, quand le texte n'est pas blanc.
    public var canCorrect: Bool { dictation.stage == .review && !Self.isBlank(dictation.draft) }

    /// On peut terminer la consigne : la correction écoute.
    public var canFinishCorrection: Bool { dictation.stage == .correcting(.recording) }

    /// Le bouton de la correction : « Corriger à la voix » commence la correction ; « Terminer », pendant qu'elle écoute, la
    /// termine. Ne fait rien dans les autres cas.
    public func correct() {
        if canCorrect {
            onCorrect?()
        } else if canFinishCorrection {
            onFinishCorrection?()
        }
    }

    /// « Version précédente » : sans effet s'il n'y en a pas (`DictationViewState.canGoBack`).
    public func previousVersion() {
        guard dictation.canGoBack, !fieldIsComposing else { return }
        onPreviousVersion?()
    }

    /// La version suivante : sans effet s'il n'y en a pas.
    public func nextVersion() {
        guard dictation.canGoForward, !fieldIsComposing else { return }
        onNextVersion?()
    }

    private static func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Réservé à `PanelController`, qui montre et cache la fenêtre en même temps.
    func toggle() {
        isOpen.toggle()
        copyState = .idle
        if isOpen { onOpen?() } else {
            welcome = nil
            panelHasKeyboard = false
        }
    }

    func close() {
        isOpen = false
        welcome = nil
        copyState = .idle
        panelHasKeyboard = false
    }

    /// Ce que la vue de dictée montre : l'état de la dictée, ce qu'a donné « Copier », et si le panneau a la frappe.
    public var dictationDisplay: DictationDisplay {
        DictationDisplay(state: dictation, copy: copyState, panelHasKeyboard: panelHasKeyboard)
    }

    /// Un identifiant inconnu est ignoré ; le mode déjà choisi n'est pas un changement.
    public func select(_ id: String) {
        guard id != selectedModeID, modes.contains(where: { $0.id == id }) else { return }
        selectedModeID = id
        onModeChanged?(id)
    }
}
