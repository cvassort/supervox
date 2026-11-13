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
    public nonisolated var measurementConditions: String {
        "modèle chargé, et préchauffé avant chaque passe hors chrono : un passage sur 2 s de bruit sans amorce, puis, "
            + "pour la passe +vocab, un second avec l'amorce de la passe. Durée mesurée : transcription complète de la "
            + "phrase (encodeur et décodeur, langue imposée, horodatage par défaut de la bibliothèque) ; passe +vocab : "
            + "en plus, l'encodage de l'amorce par le tokenizer, refait à chaque phrase, et le préremplissage de l'amorce."
    }

    /// Jetons d'amorce que WhisperKit garde : au-delà, il ne conserve que les derniers (TextDecoder, `suffix`).
    public static let promptTokenLimit = Constants.maxTokenContext / 2 - 1

    private let model: String
    private var kit: WhisperKit?

    /// `model` : variante du dépôt de modèles WhisperKit (ex. `large-v3-v20240930_turbo`).
    public init(model: String) {
        self.model = model
    }

    public func prepare() async throws {
        if kit != nil { return }
        // `load: true` : sans lui, WhisperKit charge le modèle au premier `transcribe`, donc dans la mesure.
        let kit = try await WhisperKit(WhisperKitConfig(model: model, load: true))
        guard kit.modelState == .loaded else {
            throw TranscriberError.engine("modèle WhisperKit \(model) non chargé (état : \(kit.modelState))")
        }
        self.kit = kit
    }

    /// Mesuré : sur du silence, le décodeur s'arrête tout de suite et la 1re phrase restait ~0,1 s plus lente ; sans
    /// passage avec amorce, la 1re phrase de la passe +vocab restait ~0,07 s plus lente.
    public func warmUp(vocabulary: [String]) async throws {
        guard let kit else { throw TranscriberError.notPrepared(name) }
        _ = try await run(kit, samples: warmUpClip().samples, language: "fr", vocabulary: [])
        if !vocabulary.isEmpty {
            _ = try await run(kit, samples: warmUpClip().samples, language: "fr", vocabulary: vocabulary)
        }
    }

    public func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        try TranscriberError.check16kHz(clip)
        guard let kit else { throw TranscriberError.notPrepared(name) }
        return try await run(kit, samples: clip.samples, language: language, vocabulary: vocabulary)
    }

    /// Amorce encodée. Refuse au-delà de `promptTokenLimit` plutôt que de laisser WhisperKit tronquer en silence.
    static func promptTokens(_ vocabulary: [String], tokenizer: any WhisperTokenizer) throws -> [Int] {
        let prompt = " " + vocabulary.joined(separator: ", ")
        let tokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        guard tokens.count <= promptTokenLimit else {
            throw TranscriberError.vocabularyUnavailable("\(tokens.count) jetons d'amorce, \(promptTokenLimit) au plus")
        }
        return tokens
    }

    /// Nombre de jetons de l'amorce pour `vocabulary`, avec le tokenizer du modèle `model`, sans charger le modèle
    /// (seul le tokenizer est lu, ou téléchargé s'il manque). `nil` si la variante du modèle ne se déduit pas de son nom.
    public static func promptTokenCount(_ vocabulary: [String], model: String) async throws -> Int? {
        // La variante la plus spécifique contenue dans le nom : « large-v3-v20240930_turbo » → large-v3.
        let candidates = ModelVariant.allCases.filter { model.contains($0.description) }
        guard let variant = candidates.max(by: { $0.description.count < $1.description.count }) else { return nil }
        let tokenizer = try await ModelUtilities.loadTokenizer(for: variant)
        let prompt = " " + vocabulary.joined(separator: ", ")
        return tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }.count
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
            options.promptTokens = try Self.promptTokens(vocabulary, tokenizer: tokenizer)
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
