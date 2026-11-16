import SupervoxCore

/// L'étape que l'écran de dictée montre. Elle est propre au contrôleur de dictée : la session a ses phases
/// (`DictationPhase`), l'écran a les siennes, qui en reprennent trois (`preparing`, `recording`, `finalizing`) et ajoutent ce
/// que seul l'écran connaît (le texte copié faute de collage, la relecture, le collage en cours).
public enum DictationStage: Equatable, Sendable {
    case idle
    case preparing
    case recording
    case finalizing
    /// Le texte dicté est au modèle de langage, qui le met en forme.
    case formatting
    /// Le texte attend d'être relu avant d'être collé.
    case review
    /// Le texte est en cours de collage.
    case pasting
    /// Le texte n'a pas pu être collé : il est dans le presse-papiers (repli de l'insertion).
    case copied
    case cancelled
    case failed(DictationFailure)

    /// Une dictée est en cours : le micro se prépare, écoute, ou le texte se finalise.
    public var isActive: Bool {
        switch self {
        case .preparing, .recording, .finalizing, .formatting: true
        case .idle, .review, .pasting, .copied, .cancelled, .failed: false
        }
    }

    /// Le panneau ne doit pas se fermer de lui-même : une dictée est en cours, ou son texte attend d'être relu ou collé.
    public var holdsPanel: Bool {
        switch self {
        case .review, .pasting: true
        case .preparing, .recording, .finalizing, .formatting, .idle, .copied, .cancelled, .failed: isActive
        }
    }
}
