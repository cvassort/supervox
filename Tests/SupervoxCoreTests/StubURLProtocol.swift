import Foundation
import Synchronization
@testable import SupervoxCore

/// Rejoue un statut et un corps (ou une erreur réseau) et garde les requêtes reçues, corps compris.
/// Remplace un serveur local : les réponses rejouées sont des enregistrements réels (voir `Fixtures/endpoint`).
///
/// Chaque client fabriqué par `stubbedClient` a son propre enregistrement, retrouvé à chaque requête grâce à un
/// identifiant porté par la session (en-tête `idHeader`, posé dans `httpAdditionalHeaders`). La réponse rejouée et
/// la requête capturée ne dépendent donc d'aucun état global « dernière réponse » : deux suites, ou deux tests d'une
/// même suite, peuvent s'exécuter en même temps sans se marcher dessus. Les tests lisent ce que leur client a reçu
/// avec `lastRequest(of:)`, `lastBody(of:)`, `requestCount(of:)` et `stopLoadingCount(of:)`.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// Ce que fait le « serveur » quand la requête arrive.
    enum Reply: Sendable {
        /// Statut, corps livré d'un bloc, en-têtes éventuels.
        case response(status: Int, body: Data, headers: [String: String] = [:])
        /// Échec réseau avant toute réponse HTTP.
        case failure(URLError.Code)
        /// Statut puis morceaux livrés l'un après l'autre (le client lit donc les octets au fil de l'eau), puis `end`.
        case stream(status: Int, chunks: [Data], end: End)
    }

    /// Fin d'une réponse en flux.
    enum End: Sendable {
        /// Fin normale de la réponse.
        case finish
        /// Le serveur se tait sans fermer : seule une annulation côté client (voir `stopLoadingCount`) ou
        /// `dropConnection(of:code:)` arrête la requête.
        case hang
    }

    private struct Entry {
        var reply: Reply
        var requests: [URLRequest] = []
        var lastBody = Data()
        var stopLoadingCount = 0
        /// La requête en cours d'un flux qui se tait (`End.hang`).
        var hanging: StubURLProtocol?
    }

    /// En-tête qui porte l'identifiant de l'enregistrement. Il est posé par la session, pas par le client testé.
    static let idHeader = "X-Stub-Id"

    private static let entries = Mutex<[String: Entry]>([:])
    /// Les clients sont gardés : l'identité d'un client libéré pourrait être réattribuée à un autre.
    private static let clients = Mutex<[ObjectIdentifier: (client: OpenAICompatibleClient, id: String)]>([:])

    // MARK: Fabrication

    static func makeClient(reply: Reply, baseURL: String, apiKey: String) -> OpenAICompatibleClient {
        let id = UUID().uuidString
        entries.withLock { $0[id] = Entry(reply: reply) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [idHeader: id]
        let config = EndpointConfig(baseURL: URL(string: baseURL)!, apiKey: apiKey)
        let client = OpenAICompatibleClient(config: config, session: URLSession(configuration: configuration))
        clients.withLock { $0[ObjectIdentifier(client)] = (client, id) }
        return client
    }

    // MARK: Lecture de ce qu'un client a envoyé

    private static func id(of client: OpenAICompatibleClient) -> String {
        guard let id = clients.withLock({ $0[ObjectIdentifier(client)]?.id }) else {
            fatalError("ce client ne vient pas de stubbedClient")
        }
        return id
    }

    private static func read<T>(_ client: OpenAICompatibleClient, _ body: (Entry) -> T) -> T {
        let id = id(of: client)
        return entries.withLock { body($0[id]!) }
    }

    static func lastRequest(of client: OpenAICompatibleClient) -> URLRequest? { read(client) { $0.requests.last } }
    static func lastBody(of client: OpenAICompatibleClient) -> Data { read(client) { $0.lastBody } }
    static func requestCount(of client: OpenAICompatibleClient) -> Int { read(client) { $0.requests.count } }
    /// Nombre de fois où le client a arrêté sa requête (annulation) ou où elle s'est terminée.
    static func stopLoadingCount(of client: OpenAICompatibleClient) -> Int { read(client) { $0.stopLoadingCount } }

    /// Coupe la connexion d'un flux qui se tait (`End.hang`). C'est le test qui choisit l'instant, une fois qu'il a vu
    /// passer les morceaux : une coupure donnée tout de suite après eux peut les faire perdre à URLSession.
    static func dropConnection(of client: OpenAICompatibleClient, code: URLError.Code) {
        let id = id(of: client)
        guard let live = entries.withLock({ $0[id]?.hanging }) else { fatalError("aucun flux en cours à couper") }
        live.client?.urlProtocol(live, didFailWithError: URLError(code))
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var stubID: String {
        guard let id = request.value(forHTTPHeaderField: Self.idHeader) else {
            fatalError("requête sans \(Self.idHeader) : la session ne vient pas de stubbedClient")
        }
        return id
    }

    override func stopLoading() {
        let id = stubID
        Self.entries.withLock {
            $0[id]?.stopLoadingCount += 1
            $0[id]?.hanging = nil
        }
    }

    override func startLoading() {
        // Dans un URLProtocol, le corps d'une requête arrive par `httpBodyStream`, pas par `httpBody`.
        let body = Self.readBody(of: request)
        let id = stubID
        let request = request
        guard let reply = Self.entries.withLock({ entries -> Reply? in
            entries[id]?.requests.append(request)
            entries[id]?.lastBody = body
            return entries[id]?.reply
        }) else { fatalError("aucun enregistrement pour \(id)") }

        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let data, let headers):
            client?.urlProtocol(self, didReceive: httpResponse(status, headers), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .stream(let status, let chunks, let end):
            // Sans `Content-Type`, URLSession retient les premiers octets pour deviner le type du contenu : un vrai
            // serveur de flux en envoie un, le stub aussi, sinon le test ne verrait pas les octets au fil de l'eau.
            client?.urlProtocol(self, didReceive: httpResponse(status, ["Content-Type": "text/event-stream"]), cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            switch end {
            case .finish: client?.urlProtocolDidFinishLoading(self)
            case .hang: Self.entries.withLock { $0[id]?.hanging = self }
            }
        }
    }

    private func httpResponse(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private static func readBody(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Client dont le « serveur » rejoue `reply`.
func stubbedClient(reply: StubURLProtocol.Reply, baseURL: String = "https://exemple.test", apiKey: String = "k") -> OpenAICompatibleClient {
    StubURLProtocol.makeClient(reply: reply, baseURL: baseURL, apiKey: apiKey)
}

/// Client dont le « serveur » répond `status` avec le contenu du fichier enregistré `fixture`.
func stubbedClient(status: Int, fixture: String, baseURL: String = "https://exemple.test", apiKey: String = "k") -> OpenAICompatibleClient {
    stubbedClient(reply: .response(status: status, body: fixtureData(fixture)), baseURL: baseURL, apiKey: apiKey)
}

/// Client dont le « serveur » répond `status` avec le corps `body`.
func stubbedClient(status: Int, body: String, baseURL: String = "https://exemple.test", apiKey: String = "k") -> OpenAICompatibleClient {
    stubbedClient(reply: .response(status: status, body: Data(body.utf8)), baseURL: baseURL, apiKey: apiKey)
}

/// Client dont le « serveur » répond `status` avec les octets `body` et les en-têtes `headers`.
func stubbedClient(status: Int, data: Data, headers: [String: String], baseURL: String = "https://exemple.test", apiKey: String = "k") -> OpenAICompatibleClient {
    stubbedClient(reply: .response(status: status, body: data, headers: headers), baseURL: baseURL, apiKey: apiKey)
}

/// Client dont le « serveur » livre `body` par morceaux de `chunkSize` octets (au plus), puis termine.
/// Un morceau d'un octet coupe les lignes, les `\r\n` et les caractères UTF-8 en deux, comme un réseau peut le faire.
func stubbedClient(status: Int, body: Data, chunkSize: Int, apiKey: String = "k") -> OpenAICompatibleClient {
    let chunks = stride(from: 0, to: body.count, by: chunkSize).map { Data(body[$0..<min($0 + chunkSize, body.count)]) }
    return stubbedClient(reply: .stream(status: status, chunks: chunks, end: .finish), apiKey: apiKey)
}

/// Client dont la requête échoue au niveau réseau, sans réponse HTTP.
func stubbedClient(failure code: URLError.Code, baseURL: String = "https://exemple.test") -> OpenAICompatibleClient {
    stubbedClient(reply: .failure(code), baseURL: baseURL, apiKey: "k")
}

/// Contenu d'un fichier de `Fixtures/endpoint`. Un fichier absent fait échouer le test : jamais de corps vide silencieux.
func fixtureData(_ name: String) -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/endpoint"),
          let data = try? Data(contentsOf: url), !data.isEmpty
    else { fatalError("fixture absente ou vide : \(name)") }
    return data
}

func fixtureString(_ name: String) -> String { String(decoding: fixtureData(name), as: UTF8.self) }
