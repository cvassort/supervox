import Foundation

/// Un passage de voix dans un enregistrement, en secondes depuis le début du clip.
public struct SpeechSegment: Equatable, Sendable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// Repère les passages de voix d'un enregistrement entier (pas en flux).
public protocol VoiceDetector: Sendable {
    /// Passages de voix dans l'ordre, sans chevauchement ; vide si le clip ne contient pas de voix.
    func segments(in clip: AudioClip) async throws -> [SpeechSegment]
}
