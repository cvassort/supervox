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
    ///   - resolve: retrouve le fournisseur, vérifie l'adresse et lit la clé ; `ProviderResolver.resolve`, ou un double.
    public static func environment(
        settings: @escaping @MainActor () -> AppSettings, secrets: SecretAccess,
        makeModel: @escaping @Sendable (ProviderKind, EndpointConfig) -> any LanguageModel = LiveRewriter.client,
        policy: RewritePolicy = .standard, resolve: @escaping ProviderResolution = ProviderResolver.resolve
    ) -> RewriteEnvironment {
        RewriteEnvironment(
            rewrite: { job, onText in
                let outcome = await rewrite(
                    job, settings: settings(), secrets: secrets, makeModel: makeModel, policy: policy, resolve: resolve,
                    onText: onText)
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
        resolve: ProviderResolution, onText: @escaping @MainActor (String) -> Void
    ) async -> RewriteOutcome {
        guard let choice = job.model ?? settings.strongModel else { return .failed(.noModel) }
        // Le fournisseur, l'adresse, puis la clé : l'ordre et les refus sont ceux de `ProviderResolver`.
        let resolved: ResolvedProvider
        do {
            resolved = try await resolve(choice.providerID, settings, secrets)
        } catch let failure as RewriteFailure {
            return .failed(failure)
        } catch is CancellationError {
            return .cancelled
        } catch {
            // Une erreur que le résolveur ne doit pas lever : une panne dite, jamais une annulation que personne n'a demandée. `.malformed`
            // est le cas que `RewriteFailure.from` rend déjà pour une erreur inconnue ; la phrase ne reprend rien de l'erreur.
            return .failed(RewriteFailure.from(error))
        }
        let model = makeModel(resolved.kind, resolved.config)

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
    static func kind(of failure: RewriteFailure) -> String {
        String(String(describing: failure).prefix { $0 != "(" })
    }
}
