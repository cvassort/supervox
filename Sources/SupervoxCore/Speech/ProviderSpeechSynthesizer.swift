import Foundation

/// Ce dont la voix d'un fournisseur a besoin : une requête `audio/speech`. `OpenAICompatibleClient` la fournit ; les tests
/// mettent un double à la place.
public protocol SpeechEndpoint: Sendable {
    func speech(model: String, input: String, voice: String, format: String, extra: [String: String]) async throws -> Data
}

extension OpenAICompatibleClient: SpeechEndpoint {}

/// La voix choisie chez un fournisseur : le modèle, l'identifiant de la voix, et les paramètres propres au fournisseur,
/// envoyés tels quels.
public struct ProviderVoice: Equatable, Sendable {
    public var model: String
    public var identifier: String
    public var extra: [String: String]

    public init(model: String, identifier: String, extra: [String: String]) {
        self.model = model
        self.identifier = identifier
        self.extra = extra
    }
}

/// Dit une phrase par la voix d'un fournisseur : une requête `wav`, dont les octets sont lus par `WavFile.decode` (qui accepte la
/// taille provisoire d'un WAV produit en flux).
public final class ProviderSpeechSynthesizer: SpeechSynthesizer {
    /// Fréquences acceptées dans la réponse du fournisseur : 8 000 à 192 000 Hz, choix non mesuré (de la téléphonie au haut de gamme).
    static let acceptedSampleRates: ClosedRange<Double> = 8_000...192_000

    private let endpoint: any SpeechEndpoint
    private let voice: ProviderVoice

    public init(endpoint: any SpeechEndpoint, voice: ProviderVoice) {
        self.endpoint = endpoint
        self.voice = voice
    }

    public func synthesize(_ text: String) async throws -> Speech {
        guard !text.isBlankForSpeech else { throw SpeechError.empty }
        let clip: AudioClip
        do {
            let data = try await endpoint.speech(model: voice.model, input: text, voice: voice.identifier, format: "wav", extra: voice.extra)
            clip = try WavFile.decode(data)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard Self.acceptedSampleRates.contains(clip.sampleRate) else {
            // Un clip à une fréquence absurde se rééchantillonne en clip vide, que la lecture rend « jouée » sans rien jouer :
            // on le refuse ici, par une erreur nommée, pour que le repli prenne la phrase.
            throw WavFileError.unsupported("fréquence d'échantillonnage hors de la plage acceptée")
        }
        guard !clip.samples.isEmpty else { throw SpeechError.empty }
        return Speech(clip: clip)
    }
}
