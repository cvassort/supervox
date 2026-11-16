import SupervoxCore

/// Où en est une correction à la voix : le micro se prépare, la consigne est dite, elle est transcrite, le modèle réécrit.
public enum CorrectionStep: Equatable, Sendable {
    case preparing
    case recording
    case transcribing
    case rewriting
}

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
    /// Une consigne de correction est dite, transcrite, puis appliquée au texte de la relecture, qui reste vivante : le texte est
    /// en lecture seule et ne change qu'à la réussite.
    case correcting(CorrectionStep)
    /// Le texte n'a pas pu être collé : il est dans le presse-papiers (repli de l'insertion).
    case copied
    case cancelled
    case failed(DictationFailure)

    /// Une dictée est en cours : le micro se prépare, écoute, ou le texte se finalise. Faux pendant une correction : la
    /// relecture, dont le texte est là, reste l'écran (voir `isCorrecting`).
    public var isActive: Bool {
        switch self {
        case .preparing, .recording, .finalizing, .formatting: true
        case .idle, .review, .pasting, .correcting, .copied, .cancelled, .failed: false
        }
    }

    /// Une correction à la voix est en cours, à n'importe quelle étape.
    public var isCorrecting: Bool {
        if case .correcting = self { true } else { false }
    }

    /// Le micro se prépare ou écoute, pour une dictée comme pour une correction : la fin se demande à ce moment.
    var isCapturing: Bool {
        switch self {
        case .preparing, .recording, .correcting(.preparing), .correcting(.recording): true
        default: false
        }
    }

    /// Le panneau ne doit pas se fermer de lui-même : une dictée est en cours, ou son texte attend d'être relu ou collé.
    public var holdsPanel: Bool {
        switch self {
        case .review, .pasting, .correcting: true
        case .preparing, .recording, .finalizing, .formatting, .idle, .copied, .cancelled, .failed: isActive
        }
    }
}
