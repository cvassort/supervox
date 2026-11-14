import Foundation

/// Accès asynchrone à un magasin de secrets, pour tout code de l'interface ou de l'application.
///
/// Les appels au magasin peuvent bloquer le temps qu'une invite du trousseau reçoive une réponse (contrat de
/// `SecretStore`) : chacun part sur une file série dédiée, jamais sur le fil principal ni sur le pool coopératif.
/// Par défaut, toute l'application partage la même file : deux invites ne s'ouvrent pas en même temps.
public struct SecretAccess: Sendable {
    /// La file par défaut, commune à tout le processus.
    public static let sharedQueue = DispatchQueue(label: "dev.supervox.app.secrets")

    public let store: any SecretStore
    private let queue: DispatchQueue

    /// `queue` : une file propre aux tests qui bloquent volontairement le magasin, pour ne pas retenir les autres.
    public init(_ store: any SecretStore, queue: DispatchQueue = SecretAccess.sharedQueue) {
        self.store = store
        self.queue = queue
    }

    public func read(account: String) async throws -> String? {
        try await run { [store] in try store.read(account: account) }
    }

    public func write(_ secret: String, account: String) async throws {
        try await run { [store] in try store.write(secret, account: account) }
    }

    public func delete(account: String) async throws {
        try await run { [store] in try store.delete(account: account) }
    }

    public func contains(account: String) async throws -> Bool {
        try await run { [store] in try store.contains(account: account) }
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}
