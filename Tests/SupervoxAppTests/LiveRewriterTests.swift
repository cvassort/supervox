import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxApp

/// Modèle de langage double : rend les événements qu'on lui donne, ou lève l'erreur choisie, ou ne finit jamais. Garde les
/// demandes reçues. Aucun réseau.
final class ScriptedModel: LanguageModel {
    enum Script: Sendable {
        case events([CompletionEvent])
        case fails(any Error)
        case never
        /// Livre `before`, attend que la porte s'ouvre, puis livre `after` et finit.
        case gated(TestGate, before: [CompletionEvent], after: [CompletionEvent])
    }

    private let script: Script
    private let seen = Mutex<[CompletionRequest]>([])

    init(_ script: Script) { self.script = script }

    var requests: [CompletionRequest] { seen.withLock { $0 } }

    func complete(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        seen.withLock { $0.append(request) }
        let script = script
        return AsyncThrowingStream { continuation in
            switch script {
            case .events(let events):
                for event in events { continuation.yield(event) }
                continuation.finish()
            case .fails(let error):
                continuation.finish(throwing: error)
            case .never:
                break
            case .gated(let gate, let before, let after):
                Task {
                    for event in before { continuation.yield(event) }
                    await gate.wait()
                    for event in after { continuation.yield(event) }
                    continuation.finish()
                }
            }
        }
    }
}

/// Ce que `makeModel` a reçu : le type de fournisseur, l'adresse et la clé de chaque client fabriqué.
final class MadeModels: Sendable {
    struct Made: Equatable { var kind: ProviderKind; var baseURL: URL; var apiKey: String }
    private let state = Mutex<[Made]>([])
    let model: ScriptedModel

    init(_ script: ScriptedModel.Script) { model = ScriptedModel(script) }

    var made: [Made] { state.withLock { $0 } }

    var make: @Sendable (ProviderKind, EndpointConfig) -> any LanguageModel {
        { [self] kind, config in
            state.withLock { $0.append(Made(kind: kind, baseURL: config.baseURL, apiKey: config.apiKey)) }
            return model
        }
    }
}

/// Les morceaux reçus par `onText`, dans l'ordre.
@MainActor final class Received {
    var texts: [String] = []
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct LiveRewriterTests {
    static let apiKey = "cle-exemple"
    let primary = Provider(
        id: UUID(), name: "Fournisseur exemple", baseURL: "https://example.com/v1", kind: .openAICompatible,
        models: ["modele-exemple"])
    let secondary = Provider(
        id: UUID(), name: "Second exemple", baseURL: "https://example.org/api", kind: .anthropic, models: ["autre-exemple"])

    func settings(
        strong: ModelChoice? = nil, providers: [Provider]? = nil
    ) -> AppSettings {
        var settings = AppSettings.defaults
        settings.providers = providers ?? [primary, secondary]
        settings.strongModel = strong
        return settings
    }

    func choice(_ provider: Provider, _ model: String = "modele-exemple") -> ModelChoice {
        ModelChoice(providerID: provider.id, model: model)
    }

    func job(model: ModelChoice? = nil) -> RewriteJob {
        RewriteJob(instruction: "Mets en forme.", input: "<dictee>\nbonjour\n</dictee>", model: model)
    }

    func secrets(_ entries: [UUID: String] = [:]) -> (SecretAccess, InMemorySecretStore) {
        let store = InMemorySecretStore(secrets: Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) }))
        return (SecretAccess(store, queue: DispatchQueue(label: "test.secrets.\(UUID())")), store)
    }

    func environment(
        _ settings: AppSettings, secrets: SecretAccess, made: MadeModels, policy: RewritePolicy = .standard
    ) -> RewriteEnvironment {
        LiveRewriter.environment(settings: { settings }, secrets: secrets, makeModel: made.make, policy: policy)
    }

    // MARK: - Le modèle

    @Test func theModesModelIsUsedBeforeTheStrongModel() async {
        let made = MadeModels(.events([.text("Bonjour."), .stop(.complete)]))
        let (access, _) = secrets([primary.id: "cle-un", secondary.id: Self.apiKey])
        let env = environment(settings(strong: choice(primary)), secrets: access, made: made)

        let outcome = await env.rewrite(job(model: choice(secondary, "autre-exemple"))) { _ in }

        #expect(outcome == .rewritten("Bonjour."))
        #expect(made.made == [.init(kind: .anthropic, baseURL: URL(string: "https://example.org/api")!, apiKey: Self.apiKey)])
        #expect(made.model.requests.map(\.model) == ["autre-exemple"])
    }

    @Test func withoutAModesModelTheStrongModelIsUsed() async {
        let made = MadeModels(.events([.text("Bonjour."), .stop(.complete)]))
        let (access, _) = secrets([primary.id: Self.apiKey])
        let env = environment(settings(strong: choice(primary)), secrets: access, made: made)

        let outcome = await env.rewrite(job()) { _ in }

        #expect(outcome == .rewritten("Bonjour."))
        #expect(made.made == [.init(kind: .openAICompatible, baseURL: URL(string: "https://example.com/v1")!, apiKey: Self.apiKey)])
        let request = made.model.requests.first
        #expect(request?.model == "modele-exemple")
        #expect(request?.instruction == "Mets en forme.")
        #expect(request?.input == "<dictee>\nbonjour\n</dictee>")
        #expect(request?.maxTokens == RewritePolicy.standard.maxTokens)
    }

    @Test func withNeitherModelTheFailureIsNoModelAndNothingIsSent() async {
        let made = MadeModels(.never)
        let (access, store) = secrets([primary.id: Self.apiKey])
        let env = environment(settings(), secrets: access, made: made)

        #expect(await env.rewrite(job()) { _ in } == .failed(.noModel))
        #expect(made.made.isEmpty)
        #expect(store.readCount == 0, "pas de lecture du trousseau sans modèle")
    }

    @Test func aMissingProviderIsReportedAndNothingIsSent() async {
        let made = MadeModels(.never)
        let (access, _) = secrets([primary.id: Self.apiKey])
        let gone = ModelChoice(providerID: UUID(), model: "modele-exemple")
        let env = environment(settings(strong: choice(primary)), secrets: access, made: made)

        #expect(await env.rewrite(job(model: gone)) { _ in } == .failed(.providerMissing))
        #expect(made.made.isEmpty)
    }

    // MARK: - La clé

    @Test(arguments: [ProviderKind.openAICompatible, .anthropic])
    func anAbsentKeyIsNoKeyForBothKindsAndNoRequestIsMade(kind: ProviderKind) async {
        var provider = primary
        provider.kind = kind
        let made = MadeModels(.never)
        let (access, store) = secrets()
        let env = environment(settings(strong: choice(provider), providers: [provider]), secrets: access, made: made)

        #expect(await env.rewrite(job()) { _ in } == .failed(.noKey(provider: "Fournisseur exemple")))
        #expect(made.made.isEmpty)
        #expect(made.model.requests.isEmpty)
        #expect(store.readCount == 1)
    }

    @Test func aBlankKeyIsAbsent() async {
        let made = MadeModels(.never)
        let (access, _) = secrets([primary.id: " \n"])
        let env = environment(settings(strong: choice(primary)), secrets: access, made: made)

        #expect(await env.rewrite(job()) { _ in } == .failed(.noKey(provider: "Fournisseur exemple")))
        #expect(made.made.isEmpty)
    }

    @Test func aLongProviderNameIsTrimmedWithTheSharedRuleInTheNoKeyFailure() async {
        var provider = primary
        provider.name = String(repeating: "N", count: 60)
        let made = MadeModels(.never)
        let (access, _) = secrets()
        let env = environment(settings(strong: choice(provider), providers: [provider]), secrets: access, made: made)

        #expect(await env.rewrite(job()) { _ in } == .failed(.noKey(provider: Provider.shortName(provider.name))))
    }

    @Test(arguments: [SecretError.denied, .unavailable(status: -25293)])
    func aKeychainThatRefusesIsKeychainAndNothingIsSent(failure: SecretError) async {
        let made = MadeModels(.never)
        let (access, store) = secrets([primary.id: Self.apiKey])
        store.failure = failure
        let env = environment(settings(strong: choice(primary)), secrets: access, made: made)

        #expect(await env.rewrite(job()) { _ in } == .failed(.keychain))
        #expect(made.made.isEmpty)
    }

    @Test func theKeyIsReadOffTheMainThread() async {
        // Le magasin est lu par `SecretAccess`, sur sa file : jamais sur le fil principal.
        final class ThreadStore: SecretStore {
            let onMain = Mutex<[Bool]>([])
            func read(account: String) throws -> String? {
                onMain.withLock { $0.append(Thread.isMainThread) }
                return "cle-exemple"
            }
            func write(_ secret: String, account: String) throws {}
            func delete(account: String) throws {}
            func contains(account: String) throws -> Bool { true }
        }
        let store = ThreadStore()
        let made = MadeModels(.events([.text("Ok."), .stop(.complete)]))
        let env = environment(
            settings(strong: choice(primary)), secrets: SecretAccess(store, queue: DispatchQueue(label: "test.thread")), made: made)

        _ = await env.rewrite(job()) { _ in }
        #expect(store.onMain.withLock { $0 } == [false])
    }

    // MARK: - L'adresse

    @Test(arguments: ["http://example.com/v1", "pas une adresse", "", "ftp://example.com"])
    func anAddressRefusedByTheProvidersRulesIsUnreachableAndNothingIsSent(address: String) async {
        var provider = primary
        provider.baseURL = address
        let made = MadeModels(.never)
        let (access, _) = secrets([provider.id: Self.apiKey])
        let env = environment(settings(strong: choice(provider), providers: [provider]), secrets: access, made: made)

        #expect(await env.rewrite(job()) { _ in } == .failed(.unreachable))
        #expect(made.made.isEmpty)
        #expect(made.model.requests.isEmpty)
    }

    // MARK: - La réponse

    @Test func theChunksArriveInOrderBeforeTheOutcome() async {
        let made = MadeModels(.events([.text("Bon"), .text("jour"), .text(" à tous."), .stop(.complete)]))
        let (access, _) = secrets([primary.id: Self.apiKey])
        let env = environment(settings(strong: choice(primary)), secrets: access, made: made)
        let received = Received()

        let outcome = await env.rewrite(job()) { received.texts.append($0) }

        #expect(outcome == .rewritten("Bonjour à tous."))
        #expect(received.texts == ["Bon", "Bonjour", "Bonjour à tous."])
    }

    @Test(arguments: [
        (ScriptedModel.Script.fails(EndpointError.http(status: 503, body: "corps-secret")), RewriteFailure.server(503)),
        (.fails(EndpointError.http(status: 401, body: "")), .unauthorized(401)),
        (.fails(EndpointError.transport("x")), .unreachable),
        (.events([.stop(.truncated)]), .truncated),
        (.events([.stop(.refused)]), .refused),
        (.events([.text("   "), .stop(.complete)]), .empty),
    ])
    func aModelFailureIsTheMatchingRewriteFailure(script: ScriptedModel.Script, expected: RewriteFailure) async {
        let made = MadeModels(script)
        let (access, _) = secrets([primary.id: Self.apiKey])
        let env = environment(settings(strong: choice(primary)), secrets: access, made: made)

        #expect(await env.rewrite(job()) { _ in } == .failed(expected))
    }

    @Test func aResponseThatNeverEndsFailsWhenTheDeadlineIsReached() async {
        let made = MadeModels(.never)
        let (access, _) = secrets([primary.id: Self.apiKey])
        // Le délai tombe aussitôt : aucune attente réelle.
        let policy = RewritePolicy(maxTokens: 100, timeout: 120, sleep: { _ in })
        let env = environment(settings(strong: choice(primary)), secrets: access, made: made, policy: policy)

        #expect(await env.rewrite(job()) { _ in } == .failed(.timedOut(120)))
    }

    @Test func aCancelledTaskIsCancelledNotAFailure() async {
        let made = MadeModels(.never)
        let (access, _) = secrets([primary.id: Self.apiKey])
        let env = environment(settings(strong: choice(primary)), secrets: access, made: made)

        let task = Task { await env.rewrite(job()) { _ in } }
        #expect(await until { !made.model.requests.isEmpty })
        task.cancel()
        #expect(await task.value == .cancelled)
    }

    // MARK: - Le nom du fournisseur

    @Test func theProviderNameIsTheEffectiveProvidersName() {
        let (access, _) = secrets()
        let env = environment(settings(strong: choice(primary)), secrets: access, made: MadeModels(.never))

        #expect(env.providerName(nil) == "Fournisseur exemple", "le modèle fort")
        #expect(env.providerName(choice(secondary, "autre-exemple")) == "Second exemple", "le modèle du mode")
        #expect(env.providerName(ModelChoice(providerID: UUID(), model: "m")) == nil, "fournisseur disparu")
        let none = environment(settings(), secrets: access, made: MadeModels(.never))
        #expect(none.providerName(nil) == nil, "aucun modèle")
    }

    @Test func theUnavailableEnvironmentFailsForLackOfAModel() async {
        let env = RewriteEnvironment.unavailable
        #expect(await env.rewrite(job()) { _ in } == .failed(.noModel))
        #expect(env.providerName(nil) == nil)
    }
}
