import Testing
@testable import SupervoxCore

@Test func werCountsEachErrorKind() {
    #expect(WordErrorRate.compute(reference: "le worker celery tourne", hypothesis: "le worker salary tourne")
        == ErrorCounts(substitutions: 1, deletions: 0, insertions: 0, referenceCount: 4))
    #expect(WordErrorRate.compute(reference: "le worker tourne", hypothesis: "le tourne").deletions == 1)
    #expect(WordErrorRate.compute(reference: "le worker", hypothesis: "le petit worker").insertions == 1)
    #expect(WordErrorRate.compute(reference: "a b c d", hypothesis: "a b c d").rate == 0)
    #expect(WordErrorRate.compute(reference: "", hypothesis: "merci").rate == 1)
    #expect(WordErrorRate.compute(reference: "", hypothesis: "").rate == 0)
}

@Test func termRecallMatchesMultiWordTermsAfterNormalization() {
    let r = TermRecall.compute(terms: ["FastAPI", "worker Celery", "pull request"],
                               hypothesis: "Le endpoint fastapi et le Worker  Celery, pas la poule requête.")
    #expect(r.found == 2 && r.total == 3)
}

@Test func werCombinesSubstitutionAndInsertionOnTheSameAlignment() {
    let counts = WordErrorRate.compute(reference: "a b c", hypothesis: "x b c d")
    #expect(counts == ErrorCounts(substitutions: 1, deletions: 0, insertions: 1, referenceCount: 3))
    #expect(abs(counts.rate - 2.0 / 3.0) < 1e-12)
}

@Test func werCanExceedOne() {
    let counts = WordErrorRate.compute(reference: "a", hypothesis: "x y z")
    #expect(counts.substitutions + counts.deletions + counts.insertions == 3)
    #expect(abs(counts.rate - 3.0) < 1e-12)
}

@Test func werIgnoresFormOnlyDifferences() {
    #expect(WordErrorRate.compute(reference: "C'est OK, le Worker.", hypothesis: "c est ok le worker").rate == 0)
}

@Test func termRecallRequiresContiguousOrderedWords() {
    let hypothesis = "le Celery worker et le worker puis Celery"
    let r = TermRecall.compute(terms: ["worker Celery", "Celery worker", "worker puis Celery"], hypothesis: hypothesis)
    // « Celery worker » n'apparaît contigu qu'au début ; « worker Celery » jamais contigu ; le 3e oui.
    #expect(r.found == 2 && r.total == 3)
}

@Test func termRecallNeverFindsATermWithoutWords() {
    let r = TermRecall.compute(terms: ["", "..."], hypothesis: "bonjour")
    #expect(r.found == 0 && r.total == 2)
}
