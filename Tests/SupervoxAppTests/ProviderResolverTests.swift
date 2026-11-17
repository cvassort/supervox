import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxApp

/// Un trousseau qui ne répond pas tant que le test ne le libère pas (l'invite que la personne n'a pas encore fermée), puis rend
/// la clé ou lève.
private final class HeldStore: SecretStore {
    let asked = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    let key: String?
    let failure: SecretError?

    init(key: String? = "cle-exemple", failure: SecretError? = nil) {
        self.key = key
        self.failure = failure
    }

    func read(account: String) throws -> String? {
        asked.withLock { $0 = true }
        release.wait()
        if let failure { throw failure }
        return key
    }
    func write(_ secret: String, account: String) throws {}
    func delete(account: String) throws {}
    func contains(account: String) throws -> Bool { true }
}

/// Un trousseau qui note le fil de chaque lecture.
private final class ThreadStore: SecretStore {
    let onMain = Mutex<[Bool]>([])
    func read(account: String) throws -> String? {
        onMain.withLock { $0.append(Thread.isMainThread) }
        return "cle-exemple"
    }
    func write(_ secret: String, account: String) throws {}
    func delete(account: String) throws {}
    func contains(account: String) throws -> Bool { true }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct ProviderResolverTests {
    static let apiKey = "cle-exemple"
    let provider = Provider(
        id: UUID(), name: "Fournisseur d'exemple", baseURL: "https://exemple.invalid/v1", kind: .openAICompatible,
        models: ["modele-exemple"])

    func settings(_ providers: [Provider]? = nil) -> AppSettings {
        var settings = AppSettings.defaults
        settings.providers = providers ?? [provider]
        return settings
    }

    func secrets(_ entries: [UUID: String] = [:]) -> (SecretAccess, InMemorySecretStore) {
        let store = InMemorySecretStore(secrets: Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) }))
        return (SecretAccess(store, queue: DispatchQueue(label: "test.resolver.\(UUID())")), store)
    }

    // MARK: - Le résultat

    @Test(arguments: [ProviderKind.openAICompatible, .anthropic])
    func aResolvedProviderCarriesItsKindItsAddressItsNameAndItsTrimmedKey(kind: ProviderKind) async throws {
        var chosen = provider
        chosen.kind = kind
        chosen.baseURL = "https://exemple.invalid/api"
        let other = Provider(id: UUID(), name: "Autre exemple", baseURL: "https://exemple.invalid/x", kind: .anthropic, models: [])
        let (access, _) = secrets([chosen.id: " \(Self.apiKey) \n", other.id: "cle-de-l-autre"])

        let resolved = try await ProviderResolver.resolve(
            chosen.id, settings: settings([other, chosen]), secrets: access)

        #expect(resolved.kind == kind)
        #expect(resolved.name == "Fournisseur d'exemple")
        #expect(resolved.config.baseURL == URL(string: "https://exemple.invalid/api"))
        #expect(resolved.config.apiKey == Self.apiKey, "la clé est celle du fournisseur choisi, rognée")
    }

    // MARK: - Les refus, dans l'ordre

    @Test func anUnknownProviderIsMissingAndTheKeychainIsNotAsked() async {
        let (access, store) = secrets([provider.id: Self.apiKey])

        await #expect(throws: RewriteFailure.providerMissing) {
            try await ProviderResolver.resolve(UUID(), settings: settings(), secrets: access)
        }
        #expect(store.readCount == 0)
    }

    @Test(
        "l'adresse avant la clé : une adresse refusée est « unreachable » même sans clé, et le trousseau n'est pas lu",
        arguments: ["http://exemple.invalid/v1", "pas une adresse", "", "ftp://exemple.invalid"])
    func aRefusedAddressIsUnreachableBeforeTheKeyIsLookedAt(address: String) async {
        var bad = provider
        bad.baseURL = address
        let (access, store) = secrets()  // aucune clé : l'ordre inversé rendrait `noKey`

        await #expect(throws: RewriteFailure.unreachable) {
            try await ProviderResolver.resolve(bad.id, settings: settings([bad]), secrets: access)
        }
        #expect(store.readCount == 0, "aucune invite du trousseau pour une adresse refusée")
    }

    @Test(arguments: ["", " \n\t "])
    func anAbsentOrBlankKeyIsNoKeyWithTheProvidersName(key: String) async {
        let (access, store) = key.isEmpty ? secrets() : secrets([provider.id: key])

        await #expect(throws: RewriteFailure.noKey(provider: "Fournisseur d'exemple")) {
            try await ProviderResolver.resolve(provider.id, settings: settings(), secrets: access)
        }
        #expect(store.readCount == 1)
    }

    @Test func aLongProviderNameIsTrimmedWithTheSharedRuleInNoKey() async {
        var long = provider
        long.name = String(repeating: "N", count: 60)
        let (access, _) = secrets()

        await #expect(throws: RewriteFailure.noKey(provider: Provider.shortName(long.name))) {
            try await ProviderResolver.resolve(long.id, settings: settings([long]), secrets: access)
        }
    }

    @Test(arguments: [SecretError.denied, .unavailable(status: -25293)])
    func aKeychainThatRefusesIsKeychain(failure: SecretError) async {
        let (access, store) = secrets([provider.id: Self.apiKey])
        store.failure = failure

        await #expect(throws: RewriteFailure.keychain) {
            try await ProviderResolver.resolve(provider.id, settings: settings(), secrets: access)
        }
    }

    // MARK: - Le fil, l'annulation

    @Test func theKeyIsReadOffTheMainThread() async throws {
        let store = ThreadStore()
        let access = SecretAccess(store, queue: DispatchQueue(label: "test.resolver.thread"))

        _ = try await ProviderResolver.resolve(provider.id, settings: settings(), secrets: access)

        #expect(store.onMain.withLock { $0 } == [false])
    }

    @Test("annulée pendant que le trousseau répond, la tâche lève l'annulation, même si la clé arrive")
    func aTaskCancelledWhileTheKeychainAnswersThrowsCancellation() async {
        let held = HeldStore()
        let access = SecretAccess(held, queue: DispatchQueue(label: "test.resolver.held.ok"))
        let (provider, settings) = (provider, settings())

        let task = Task { @MainActor in try await ProviderResolver.resolve(provider.id, settings: settings, secrets: access) }
        #expect(await until { held.asked.withLock { $0 } })
        task.cancel()
        held.release.signal()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("annulée pendant que le trousseau répond, une lecture en échec est l'annulation, pas « keychain »")
    func aCancelledTaskWhoseKeychainReadFailsThrowsCancellationNotKeychain() async {
        let held = HeldStore(failure: .denied)
        let access = SecretAccess(held, queue: DispatchQueue(label: "test.resolver.held.fail"))
        let (provider, settings) = (provider, settings())

        let task = Task { @MainActor in try await ProviderResolver.resolve(provider.id, settings: settings, secrets: access) }
        #expect(await until { held.asked.withLock { $0 } })
        task.cancel()
        held.release.signal()

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
