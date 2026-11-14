import Foundation

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

public enum HotKeyBehavior: String, Codable, Sendable {
    case toggle
    case hold
}

/// Réglages de l'application, tels qu'ils sont écrits dans `settings.json`.
///
/// Règle d'évolution du format : tout champ ajouté est décodé avec `decodeIfPresent` et une valeur par défaut, pour
/// qu'un fichier écrit avant son ajout se lise encore ; un champ inconnu est ignoré. `version` ne change que pour un
/// format que l'ancienne application ne saurait pas lire correctement (voir `SettingsStore`).
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

    public init(
        version: Int, providers: [Provider], hotKey: HotKey,
        hotKeyBehavior: HotKeyBehavior, lastModeID: String, systemConflictShown: HotKey? = nil
    ) {
        self.version = version
        self.providers = providers
        self.hotKey = hotKey
        self.hotKeyBehavior = hotKeyBehavior
        self.lastModeID = lastModeID
        self.systemConflictShown = systemConflictShown
    }

    private enum CodingKeys: String, CodingKey {
        case version, providers, hotKey, hotKeyBehavior, lastModeID, systemConflictShown
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
    }

    public static var defaults: AppSettings {
        AppSettings(
            version: current, providers: [], hotKey: .standard,
            hotKeyBehavior: .toggle, lastModeID: "dictee-brute")
    }
}
