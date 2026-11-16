import Foundation

/// Une phrase dite : l'audio, et si c'est la voix de secours qui l'a dite.
public struct Speech: Equatable, Sendable {
    public var clip: AudioClip
    /// Vrai si la voix de secours l'a dite parce que la voix choisie a échoué (`FallbackSpeechSynthesizer`).
    public var fellBack: Bool

    public init(clip: AudioClip, fellBack: Bool = false) {
        self.clip = clip
        self.fellBack = fellBack
    }
}

public enum SpeechError: Error, Equatable, Sendable {
    /// Le système n'a aucune voix de cette langue (par exemple `fr-FR`).
    case noVoice(language: String)
    /// Rien à dire, ou aucun échantillon rendu.
    case empty
    /// La synthèse n'a rien rendu dans le temps imparti.
    case timedOut
}

/// Texte vers audio. Lève une `SpeechError` (ou l'erreur propre à la voix : octets illisibles, requête refusée) ; une tâche
/// annulée lève `CancellationError`, jamais autre chose.
public protocol SpeechSynthesizer: Sendable {
    func synthesize(_ text: String) async throws -> Speech
}
