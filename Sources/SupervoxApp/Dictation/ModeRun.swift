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
    /// Le mode ne dicte pas encore (Entretien, mode absent des réglages) : le panneau le dit.
    case later

    /// Le déroulé d'un mode des réglages ; `nil` (mode absent) ne dicte rien.
    public static func from(_ mode: Mode?) -> ModeRun {
        guard let mode, mode.id != ModeChip.interviewID else { return .later }
        guard mode.usesModel else { return .raw(engine: mode.engine) }
        return .rewrite(instruction: mode.effectiveInstruction, model: mode.model, engine: mode.engine)
    }

    /// Le défaut du contrôleur de dictée, sans réglages : Dictée brute dicte, tout autre mode attend (le comportement de
    /// l'étape 4).
    public static func legacy(_ id: String) -> ModeRun {
        id == ModeChip.rawID ? .raw(engine: nil) : .later
    }

    /// Le moteur du mode, s'il en a un.
    var engine: TranscriptionEngine? {
        switch self {
        case .raw(let engine): engine
        case .rewrite(_, _, let engine): engine
        case .later: nil
        }
    }
}
