import Darwin
import Foundation
import Network
import Testing

/// Les serveurs des tests n'écoutent que sur la boucle locale : un autre poste du réseau ne peut pas les joindre
/// pendant la suite. Vérifié en se connectant à une adresse IPv4 de ce Mac hors de la boucle locale (la connexion
/// reste sur la machine) : elle doit être refusée, et celle par 127.0.0.1 acceptée.
@Suite struct LoopbackServerTests {
    @Test func localHTTPServerOnlyAcceptsLoopbackConnections() async throws {
        let server = try LocalHTTPServer { _ in .init(status: 204) }
        try await server.start()
        defer { server.stop() }

        #expect(await Self.connects(to: .ipv4(.loopback), port: server.port))
        let outside = try #require(Self.nonLoopbackIPv4(), "aucune adresse IPv4 hors boucle locale sur ce Mac")
        #expect(await !Self.connects(to: .ipv4(outside), port: server.port))
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
        let outside = try #require(Self.nonLoopbackIPv4(), "aucune adresse IPv4 hors boucle locale sur ce Mac")
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
