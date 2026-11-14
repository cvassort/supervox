import Foundation
import Synchronization

/// Pourquoi un secret n'a pas pu être lu ou écrit. Ne porte jamais la valeur d'un secret.
public enum SecretError: Error, Equatable, Sendable {
    /// L'utilisateur a refusé l'accès, ou l'authentification a échoué.
    case denied
    /// Le magasin est inutilisable ; `status` est le code `OSStatus` du système.
    case unavailable(status: Int32)
    /// Un secret vide a été présenté à `write` : refusé, rien n'est écrit ni oublié. Pour effacer, on appelle `delete`.
    case emptySecret
}

extension SecretError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .denied: "Accès au trousseau refusé"
        case .unavailable(let status): "Trousseau indisponible (statut \(status))"
        case .emptySecret: "Un secret vide n'est pas enregistré"
        }
    }

    public var errorDescription: String? { description }
}

extension SecretError {
    /// Garde commune des `write` : un secret vide est refusé avant tout effet.
    static func rejectEmpty(_ secret: String) throws {
        if secret.isEmpty { throw SecretError.emptySecret }
    }
}

/// Un magasin de secrets (clés d'API), indexé par compte. Le compte d'un fournisseur est
/// `provider.id.uuidString`.
///
/// Contrat de l'appelant :
/// - `read`, `write` et `delete` peuvent bloquer le temps qu'une invite du trousseau reçoive une réponse :
///   ne jamais les appeler depuis le fil principal ni depuis un acteur d'interface, de préférence sur une
///   file dédiée plutôt que sur le pool coopératif.
/// - Ne pas boucler sur `.denied` : chaque nouvel appel rouvre l'invite. Remonter l'erreur à l'interface
///   et attendre une action de l'utilisateur.
/// - Partager une seule instance de `CachedSecretStore` par service : deux instances ont des caches
///   indépendants.
public protocol SecretStore: Sendable {
    /// `nil` si aucun secret n'existe pour ce compte ; une erreur seulement si le magasin a échoué.
    func read(account: String) throws -> String?
    /// Crée le secret, ou remplace celui qui existe. Un secret vide lève `SecretError.emptySecret`.
    func write(_ secret: String, account: String) throws
    /// Supprimer un secret absent n'est pas une erreur.
    func delete(account: String) throws
    /// Dit si un secret existe pour ce compte, sans lire sa valeur. Peut bloquer comme `read` : même contrat.
    func contains(account: String) throws -> Bool
}

/// Magasin en mémoire, pour les tests. Sûr en accès concurrent.
public final class InMemorySecretStore: SecretStore {
    private struct State {
        var secrets: [String: String]
        var readCount = 0
        var containsCount = 0
        var failure: SecretError?
    }

    private let state: Mutex<State>

    public init(secrets: [String: String] = [:]) {
        state = Mutex(State(secrets: secrets))
    }

    /// Nombre d'appels à `contains`, ceux qui échouent compris. Ils ne comptent pas dans `readCount`.
    public var containsCount: Int { state.withLock { $0.containsCount } }

    public func contains(account: String) throws -> Bool {
        try state.withLock { state in
            state.containsCount += 1
            if let failure = state.failure { throw failure }
            return state.secrets[account] != nil
        }
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
        try SecretError.rejectEmpty(secret)
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


/// Garde en mémoire ce que le magasin dessous a répondu, pour ne l'interroger qu'une fois par compte.
/// Avec le trousseau, chaque lecture peut afficher une invite : on lit à la demande, jamais d'avance.
///
/// Une lecture réussie est gardée, y compris « aucun secret » (`nil`). Une erreur n'est jamais gardée :
/// la lecture suivante réessaie. Le cache n'est invalidé que par `write` et `delete` de cette instance :
/// une clé changée hors du processus (app « Trousseaux d'accès », autre instance) n'est vue qu'au redémarrage.
/// Le verrou est tenu pendant l'appel au magasin dessous : deux lectures
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
        try SecretError.rejectEmpty(secret)
        try cache.withLock { cache in
            // Si l'écriture échoue, on ne sait plus ce que contient le magasin : on oublie ce compte.
            cache[account] = nil
            try underlying.write(secret, account: account)
            cache[account] = .present(secret)
        }
    }

    /// Répond d'après le cache s'il connaît ce compte ; sinon demande au magasin dessous, sans lire la valeur.
    /// Une absence est gardée (comme celle vue par `read`) ; une présence ne l'est pas, faute de valeur.
    public func contains(account: String) throws -> Bool {
        try cache.withLock { cache in
            switch cache[account] {
            case .present: return true
            case .absent: return false
            case nil: break
            }
            let exists = try underlying.contains(account: account)
            if !exists { cache[account] = .absent }
            return exists
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

