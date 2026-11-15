import Foundation

/// Enregistré dans `settings.json` : un nouveau cas exige une nouvelle `AppSettings.current` (voir sa règle
/// d'évolution).
public enum ProviderKind: String, Codable, Sendable {
    case openAICompatible
    case anthropic
}

/// Un fournisseur de modèles. Aucune clé d'API ici : elles vivent dans le trousseau.
public struct Provider: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var kind: ProviderKind
    /// Dernière liste de modèles lue depuis l'endpoint.
    public var models: [String]

    public init(id: UUID, name: String, baseURL: String, kind: ProviderKind, models: [String]) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.kind = kind
        self.models = models
    }

    private enum CodingKeys: String, CodingKey { case id, name, baseURL, kind, models }

    /// Décodage tolérant (voir `AppSettings`) : sans identité, adresse ni type, un fournisseur n'a pas de sens ; la
    /// liste des modèles, elle, se relit en un clic.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        kind = try container.decode(ProviderKind.self, forKey: .kind)
        models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
    }
}

/// Enregistré dans `settings.json` : un nouveau cas exige une nouvelle `AppSettings.current` (voir sa règle
/// d'évolution).
public enum HotKeyBehavior: String, Codable, Sendable {
    case toggle
    case hold
}

/// Réglages de l'application, tels qu'ils sont écrits dans `settings.json`.
///
/// Règle d'évolution du format : tout champ ajouté est décodé avec `decodeIfPresent` et une valeur par défaut, pour
/// qu'un fichier écrit avant son ajout se lise encore. `version` ne change que pour un format que l'ancienne application ne
/// saurait pas lire ou réécrire correctement (voir `SettingsStore`).
///
/// Ce que cette version garde, et ce qu'elle perd, à la réécriture d'un fichier :
/// - un champ inconnu de `AppSettings` (premier niveau) ou de `Mode` est lu, gardé et réécrit tel quel (`UnknownFields`) ;
///   `modeOptions` de la version 1 en fait partie ;
/// - un champ inconnu de `Provider`, `HotKey`, `TranscriptionSettings` ou `ModelChoice` est PERDU à l'enregistrement
///   (`SettingsStoreTests.unknownFieldsAreKeptAndWrittenBack` le fixe). Ajouter un champ à l'un de ces types exige donc
///   d'augmenter `current`, ou d'étendre la garde à ce type.
///
/// Un nouveau cas d'une énumération enregistrée (`ProviderKind`, `HotKeyBehavior`, `TranscriptionEngine`, ou toute énumération
/// ajoutée plus tard) est un tel format : il exige d'augmenter `current`. Sans cela, une application plus ancienne lit un cas
/// inconnu à sa propre version, ne sait pas décoder le fichier et le met entièrement de côté (fournisseurs compris) ; pour
/// `TranscriptionEngine`, dont le décodage est tolérant, elle le réécrit `whisperkit` sans avis, dans l'onglet Transcription et
/// dans chaque mode (`SettingsStoreTests.anUnknownEngineInAVersionTwoFile…`). Avec une version plus récente, elle garde le
/// fichier intact, n'y écrit rien et prend les réglages par défaut (ou ce qu'elle sait en lire). Ces comportements sont fixés par
/// `SettingsStoreTests` (`unknownEnumCase…`).
///
/// Version 2 : les modes deviennent des données (`modes`). Un fichier de la version 1 n'a pas `modes` : il reçoit `Mode.base`,
/// avec le choix de relecture que `modeOptions` portait. `modeOptions` reste dans le fichier, tel quel, mais ne sert qu'à cette
/// migration, faite une fois : un fichier qui a `modes`, ou qui est déjà en version 2, ne le relit jamais.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Version du format du fichier que cette application sait lire et écrire.
    public static let current = 2

    public var version: Int
    public var providers: [Provider]
    public var hotKey: HotKey
    public var hotKeyBehavior: HotKeyBehavior
    public var lastModeID: String
    /// Raccourci déjà signalé comme raccourci de macOS activé en ouvrant le panneau au lancement : il ne l'ouvre plus
    /// seul (l'avis reste). `nil` : rien de signalé.
    public var systemConflictShown: HotKey?
    /// Moteur, modèle, langue et vocabulaire de la dictée. Absent d'un fichier plus ancien : les défauts s'appliquent.
    public var transcription: TranscriptionSettings
    /// Les modes, dans l'ordre des pastilles. Dictée brute et Entretien y sont toujours (`Mode.normalized`). Absent d'un
    /// fichier de la version 2 : `Mode.base`.
    public var modes: [Mode]
    /// Le modèle des modes qui n'en choisissent pas un. `nil` : aucun choix fait.
    public var strongModel: ModelChoice?
    /// Le modèle rapide, enregistré dès cette version et employé à l'étape 6. `nil` : aucun choix fait.
    public var fastModel: ModelChoice?
    /// Ce que cette version ne connaît pas, réécrit tel quel.
    var unknown = UnknownFields()

    public init(
        version: Int, providers: [Provider], hotKey: HotKey,
        hotKeyBehavior: HotKeyBehavior, lastModeID: String, systemConflictShown: HotKey? = nil,
        transcription: TranscriptionSettings = .defaults, modes: [Mode] = Mode.base,
        strongModel: ModelChoice? = nil, fastModel: ModelChoice? = nil
    ) {
        self.version = version
        self.providers = providers
        self.hotKey = hotKey
        self.hotKeyBehavior = hotKeyBehavior
        self.lastModeID = lastModeID
        self.systemConflictShown = systemConflictShown
        self.transcription = transcription
        self.modes = modes
        self.strongModel = strongModel
        self.fastModel = fastModel
    }

    private enum CodingKeys: String, CaseIterable {
        case version, providers, hotKey, hotKeyBehavior, lastModeID, systemConflictShown, transcription, modes, strongModel,
            fastModel
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
    /// Le champ de la version 1 que la migration lit une fois.
    private static let legacyOptionsKey = "modeOptions"

    /// Un champ absent prend sa valeur par défaut ; un champ inconnu est gardé ; un champ présent mais d'une autre
    /// forme lève une erreur (le fichier est alors illisible). Seul `version` est obligatoire.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        func key(_ key: CodingKeys) -> JSONKey { JSONKey(key.rawValue) }
        let defaults = AppSettings.defaults
        version = try container.decode(Int.self, forKey: key(.version))
        providers = try container.decodeIfPresent([Provider].self, forKey: key(.providers)) ?? defaults.providers
        hotKey = try container.decodeIfPresent(HotKey.self, forKey: key(.hotKey)) ?? defaults.hotKey
        hotKeyBehavior =
            try container.decodeIfPresent(HotKeyBehavior.self, forKey: key(.hotKeyBehavior)) ?? defaults.hotKeyBehavior
        lastModeID = try container.decodeIfPresent(String.self, forKey: key(.lastModeID)) ?? defaults.lastModeID
        systemConflictShown = try container.decodeIfPresent(HotKey.self, forKey: key(.systemConflictShown))
        transcription =
            try container.decodeIfPresent(TranscriptionSettings.self, forKey: key(.transcription))
            ?? defaults.transcription
        strongModel = try container.decodeIfPresent(ModelChoice.self, forKey: key(.strongModel))
        fastModel = try container.decodeIfPresent(ModelChoice.self, forKey: key(.fastModel))
        if let modes = try container.decodeIfPresent([Mode].self, forKey: key(.modes)) {
            self.modes = Mode.normalized(modes)
        } else if version < 2 {
            // Un fichier de la version 1, ou avant : les choix de relecture de `modeOptions`. Une valeur d'une autre forme ne
            // fait pas perdre le fichier pour un champ qui ne sert plus : elle est gardée, et rien n'est repris.
            let options = (try? container.decode([String: ModeOptions].self, forKey: JSONKey(Self.legacyOptionsKey))) ?? [:]
            modes = Mode.base.map { mode in
                var mode = mode
                mode.reviewBeforePaste = options[mode.id]?.reviewBeforePaste
                return mode
            }
        } else {
            modes = Mode.base
        }
        unknown = try UnknownFields(reading: container, excluding: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JSONKey.self)
        func key(_ key: CodingKeys) -> JSONKey { JSONKey(key.rawValue) }
        try container.encode(version, forKey: key(.version))
        try container.encode(providers, forKey: key(.providers))
        try container.encode(hotKey, forKey: key(.hotKey))
        try container.encode(hotKeyBehavior, forKey: key(.hotKeyBehavior))
        try container.encode(lastModeID, forKey: key(.lastModeID))
        try container.encodeIfPresent(systemConflictShown, forKey: key(.systemConflictShown))
        try container.encode(transcription, forKey: key(.transcription))
        try container.encode(modes, forKey: key(.modes))
        try container.encodeIfPresent(strongModel, forKey: key(.strongModel))
        try container.encodeIfPresent(fastModel, forKey: key(.fastModel))
        try unknown.write(to: &container, excluding: Self.knownKeys)
    }

    public static var defaults: AppSettings {
        AppSettings(
            version: current, providers: [], hotKey: .standard,
            hotKeyBehavior: .toggle, lastModeID: ModeChip.rawID)
    }

    /// Le mode de cet identifiant, `nil` s'il n'y en a pas.
    public func mode(_ id: String) -> Mode? { modes.first { $0.id == id } }

    // MARK: - Relire avant de coller

    /// Les modes dont le texte passe toujours par la relecture : leur choix enregistré, quel qu'il soit, n'y change rien.
    public static let alwaysReviewed: Set<String> = [ModeChip.interviewID]

    /// Le choix d'un mode qui n'en a pas enregistré : relire pour Prompt et Entretien, coller tout de suite pour le reste.
    public static func reviewDefault(_ modeID: String) -> Bool {
        modeID == ModeChip.promptID || modeID == ModeChip.interviewID
    }

    /// Vrai si le texte de ce mode s'affiche pour relecture avant d'être collé. Entretien l'est toujours, même si le fichier
    /// de réglages dit le contraire : la règle est ici, à la lecture, pas dans ce que le fichier porte.
    public func reviewsBeforePaste(_ modeID: String) -> Bool {
        if Self.alwaysReviewed.contains(modeID) { return true }
        return mode(modeID)?.reviewBeforePaste ?? Self.reviewDefault(modeID)
    }

    /// La même règle pour des options prises hors d'un `AppSettings` (l'onglet Modes, jusqu'à ce qu'il lise les modes).
    static func reviews(_ modeID: String, options: [String: ModeOptions]) -> Bool {
        if alwaysReviewed.contains(modeID) { return true }
        return options[modeID]?.reviewBeforePaste ?? reviewDefault(modeID)
    }
}
