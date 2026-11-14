import Foundation
import Testing
@testable import SupervoxCore

/// Une clé n'est envoyée qu'à l'origine (schéma, hôte, port) pour laquelle elle a été saisie, même quand le serveur
/// répond par une redirection. Vrais serveurs locaux : l'assertion qui compte est « l'autre origine ne reçoit aucune
/// requête ». Sans garde, CFNetwork retire `Authorization` mais transmet `x-api-key` (mesure de la revue finale).
@Suite("RedirectTests", .serialized)
struct RedirectTests {
    enum Target: String, CaseIterable, Sendable {
        /// Même hôte, autre port.
        case otherPort
        /// Même port, autre nom d'hôte (`localhost` au lieu de `127.0.0.1`).
        case otherHost
        /// Même hôte, même port, autre schéma (`https` au lieu de `http`). Suivie, la redirection ouvrirait une
        /// connexion TLS vers le serveur d'origine : elle se voit dans `connectionsAccepted`, pas dans `requests`.
        case otherScheme
    }

    /// Le serveur configuré redirige tout vers `target` ; `elsewhere` est le serveur de l'autre port.
    private func redirectingServers(_ target: Target, status: Int, body: Data) async throws
        -> (origin: LocalHTTPServer, elsewhere: LocalHTTPServer)
    {
        let elsewhere = try LocalHTTPServer { _ in .init(status: 200, headers: ["Content-Type": "application/json"], body: body) }
        try await elsewhere.start()
        let otherPort = elsewhere.port
        let portBox = PortBox()
        let origin = try LocalHTTPServer { request in
            if request.path.hasPrefix("/ailleurs") {
                return .init(status: 200, headers: ["Content-Type": "application/json"], body: body)
            }
            let location = switch target {
            case .otherPort: "http://127.0.0.1:\(otherPort)\(request.path)"
            case .otherHost: "http://localhost:\(portBox.port)/ailleurs\(request.path)"
            case .otherScheme: "https://127.0.0.1:\(portBox.port)/ailleurs\(request.path)"
            }
            return .init(status: status, headers: ["Location": location])
        }
        try await origin.start()
        portBox.port = origin.port
        return (origin, elsewhere)
    }

    /// Requêtes reçues par l'autre origine : sur l'autre serveur, ou sur le chemin `/ailleurs` du même port, plus
    /// toute connexion du serveur d'origine qui n'a pas porté de requête lisible (TLS de l'autre schéma).
    private func requestsElsewhere(_ servers: (origin: LocalHTTPServer, elsewhere: LocalHTTPServer)) -> Int {
        servers.elsewhere.connectionsAccepted + servers.origin.requests.filter { $0.path.hasPrefix("/ailleurs") }.count
            + (servers.origin.connectionsAccepted - servers.origin.requests.count)
    }

    @Test(arguments: Target.allCases, [ModelListingKind.openAICompatible, .anthropic])
    func listerRefusesARedirectToAnotherOriginAndSendsItNothing(target: Target, kind: ModelListingKind) async throws {
        let servers = try await redirectingServers(target, status: 302, body: Data(#"{"data":[{"id":"m"}]}"#.utf8))
        defer { servers.origin.stop(); servers.elsewhere.stop() }
        let lister = ModelLister(config: EndpointConfig(baseURL: URL(string: servers.origin.base)!, apiKey: "cle-test"),
                                 kind: kind, requestTimeout: 5)

        await #expect(throws: EndpointError.crossOriginRedirect) { _ = try await lister.listModels() }
        #expect(requestsElsewhere(servers) == 0)
        #expect(servers.origin.requests.count == 1)
    }

    /// La clé suit la redirection de même origine, dans l'en-tête du type : `Authorization` ou `x-api-key`.
    @Test(arguments: [ModelListingKind.openAICompatible, .anthropic])
    func listerFollowsARedirectOnTheSameOrigin(kind: ModelListingKind) async throws {
        let server = try LocalHTTPServer { request in
            request.path.hasPrefix("/nouveau")
                ? .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"data":[{"id":"m"}]}"#.utf8))
                : .init(status: 301, headers: ["Location": "/nouveau\(request.path)"])
        }
        try await server.start()
        defer { server.stop() }
        let lister = ModelLister(config: EndpointConfig(baseURL: URL(string: server.base)!, apiKey: "cle-test"),
                                 kind: kind, requestTimeout: 5)

        #expect(try await lister.listModels() == ["m"])
        // Chemins sans la requête (`?limit=…` pour le type anthropic).
        #expect(server.requests.map { $0.path.prefix { $0 != "?" } } == ["/v1/models", "/nouveau/v1/models"])
        let first = try #require(server.requests.first?.headers)
        let followed = try #require(server.requests.last?.headers)
        switch kind {
        case .openAICompatible:
            #expect(first["authorization"] == "Bearer cle-test")
            #expect(followed["authorization"] == "Bearer cle-test")
        case .anthropic:
            #expect(first["x-api-key"] == "cle-test")
            #expect(followed["x-api-key"] == "cle-test")
        }
    }

    /// Transcription et synthèse (`upload`), flux de chat (`bytes`) : la même garde sur chaque route.
    @Test(arguments: Target.allCases)
    func clientRefusesARedirectToAnotherOriginOnEveryRoute(target: Target) async throws {
        let servers = try await redirectingServers(target, status: 307, body: Data(#"{"text":"ok"}"#.utf8))
        defer { servers.origin.stop(); servers.elsewhere.stop() }
        let client = OpenAICompatibleClient(
            config: EndpointConfig(baseURL: URL(string: servers.origin.base)!, apiKey: "cle-test"), requestTimeout: 5)

        await #expect(throws: EndpointError.crossOriginRedirect) {
            _ = try await client.transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil)
        }
        await #expect(throws: EndpointError.crossOriginRedirect) {
            _ = try await client.speech(model: "m", input: "a", voice: "v", format: "wav", extra: [:])
        }
        await #expect(throws: EndpointError.crossOriginRedirect) {
            for try await _ in client.chatStream(model: "m", messages: [ChatMessage(role: "user", content: "a")], maxTokens: 5) {}
        }
        #expect(requestsElsewhere(servers) == 0)
        #expect(servers.origin.requests.count == 3)
    }

    @Test func clientFollowsARedirectOnTheSameOrigin() async throws {
        let server = try LocalHTTPServer { request in
            request.path.hasPrefix("/nouveau")
                ? .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"text":"ok"}"#.utf8))
                : .init(status: 307, headers: ["Location": "/nouveau\(request.path)"])
        }
        try await server.start()
        defer { server.stop() }
        let client = OpenAICompatibleClient(
            config: EndpointConfig(baseURL: URL(string: server.base)!, apiKey: "cle-test"), requestTimeout: 5)

        #expect(try await client.transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil) == "ok")
        #expect(server.requests.map(\.path) == ["/v1/audio/transcriptions", "/nouveau/v1/audio/transcriptions"])
        #expect(server.requests.last?.headers["authorization"] == "Bearer cle-test")
    }
}

/// Port du serveur d'origine, connu seulement après son démarrage.
private final class PortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16 = 0
    var port: UInt16 {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
