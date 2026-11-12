import Foundation
import SupervoxCore
import WhisperKit

/// Whisper par WhisperKit (Core ML), entièrement local.
///
/// Vocabulaire : les termes, joints par des virgules, deviennent l'amorce du décodeur (`promptTokens`, encodés comme
/// le fait la ligne de commande de WhisperKit). La langue est imposée (`fr`), sans détection.
public actor WhisperKitTranscriber: Transcriber {
    public nonisolated let name = "whisperkit"
    public nonisolated var acceptsVocabulary: Bool { true }
    private let model: String
    private let warmUp: Bool
    private var kit: WhisperKit?

    /// `model` : variante du dépôt de modèles WhisperKit (ex. `large-v3-v20240930_turbo`).
    public init(model: String, warmUp: Bool = true) {
        self.model = model
        self.warmUp = warmUp
    }

    public func prepare() async throws {
        if kit != nil { return }
        // `load: true` : sans lui, WhisperKit charge le modèle au premier `transcribe`, donc dans la mesure.
        let kit = try await WhisperKit(WhisperKitConfig(model: model, load: true))
        guard kit.modelState == .loaded else {
            throw TranscriberError.engine("modèle WhisperKit \(model) non chargé (état : \(kit.modelState))")
        }
        if warmUp {
            // Deux passages : sans amorce, puis avec une amorce quelconque. Sans le second, la première phrase de la
            // ligne « +vocab » restait ~0,07 s plus lente que les suivantes (0,57 s contre 0,50 s).
            _ = try await run(kit, samples: warmUpClip().samples, language: "fr", vocabulary: [])
            _ = try await run(kit, samples: warmUpClip().samples, language: "fr", vocabulary: ["bonjour"])
        }
        self.kit = kit
    }

    public func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        try TranscriberError.check16kHz(clip)
        guard let kit else { throw TranscriberError.notPrepared(name) }
        return try await run(kit, samples: clip.samples, language: language, vocabulary: vocabulary)
    }

    private func run(_ kit: WhisperKit, samples: [Float], language: String, vocabulary: [String]) async throws -> String {
        var options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true    // sinon le texte porte <|fr|>, <|0.00|>… comptés comme mots insérés
            // Horodatage laissé au défaut de la bibliothèque (activé) : même texte que sans sur le corpus de contrôle,
            // ~0,03 s de plus par phrase, et c'est lui qui découpe un enregistrement de plus de 30 s en fenêtres.
        )
        if !vocabulary.isEmpty {
            guard let tokenizer = kit.tokenizer else { throw TranscriberError.vocabularyUnavailable("tokenizer WhisperKit absent") }
            let prompt = " " + vocabulary.joined(separator: ", ")
            let tokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            // WhisperKit ne garde que les derniers jetons au-delà de cette taille : on refuse plutôt que tronquer en silence.
            let limit = Constants.maxTokenContext / 2 - 1
            guard tokens.count <= limit else {
                throw TranscriberError.vocabularyUnavailable("\(tokens.count) jetons d'amorce, \(limit) au plus")
            }
            options.promptTokens = tokens
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
