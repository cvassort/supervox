import Foundation

/// La session de toute requête qui porte une clé d'API.
///
/// `URLSession.shared` garde ses réponses dans `URLCache.shared`, sur le disque : mesuré, une simple liste de
/// modèles y laissait les en-têtes `Authorization` et `x-api-key` en clair (`Library/Caches/<bundle>/Cache.db`).
/// Cette session ne garde rien : configuration éphémère, sans cache, sans cookies, sans identifiants enregistrés.
public enum EndpointSession {
    /// Configuration éphémère dont tous les stockages sont retirés : `.ephemeral` seul garde encore un cache, des
    /// cookies et des identifiants en mémoire pendant la vie de la session.
    public static func storelessConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// Une seule session pour tout le processus : un client créé à chaque clic n'en ouvre pas une nouvelle, qui ne
    /// serait jamais invalidée.
    public static let shared = URLSession(configuration: storelessConfiguration())
}
