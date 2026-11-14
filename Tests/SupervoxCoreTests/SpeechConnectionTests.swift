import Foundation
import Network
import Testing
@testable import SupervoxCore

/// Serveur HTTP/1.1 local qui répond à chaque requête complète par un WAV et garde la connexion ouverte
/// (keep-alive) : la seconde requête du même client peut la réutiliser. Vraie pile réseau, pas de double.
/// État touché seulement sur sa file.
private final class KeepAliveWavServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "serveur-wav")
    private var connections: [NWConnection] = []
    private(set) var accepted = 0
    private let wav: Data

    init(wav: Data) throws {
        self.wav = wav
        listener = try NWListener.loopbackOnly()
    }

    func start() async throws -> UInt16 {
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            self.accepted += 1
            self.connections.append(connection)
            connection.start(queue: queue)
            self.serve(connection, buffer: Data())
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

    var acceptedConnections: Int { queue.sync { accepted } }

    /// Lit une requête entière (en-têtes, puis `Content-Length` octets de corps), répond, recommence.
    private func serve(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
            var buffer = buffer + (data ?? Data())
            while let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self).lowercased()
                let length = headers.components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                let end = headerEnd.upperBound + length
                guard buffer.count >= end - buffer.startIndex else { break }
                buffer = Data(buffer[end...])
                let head = "HTTP/1.1 200 OK\r\nContent-Type: audio/wav\r\nContent-Length: \(self.wav.count)\r\nConnection: keep-alive\r\n\r\n"
                connection.send(content: Data(head.utf8) + self.wav, completion: .idempotent)
            }
            if done || error != nil { return }
            self.serve(connection, buffer: buffer)
        }
    }

    func stop() { listener.cancel(); queue.sync { connections.forEach { $0.cancel() } } }
}

@Suite("SpeechConnectionTests", .serialized)
struct SpeechConnectionTests {
    /// Le protocole négocié et la réutilisation de la connexion sont relevés (`URLSessionTaskMetrics`) pour chaque
    /// appel de synthèse : le premier ouvre une connexion, le second, sur le même client, la réutilise.
    @Test func speechReportsTheProtocolAndWhetherTheConnectionWasReused() async throws {
        let wav = fixtureData("speech-200.wav")
        let server = try KeepAliveWavServer(wav: wav)
        let port = try await server.start()
        defer { server.stop() }
        let client = OpenAICompatibleClient(config: EndpointConfig(baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: "k"),
                                            session: URLSession(configuration: .ephemeral))
        let first = try await client.speechMeasured(model: "m", input: "Bonjour.", voice: "v", format: "wav", extra: [:])
        let second = try await client.speechMeasured(model: "m", input: "Bonjour. ", voice: "v", format: "wav", extra: [:])
        #expect(first.audio == wav && second.audio == wav)
        #expect(first.connection == ConnectionInfo(networkProtocol: "http/1.1", reused: false))
        #expect(second.connection == ConnectionInfo(networkProtocol: "http/1.1", reused: true))
        #expect(server.acceptedConnections == 1)
    }
}
