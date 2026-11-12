import Testing
@testable import SupervoxCore

@Test func normalizationFoldsFormOnly() {
    #expect(TextNormalizer.words("L’endpoint FastAPI, c'est OK !") == ["l", "endpoint", "fastapi", "c", "est", "ok"])
    #expect(TextNormalizer.words("Est-ce que… ça marche ?") == ["est", "ce", "que", "ça", "marche"])
    #expect(TextNormalizer.words("3 workers") != TextNormalizer.words("trois workers"))
    #expect(TextNormalizer.words("   ") == [])
}

@Test func normalizationTreatsDecomposedAndPrecomposedAccentsAlike() {
    // « é » écrit en deux scalaires (e + accent combinant) ne doit ni couper le mot ni changer de valeur.
    #expect(TextNormalizer.words("cafe\u{301} Crème") == ["café", "crème"])
}

@Test func normalizationSplitsOnHyphensAndStraightApostrophes() {
    #expect(TextNormalizer.words("aujourd'hui, peut-être") == ["aujourd", "hui", "peut", "être"])
}
