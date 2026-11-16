import Foundation

/// Les moteurs de dictée que l'application sait lancer. Enregistré dans `settings.json` sous le nom de `rawValue` : un nouveau
/// cas exige une nouvelle `AppSettings.current` (voir la règle d'évolution d'`AppSettings`). C'est le seul fichier qui écrit
/// ces noms (un contrôle de sources le vérifie) : partout ailleurs, on compare des cas.
public enum TranscriptionEngine: String, Codable, CaseIterable, Sendable {
    case whisperKit = "whisperkit"
    case parakeet

    /// Le nom que l'interface montre.
    public var title: String {
        switch self {
        case .whisperKit: "WhisperKit"
        case .parakeet: "Parakeet"
        }
    }

    /// Décodage tolérant : toute valeur inconnue (ou d'une autre forme) se lit `.whisperKit`.
    public init(from decoder: any Decoder) throws {
        let value = try? decoder.singleValueContainer().decode(String.self)
        self = value.flatMap(Self.init(rawValue:)) ?? .whisperKit
    }
}

/// Réglages de la transcription, enregistrés dans `settings.json` (voir la règle d'évolution de `AppSettings`).
public struct TranscriptionSettings: Codable, Equatable, Sendable {
    public var engine: TranscriptionEngine
    /// Variante WhisperKit, par le nom que lui donne le dépôt de modèles de WhisperKit.
    public var whisperModel: String
    /// Code de langue passé au moteur (`fr`).
    public var language: String
    /// Termes que le moteur doit mieux reconnaître, un par entrée.
    public var vocabulary: [String]

    public init(engine: TranscriptionEngine, whisperModel: String, language: String, vocabulary: [String]) {
        self.engine = engine
        self.whisperModel = whisperModel
        self.language = language
        self.vocabulary = vocabulary
    }

    /// WhisperKit, la variante mesurée à l'étape 1 (`docs/bench/2026-11-13-resultats.md`), français, sans vocabulaire.
    public static let defaults = TranscriptionSettings(
        engine: .whisperKit, whisperModel: "large-v3-v20240930_turbo", language: "fr", vocabulary: [])

    private enum CodingKeys: String, CodingKey { case engine, whisperModel, language, vocabulary }

    /// Un champ absent prend sa valeur par défaut ; un moteur inconnu se lit `whisperkit`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        self.init(
            engine: try container.decodeIfPresent(TranscriptionEngine.self, forKey: .engine) ?? defaults.engine,
            whisperModel: try container.decodeIfPresent(String.self, forKey: .whisperModel) ?? defaults.whisperModel,
            language: try container.decodeIfPresent(String.self, forKey: .language) ?? defaults.language,
            vocabulary: try container.decodeIfPresent([String].self, forKey: .vocabulary) ?? defaults.vocabulary)
    }
}
