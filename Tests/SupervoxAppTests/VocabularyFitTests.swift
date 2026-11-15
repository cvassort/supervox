import Testing

@testable import SupervoxApp

/// Garder, d'une liste de termes, les premiers qui tiennent dans la limite de l'amorce de Whisper.
@Suite(.timeLimit(.minutes(1))) struct VocabularyFitTests {
    /// 10 jetons par terme.
    private static let tenPerTerm: @Sendable ([String]) async -> Int? = { $0.count * 10 }

    @Test func aListThatFitsIsKeptWhole() async {
        let outcome = await VocabularyFit.fit(["a", "b", "c"], limit: 30, count: Self.tenPerTerm)
        #expect(outcome == .fits)
    }

    @Test func aTooLongListKeepsTheLongestPrefixThatFits() async {
        let outcome = await VocabularyFit.fit(["a", "b", "c", "d", "e"], limit: 25, count: Self.tenPerTerm)
        #expect(outcome == .trimmed(kept: ["a", "b"], of: 5))
    }

    @Test func theLimitItselfIsAccepted() async {
        let outcome = await VocabularyFit.fit(["a", "b", "c", "d"], limit: 30, count: Self.tenPerTerm)
        #expect(outcome == .trimmed(kept: ["a", "b", "c"], of: 4))
    }

    @Test func aFirstTermAloneTooLongKeepsNothing() async {
        let outcome = await VocabularyFit.fit(["a", "b"], limit: 5, count: Self.tenPerTerm)
        #expect(outcome == .trimmed(kept: [], of: 2))
    }

    @Test func anUncountableListIsReportedAsSuch() async {
        let outcome = await VocabularyFit.fit(["a", "b"], limit: 5, count: { _ in nil })
        #expect(outcome == .unknown)
    }

    @Test func anEmptyListIsNeverCounted() async {
        let outcome = await VocabularyFit.fit([], limit: 5, count: { _ in 999 })
        #expect(outcome == .fits)
    }

    /// Chaque comptage recharge le tokenizer : la recherche est dichotomique, pas terme après terme.
    @Test func theSearchIsLogarithmicInTheNumberOfTerms() async {
        let terms = (0..<200).map { "terme\($0)" }
        let calls = CallCounter()
        let outcome = await VocabularyFit.fit(
            terms, limit: 1000,
            count: { prefix in
                await calls.increment()
                return prefix.count * 10
            })
        #expect(outcome == .trimmed(kept: Array(terms.prefix(100)), of: 200))
        #expect(await calls.value <= 12)
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
