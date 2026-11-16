import Foundation
import SupervoxCore
import os

/// La vraie mise en forme : retrouve le modèle, le fournisseur et la clé dans les réglages et le trousseau, puis lit la
/// réponse du modèle en flux (`Rewriter`).
///
/// Le texte dicté et la clé ne sont écrits dans aucun journal : une panne n'y laisse que sa nature (le nom du cas). La clé est
/// lue par `SecretAccess` (jamais sur le fil principal) et part dans l'`EndpointConfig` du client, nulle part ailleurs.
public enum LiveRewriter {
    /// Le client du type de fournisseur, sur son adresse et sa clé.
    public static let client: @Sendable (ProviderKind, EndpointConfig) -> any LanguageModel = { kind, config in
        switch kind {
        case .openAICompatible: OpenAICompatibleClient(config: config)
        case .anthropic: AnthropicClient(config: config)
        }
    }

    private static let log = Logger(subsystem: "dev.supervox.app", category: "rewrite")

    /// - Parameters:
    ///   - settings: les réglages en vigueur, relus à chaque mise en forme.
    ///   - secrets: l'accès aux clés des fournisseurs (compte : l'identifiant du fournisseur).
    ///   - makeModel: fabrique le client ; injectée pour que les tests n'ouvrent aucune connexion.
    ///   - policy: les bornes d'une réécriture.
    public static func environment(
        settings: @escaping @MainActor () -> AppSettings, secrets: SecretAccess,
        makeModel: @escaping @Sendable (ProviderKind, EndpointConfig) -> any LanguageModel = LiveRewriter.client,
        policy: RewritePolicy = .standard
    ) -> RewriteEnvironment {
        RewriteEnvironment(
            rewrite: { job, onText in
                let outcome = await rewrite(
                    job, settings: settings(), secrets: secrets, makeModel: makeModel, policy: policy, onText: onText)
                if case .failed(let failure) = outcome { log.notice("mise en forme échouée : \(kind(of: failure), privacy: .public)") }
                return outcome
            },
            providerName: { choice in
                let current = settings()
                guard let choice = choice ?? current.strongModel else { return nil }
                return current.providers.first { $0.id == choice.providerID }?.name
            })
    }

    @MainActor
    private static func rewrite(
        _ job: RewriteJob, settings: AppSettings, secrets: SecretAccess,
        makeModel: @Sendable (ProviderKind, EndpointConfig) -> any LanguageModel, policy: RewritePolicy,
        onText: @escaping @MainActor (String) -> Void
    ) async -> RewriteOutcome {
        guard let choice = job.model ?? settings.strongModel else { return .failed(.noModel) }
        guard let provider = settings.providers.first(where: { $0.id == choice.providerID }) else {
            return .failed(.providerMissing)
        }
        // L'adresse avant la clé : une adresse refusée ne coûte pas une invite du trousseau.
        guard let address = try? ProvidersModel.validatedBaseURL(provider.baseURL), let url = URL(string: address) else {
            return .failed(.unreachable)
        }
        let key: String?
        do {
            key = try await secrets.read(account: provider.id.uuidString)
        } catch {
            return Task.isCancelled ? .cancelled : .failed(.keychain)
        }
        if Task.isCancelled { return .cancelled }
        guard let apiKey = key?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            return .failed(.noKey(provider: Provider.shortName(provider.name)))
        }
        let model = makeModel(provider.kind, EndpointConfig(baseURL: url, apiKey: apiKey))

        // Les morceaux passent par un flux ordonné jusqu'au fil principal, et tous sont rendus avant l'issue : aucun ne la suit.
        let (texts, sink) = AsyncStream<String>.makeStream()
        let pump = Task { @MainActor in for await text in texts { onText(text) } }
        let outcome: RewriteOutcome
        do {
            let text = try await Rewriter.run(
                model, model: choice.model, instruction: job.instruction, input: job.input, policy: policy,
                onText: { sink.yield($0) })
            outcome = Task.isCancelled ? .cancelled : .rewritten(text)
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            outcome = .failed(RewriteFailure.from(error))
        }
        sink.finish()
        await pump.value
        return outcome
    }

    /// La nature d'une panne pour le journal : le nom du cas, jamais ses valeurs.
    private static func kind(of failure: RewriteFailure) -> String {
        String(String(describing: failure).prefix { $0 != "(" })
    }
}
