import Foundation
import Network
import Testing
@testable import SupervoxCore

/// Serveur TCP local qui accepte la connexion, lit la requête et ne répond jamais : un endpoint « muet ».
/// Ses connexions ne sont touchées que sur sa file.
private final class MuteServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "serveur-muet")
    private var connections: [NWConnection] = []

    init() throws { listener = try NWListener.loopbackOnly() }

    /// Démarre l'écoute et rend le port.
    func start() async throws -> UInt16 {
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            self.connections.append(connection)
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { _, _, _, _ in }
        }
        let listener = self.listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel(); queue.sync { connections.forEach { $0.cancel() } } }
}

private func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

@Suite("RequestTimeoutTests", .serialized)
struct RequestTimeoutTests {
    /// Un endpoint qui accepte la connexion puis se tait : la requête échoue en panne de transport après le délai,
    /// au lieu d'attendre le délai par défaut du système (60 s). Vraie pile réseau, pas de double.
    @Test func muteEndpointFailsAfterTheRequestTimeout() async throws {
        let server = try MuteServer()
        let port = try await server.start()
        defer { server.stop() }
        let client = OpenAICompatibleClient(config: EndpointConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                                                                   apiKey: "k"),
                                            requestTimeout: 0.5)
        let clock = ContinuousClock()
        let start = clock.now
        var caught: (any Error)?
        do { _ = try await client.transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil) } catch { caught = error }
        let elapsed = seconds(start.duration(to: clock.now))
        guard case .transport? = caught as? EndpointError else {
            Issue.record("attendu une panne de transport, reçu \(String(describing: caught))"); return
        }
        #expect(elapsed >= 0.45 && elapsed < 5, "durée \(elapsed) s")

        // Même chose pour la synthèse et pour le flux de chat.
        await #expect { _ = try await client.speech(model: "m", input: "a", voice: "v", format: "wav", extra: [:]) }
            throws: { if case .transport? = $0 as? EndpointError { true } else { false } }
        await #expect {
            for try await _ in client.chatStream(model: "m", messages: [ChatMessage(role: "user", content: "a")], maxTokens: 5) {}
        } throws: { if case .transport? = $0 as? EndpointError { true } else { false } }
    }

    /// Chaque requête porte le délai du client ; la valeur par défaut est celle annoncée.
    @Test func everyRequestCarriesTheClientTimeout() async throws {
        #expect(OpenAICompatibleClient.defaultRequestTimeout == 30)
        let transcription = stubbedClient(status: 200, body: "{\"text\":\"ok\"}", requestTimeout: 12)
        _ = try await transcription.transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil)
        #expect(StubURLProtocol.lastRequest(of: transcription)?.timeoutInterval == 12)
        #expect(transcription.requestTimeout == 12)

        let speech = stubbedClient(status: 200, fixture: "speech-200.wav", requestTimeout: 12)
        _ = try await speech.speech(model: "m", input: "a", voice: "v", format: "wav", extra: [:])
        #expect(StubURLProtocol.lastRequest(of: speech)?.timeoutInterval == 12)

        let chat = stubbedClient(status: 200, fixture: "chat-stream-content.sse", requestTimeout: 12)
        for try await _ in chat.chatStream(model: "m", messages: [ChatMessage(role: "user", content: "a")], maxTokens: 5) {}
        #expect(StubURLProtocol.lastRequest(of: chat)?.timeoutInterval == 12)
    }
}
