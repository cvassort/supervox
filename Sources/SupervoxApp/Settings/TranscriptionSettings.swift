import Foundation

/// Réglages de la transcription, enregistrés dans `settings.json` (voir la règle d'évolution de `AppSettings`).
public struct TranscriptionSettings: Codable, Equatable, Sendable {
    /// Les moteurs que l'application sait lancer. Toute autre valeur lue dans le fichier se lit `whisperkit`.
    public static let knownEngines = ["whisperkit", "parakeet"]

    /// `whisperkit` ou `parakeet`.
    public var engine: String
    /// Variante WhisperKit, par le nom que lui donne le dépôt de modèles de WhisperKit.
    public var whisperModel: String
    /// Code de langue passé au moteur (`fr`).
    public var language: String
    /// Termes que le moteur doit mieux reconnaître, un par entrée.
    public var vocabulary: [String]

    public init(engine: String, whisperModel: String, language: String, vocabulary: [String]) {
        self.engine = Self.knownEngines.contains(engine) ? engine : "whisperkit"
        self.whisperModel = whisperModel
        self.language = language
        self.vocabulary = vocabulary
    }

    /// WhisperKit, la variante mesurée à l'étape 1 (`docs/bench/2026-11-13-resultats.md`), français, sans vocabulaire.
    public static let defaults = TranscriptionSettings(
        engine: "whisperkit", whisperModel: "large-v3-v20240930_turbo", language: "fr", vocabulary: [])

    private enum CodingKeys: String, CodingKey { case engine, whisperModel, language, vocabulary }

    /// Un champ absent prend sa valeur par défaut ; un moteur inconnu se lit `whisperkit`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        self.init(
            engine: try container.decodeIfPresent(String.self, forKey: .engine) ?? defaults.engine,
            whisperModel: try container.decodeIfPresent(String.self, forKey: .whisperModel) ?? defaults.whisperModel,
            language: try container.decodeIfPresent(String.self, forKey: .language) ?? defaults.language,
            vocabulary: try container.decodeIfPresent([String].self, forKey: .vocabulary) ?? defaults.vocabulary)
    }
}
