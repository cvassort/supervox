import Foundation

/// Ce que les clients d'un endpoint ont en commun : l'adresse `<base>/v1/…`, la conversion des erreurs et le masquage
/// de la clé. Interne : aucun client n'est tenu de passer par là, mais aucun ne doit réécrire ces règles.
struct EndpointRequest: Sendable {
    let config: EndpointConfig
    let session: URLSession
    /// Délai d'inactivité de chaque requête, en secondes (voir `OpenAICompatibleClient.requestTimeout`).
    let timeout: TimeInterval

    /// Un corps d'erreur HTTP n'est lu que jusqu'à cette taille : on n'en garde de toute façon que 500 caractères.
    static let errorBodyReadLimit = 64 * 1024

    /// `<base>/v1/<path>`. La base peut avoir un `/` final, se terminer par `/v1` ou porter un préfixe de chemin :
    /// dans tous les cas on obtient exactement un `/v1`, sans `//`. La requête et le fragment de la base sont ignorés.
    func url(path: [String]) throws -> URL {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else {
            throw EndpointError.transport("\(EndpointConfig.baseURLVariable) doit être une adresse http(s) complète")
        }
        var segments = components.path.split(separator: "/").map(String.init)
        if segments.last == "v1" { segments.removeLast() }
        components.path = "/" + (segments + ["v1"] + path).joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw EndpointError.transport("\(EndpointConfig.baseURLVariable) donne une adresse inutilisable")
        }
        return url
    }

    /// Erreur de `URLSession` (ou levée en cours de lecture) rendue au format des clients : l'annulation reste une
    /// `CancellationError`, une `EndpointError` passe telle quelle, tout le reste est une panne de transport.
    func mapped(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError: return CancellationError()
        case let error as URLError where error.code == .cancelled: return CancellationError()
        case let error as EndpointError: return error
        default: return EndpointError.transport(error.localizedDescription)
        }
    }

    /// Corps d'erreur affichable : la clé est masquée d'abord (une troncature ne doit pas en laisser un morceau),
    /// puis le texte est limité à 500 caractères.
    func errorBody(_ data: Data) -> String {
        errorBody(String(decoding: data, as: UTF8.self))
    }

    func errorBody(_ text: String) -> String {
        String(text.replacingOccurrences(of: config.apiKey, with: "***").prefix(500))
    }
}

/// Découpe un flux d'octets en lignes selon les règles SSE : fin de ligne `\n`, `\r\n` ou `\r` seul, quelle que soit
/// la façon dont le réseau a coupé les morceaux (un `\r` et son `\n` peuvent arriver séparés).
/// Une ligne est décodée en UTF-8 une fois complète : un caractère coupé en deux par le réseau est recollé.
struct SSELineSplitter {
    /// Au-delà, la ligne n'est plus un événement de chat : le corps n'est pas un flux utilisable.
    static let maxLineBytes = 1 << 20

    private var line: [UInt8] = []
    private var skipLineFeed = false

    mutating func push(_ byte: UInt8) throws -> [String] {
        switch byte {
        case 0x0D:
            skipLineFeed = true
            return [take()]
        case 0x0A:
            if skipLineFeed { skipLineFeed = false; return [] }
            return [take()]
        default:
            skipLineFeed = false
            line.append(byte)
            if line.count > Self.maxLineBytes { throw EndpointError.malformedResponse }
            return []
        }
    }

    /// La dernière ligne, quand le flux s'arrête sans fin de ligne.
    mutating func finish() -> String? {
        line.isEmpty ? nil : take()
    }

    private mutating func take() -> String {
        defer { line.removeAll(keepingCapacity: true) }
        return String(decoding: line, as: UTF8.self)
    }
}
