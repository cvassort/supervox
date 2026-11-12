import Foundation

public enum EndpointError: Error, Equatable {
    /// Une variable d'environnement obligatoire est absente ou vide.
    case missingVariable(String)
    /// Réponse HTTP hors 2xx. `body` est le corps reçu, sans la clé d'API, tronqué à 500 caractères.
    case http(status: Int, body: String)
    /// Réponse 2xx dont le contenu n'a pas la forme attendue.
    case malformedResponse
    case streamInterrupted
    /// Échec avant d'obtenir une réponse HTTP (réseau, TLS, délai) ou adresse de base inutilisable.
    case transport(String)
}

/// Adresse et clé de l'endpoint, lues dans l'environnement. La clé n'apparaît dans aucun affichage :
/// ni `description`, ni `debugDescription`, ni le miroir utilisé par `dump` et par les messages d'échec des tests.
public struct EndpointConfig: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let baseURL: URL
    public let apiKey: String

    public init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    public static let baseURLVariable = "SUPERVOX_BASE_URL"
    public static let apiKeyVariable = "SUPERVOX_API_KEY"

    /// Une variable absente, vide ou faite d'espaces est une variable manquante. Les espaces et retours à la ligne
    /// autour d'une valeur sont retirés : un retour à la ligne collé avec la clé rendrait l'en-tête HTTP invalide.
    public static func fromEnvironment(_ env: [String: String]) throws -> EndpointConfig {
        func value(_ name: String) throws -> String {
            let trimmed = (env[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { throw EndpointError.missingVariable(name) }
            return trimmed
        }
        let base = try value(baseURLVariable)
        let key = try value(apiKeyVariable)
        guard let url = URL(string: base) else {
            throw EndpointError.transport("\(baseURLVariable) n'est pas une adresse valide")
        }
        return EndpointConfig(baseURL: url, apiKey: key)
    }

    public var description: String { "EndpointConfig(baseURL: \(baseURL.absoluteString), apiKey: ***)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["baseURL": baseURL, "apiKey": "***"], displayStyle: .struct)
    }
}
