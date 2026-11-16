import CoreGraphics
import Foundation
import SupervoxCore

/// Les textes de la vue de dictée : tout ce qui se décide sans dessiner.
public enum DictationText {
    /// Texte en direct : quatre lignes au plus à la largeur du panneau (une ligne tient 80 à 90 caractères en
    /// `callout`, relevé sur les images : 245 caractères y font trois lignes), avec la marge d'une coupe à une limite de mot. Choix de mise en page.
    public static let liveTextLimit = 260
    /// Dernier texte récupérable : trois lignes. Même nature.
    public static let transcriptLimit = 170
    /// Message sous le titre (raison d'un échec, d'une copie) : quatre lignes en `caption`.
    public static let detailLimit = 320

    /// La ligne d'aide sous le champ de relecture.
    public static let reviewHint = "⌘↩ colle le texte. Échap ferme sans coller ; le texte reste dans « Dernière dictée »."

    /// L'aide sous le champ quand le panneau n'a pas la frappe (un collage manqué la lui a fait rendre, ou un clic dans une autre
    /// application la lui a prise) : ⌘↩ partirait dans l'autre application, et n'est donc pas annoncé. Une seule phrase pour
    /// les deux cas, et sans « réessayer » : sans Accessibilité, un nouveau « Coller » échouerait de la même façon.
    public static let reviewNoKeyboardHint =
        "Cliquez dans le texte pour le corriger, ou sur « Coller » pour le coller. Échap ferme sans coller."
    /// L'aide sous un champ vide : « Coller » est inactif, ⌘↩ ne fait rien.
    public static let reviewEmptyHint = "Tapez un texte, ou appuyez sur Échap pour fermer sans coller."
    /// Ce que dit un champ vide.
    public static let reviewPlaceholder = "Le texte est vide."

    /// Hauteur la plus basse du champ de relecture : quatre lignes de `callout` à 15 points plus 2, la même mesure que la place
    /// du texte en direct (relevée sur les images de l'étape 3 ; voir `DictationView.liveText`).
    public static let editorMinHeight: CGFloat = 62
    /// Hauteur la plus haute : seize lignes. Choix de mise en page, non mesuré. Au-delà, le champ défile.
    public static let editorMaxHeight: CGFloat = 242

    /// La hauteur du champ de relecture pour un contenu de cette hauteur : celle du contenu, entre les deux bornes. Une valeur
    /// négative ou non finie (que la mesure ne devrait pas donner) vaut la borne basse : y compris +∞, par cohérence avec
    /// `duration` (une valeur absurde ne doit pas ouvrir le champ au maximum) ; le brief ne tranche que NaN et le négatif.
    public static func editorHeight(contentHeight: CGFloat) -> CGFloat {
        guard contentHeight.isFinite else { return editorMinHeight }
        return min(max(contentHeight, editorMinHeight), editorMaxHeight)
    }

    private static let ellipsis = "…"

    /// `0:07`, `1:05` : minutes, puis secondes sur deux chiffres. Les secondes sont tronquées, pas arrondies ; une valeur
    /// négative ou non numérique donne `0:00`.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let whole = Int(seconds)
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// La fin de `text`, au plus `maxCharacters` caractères préfixe compris, coupée à une limite de mot : « … » puis des
    /// mots entiers. Un texte qui tient est rendu tel quel. Sans aucune espace dans ce qui reste, la coupe est franche
    /// (« … » collé au texte) plutôt qu'un effacement.
    public static func tail(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        guard maxCharacters > ellipsis.count + 1 else { return ellipsis }
        let budget = maxCharacters - (ellipsis.count + 1)
        let kept = String(text.suffix(budget))
        // Le caractère juste avant la coupe : une espace veut dire que le premier mot gardé est entier.
        let before = text[text.index(text.endIndex, offsetBy: -budget - 1)]
        var words = Substring(kept)
        if !before.isWhitespace, let space = words.firstIndex(where: \.isWhitespace) {
            words = words[space...]
        } else if !before.isWhitespace {
            words = ""
        }
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ellipsis + String(text.suffix(maxCharacters - ellipsis.count)) }
        return ellipsis + " " + trimmed
    }

    /// Le début de `text`, au plus `maxCharacters` caractères suffixe compris, coupé à une limite de mot : des mots
    /// entiers puis « … ». Pour un message dont le début compte (la raison d'un échec).
    public static func head(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        guard maxCharacters > ellipsis.count + 1 else { return ellipsis }
        let budget = maxCharacters - (ellipsis.count + 1)
        let kept = String(text.prefix(budget))
        let after = text[text.index(text.startIndex, offsetBy: budget)]
        var words = Substring(kept)
        if !after.isWhitespace, let space = words.lastIndex(where: \.isWhitespace) {
            words = words[..<space]
        } else if !after.isWhitespace {
            words = ""
        }
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(text.prefix(maxCharacters - ellipsis.count)) + ellipsis }
        return trimmed + " " + ellipsis
    }

    /// Le texte du bouton « Copier » ; un échec laisse « Copier » (on peut réessayer) et s'écrit à côté (`copyFailure`).
    public static func copyLabel(for state: CopyState) -> String {
        state == .copied ? "Copié" : "Copier"
    }

    /// Ce que le panneau dit quand le presse-papiers n'a pas accepté le texte.
    public static let copyFailure = "Copie impossible"

    /// Le libellé d'une étape, en mots simples. Il ne porte jamais le texte dicté.
    public static func status(for stage: DictationStage) -> String {
        switch stage {
        case .idle: "Prêt"
        case .preparing: "Préparation…"
        case .recording: "Enregistrement"
        case .finalizing: "Transcription…"
        case .formatting: "Mise en forme…"
        case .review: "À relire"
        case .pasting: "Collage…"
        case .copied: "Texte copié"
        case .cancelled: "Dictée interrompue"
        case .failed(.noSpeech): "Rien à transcrire"
        case .failed(.microphone): "Micro indisponible"
        case .failed(.engine): "Transcription impossible"
        case .failed(.clipboard): "Texte non copié"
        }
    }

    /// Les barres de la forme d'onde : toujours `count`, la plus ancienne à gauche, complétées de silence à gauche quand
    /// il y a moins de niveaux, les niveaux bornés à 0…1 (un niveau non numérique vaut 0).
    public static func bars(_ levels: [Float], count: Int = DictationViewState.levelCount) -> [Float] {
        let recent = levels.suffix(count).map { level -> Float in
            level.isNaN ? 0 : min(max(level, 0), 1)
        }
        return Array(repeating: 0, count: count - recent.count) + recent
    }
}

/// Ce que la vue de dictée montre pour un état et un dernier texte : décidé ici, dessiné par `DictationView`.
public struct DictationDisplay: Equatable, Sendable {
    /// Le ton du titre : choisit l'icône et la couleur.
    public enum Mood: Equatable, Sendable {
        case ready, info, working, recording, success, failure
        /// Le texte attend d'être relu.
        case review
    }

    /// Le dernier texte dicté, que l'on peut copier.
    public struct Transcript: Equatable, Sendable {
        /// « Dernière dictée » quand ce texte n'est pas celui de la dictée que le titre décrit ; `nil` sinon.
        public var label: String?
        /// La fin du texte, coupée pour tenir dans la carte ; le bouton « Copier » copie le texte entier.
        public var text: String
        /// Ce qu'a donné le dernier clic sur « Copier ».
        public var copy: CopyState
    }

    public var mood: Mood
    public var headline: String
    /// `0:07`, pendant l'enregistrement et la transcription.
    public var duration: String?
    /// Les barres de la forme d'onde, pendant l'enregistrement seulement.
    public var bars: [Float]?
    /// La fin du texte en direct, quand il y en a un.
    public var liveText: String?
    /// Le message sous le titre : téléchargement, vocabulaire, raison d'un échec ou d'une copie.
    public var detail: String?
    /// Le raccourci s'affiche sous « Prêt ».
    public var showsHotKey: Bool
    public var transcript: Transcript?

    /// Le texte à relire : la vue de relecture à la place de la carte « Dernière dictée », pendant la relecture et le collage.
    public struct Review: Equatable, Sendable {
        /// Le texte entier, tel que l'utilisateur le corrige : jamais coupé ni rogné.
        public var text: String
        /// On peut écrire dans le champ (relecture, pas collage).
        public var isEditable: Bool
        public var canPaste: Bool
        public var canCopy: Bool
        /// Le collage est en cours.
        public var isPasting: Bool
        /// Ce qu'a donné le dernier clic sur « Copier ».
        public var copy: CopyState
        /// La ligne d'aide sous le champ ; aucune pendant le collage. Elle n'annonce ⌘↩ que si ⌘↩ colle : le texte n'est pas
        /// blanc et le panneau a la frappe.
        public var hint: String?
        /// Le champ est vide (aucun caractère) : il dit « Le texte est vide. ».
        public var showsPlaceholder: Bool
    }

    public var review: Review?

    /// - Parameters:
    ///   - copy: ce qu'a donné le dernier clic sur « Copier » (`PanelModel.copyState`).
    ///   - panelHasKeyboard: le panneau est la fenêtre clé (`PanelModel.panelHasKeyboard`) : seul cas où l'aide annonce ⌘↩.
    ///     Sans information, le choix sûr : ne pas l'annoncer.
    public init(state: DictationViewState, copy: CopyState = .idle, panelHasKeyboard: Bool = false) {
        let notice = state.notice.map { DictationText.head($0, maxCharacters: DictationText.detailLimit) }
        let stage = state.stage
        headline = DictationText.status(for: stage)
        duration = nil
        bars = nil
        liveText = nil
        detail = notice
        showsHotKey = false
        let live = Self.nonBlank(state.liveText).map {
            DictationText.tail($0, maxCharacters: DictationText.liveTextLimit)
        }

        switch stage {
        case .idle:
            if let notice {
                mood = .info
                headline = notice
                detail = nil
            } else {
                mood = .ready
                showsHotKey = true
            }
        case .preparing:
            mood = .working
        case .recording:
            mood = .recording
            duration = DictationText.duration(state.elapsed)
            bars = DictationText.bars(state.levels)
            liveText = live
        case .finalizing:
            mood = .working
            duration = DictationText.duration(state.elapsed)
            liveText = live
        case .formatting:
            mood = .working
        case .review:
            mood = .review
        case .pasting:
            mood = .working
        case .copied:
            mood = .success
        case .cancelled:
            mood = .info
        case .failed:
            mood = .failure
        }

        // La relecture : le texte entier, à corriger, coller ou copier. Rien d'autre ne le montre.
        if stage == .review || stage == .pasting {
            let usable = stage == .review && Self.nonBlank(state.draft) != nil
            let hint: String? =
                stage == .pasting
                ? nil
                : !usable
                    ? DictationText.reviewEmptyHint
                    : panelHasKeyboard ? DictationText.reviewHint : DictationText.reviewNoKeyboardHint
            review = Review(
                text: state.draft, isEditable: stage == .review, canPaste: usable, canCopy: usable,
                isPasting: stage == .pasting, copy: copy, hint: hint, showsPlaceholder: state.draft.isEmpty)
        } else {
            review = nil
        }

        // Le texte récupérable : jamais pendant une dictée, ni pendant la relecture et le collage (le texte y est celui que
        // l'on relit). Après une copie, c'est le texte de cette dictée, sans étiquette.
        if !stage.holdsPanel, let text = Self.nonBlank(state.lastTranscript) {
            self.transcript = Transcript(
                label: stage == .copied ? nil : "Dernière dictée",
                text: DictationText.tail(text, maxCharacters: DictationText.transcriptLimit), copy: copy)
        } else {
            self.transcript = nil
        }
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
