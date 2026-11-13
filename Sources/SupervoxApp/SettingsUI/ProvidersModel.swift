import Foundation
import Observation
import SupervoxCore

/// Où en est la dernière lecture de la liste des modèles d'un fournisseur.
public enum ProviderStatus: Equatable, Sendable {
    case idle, loading, ok(count: Int), failed(String)
}

/// Ce que l'on sait de la clé d'un fournisseur sans l'avoir relue pour l'afficher.
public enum KeyState: Equatable, Sendable {
    /// Rien n'a été écrit ni lu pendant cette session : le trousseau n'est pas interrogé pour le savoir.
    case unknown
    case present
    case absent
}

/// Refus d'une saisie dans la fenêtre de réglages, ou effet resté à moitié.
public enum ProvidersError: Error, Equatable, LocalizedError {
    case emptyName
    case invalidAddress
    /// Adresse `http` vers un autre hôte que `localhost` ou `127.0.0.1`.
    case cleartextAddress
    case keyRequired
    case unknownProvider
    /// Les réglages sont enregistrés, mais la nouvelle clé n'a pas pu l'être ; le texte est la cause.
    case keyNotSaved(String)
    /// Le fournisseur est supprimé, mais sa clé est restée dans le trousseau ; le texte est la cause.
    case keyNotDeleted(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Donnez un nom au fournisseur."
        case .invalidAddress: "Adresse invalide : saisissez une adresse complète qui commence par https://."
        case .cleartextAddress:
            "Adresse en http vers un autre ordinateur : la clé voyagerait en clair. Utilisez https:// (http:// n'est permis que pour localhost et 127.0.0.1)."
        case .keyRequired: "Saisissez la clé d'API de ce fournisseur."
        case .unknownProvider: "Ce fournisseur n'existe plus."
        case .keyNotSaved(let cause): "Réglages enregistrés, mais la nouvelle clé ne l'est pas : \(cause)"
        case .keyNotDeleted(let cause): "Fournisseur supprimé, mais sa clé reste dans le trousseau : \(cause)"
        }
    }
}

/// Les fournisseurs de modèles tels que la fenêtre de réglages les montre et les modifie.
///
/// Les clés vivent dans le magasin de secrets, sous le compte `provider.id.uuidString`, jamais dans les
/// réglages. Construire le modèle et lire ses états ne lit aucune clé : la seule lecture a lieu dans
/// `refreshModels`. Tout appel au magasin passe par une file dédiée, hors du fil principal, parce qu'il
/// peut attendre la réponse à une invite du trousseau.
///
/// `providers` reflète toujours ce qui est enregistré : il ne change qu'après un `save` réussi.
@MainActor @Observable
public final class ProvidersModel {
    public typealias ListModels = @Sendable (Provider, String) async throws -> [String]

    public private(set) var providers: [Provider]
    public private(set) var status: [UUID: ProviderStatus] = [:]
    private var keyStates: [UUID: KeyState] = [:]

    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let listModels: ListModels
    @ObservationIgnored private let save: ([Provider]) throws -> Void

    /// `save` enregistre la liste complète des fournisseurs ; s'il lève, rien ne change en mémoire.
    public init(
        providers: [Provider], secrets: any SecretStore, listModels: @escaping ListModels,
        save: @escaping ([Provider]) throws -> Void
    ) {
        self.providers = providers
        self.secrets = secrets
        self.listModels = listModels
        self.save = save
    }

    public func status(of id: UUID) -> ProviderStatus { status[id] ?? .idle }

    public func keyState(_ id: UUID) -> KeyState { keyStates[id] ?? .unknown }

    // MARK: - Modifications

    /// Une clé vide n'est permise que pour le type `openAICompatible` (serveur local sans authentification) :
    /// rien n'est alors écrit. Sinon la clé est écrite d'abord, puis les réglages ; si l'enregistrement
    /// échoue, la clé est retirée et l'erreur remonte.
    public func add(name: String, baseURL: String, kind: ProviderKind, key: String) async throws {
        let name = try Self.validatedName(name)
        let baseURL = try Self.validatedBaseURL(baseURL)
        let key = Self.trimmed(key)
        if key.isEmpty, kind != .openAICompatible { throw ProvidersError.keyRequired }

        let provider = Provider(id: UUID(), name: name, baseURL: baseURL, kind: kind, models: [])
        let account = provider.id.uuidString
        if !key.isEmpty {
            try await Self.secretsQueue { [secrets] in try secrets.write(key, account: account) }
        }
        do {
            try commit(providers + [provider])
        } catch {
            if !key.isEmpty {
                try? await Self.secretsQueue { [secrets] in try secrets.delete(account: account) }
            }
            throw error
        }
        keyStates[provider.id] = key.isEmpty ? .absent : .present
    }

    /// Remplace le nom, l'adresse et le type du fournisseur de même identifiant. `newKey` vide ou `nil` :
    /// la clé enregistrée ne change pas. Les réglages sont enregistrés d'abord (une clé remplacée ne se
    /// restaure pas), puis la clé. Une nouvelle adresse ou un nouveau type vident la liste des modèles,
    /// qui était celle de l'ancien endpoint.
    public func update(_ provider: Provider, newKey: String?) async throws {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else {
            throw ProvidersError.unknownProvider
        }
        var changed = provider
        changed.name = try Self.validatedName(provider.name)
        changed.baseURL = try Self.validatedBaseURL(provider.baseURL)
        let current = providers[index]
        let endpointChanged = changed.baseURL != current.baseURL || changed.kind != current.kind
        // La liste des modèles ne vient que de `refreshModels` : celle de `provider` peut dater de l'ouverture
        // de la feuille d'édition.
        changed.models = endpointChanged ? [] : current.models

        var updated = providers
        updated[index] = changed
        try commit(updated)
        if endpointChanged { status[provider.id] = nil }

        let key = Self.trimmed(newKey ?? "")
        guard !key.isEmpty else { return }
        let account = provider.id.uuidString
        do {
            try await Self.secretsQueue { [secrets] in try secrets.write(key, account: account) }
            keyStates[provider.id] = .present
        } catch {
            keyStates[provider.id] = .unknown
            throw ProvidersError.keyNotSaved(Self.message(for: error))
        }
    }

    /// Retire le fournisseur des réglages, puis sa clé du trousseau.
    public func remove(_ id: UUID) async throws {
        guard providers.contains(where: { $0.id == id }) else { throw ProvidersError.unknownProvider }
        try commit(providers.filter { $0.id != id })
        status[id] = nil
        keyStates[id] = nil
        let account = id.uuidString
        do {
            try await Self.secretsQueue { [secrets] in try secrets.delete(account: account) }
        } catch {
            throw ProvidersError.keyNotDeleted(Self.message(for: error))
        }
    }

    // MARK: - Liste des modèles

    /// Lit la clé (hors du fil principal), demande la liste au serveur, l'enregistre. En cas d'échec,
    /// la liste précédente est gardée et `status` dit pourquoi. Sans effet si une lecture est déjà en cours.
    public func refreshModels(_ id: UUID) async {
        guard let provider = providers.first(where: { $0.id == id }), status(of: id) != .loading else { return }
        status[id] = .loading

        let outcome: ProviderStatus
        do {
            let account = id.uuidString
            let key = try await Self.secretsQueue { [secrets] in try secrets.read(account: account) }
            outcome = try await refreshed(provider, key: key)
        } catch is CancellationError {
            outcome = .idle
        } catch {
            outcome = .failed(Self.message(for: error))
        }
        // Le fournisseur a pu être supprimé entre-temps : on n'écrit pas d'état pour un absent.
        guard providers.contains(where: { $0.id == id }) else { return }
        status[id] = outcome
    }

    /// Suite de `refreshModels` une fois la clé lue (`nil` : aucune clé enregistrée).
    private func refreshed(_ provider: Provider, key: String?) async throws -> ProviderStatus {
        guard let key else {
            keyStates[provider.id] = .absent
            switch provider.kind {
            case .openAICompatible:
                return .failed("La liste des modèles sans clé n'est pas encore prise en charge.")
            case .anthropic:
                return .failed("Aucune clé enregistrée : modifiez le fournisseur pour en saisir une.")
            }
        }
        keyStates[provider.id] = .present
        let models = try await listModels(provider, key)

        // Pendant l'attente, le fournisseur a pu être supprimé ou pointer ailleurs : la liste ne vaut plus.
        guard let index = providers.firstIndex(where: { $0.id == provider.id }),
            providers[index].baseURL == provider.baseURL, providers[index].kind == provider.kind
        else { return .idle }
        var updated = providers
        updated[index].models = models
        try commit(updated)
        return .ok(count: models.count)
    }

    // MARK: - Messages

    /// Message en français pour l'utilisateur. Ni le corps d'une réponse ni le détail technique d'une panne
    /// de transport ne sont repris.
    public static func message(for error: any Error) -> String {
        switch error {
        case EndpointError.http(let status, _) where status == 401 || status == 403:
            return "Clé refusée par le serveur (HTTP \(status)) : vérifiez la clé."
        case EndpointError.http(404, _):
            return "Adresse introuvable sur ce serveur (HTTP 404) : vérifiez l'adresse."
        case EndpointError.http(let status, _):
            return "Le serveur a répondu par une erreur HTTP \(status)."
        case EndpointError.transport:
            return "Serveur injoignable : vérifiez l'adresse et la connexion."
        case EndpointError.malformedResponse:
            return "La réponse n'est pas une liste de modèles : vérifiez l'adresse et le type."
        case EndpointError.streamInterrupted:
            return "La réponse du serveur a été interrompue."
        case EndpointError.missingVariable:
            return "Erreur inattendue de configuration."
        case SecretError.denied:
            return "Accès au trousseau refusé : autorisez Supervox dans l'invite du trousseau, puis réessayez."
        case let error as SecretError:
            return error.description + "."
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Validation

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validatedName(_ name: String) throws -> String {
        let name = trimmed(name)
        if name.isEmpty { throw ProvidersError.emptyName }
        return name
    }

    /// Adresse complète en `https`, ou en `http` seulement vers `localhost` ou `127.0.0.1` : ailleurs, la clé
    /// voyagerait en clair. Rend l'adresse sans les espaces autour.
    static func validatedBaseURL(_ text: String) throws -> String {
        let text = trimmed(text)
        guard let components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = components.host?.lowercased(), !host.isEmpty
        else { throw ProvidersError.invalidAddress }
        if scheme == "http", host != "localhost", host != "127.0.0.1" { throw ProvidersError.cleartextAddress }
        return text
    }

    // MARK: - Enregistrement et trousseau

    private func commit(_ updated: [Provider]) throws {
        try save(updated)
        providers = updated
    }

    /// File série dédiée aux appels du magasin de secrets, qui peuvent bloquer sur une invite du trousseau.
    private nonisolated static let queue = DispatchQueue(label: "dev.supervox.app.settings-secrets")

    private nonisolated static func secretsQueue<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    // MARK: - Réalisation

    /// La vraie liste des modèles : `ModelLister` sur l'adresse et le type du fournisseur.
    public static let live: ListModels = { provider, key in
        guard let url = URL(string: provider.baseURL) else { throw EndpointError.transport("adresse inutilisable") }
        let kind: ModelListingKind =
            switch provider.kind {
            case .openAICompatible: .openAICompatible
            case .anthropic: .anthropic
            }
        return try await ModelLister(config: EndpointConfig(baseURL: url, apiKey: key), kind: kind).listModels()
    }
}
