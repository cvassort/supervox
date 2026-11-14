import Foundation
import Network
import Synchronization

/// Petit serveur HTTP/1.1 sur la boucle locale : vraie pile réseau, pas de double. Chaque requête complète (en-têtes,
/// puis `Content-Length` octets de corps) est notée, puis reçoit la réponse que rend `respond`, et la connexion est
/// fermée. Sert aux tests de redirection : une redirection rendue par un `URLProtocol` ne passe pas par la même
/// mécanique que celle d'un vrai serveur.
final class LocalHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        /// Noms en minuscules.
        let headers: [String: String]
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "serveur-http-local")
    private let respond: @Sendable (Request) -> Response
    private let received = Mutex<[Request]>([])
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init(respond: @escaping @Sendable (Request) -> Response) throws {
        self.respond = respond
        listener = try NWListener(using: .tcp, on: .any)
    }

    /// Requêtes reçues jusqu'ici, dans l'ordre.
    var requests: [Request] { received.withLock { $0 } }

    /// `http://127.0.0.1:<port>`
    var base: String { "http://127.0.0.1:\(port)" }

    func start() async throws {
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            self.connections.append(connection)
            connection.start(queue: queue)
            self.serve(connection, buffer: Data())
        }
        let listener = self.listener
        port = try await withCheckedThrowingContinuation { continuation in
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

    private func serve(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
            let buffer = buffer + (data ?? Data())
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if buffer.count - (headerEnd.upperBound - buffer.startIndex) >= length {
                    let request = Request(method: requestLine.first ?? "", path: requestLine.dropFirst().first ?? "", headers: headers)
                    self.received.withLock { $0.append(request) }
                    self.reply(self.respond(request), on: connection)
                    return
                }
            }
            if done || error != nil { return }
            self.serve(connection, buffer: buffer)
        }
    }

    private func reply(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) Statut\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
