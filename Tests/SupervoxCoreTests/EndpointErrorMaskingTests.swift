import Foundation
import Testing
@testable import SupervoxCore

/// Le texte d'une panne de transport ne montre jamais la clé, pour chaque appel du client compatible OpenAI (le masquage
/// est commun à tous : `transcribe` et `speech` y passent comme `chatStream` et `complete`). Égalité exacte : la clé est
/// placée à cheval sur la coupe à 500 caractères, de sorte que sans masquage il reste `cle` (début de la clé) et qu'un
/// « ne contient pas la clé » passerait quand même.
@Suite("EndpointErrorMaskingTests", .serialized)
struct EndpointErrorMaskingTests {
    private static let key = "cle-de-test-0123"
    private static let masked = EndpointError.transport(String(repeating: "x", count: 497) + "***")

    private static func client() -> OpenAICompatibleClient {
        let text = String(repeating: "x", count: 497) + key + String(repeating: "y", count: 100)
        let echoing = NSError(domain: "exemple", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        return stubbedClient(reply: .failureWith(echoing), apiKey: key)
    }

    @Test func transcribeTransportMessagesNeverContainTheKey() async {
        await #expect(throws: Self.masked) {
            _ = try await Self.client().transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil)
        }
    }

    @Test func speechTransportMessagesNeverContainTheKey() async {
        await #expect(throws: Self.masked) {
            _ = try await Self.client().speech(model: "m", input: "a", voice: "v", format: "wav", extra: [:])
        }
    }
}
