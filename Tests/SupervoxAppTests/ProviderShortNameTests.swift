import Foundation
import Testing

@testable import SupervoxApp

/// Le nom d'un fournisseur tel qu'une phrase de l'onglet Modes le cite : au plus 40 caractères, puis « … ».
@Suite struct ProviderShortNameTests {
    private func provider(_ name: String) -> Provider {
        Provider(id: UUID(), name: name, baseURL: "https://example.com", kind: .openAICompatible, models: [])
    }

    @Test func aNameOfFortyCharactersOrLessIsKeptAsIs() {
        let forty = String(repeating: "a", count: 40)
        #expect(Provider.shortName(forty) == forty)
        #expect(Provider.shortName("Fournisseur d'exemple") == "Fournisseur d'exemple")
        #expect(Provider.shortName("") == "")
        #expect(provider(forty).shortName == forty)
    }

    @Test func aNameOfFortyOneCharactersIsCutToFortyAndEndsWithAnEllipsis() {
        let forty = String(repeating: "a", count: 40)
        #expect(Provider.shortName(forty + "b") == forty + "…")
        #expect(provider(forty + "b").shortName == forty + "…")
        #expect(Provider.shortName(String(repeating: "x", count: 500)) == String(repeating: "x", count: 40) + "…")
    }

    /// Les caractères se comptent comme l'utilisateur les voit : une lettre accentuée ou un emoji composé n'est pas coupé en deux.
    @Test func charactersAreCountedAsTheUserSeesThem() {
        let accented = String(repeating: "e\u{301}", count: 40)  // 40 « é » en deux scalaires
        #expect(Provider.shortName(accented) == accented)
        let family = String(repeating: "👨‍👩‍👧", count: 41)
        #expect(Provider.shortName(family) == String(repeating: "👨‍👩‍👧", count: 40) + "…")
    }
}
