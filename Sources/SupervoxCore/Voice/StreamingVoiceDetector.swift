import Foundation

/// Ce que dit le détecteur de voix en flux. Les indices sont en échantillons à 16 kHz, depuis le début de la prise.
public enum VoiceEvent: Equatable, Sendable {
    case speechStart(sample: Int)
    case speechEnd(sample: Int)
}

/// Repère la voix au fil de l'eau : on lui donne l'audio par blocs de `blockSize` échantillons, il rend au plus un
/// événement par bloc. Un détecteur garde son état d'un bloc à l'autre : les appels à `process` se font l'un après
/// l'autre, jamais en parallèle ; `reset()` le remet à neuf pour une nouvelle prise.
public protocol StreamingVoiceDetector: Sendable {
    /// Nombre exact d'échantillons (16 kHz) de chaque bloc passé à `process`.
    var blockSize: Int { get }
    /// Charge le modèle (téléchargement compris). Les appels suivants ne rechargent rien.
    func prepare() async throws
    /// Oublie tout ce qui précède : le bloc suivant est le premier d'une nouvelle prise.
    func reset() async
    /// `block` a exactement `blockSize` échantillons à 16 kHz.
    func process(_ block: [Float]) async throws -> VoiceEvent?
}
