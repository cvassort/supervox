import Foundation
import Testing
@testable import SupervoxCore

/// Une requête qui porte une clé ne laisse rien derrière elle : ni réponse en cache (le cache disque du système
/// gardait les en-têtes, clé comprise), ni cookie, ni identifiant.
@Suite struct EndpointSessionTests {
    @Test func storelessSessionKeepsNoCacheCookieNorCredential() {
        let configuration = EndpointSession.shared.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCredentialStorage == nil)
    }

    /// Les deux clients qui envoient une clé passent par la session sans stockage quand on ne leur en donne
    /// aucune : jamais par `URLSession.shared`, dont le cache est écrit sur le disque.
    @Test func keyCarryingClientsUseTheStorelessSessionByDefault() throws {
        let config = EndpointConfig(baseURL: try #require(URL(string: "https://exemple.test")), apiKey: "k")

        let lister = ModelLister(config: config, kind: .anthropic)
        #expect(lister.session !== URLSession.shared)
        #expect(lister.session === EndpointSession.shared)

        let client = OpenAICompatibleClient(config: config)
        #expect(client.session !== URLSession.shared)
        #expect(client.session === EndpointSession.shared)
    }
}
