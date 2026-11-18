import Foundation

/// Les moteurs de dictée que l'application sait lancer. Enregistré dans `settings.json` sous le nom de `rawValue` : un nouveau
/// cas exige une nouvelle `AppSettings.current` (voir la règle d'évolution d'`AppSettings`). C'est le seul fichier qui écrit
/// ces noms (un contrôle de sources le vérifie) : partout ailleurs, on compare des cas.
public enum TranscriptionEngine: String, Codable, CaseIterable, Sendable {
    case whisperKit = "whisperkit"
    case parakeet

    /// Le moteur de l'entretien vocal : le moteur local rapide (design 6.4 : Parakeet pour l'entretien, où la vitesse prime),
    /// distinct de celui de la dictée par défaut.
    public static let interviewDefault: TranscriptionEngine = .parakeet

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

/// Réglages de la transcription, enregistrés dans `settings.json` (voir la règle d'évolution de `AppSettings`). Un champ que cette
/// version ne connaît pas est gardé et réécrit tel quel (`UnknownFields`) ; l'égalité ne compare que les champs connus.
public struct TranscriptionSettings: Codable, Equatable, Sendable {
    public var engine: TranscriptionEngine
    /// Variante WhisperKit, par le nom que lui donne le dépôt de modèles de WhisperKit.
    public var whisperModel: String
    /// Code de langue passé au moteur (`fr`).
    public var language: String
    /// Termes que le moteur doit mieux reconnaître, un par entrée.
    public var vocabulary: [String]
    /// Ce que cette version ne connaît pas, réécrit tel quel.
    var unknown = UnknownFields()

    public init(engine: TranscriptionEngine, whisperModel: String, language: String, vocabulary: [String]) {
        self.engine = engine
        self.whisperModel = whisperModel
        self.language = language
        self.vocabulary = vocabulary
    }

    /// WhisperKit, la variante mesurée à l'étape 1 (`docs/bench/2026-11-13-resultats.md`), français, sans vocabulaire.
    public static let defaults = TranscriptionSettings(
        engine: .whisperKit, whisperModel: "large-v3-v20240930_turbo", language: "fr", vocabulary: [])

    /// Les champs connus seulement : un champ inconnu ne change pas l'égalité.
    public static func == (lhs: TranscriptionSettings, rhs: TranscriptionSettings) -> Bool {
        lhs.engine == rhs.engine && lhs.whisperModel == rhs.whisperModel && lhs.language == rhs.language
            && lhs.vocabulary == rhs.vocabulary
    }

    private enum CodingKeys: String, CaseIterable { case engine, whisperModel, language, vocabulary }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    /// Un champ absent prend sa valeur par défaut ; un moteur inconnu se lit `whisperkit`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        func key(_ key: CodingKeys) -> JSONKey { JSONKey(key.rawValue) }
        let defaults = Self.defaults
        self.init(
            engine: try container.decodeIfPresent(TranscriptionEngine.self, forKey: key(.engine)) ?? defaults.engine,
            whisperModel: try container.decodeIfPresent(String.self, forKey: key(.whisperModel)) ?? defaults.whisperModel,
            language: try container.decodeIfPresent(String.self, forKey: key(.language)) ?? defaults.language,
            vocabulary: try container.decodeIfPresent([String].self, forKey: key(.vocabulary)) ?? defaults.vocabulary)
        unknown = try UnknownFields(reading: container, excluding: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JSONKey.self)
        func key(_ key: CodingKeys) -> JSONKey { JSONKey(key.rawValue) }
        try container.encode(engine, forKey: key(.engine))
        try container.encode(whisperModel, forKey: key(.whisperModel))
        try container.encode(language, forKey: key(.language))
        try container.encode(vocabulary, forKey: key(.vocabulary))
        try unknown.write(to: &container, excluding: Self.knownKeys)
    }
}
