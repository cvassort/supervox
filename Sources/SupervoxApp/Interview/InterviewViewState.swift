import Foundation
import SupervoxCore

/// Où en est l'entretien, tel que la vue le montre. Un état de moins que le moteur : `finished` n'a pas de vue, l'entretien est alors
/// retiré du panneau (`PanelModel.setInterview(nil)`).
public enum InterviewPhase: Equatable, Sendable {
    case preparing, listening, thinking, speaking, concluding

    public init?(_ state: ConversationState) {
        switch state {
        case .preparing: self = .preparing
        case .listening: self = .listening
        case .thinking: self = .thinking
        case .speaking: self = .speaking
        case .concluding: self = .concluding
        case .finished: return nil
        }
    }
}

/// L'entretien tel que le panneau le montre ; mis à jour par le contrôleur de l'entretien (tâche 9), qui lit les événements du moteur.
/// Ne porte que des phrases déjà choisies (`notice`, `privacy` viennent de `InterviewText`), jamais le texte d'une erreur.
public struct InterviewViewState: Equatable, Sendable {
    public var phase: InterviewPhase
    /// Le numéro de la question posée ; 0 tant qu'aucune ne l'a été (`ConversationEvent.speakingStarted(question: 0)` : la réplique de
    /// conclusion avant toute question).
    public var question: Int
    public var maxQuestions: Int
    /// La réplique de Supervox en cours, ou la dernière.
    public var questionText: String
    /// La dernière réplique de la personne, ou sa transcription partielle.
    public var lastReply: String
    /// Le niveau du micro, de 0 à 1, à chaque tranche traitée.
    public var level: Float
    /// L'avis du moment (`InterviewText.notice`), `nil` quand il n'y en a pas.
    public var notice: String?
    /// Le réglage du raccourci est « maintien » : la note qui dit qu'en entretien il fonctionne en bascule est montrée.
    public var holdNote: Bool
    /// La phrase de vie privée du pied (`InterviewText.privacy`).
    public var privacy: String
    /// Aucune voix ne parle : la réplique est seulement affichée (voix indisponible). La phase de parole s'appelle alors « Supervox
    /// répond » et dit de lire ; posé par le contrôleur de l'entretien.
    public var textOnly: Bool

    public init(maxQuestions: Int, privacy: String) {
        phase = .preparing
        question = 0
        self.maxQuestions = maxQuestions
        questionText = ""
        lastReply = ""
        level = 0
        notice = nil
        holdNote = false
        self.privacy = privacy
        textOnly = false
    }
}

// MARK: - Ce que la vue montre

/// Tout ce qui se décide sans dessiner : la vue de l'entretien (`InterviewView`) ne fait que l'afficher.
extension InterviewViewState {
    public var title: String { InterviewText.title(phase, textOnly: textOnly) }

    /// « Question n sur m », à partir de la première question seulement : rien avant, ni pour la réplique de conclusion (n = 0).
    var counter: String? {
        question >= 1 ? InterviewText.questionCounter(question, of: maxQuestions) : nil
    }

    /// L'aide de la phase ; aucune en préparation ni en conclusion.
    var hint: String? {
        let hint = InterviewText.hint(phase, textOnly: textOnly)
        return hint.isEmpty ? nil : hint
    }

    /// Le pied qui dit comment annuler : à tout état sauf la conclusion (cahier des charges de la vue).
    var cancelHint: String? { phase == .concluding ? nil : InterviewText.cancelHint }

    var shownHoldNote: String? { holdNote ? InterviewText.holdNote : nil }

    /// « Conclure » est actif quand il y a quelque chose à conclure et que la conclusion n'est pas déjà lancée.
    var canConclude: Bool { phase != .preparing && phase != .concluding }

    /// La dernière réplique de la personne, entière (la vue la fait défiler si elle est longue) ; `nil` si elle est blanche.
    var shownReply: String? {
        lastReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : lastReply
    }

    /// Ce que VoiceOver doit annoncer quand l'état passe de `old` à `new`, dans l'ordre : le titre de la nouvelle phase quand il change
    /// (ou quand l'entretien commence), puis l'avis quand il apparaît ou change. Le niveau, les textes et le numéro de la question
    /// changent sans cesse et ne s'annoncent pas ; un avis inchangé ne se redit pas (le contrôleur efface un avis avant d'en
    /// poser un identique, pour qu'il soit redit).
    static func announcements(from old: InterviewViewState?, to new: InterviewViewState?) -> [String] {
        guard let new else { return [] }
        var spoken: [String] = []
        if new.title != old?.title { spoken.append(new.title) }
        if let notice = new.notice, notice != old?.notice { spoken.append(notice) }
        return spoken
    }
}
