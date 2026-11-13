import Foundation
import Synchronization

/// Pourquoi un secret n'a pas pu être lu ou écrit. Ne porte jamais la valeur d'un secret.
public enum SecretError: Error, Equatable, Sendable {
    /// L'utilisateur a refusé l'accès, ou l'authentification a échoué.
    case denied
    /// Le magasin est inutilisable ; `status` est le code `OSStatus` du système.
    case unavailable(status: Int32)
}

extension SecretError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .denied: "Accès au trousseau refusé"
        case .unavailable(let status): "Trousseau indisponible (statut \(status))"
        }
    }

    public var errorDescription: String? { description }
}

/// Un magasin de secrets (clés d'API), indexé par compte. Le compte d'un fournisseur est
/// `provider.id.uuidString`.
public protocol SecretStore: Sendable {
    /// `nil` si aucun secret n'existe pour ce compte ; une erreur seulement si le magasin a échoué.
    func read(account: String) throws -> String?
    /// Crée le secret, ou remplace celui qui existe.
    func write(_ secret: String, account: String) throws
    /// Supprimer un secret absent n'est pas une erreur.
    func delete(account: String) throws
}

/// Magasin en mémoire, pour les tests. Sûr en accès concurrent.
public final class InMemorySecretStore: SecretStore {
    private struct State {
        var secrets: [String: String]
        var readCount = 0
        var failure: SecretError?
    }

    private let state: Mutex<State>

    public init(secrets: [String: String] = [:]) {
        state = Mutex(State(secrets: secrets))
    }

    /// Nombre d'appels à `read`, ceux qui échouent compris.
    public var readCount: Int { state.withLock { $0.readCount } }

    /// Si défini, `read`, `write` et `delete` lèvent cette erreur sans rien modifier.
    public var failure: SecretError? {
        get { state.withLock { $0.failure } }
        set { state.withLock { $0.failure = newValue } }
    }

    public func read(account: String) throws -> String? {
        try state.withLock { state in
            state.readCount += 1
            if let failure = state.failure { throw failure }
            return state.secrets[account]
        }
    }

    public func write(_ secret: String, account: String) throws {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            state.secrets[account] = secret
        }
    }

    public func delete(account: String) throws {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            state.secrets[account] = nil
        }
    }
}

extension InMemorySecretStore: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "InMemorySecretStore" }
    public var debugDescription: String { description }
    /// Ni `dump` ni le débogueur ne montrent les secrets gardés.
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// Garde en mémoire ce que le magasin dessous a répondu, pour ne l'interroger qu'une fois par compte.
/// Avec le trousseau, chaque lecture peut afficher une invite : on lit à la demande, jamais d'avance.
///
/// Une lecture réussie est gardée, y compris « aucun secret » (`nil`). Une erreur n'est jamais gardée :
/// la lecture suivante réessaie. Le verrou est tenu pendant l'appel au magasin dessous : deux lectures
/// simultanées d'un même compte n'interrogent donc le trousseau (et n'affichent l'invite) qu'une fois.
public final class CachedSecretStore: SecretStore {
    private enum Entry {
        case present(String)
        case absent
    }

    private let underlying: any SecretStore
    private let cache = Mutex<[String: Entry]>([:])

    /// Ne lit rien : la première lecture a lieu au premier `read`.
    public init(_ underlying: any SecretStore) {
        self.underlying = underlying
    }

    public func read(account: String) throws -> String? {
        try cache.withLock { cache in
            switch cache[account] {
            case .present(let secret): return secret
            case .absent: return nil
            case nil: break
            }
            let secret = try underlying.read(account: account)
            cache[account] = secret.map(Entry.present) ?? .absent
            return secret
        }
    }

    public func write(_ secret: String, account: String) throws {
        try cache.withLock { cache in
            // Si l'écriture échoue, on ne sait plus ce que contient le magasin : on oublie ce compte.
            cache[account] = nil
            try underlying.write(secret, account: account)
            cache[account] = .present(secret)
        }
    }

    public func delete(account: String) throws {
        try cache.withLock { cache in
            cache[account] = nil
            try underlying.delete(account: account)
            cache[account] = .absent
        }
    }
}

extension CachedSecretStore: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "CachedSecretStore" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
