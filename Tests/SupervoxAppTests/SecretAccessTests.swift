import Foundation
import Testing

@testable import SupervoxApp

/// L'accès asynchrone au magasin de secrets : chaque appel part sur la file dédiée (ni le fil principal, ni le pool
/// coopératif), et rend le résultat ou l'erreur du magasin tels quels.
@MainActor @Suite struct SecretAccessTests {
    @Test func everyCallRunsOffTheMainThreadAndReturnsTheStoreAnswer() async throws {
        let store = RecordingSecretStore(secrets: ["a": "sk-a"])
        let access = SecretAccess(store, queue: DispatchQueue(label: "test-secrets"))

        #expect(try await access.read(account: "a") == "sk-a")
        #expect(try await access.contains(account: "a"))
        try await access.write("sk-b", account: "b")
        try await access.delete(account: "a")

        #expect(store.calls.map(\.name) == ["read", "contains", "write", "delete"])
        #expect(store.calls.allSatisfy { !$0.onMainThread })
        // Sur la file donnée, pas sur le pool coopératif.
        #expect(store.calls.allSatisfy { $0.queueLabel == "test-secrets" })
        #expect(store.peek("a") == nil)
        #expect(store.peek("b") == "sk-b")
    }

    @Test func storeErrorsAreRethrownAsIs() async {
        let store = RecordingSecretStore()
        store.deleteFailure = .denied
        let access = SecretAccess(store, queue: DispatchQueue(label: "test-secrets"))
        await #expect(throws: SecretError.denied) { try await access.delete(account: "a") }
    }
}
