import Foundation
import Synchronization
import Testing
@testable import SupervoxCore

/// Les deux clients de modèle de langage contre un vrai serveur sur la boucle locale (pile réseau réelle, pas de double) :
/// coupures, statuts, silence, annulation.
@Suite("LanguageModelServerTests", .serialized)
struct LanguageModelServerTests {
    enum Kind: String, CaseIterable, Sendable {
        case openAI, anthropic

        func model(base: String, key: String = "cle-test", requestTimeout: TimeInterval = 10) -> any LanguageModel {
            let config = EndpointConfig(baseURL: URL(string: base)!, apiKey: key)
            switch self {
            case .openAI: return OpenAICompatibleClient(config: config, requestTimeout: requestTimeout)
            case .anthropic: return AnthropicClient(config: config, requestTimeout: requestTimeout)
            }
        }

        /// Un événement de texte, tel que ce type de serveur l'envoie.
        func textEvent(_ text: String) -> Data {
            switch self {
            case .openAI:
                Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\(text)\"},\"finish_reason\":null}]}\n\n".utf8)
            case .anthropic:
                Data("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}\n\n".utf8)
            }
        }

        /// Les événements qui précèdent le texte (début de message d'Anthropic), sinon rien.
        var opening: [Data] {
            switch self {
            case .openAI: []
            case .anthropic: [Data("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"requete-exemple\"}}\n\n".utf8)]
            }
        }

        var reasoningThenAnswer: String {
            switch self {
            case .openAI: "completion-openai-reasoning-then-content.sse"
            case .anthropic: "messages-anthropic-thinking.sse"
            }
        }
    }

    private static func serve(_ response: LocalHTTPServer.Response) async throws -> LocalHTTPServer {
        let server = try LocalHTTPServer { _ in response }
        try await server.start()
        return server
    }

    private static func serve(chunks: [Data], end: LocalHTTPServer.End) async throws -> LocalHTTPServer {
        try await serve(.init(status: 200, stream: .init(chunks: chunks, end: end)))
    }

    private static let request = CompletionRequest(model: "modele-exemple", instruction: "Consigne.", input: "Texte.", maxTokens: 50)

    // MARK: Fin du flux

    @Test(arguments: Kind.allCases)
    func aStreamCutByTheServerGivesTheTextAlreadyReceivedThenAnInterruption(kind: Kind) async throws {
        let server = try await Self.serve(chunks: kind.opening + [kind.textEvent("Bon"), kind.textEvent("jour")], end: .close)
        defer { server.stop() }
        let r = await collectEvents(kind.model(base: server.base).complete(Self.request))
        #expect(r.events == [.text("Bon"), .text("jour")])
        #expect(r.error as? EndpointError == .streamInterrupted)
    }

    @Test(arguments: Kind.allCases)
    func anEmptyBodyIsAnErrorNeverANormalEnd(kind: Kind) async throws {
        let server = try await Self.serve(.init(status: 200))
        defer { server.stop() }
        let r = await collectEvents(kind.model(base: server.base).complete(Self.request))
        #expect(r.events.isEmpty)
        #expect(r.error as? EndpointError == .streamInterrupted)

        let silent = try await Self.serve(chunks: [], end: .close)
        defer { silent.stop() }
        let s = await collectEvents(kind.model(base: silent.base).complete(Self.request))
        #expect(s.events.isEmpty)
        #expect(s.error as? EndpointError == .streamInterrupted)
    }

    @Test(arguments: Kind.allCases)
    func reasoningThenAnswerThenCompleteStop(kind: Kind) async throws {
        let body = fixtureData(kind.reasoningThenAnswer)
        // Découpé en morceaux de 40 octets : de vrais paquets, coupant lignes et caractères.
        let chunks = stride(from: 0, to: body.count, by: 40).map { Data(body[$0..<min($0 + 40, body.count)]) }
        let server = try await Self.serve(chunks: chunks, end: .close)
        defer { server.stop() }
        let r = await collectEvents(kind.model(base: server.base).complete(Self.request))
        #expect(r.error == nil)
        let firstText = try #require(r.events.firstIndex { if case .text = $0 { true } else { false } })
        #expect(firstText > 0)
        #expect(r.events[..<firstText].allSatisfy { if case .reasoning = $0 { true } else { false } })
        #expect(r.events[firstText...].dropLast().allSatisfy { if case .text = $0 { true } else { false } })
        #expect(r.events.last == .stop(.complete))
        let answer = r.events.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
        #expect(answer == "Bonjour, tout le monde.")
    }

    // MARK: Statuts

    @Test(arguments: Kind.allCases)
    func a401ThatRepeatsTheKeyIsAnHttpErrorWithoutTheKey(kind: Kind) async throws {
        let key = "cle-secrete-0123"
        let body = "{\"error\":{\"type\":\"authentication_error\",\"message\":\"clé \(key) refusée\"}}"
        let server = try await Self.serve(.init(status: 401, headers: ["Content-Type": "application/json"], body: Data(body.utf8)))
        defer { server.stop() }
        let r = await collectEvents(kind.model(base: server.base, key: key).complete(Self.request))
        #expect(r.events.isEmpty)
        #expect(r.error as? EndpointError == .http(status: 401, body: body.replacingOccurrences(of: key, with: "***")))
    }

    @Test(arguments: Kind.allCases, [500, 529])
    func serverErrorsAreHttpErrors(kind: Kind, status: Int) async throws {
        let body = fixtureData("messages-anthropic-529.json")
        let server = try await Self.serve(.init(status: status, headers: ["Content-Type": "application/json"], body: body))
        defer { server.stop() }
        let r = await collectEvents(kind.model(base: server.base).complete(Self.request))
        #expect(r.events.isEmpty)
        #expect(r.error as? EndpointError == .http(status: status, body: fixtureString("messages-anthropic-529.json")))
    }

    // MARK: Silence

    /// Le serveur accepte, puis se tait (avant tout octet de corps, ou après un morceau) : `complete` lève `stalled`,
    /// jamais une panne de transport ; `chatStream` garde la panne de transport.
    @Test(arguments: Kind.allCases, [false, true])
    func silenceIsStalledForComplete(kind: Kind, afterSomeText: Bool) async throws {
        let chunks = afterSomeText ? kind.opening + [kind.textEvent("Bon")] : []
        let server = try await Self.serve(chunks: chunks, end: .hang)
        defer { server.stop() }
        let r = await collectEvents(kind.model(base: server.base, requestTimeout: 0.5).complete(Self.request))
        #expect(r.events == (afterSomeText ? [.text("Bon")] : []))
        #expect(r.error as? CompletionError == .stalled)
    }

    @Test func silenceStaysATransportErrorForChatStream() async throws {
        let server = try await Self.serve(chunks: [], end: .hang)
        defer { server.stop() }
        let client = OpenAICompatibleClient(config: EndpointConfig(baseURL: URL(string: server.base)!, apiKey: "k"), requestTimeout: 0.5)
        var caught: (any Error)?
        do { for try await _ in client.chatStream(model: "m", messages: [], maxTokens: 5) {} } catch { caught = error }
        guard case .transport? = caught as? EndpointError else {
            Issue.record("attendu .transport, reçu \(String(describing: caught))"); return
        }
    }

    // MARK: Annulation

    private static func hangingServer(_ kind: Kind) async throws -> LocalHTTPServer {
        try await serve(chunks: kind.opening + [kind.textEvent("Bon")], end: .hang)
    }

    /// Annuler la tâche consommatrice fait fermer la connexion par le client. La boucle se termine sans erreur
    /// (comportement d'`AsyncThrowingStream`) : le consommateur teste `Task.isCancelled`.
    @Test(arguments: Kind.allCases)
    func cancellingTheConsumingTaskClosesTheConnection(kind: Kind) async throws {
        let server = try await Self.hangingServer(kind)
        defer { server.stop() }
        let model = kind.model(base: server.base)
        let received = Mutex<[CompletionEvent]>([])
        let consumer = Task { () -> (error: (any Error)?, cancelled: Bool) in
            do {
                for try await event in model.complete(Self.request) { received.withLock { $0.append(event) } }
                return (nil, Task.isCancelled)
            } catch { return (error, Task.isCancelled) }
        }
        #expect(await waitUntil { received.withLock { $0.count } == 1 })
        #expect(server.closedByClient == 0)    // le serveur se tait mais la connexion vit encore
        consumer.cancel()
        let outcome = await consumer.value
        #expect(outcome.error == nil)
        #expect(outcome.cancelled)
        #expect(await waitUntil { server.closedByClient == 1 }, "le client n'a pas fermé la connexion")
        #expect(received.withLock { $0 } == [.text("Bon")])
    }

    @Test(arguments: Kind.allCases)
    func leavingTheLoopEarlyClosesTheConnection(kind: Kind) async throws {
        let server = try await Self.hangingServer(kind)
        defer { server.stop() }
        let model = kind.model(base: server.base)
        for try await event in model.complete(Self.request) {
            #expect(event == .text("Bon"))
            break
        }
        #expect(await waitUntil { server.closedByClient == 1 }, "le client n'a pas fermé la connexion")
    }
}
