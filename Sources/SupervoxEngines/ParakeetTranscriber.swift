import FluidAudio
import Foundation
import SupervoxCore

/// Parakeet TDT 0.6B v3 (multilingue) par `AsrManager` de FluidAudio, entièrement local.
///
/// Vocabulaire : non transmis. FluidAudio propose un recalage par vocabulaire (encodeur CTC séparé), mais cet
/// adaptateur ne le branche pas : le moteur est mesuré une seule fois.
///
/// Langue : `fr` devient l'indice `Language.french`. Pour le français, FluidAudio applique en plus une liste de mots
/// outils anglais interdits (« the », « and », « with »…) : utile contre les dérives vers l'anglais, mais elle peut
/// aussi remplacer ces mots quand ils sont réellement prononcés dans une phrase mêlée d'anglais.
public actor ParakeetTranscriber: Transcriber {
    public nonisolated let name = "parakeet"
    private let warmUp: Bool
    private var manager: AsrManager?

    /// `warmUp` : passe `warmUpClip()` dans `prepare()` pour que le coût du premier appel ne tombe pas dans la
    /// première phrase chronométrée. `false` sert seulement à mesurer ce coût (test d'intégration).
    public init(warmUp: Bool = true) {
        self.warmUp = warmUp
    }

    public func prepare() async throws {
        if manager != nil { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        if warmUp { _ = try await run(manager, samples: warmUpClip().samples, language: .french) }
        self.manager = manager
    }

    public func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        try TranscriberError.check16kHz(clip)
        guard let manager else { throw TranscriberError.notPrepared(name) }
        return try await run(manager, samples: clip.samples, language: Language(rawValue: language))
    }

    /// Un état de décodeur neuf par phrase : réutilisé, il porterait le dernier jeton de la phrase précédente.
    private func run(_ manager: AsrManager, samples: [Float], language: Language?) async throws -> String {
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state, language: language)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
