import Foundation
import Testing

@testable import SupervoxApp

/// Parle au vrai trousseau de l'utilisateur : désactivé sauf `SUPERVOX_KEYCHAIN=1`.
/// N'utilise que le service `dev.supervox.tests`, avec un compte aléatoire supprimé en fin de test.
/// Ce test tourne dans le processus de test, pas dans l'application : le trousseau peut afficher une invite.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_KEYCHAIN"] == "1"))
struct KeychainIntegrationTests {
    @Test func writeReadUpdateDeleteRoundTrip() throws {
        let store = KeychainSecretStore(service: "dev.supervox.tests")
        let account = "test-\(UUID().uuidString)"
        defer { try? store.delete(account: account) }

        #expect(try store.read(account: account) == nil)

        try store.write("premier", account: account)
        #expect(try store.read(account: account) == "premier")

        // Mise à jour de l'entrée existante : ni erreur de doublon, ni ancienne valeur.
        try store.write("second é ✓", account: account)
        #expect(try store.read(account: account) == "second é ✓")

        try store.delete(account: account)
        #expect(try store.read(account: account) == nil)

        // Supprimer une entrée absente n'est pas une erreur.
        try store.delete(account: account)
    }

    @Test func containsSeesTheEntryWithoutReadingIt() throws {
        let store = KeychainSecretStore(service: "dev.supervox.tests")
        let account = "test-\(UUID().uuidString)"
        defer { try? store.delete(account: account) }

        #expect(try !store.contains(account: account))
        try store.write("valeur", account: account)
        #expect(try store.contains(account: account))
        try store.delete(account: account)
        #expect(try !store.contains(account: account))
    }
}
