import Foundation

/// Forme de la route qui liste les modèles d'un endpoint.
public enum ModelListingKind: Sendable {
    /// `GET <base>/v1/models`, authentification `Authorization: Bearer <clé>`, réponse `{"object":"list","data":[{"id":…}]}`
    /// sans pagination (documentation OpenAI, vérifiée sur un endpoint compatible réel).
    case openAICompatible
    /// `GET <base>/v1/models?limit=…&after_id=…`, en-têtes `x-api-key` et `anthropic-version`, réponse
    /// `{"data":[{"id":…}],"first_id":…,"has_more":…,"last_id":…}` paginée par curseur (documentation de l'API Claude).
    case anthropic
}

/// Lit la liste des identifiants de modèles d'un endpoint. Aucune clé ni adresse complète n'apparaît dans une erreur.
public struct ModelLister: Sendable {
    private let config: EndpointConfig
    private let kind: ModelListingKind
    private let session: URLSession
    /// Délai d'inactivité de chaque requête, en secondes (voir `OpenAICompatibleClient.requestTimeout`).
    public let requestTimeout: TimeInterval

    /// Version d'API envoyée à la route de type `anthropic` : l'exemple de la documentation officielle des modèles.
    static let anthropicVersion = "2026-10-21"
    /// Taille de page demandée à la route de type `anthropic` : le maximum documenté (1 à 1000, 20 par défaut).
    static let anthropicPageSize = 1000
    /// Au-delà de ce nombre de pages, la liste est refusée : un serveur qui annonce toujours une suite ne boucle pas.
    static let maxPages = 20

    public init(config: EndpointConfig, kind: ModelListingKind, session: URLSession = .shared, requestTimeout: TimeInterval = 15) {
        self.config = config
        self.kind = kind
        self.session = session
        self.requestTimeout = requestTimeout
    }

    /// Identifiants des modèles, triés et sans doublon. Une liste vide est une réponse valide.
    ///
    /// Erreurs : `.http` (statut hors 2xx, avec le corps masqué et tronqué à 500 caractères), `.transport` (échec avant
    /// toute réponse, ou adresse de base inutilisable), `.malformedResponse` (corps 2xx qui n'a pas la forme attendue,
    /// entrée sans identifiant, pagination sans curseur, qui ne progresse pas ou de plus de 20 pages). L'annulation de
    /// la tâche reste une `CancellationError`.
    public func listModels() async throws -> [String] {
        switch kind {
        case .openAICompatible: return try await listOpenAICompatible()
        case .anthropic: return try await listAnthropic()
        }
    }

    // MARK: - Routes

    private func listOpenAICompatible() async throws -> [String] {
        var request = URLRequest(url: try modelsURL(query: nil))
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        let object = try await fetchObject(request)
        return Self.sortedUnique(try Self.ids(in: object))
    }

    private func listAnthropic() async throws -> [String] {
        var ids: [String] = []
        var cursor: String?
        for _ in 0..<Self.maxPages {
            var query = [("limit", String(Self.anthropicPageSize))]
            if let cursor { query.append(("after_id", cursor)) }
            var request = URLRequest(url: try modelsURL(query: query))
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            let object = try await fetchObject(request)
            ids += try Self.ids(in: object)
            guard let hasMore = object["has_more"] as? Bool, hasMore else { return Self.sortedUnique(ids) }
            // Une suite annoncée sans curseur, ou avec le curseur qu'on vient d'utiliser, ne peut pas avancer.
            guard let last = object["last_id"] as? String, !last.isEmpty, last != cursor else { throw EndpointError.malformedResponse }
            cursor = last
        }
        throw EndpointError.malformedResponse
    }

    // MARK: - Requêtes

    /// `<base>/v1/models`, avec la requête `query` (valeurs encodées). Même règle que `OpenAICompatibleClient` : la base
    /// peut avoir un `/` final, se terminer par `/v1` ou porter un préfixe de chemin ; la requête et le fragment de la
    /// base sont ignorés. Les identifiants éventuels de l'adresse de base (`utilisateur:motdepasse@`) ne partent pas.
    private func modelsURL(query: [(name: String, value: String)]?) throws -> URL {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else {
            throw EndpointError.transport("\(EndpointConfig.baseURLVariable) doit être une adresse http(s) complète")
        }
        var segments = components.path.split(separator: "/").map(String.init)
        if segments.last == "v1" { segments.removeLast() }
        components.path = "/" + (segments + ["v1", "models"]).joined(separator: "/")
        components.user = nil
        components.password = nil
        components.fragment = nil
        components.percentEncodedQuery = query?.map { "\($0.name)=\(Self.encode($0.value))" }.joined(separator: "&")
        guard let url = components.url else {
            throw EndpointError.transport("\(EndpointConfig.baseURLVariable) donne une adresse inutilisable")
        }
        return url
    }

    /// Tout sauf les caractères non réservés de la RFC 3986 est encodé : un curseur contenant `&`, `+` ou `=` reste une valeur.
    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Envoie la requête (GET) et rend l'objet JSON d'une réponse 2xx. Toute autre issue est une `EndpointError`,
    /// sauf l'annulation de la tâche, qui reste une `CancellationError`.
    private func fetchObject(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapped(error)
        }
        guard let http = response as? HTTPURLResponse else { throw EndpointError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw EndpointError.http(status: http.statusCode, body: masked(String(decoding: data, as: UTF8.self)))
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw EndpointError.malformedResponse
        }
        return object
    }

    /// Les identifiants du tableau `data`. Un `data` absent, ou une entrée sans identifiant texte non vide, est une
    /// réponse mal formée : on ne rend pas silencieusement une liste amputée.
    private static func ids(in object: [String: Any]) throws -> [String] {
        guard let entries = object["data"] as? [Any] else { throw EndpointError.malformedResponse }
        return try entries.map { entry in
            guard let id = (entry as? [String: Any])?["id"] as? String, !id.isEmpty else { throw EndpointError.malformedResponse }
            return id
        }
    }

    private static func sortedUnique(_ ids: [String]) -> [String] { Array(Set(ids)).sorted() }

    // MARK: - Erreurs

    /// Erreur de `URLSession` rendue au format du client : l'annulation reste une `CancellationError`, une
    /// `EndpointError` passe telle quelle, tout le reste est une panne de transport (message masqué).
    private func mapped(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError: return CancellationError()
        case let error as URLError where error.code == .cancelled: return CancellationError()
        case let error as EndpointError: return error
        default: return EndpointError.transport(masked(error.localizedDescription))
        }
    }

    /// Texte affichable : la clé est masquée d'abord (une troncature ne doit pas en laisser un morceau), puis le texte
    /// est limité à 500 caractères.
    private func masked(_ text: String) -> String {
        String(text.replacingOccurrences(of: config.apiKey, with: "***").prefix(500))
    }
}
