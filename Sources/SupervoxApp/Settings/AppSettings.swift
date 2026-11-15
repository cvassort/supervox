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
/// qu'un fichier écrit avant son ajout se lise encore ; un champ inconnu est ignoré. `version` ne change que pour un
/// format que l'ancienne application ne saurait pas lire correctement (voir `SettingsStore`).
///
/// Un nouveau cas d'une énumération enregistrée (`ProviderKind`, `HotKeyBehavior`, ou toute énumération ajoutée plus
/// tard) est un tel format : il exige d'augmenter `current`. Sans cela, une application plus ancienne lit un cas
/// inconnu à sa propre version, ne sait pas décoder le fichier et le met entièrement de côté (fournisseurs compris) ;
/// avec une version plus récente, elle le garde intact, n'y écrit rien et prend les réglages par défaut. Les deux
/// comportements sont fixés par `SettingsStoreTests` (`unknownEnumCase…`).
public struct AppSettings: Codable, Equatable, Sendable {
    /// Version du format du fichier que cette application sait lire et écrire.
    public static let current = 1

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
    /// Les options de chaque mode, par identifiant de mode. Un mode sans entrée, ou une entrée sans choix, prend les
    /// valeurs par défaut du mode. Un identifiant inconnu est gardé tel quel (modes personnalisés d'une étape suivante).
    /// Absent d'un fichier plus ancien : `[:]`.
    public var modeOptions: [String: ModeOptions]

    public init(
        version: Int, providers: [Provider], hotKey: HotKey,
        hotKeyBehavior: HotKeyBehavior, lastModeID: String, systemConflictShown: HotKey? = nil,
        transcription: TranscriptionSettings = .defaults, modeOptions: [String: ModeOptions] = [:]
    ) {
        self.version = version
        self.providers = providers
        self.hotKey = hotKey
        self.hotKeyBehavior = hotKeyBehavior
        self.lastModeID = lastModeID
        self.systemConflictShown = systemConflictShown
        self.transcription = transcription
        self.modeOptions = modeOptions
    }

    private enum CodingKeys: String, CodingKey {
        case version, providers, hotKey, hotKeyBehavior, lastModeID, systemConflictShown, transcription, modeOptions
    }

    /// Un champ absent prend sa valeur par défaut ; un champ inconnu est ignoré ; un champ présent mais d'une autre
    /// forme lève une erreur (le fichier est alors illisible). Seul `version` est obligatoire.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.defaults
        version = try container.decode(Int.self, forKey: .version)
        providers = try container.decodeIfPresent([Provider].self, forKey: .providers) ?? defaults.providers
        hotKey = try container.decodeIfPresent(HotKey.self, forKey: .hotKey) ?? defaults.hotKey
        hotKeyBehavior = try container.decodeIfPresent(HotKeyBehavior.self, forKey: .hotKeyBehavior) ?? defaults.hotKeyBehavior
        lastModeID = try container.decodeIfPresent(String.self, forKey: .lastModeID) ?? defaults.lastModeID
        systemConflictShown = try container.decodeIfPresent(HotKey.self, forKey: .systemConflictShown)
        transcription =
            try container.decodeIfPresent(TranscriptionSettings.self, forKey: .transcription) ?? defaults.transcription
        modeOptions = try container.decodeIfPresent([String: ModeOptions].self, forKey: .modeOptions) ?? [:]
    }

    public static var defaults: AppSettings {
        AppSettings(
            version: current, providers: [], hotKey: .standard,
            hotKeyBehavior: .toggle, lastModeID: ModeChip.rawID)
    }

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
        Self.reviews(modeID, options: modeOptions)
    }

    /// La même règle pour des options prises hors d'un `AppSettings` (l'onglet Modes).
    static func reviews(_ modeID: String, options: [String: ModeOptions]) -> Bool {
        if alwaysReviewed.contains(modeID) { return true }
        return options[modeID]?.reviewBeforePaste ?? reviewDefault(modeID)
    }
}
