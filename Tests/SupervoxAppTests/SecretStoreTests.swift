import Foundation
import Security
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
        #expect(!String(reflecting: error).contains(canary))
        let localized: String = error?.localizedDescription ?? ""
        #expect(!localized.contains(canary))
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

    @Test func concurrentWritesAndReadsEndOnTheLastCoherentValue() async throws {
        let underlying = InMemorySecretStore()
        let store = CachedSecretStore(underlying)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<64 {
                group.addTask { try? store.write("valeur-\(index)", account: "compte") }
                group.addTask { _ = try? store.read(account: "compte") }
            }
        }

        // Quel que soit l'ordre, le cache et le magasin dessous disent la même chose.
        let cached = try store.read(account: "compte")
        let stored = try underlying.read(account: "compte")
        #expect(cached == stored)
        #expect(cached?.hasPrefix("valeur-") == true)
    }

    @Test func noDescriptionOfAStoreOrItsErrorsRevealsASecret() throws {
        let underlying = InMemorySecretStore(secrets: ["compte": canary])
        let store = CachedSecretStore(underlying)
        _ = try store.read(account: "compte")

        let texts = [
            String(describing: underlying), String(reflecting: underlying),
            String(describing: store), String(reflecting: store),
            String(describing: KeychainSecretStore(service: "dev.supervox.tests")),
            String(describing: SecretError.denied),
            String(reflecting: SecretError.unavailable(status: -34018)),
            SecretError.denied.localizedDescription,
            SecretError.unavailable(status: -34018).localizedDescription,
        ]
        for text in texts { #expect(!text.contains(canary)) }

        var dumped = ""
        dump(underlying, to: &dumped)
        dump(store, to: &dumped)
        #expect(!dumped.contains(canary))
    }

    @Test(arguments: [
        (Int32(0), SecretOutcome.success),
        (errSecItemNotFound, .notFound),
        (errSecUserCanceled, .failure(.denied)),
        (errSecAuthFailed, .failure(.denied)),
        (-34018, .failure(.unavailable(status: -34018))),
        (errSecInteractionNotAllowed, .failure(.unavailable(status: errSecInteractionNotAllowed))),
        (errSecDuplicateItem, .failure(.unavailable(status: errSecDuplicateItem))),
    ])
    func keychainStatusesMapToSecretErrors(status: Int32, expected: SecretOutcome) {
        #expect(KeychainSecretStore.outcome(forStatus: status) == expected)
    }
}
