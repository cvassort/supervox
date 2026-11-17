import Foundation
import SupervoxCore

/// Un fournisseur prêt à servir : son type, son adresse et sa clé (dans `config`, qui ne se laisse pas imprimer), et son nom tel
/// que l'utilisateur l'a saisi (les phrases le rognent par `Provider.shortName`).
public struct ResolvedProvider: Sendable {
    public var kind: ProviderKind
    public var config: EndpointConfig
    public var name: String

    public init(kind: ProviderKind, config: EndpointConfig, name: String) {
        self.kind = kind
        self.config = config
        self.name = name
    }
}

/// Retrouve un fournisseur dans les réglages, vérifie son adresse, puis lit sa clé. Commun à la mise en forme (`LiveRewriter`) et à
/// l'entretien (`InterviewSetup`) : une seule règle, dans un seul ordre.
public enum ProviderResolver {
    /// L'ordre est celui de la mise en forme : le fournisseur, l'adresse, puis la clé (une adresse refusée ne coûte pas une invite du
    /// trousseau). La clé est lue par `SecretAccess`, sur sa file : jamais sur le fil principal.
    ///
    /// - Throws: `RewriteFailure` (`.providerMissing`, `.unreachable`, `.keychain`, `.noKey`), ou `CancellationError` si la tâche est
    ///   annulée pendant ou après la lecture de la clé (aucune clé n'est alors rendue, même lue).
    @MainActor
    public static func resolve(
        _ providerID: UUID, settings: AppSettings, secrets: SecretAccess
    ) async throws -> ResolvedProvider {
        guard let provider = settings.providers.first(where: { $0.id == providerID }) else {
            throw RewriteFailure.providerMissing
        }
        guard let address = try? ProvidersModel.validatedBaseURL(provider.baseURL), let url = URL(string: address) else {
            throw RewriteFailure.unreachable
        }
        let key: String?
        do {
            key = try await secrets.read(account: provider.id.uuidString)
        } catch {
            // Une lecture qui échoue parce que la tâche est annulée n'est pas une panne du trousseau.
            if Task.isCancelled { throw CancellationError() }
            throw RewriteFailure.keychain
        }
        try Task.checkCancellation()
        guard let apiKey = key?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw RewriteFailure.noKey(provider: Provider.shortName(provider.name))
        }
        return ResolvedProvider(
            kind: provider.kind, config: EndpointConfig(baseURL: url, apiKey: apiKey), name: provider.name)
    }
}
