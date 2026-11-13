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
}

public enum HotKeyBehavior: String, Codable, Sendable {
    case toggle
    case hold
}

public struct AppSettings: Codable, Equatable, Sendable {
    /// Version du format du fichier que cette application sait lire et écrire.
    public static let current = 1

    public var version: Int
    public var providers: [Provider]
    public var hotKey: HotKey
    public var hotKeyBehavior: HotKeyBehavior
    public var lastModeID: String

    public init(
        version: Int, providers: [Provider], hotKey: HotKey,
        hotKeyBehavior: HotKeyBehavior, lastModeID: String
    ) {
        self.version = version
        self.providers = providers
        self.hotKey = hotKey
        self.hotKeyBehavior = hotKeyBehavior
        self.lastModeID = lastModeID
    }

    public static var defaults: AppSettings {
        AppSettings(
            version: current, providers: [], hotKey: .standard,
            hotKeyBehavior: .toggle, lastModeID: "dictee-brute")
    }
}
