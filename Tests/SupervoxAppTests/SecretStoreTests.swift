import Foundation
import Security
import Synchronization
import Testing

@testable import SupervoxApp

/// Valeur reconnaissable : si elle apparaît quelque part où elle ne devrait pas, les tests la trouvent.
private let canary = "sk-canari-7f3a91-ne-doit-jamais-fuiter"

/// Magasin dont la lecture traîne un peu : élargit la fenêtre où deux lectures simultanées se croiseraient.
/// Le délai ne sert qu'à provoquer la course ; aucun test ne mesure une durée.
private struct SlowReadStore: SecretStore {
    let base: InMemorySecretStore
    func read(account: String) throws -> String? {
        Thread.sleep(forTimeInterval: 0.01)
        return try base.read(account: account)
    }
    func write(_ secret: String, account: String) throws { try base.write(secret, account: account) }
    func delete(account: String) throws { try base.delete(account: account) }
    func contains(account: String) throws -> Bool { try base.contains(account: account) }
}

/// Magasin sonde : compte les appels simultanés qu'il reçoit. Le délai dans chaque appel élargit la
/// fenêtre où deux appels se chevaucheraient ; aucun test ne mesure une durée.
private final class ProbeStore: SecretStore {
    private let base = InMemorySecretStore()
    private let flight = Mutex((now: 0, max: 0))

    var maxInFlight: Int { flight.withLock { $0.max } }

    private func tracked<T>(_ body: () throws -> T) rethrows -> T {
        flight.withLock {
            $0.now += 1
            $0.max = Swift.max($0.max, $0.now)
        }
        defer { flight.withLock { $0.now -= 1 } }
        Thread.sleep(forTimeInterval: 0.002)
        return try body()
    }

    func read(account: String) throws -> String? { try tracked { try base.read(account: account) } }
    func write(_ secret: String, account: String) throws { try tracked { try base.write(secret, account: account) } }
    func delete(account: String) throws { try tracked { try base.delete(account: account) } }
    func contains(account: String) throws -> Bool { try tracked { try base.contains(account: account) } }
}

@Suite struct SecretStoreTests {
    @Test func cachedStoreReadsTheUnderlyingStoreOnce() throws {
        let underlying = InMemorySecretStore(secrets: ["compte": canary])
        let store = CachedSecretStore(underlying)

        #expect(try store.read(account: "compte") == canary)
        #expect(try store.read(account: "compte") == canary)
        #expect(try store.read(account: "compte") == canary)

        #expect(underlying.readCount == 1)
    }

    @Test func cachedStoreNeverReadsBeforeItIsAsked() throws {
        let underlying = InMemorySecretStore(secrets: ["compte": canary])

        let store = CachedSecretStore(underlying)
        #expect(underlying.readCount == 0)

        _ = try store.read(account: "compte")
        #expect(underlying.readCount == 1)
    }

    @Test func cacheIsPerAccount() throws {
        let underlying = InMemorySecretStore(secrets: ["a": "un", "b": "deux"])
        let store = CachedSecretStore(underlying)

        #expect(try store.read(account: "a") == "un")
        #expect(try store.read(account: "b") == "deux")
        #expect(try store.read(account: "a") == "un")
        #expect(try store.read(account: "b") == "deux")

        #expect(underlying.readCount == 2)
    }

    @Test func writeAndDeleteUpdateTheCache() throws {
        let underlying = InMemorySecretStore()
        let store = CachedSecretStore(underlying)

        try store.write("premier", account: "compte")
        #expect(try store.read(account: "compte") == "premier")
        #expect(underlying.readCount == 0)

        try store.write("second", account: "compte")
        #expect(try store.read(account: "compte") == "second")
        #expect(underlying.readCount == 0)

        try store.delete(account: "compte")
        #expect(try store.read(account: "compte") == nil)
        #expect(underlying.readCount == 0)
        #expect(try underlying.read(account: "compte") == nil)
    }

    @Test func writeReachesTheUnderlyingStore() throws {
        let underlying = InMemorySecretStore()
        let store = CachedSecretStore(underlying)

        try store.write(canary, account: "compte")

        #expect(try underlying.read(account: "compte") == canary)
    }

    @Test func writeReplacesAValueAlreadyCached() throws {
        let underlying = InMemorySecretStore(secrets: ["compte": "ancien"])
        let store = CachedSecretStore(underlying)
        #expect(try store.read(account: "compte") == "ancien")

        try store.write("nouveau", account: "compte")

        #expect(try store.read(account: "compte") == "nouveau")
        #expect(underlying.readCount == 1)
    }

    @Test func deniedReadSurfacesAnErrorWithoutTheSecret() throws {
        let underlying = InMemorySecretStore(secrets: ["compte": canary])
        let store = CachedSecretStore(underlying)
        underlying.failure = .denied

        let error = #expect(throws: SecretError.self) { try store.read(account: "compte") }
        #expect(error == .denied)
        #expect(!String(describing: error).contains(canary))
        #expect(underlying.readCount == 1)

        // L'erreur n'est pas mise en cache : la lecture suivante réessaie, et réussit une fois l'accès rendu.
        #expect(throws: SecretError.self) { try store.read(account: "compte") }
        #expect(underlying.readCount == 2)

        underlying.failure = nil
        #expect(try store.read(account: "compte") == canary)
        #expect(underlying.readCount == 3)
    }

    @Test func unavailableReadIsNotCachedEither() throws {
        let underlying = InMemorySecretStore(secrets: ["compte": canary])
        let store = CachedSecretStore(underlying)
        underlying.failure = .unavailable(status: -25291)

        let error = #expect(throws: SecretError.self) { try store.read(account: "compte") }
        #expect(error == .unavailable(status: -25291))

        underlying.failure = nil
        #expect(try store.read(account: "compte") == canary)
    }

    @Test func failedWriteLeavesNothingInTheCache() throws {
        let underlying = InMemorySecretStore(secrets: ["compte": "ancien"])
        let store = CachedSecretStore(underlying)
        #expect(try store.read(account: "compte") == "ancien")

        underlying.failure = .denied
        #expect(throws: SecretError.self) { try store.write("nouveau", account: "compte") }
        underlying.failure = nil

        // Le cache ne doit pas annoncer « nouveau » : l'écriture n'a pas eu lieu.
        #expect(try store.read(account: "compte") == "ancien")
    }

    @Test func failedDeleteLeavesTheSecretReadable() throws {
        let underlying = InMemorySecretStore(secrets: ["compte": "valeur"])
        let store = CachedSecretStore(underlying)
        #expect(try store.read(account: "compte") == "valeur")

        underlying.failure = .denied
        #expect(throws: SecretError.self) { try store.delete(account: "compte") }
        underlying.failure = nil

        #expect(try store.read(account: "compte") == "valeur")
    }

    @Test func missingSecretIsNilNotAnError() throws {
        let underlying = InMemorySecretStore()
        let store = CachedSecretStore(underlying)

        #expect(try store.read(account: "absent") == nil)
        #expect(try underlying.read(account: "absent") == nil)
    }

    @Test func missingSecretIsRememberedToo() throws {
        let underlying = InMemorySecretStore()
        let store = CachedSecretStore(underlying)

        #expect(try store.read(account: "absent") == nil)
        #expect(try store.read(account: "absent") == nil)

        #expect(underlying.readCount == 1)
    }

    @Test func deletingAMissingSecretIsNotAnError() throws {
        let store = CachedSecretStore(InMemorySecretStore())
        try store.delete(account: "absent")
        #expect(try store.read(account: "absent") == nil)
    }

    @Test func concurrentReadsReachTheUnderlyingStoreOnce() async throws {
        let underlying = InMemorySecretStore(secrets: ["compte": canary])
        let store = CachedSecretStore(SlowReadStore(base: underlying))

        let values = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<64 {
                group.addTask { try? store.read(account: "compte") }
            }
            var all: [String?] = []
            for await value in group { all.append(value) }
            return all
        }

        #expect(values.count == 64)
        #expect(values.allSatisfy { $0 == canary })
        #expect(underlying.readCount == 1)
    }

    @Test func theUnderlyingStoreNeverSeesTwoCallsAtOnce() async throws {
        let probe = ProbeStore()
        let store = CachedSecretStore(probe)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask { try? store.write("valeur-\(index)", account: "compte") }
                group.addTask { _ = try? store.read(account: "compte") }
                group.addTask { try? store.delete(account: "autre") }
            }
        }

        // Le verrou est tenu pendant l'appel dessous : jamais deux appels en même temps.
        #expect(probe.maxInFlight == 1)
        // Et le cache dit la même chose que le magasin dessous.
        #expect(try store.read(account: "compte") == (try probe.read(account: "compte")))
    }

    @Test func secretErrorsDescribeOnlyTheirStatus() {
        #expect(String(describing: SecretError.denied) == "Accès au trousseau refusé")
        #expect(String(describing: SecretError.unavailable(status: errSecMissingEntitlement))
            == "Trousseau indisponible (statut \(errSecMissingEntitlement))")
        #expect(SecretError.emptySecret.localizedDescription == "Un secret vide n'est pas enregistré")
    }

    @Test func absentThenWriteIsReadWithoutReadingBelow() throws {
        let underlying = InMemorySecretStore()
        let store = CachedSecretStore(underlying)
        #expect(try store.read(account: "compte") == nil)

        try store.write(canary, account: "compte")

        #expect(try store.read(account: "compte") == canary)
        #expect(underlying.readCount == 1)
    }

    @Test func presentThenDeleteReadsNilWithoutReadingBelow() throws {
        let underlying = InMemorySecretStore(secrets: ["compte": canary])
        let store = CachedSecretStore(underlying)
        #expect(try store.read(account: "compte") == canary)

        try store.delete(account: "compte")

        #expect(try store.read(account: "compte") == nil)
        #expect(underlying.readCount == 1)
    }

    @Test func emptySecretIsRefusedAndTheCachedOneSurvives() throws {
        let underlying = InMemorySecretStore(secrets: ["compte": "ancien"])
        let store = CachedSecretStore(underlying)
        #expect(try store.read(account: "compte") == "ancien")

        let error = #expect(throws: SecretError.self) { try store.write("", account: "compte") }
        #expect(error == .emptySecret)

        // Refus avant tout effet : ni le cache ni le magasin dessous n'ont bougé.
        #expect(try store.read(account: "compte") == "ancien")
        #expect(underlying.readCount == 1)
        #expect(try underlying.read(account: "compte") == "ancien")
    }

    @Test func inMemoryStoreRefusesAnEmptySecret() throws {
        let store = InMemorySecretStore(secrets: ["compte": "ancien"])
        #expect(throws: SecretError.emptySecret) { try store.write("", account: "compte") }
        #expect(try store.read(account: "compte") == "ancien")
    }

    @Test func keychainStoreRefusesAnEmptySecretBeforeTouchingTheKeychain() {
        // Le refus précède tout appel `SecItem*` : ce test ne touche pas au trousseau.
        let store = KeychainSecretStore(service: "dev.supervox.tests")
        #expect(throws: SecretError.emptySecret) { try store.write("", account: "test-\(UUID().uuidString)") }
    }

    @Test(arguments: [
        (Int32(0), SecretOutcome.success),
        (errSecItemNotFound, .notFound),
        (errSecUserCanceled, .failure(.denied)),
        (errSecAuthFailed, .failure(.denied)),
        (errSecMissingEntitlement, .failure(.unavailable(status: errSecMissingEntitlement))),
        (errSecInteractionNotAllowed, .failure(.unavailable(status: errSecInteractionNotAllowed))),
        (errSecDuplicateItem, .failure(.unavailable(status: errSecDuplicateItem))),
    ])
    func keychainStatusesMapToSecretErrors(status: Int32, expected: SecretOutcome) {
        #expect(KeychainSecretStore.outcome(forStatus: status) == expected)
    }

    // MARK: - Existence sans lecture

    @Test func inMemoryContainsDoesNotCountAsARead() throws {
        let store = InMemorySecretStore(secrets: ["compte": canary])
        #expect(try store.contains(account: "compte"))
        #expect(try !store.contains(account: "autre"))
        #expect(store.readCount == 0)
        #expect(store.containsCount == 2)

        store.failure = .denied
        #expect(throws: SecretError.denied) { try store.contains(account: "compte") }
        #expect(store.readCount == 0)
    }

    @Test func cachedContainsNeverReadsTheUnderlyingSecret() throws {
        let underlying = InMemorySecretStore(secrets: ["compte": canary])
        let store = CachedSecretStore(underlying)

        #expect(try store.contains(account: "compte"))
        #expect(try !store.contains(account: "autre"))
        #expect(underlying.readCount == 0)
        #expect(underlying.containsCount == 2)
    }

    @Test func cachedContainsAnswersFromWhatTheCacheAlreadyKnows() throws {
        let underlying = InMemorySecretStore()
        let store = CachedSecretStore(underlying)
        try store.write(canary, account: "écrit")
        try store.delete(account: "supprimé")

        #expect(try store.contains(account: "écrit"))
        #expect(try !store.contains(account: "supprimé"))
        #expect(underlying.containsCount == 0)
        #expect(underlying.readCount == 0)
    }

    @Test func absenceSeenByContainsIsRememberedAndAWriteReplacesIt() throws {
        let underlying = InMemorySecretStore()
        let store = CachedSecretStore(underlying)
        #expect(try !store.contains(account: "compte"))
        #expect(try store.read(account: "compte") == nil)
        #expect(underlying.readCount == 0)

        try store.write(canary, account: "compte")
        #expect(try store.contains(account: "compte"))
        #expect(underlying.containsCount == 1)
    }

    @Test func failedContainsIsNotCached() throws {
        let underlying = InMemorySecretStore(secrets: ["compte": canary])
        let store = CachedSecretStore(underlying)
        underlying.failure = .denied
        #expect(throws: SecretError.denied) { try store.contains(account: "compte") }
        underlying.failure = nil
        #expect(try store.contains(account: "compte"))
        #expect(underlying.containsCount == 2)
    }

    /// La requête d'existence du trousseau demande les attributs, jamais la donnée.
    @Test func keychainExistenceQueryAsksForAttributesNotData() {
        let query = KeychainSecretStore(service: "dev.supervox.tests").existenceQuery(account: "compte")
        #expect(query[kSecReturnData] == nil)
        #expect(query[kSecReturnAttributes] as? Bool == true)
        #expect(query[kSecAttrAccount] as? String == "compte")
        #expect(query[kSecAttrService] as? String == "dev.supervox.tests")
        #expect((query[kSecClass] as? String) == (kSecClassGenericPassword as String))
    }
}
