import Foundation
import SupervoxCore
import Testing

@testable import SupervoxApp

/// Ce que `LiveRewriter` fait de ce que lève la résolution du fournisseur, par un résolveur double : les trois sortes d'erreurs.
@MainActor @Suite(.timeLimit(.minutes(1))) struct LiveRewriterResolverTests {
    struct StrangeError: Error { let text = "texte-secret-de-l-erreur" }

    let provider = Provider(
        id: UUID(), name: "Fournisseur d'exemple", baseURL: "https://exemple.invalid/v1", kind: .openAICompatible,
        models: ["modele-exemple"])

    func outcome(resolving resolve: @escaping ProviderResolution, made: SetupLikeModels) async -> RewriteOutcome {
        var settings = AppSettings.defaults
        settings.providers = [provider]
        settings.strongModel = ModelChoice(providerID: provider.id, model: "modele-exemple")
        let access = SecretAccess(InMemorySecretStore(), queue: DispatchQueue(label: "test.rewriter.resolver.\(UUID())"))
        let environment = LiveRewriter.environment(
            settings: { settings }, secrets: access, makeModel: made.make, resolve: resolve)
        let job = RewriteJob(instruction: "Mets en forme.", input: "<dictee>\nbonjour\n</dictee>", model: nil)
        return await environment.rewrite(job) { _ in }
    }

    @Test("une erreur que le résolveur ne doit pas lever est une panne dite, jamais une annulation, et rien du texte de l'erreur")
    func anUnexpectedErrorIsAFailureNotACancellation() async {
        let made = SetupLikeModels()

        let result = await outcome(resolving: { _, _, _ in throw StrangeError() }, made: made)

        #expect(result == .failed(.malformed))
        #expect(made.count == 0, "aucun client n'est fabriqué")
        #expect(!String(describing: result).contains("texte-secret-de-l-erreur"))
    }

    @Test func aCancellationFromTheResolverIsCancelled() async {
        let made = SetupLikeModels()
        let result = await outcome(resolving: { _, _, _ in throw CancellationError() }, made: made)
        #expect(result == .cancelled)
        #expect(made.count == 0)
    }

    @Test func aRewriteFailureFromTheResolverIsReportedAsIs() async {
        let made = SetupLikeModels()
        let result = await outcome(resolving: { _, _, _ in throw RewriteFailure.keychain }, made: made)
        #expect(result == .failed(.keychain))
        #expect(made.count == 0)
    }
}

/// Compte les clients que `makeModel` a fabriqués.
final class SetupLikeModels: Sendable {
    private let made = MadeModels(.never)
    var count: Int { made.made.count }
    var make: @Sendable (ProviderKind, EndpointConfig) -> any LanguageModel { made.make }
}
