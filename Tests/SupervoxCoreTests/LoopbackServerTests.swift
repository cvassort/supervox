import Darwin
import Foundation
import Network
import Testing

/// Les serveurs des tests n'écoutent que sur la boucle locale : un autre poste du réseau ne peut pas les joindre
/// pendant la suite. Vérifié en se connectant à une adresse IPv4 de ce Mac hors de la boucle locale (la connexion
/// reste sur la machine) : elle doit être refusée, et celle par 127.0.0.1 acceptée. Un Mac sans adresse IPv4 hors
/// boucle locale ne fait que le second essai.
@Suite struct LoopbackServerTests {
    @Test func localHTTPServerOnlyAcceptsLoopbackConnections() async throws {
        let server = try LocalHTTPServer { _ in .init(status: 204) }
        try await server.start()
        defer { server.stop() }

        #expect(await Self.connects(to: .ipv4(.loopback), port: server.port))
        // Sans aucune interface IPv4 active, rien d'autre à essayer : `SourceScanTests` garde alors seul la règle.
        guard let outside = Self.nonLoopbackIPv4() else { return }
        #expect(await !Self.connects(to: .ipv4(outside), port: server.port))
    }

    /// Le mode flux (réponse sans longueur, connexion gardée ouverte) écoute lui aussi sur la boucle locale seulement.
    @Test func streamingLocalHTTPServerOnlyAcceptsLoopbackConnections() async throws {
        let stream = LocalHTTPServer.Stream(chunks: [Data("data: x\n\n".utf8)], end: .hang)
        let server = try LocalHTTPServer { _ in .init(status: 200, stream: stream) }
        try await server.start()
        defer { server.stop() }

        #expect(await Self.connects(to: .ipv4(.loopback), port: server.port))
        guard let outside = Self.nonLoopbackIPv4() else { return }
        #expect(await !Self.connects(to: .ipv4(outside), port: server.port))
    }

    /// Un flux envoie ses morceaux sans `Content-Length`, et `closedByClient` compte la connexion que le client ferme
    /// pendant un `hang`, pas celle que `stop()` ferme.
    @Test func hangingStreamCountsOnlyTheConnectionTheClientCloses() async throws {
        let stream = LocalHTTPServer.Stream(chunks: [Data("data: un\n\n".utf8), Data("data: deux\n\n".utf8)], end: .hang)
        let server = try LocalHTTPServer { _ in .init(status: 200, stream: stream) }
        try await server.start()
        defer { server.stop() }

        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: server.port)!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "client-flux"))
        connection.send(content: Data("POST /flux HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8), completion: .idempotent)
        var received = Data()
        while !String(decoding: received, as: UTF8.self).contains("data: deux") {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
                }
            }
            #expect(!chunk.isEmpty, "le serveur a fermé avant le second morceau")
            if chunk.isEmpty { break }
            received += chunk
        }
        let text = String(decoding: received, as: UTF8.self).lowercased()
        #expect(text.hasPrefix("http/1.1 200"))
        #expect(text.contains("content-type: text/event-stream"))
        #expect(!text.contains("content-length"))
        #expect(server.closedByClient == 0)

        connection.cancel()
        #expect(await Self.eventually { server.closedByClient == 1 })
    }

    @Test func stoppingTheServerIsNotACloseByTheClient() async throws {
        let stream = LocalHTTPServer.Stream(chunks: [Data("data: un\n\n".utf8)], end: .hang)
        let server = try LocalHTTPServer { _ in .init(status: 200, stream: stream) }
        try await server.start()
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: server.port)!, using: .tcp)
        defer { connection.cancel() }
        connection.start(queue: DispatchQueue(label: "client-flux"))
        connection.send(content: Data("POST /flux HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8), completion: .idempotent)
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
            }
        }
        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.closedByClient == 0)
    }

    /// Attend qu'une condition devienne vraie, au plus 10 s : un test en échec ne bloque jamais la suite.
    private static func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func loopbackListenerOnlyAcceptsLoopbackConnections() async throws {
        let listener = try NWListener.loopbackOnly()
        let queue = DispatchQueue(label: "boucle-locale")
        listener.newConnectionHandler = { $0.cancel() }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        defer { listener.cancel() }

        #expect(await Self.connects(to: .ipv4(.loopback), port: port))
        // Sans aucune interface IPv4 active, rien d'autre à essayer : `SourceScanTests` garde alors seul la règle.
        guard let outside = Self.nonLoopbackIPv4() else { return }
        #expect(await !Self.connects(to: .ipv4(outside), port: port))
    }

    /// `true` si la connexion TCP s'établit, `false` si elle est refusée.
    private static func connects(to host: NWEndpoint.Host, port: UInt16) async -> Bool {
        let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "client-boucle-locale")
        let result: Bool = await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: connection.stateUpdateHandler = nil; continuation.resume(returning: true)
                case .waiting, .failed: connection.stateUpdateHandler = nil; continuation.resume(returning: false)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        connection.cancel()
        return result
    }

    /// Une adresse IPv4 d'une interface active de ce Mac, hors boucle locale.
    private static func nonLoopbackIPv4() -> IPv4Address? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }
        defer { freeifaddrs(first) }
        var cursor = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            return withUnsafeBytes(of: ipv4) { IPv4Address(Data($0)) }
        }
        return nil
    }
}
