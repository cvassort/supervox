import Foundation
import SupervoxCore

/// Ce que la dictée d'un mode fait du texte, tel que le mode le dit au moment de l'appui. Lu une seule fois : modifier ou
/// supprimer le mode pendant la dictée ne change pas cette dictée.
public enum ModeRun: Equatable, Sendable {
    /// Le texte est celui du moteur, sans le modèle de langage (Dictée brute, mode personnel sans consigne). `engine` : le
    /// moteur du mode, qui remplace celui de l'onglet Transcription pour cette dictée seulement.
    case raw(engine: TranscriptionEngine?)
    /// Le texte passe par le modèle de langage selon `instruction` ; `model` `nil` : le modèle fort des réglages.
    case rewrite(instruction: String, model: ModelChoice?, engine: TranscriptionEngine?)
    /// Le mode Entretien : l'appui lance un entretien vocal (`InterviewRunning`) au lieu d'une dictée. `engine` : le moteur du
    /// mode, `nil` pour celui de l'entretien par défaut.
    case interview(engine: TranscriptionEngine?)
    /// Le mode n'est pas dans les réglages (supprimé entre-temps) : rien ne démarre, ni micro ni modèle.
    case missing

    /// Le déroulé d'un mode des réglages ; `nil` (mode absent) ne démarre rien.
    public static func from(_ mode: Mode?) -> ModeRun {
        guard let mode else { return .missing }
        guard mode.id != ModeChip.interviewID else { return .interview(engine: mode.engine) }
        guard mode.usesModel else { return .raw(engine: mode.engine) }
        return .rewrite(instruction: mode.effectiveInstruction, model: mode.model, engine: mode.engine)
    }

    /// Le défaut du contrôleur de dictée, sans réglages : Dictée brute dicte, Entretien lance l'entretien, tout autre mode ne
    /// démarre rien (sans réglages, sa consigne et son modèle ne sont pas connus).
    public static func legacy(_ id: String) -> ModeRun {
        switch id {
        case ModeChip.rawID: .raw(engine: nil)
        case ModeChip.interviewID: .interview(engine: nil)
        default: .missing
        }
    }

    /// Le moteur du mode, s'il en a un.
    var engine: TranscriptionEngine? {
        switch self {
        case .raw(let engine): engine
        case .rewrite(_, _, let engine): engine
        case .interview(let engine): engine
        case .missing: nil
        }
    }
}
