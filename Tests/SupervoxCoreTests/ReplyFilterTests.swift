import Foundation
import Testing
@testable import SupervoxCore

// Le marqueur de conclusion que le modèle écrit en tête de sa réponse ([SUITE], [PROPOSER], [CONCLURE]) ne se dit jamais et
// ne se montre jamais, où qu'il tombe dans le flux. Le filtre reçoit le texte visible cumulé, comme `onText`.

/// Ce que le filtre rend pour un texte livré en morceaux : `cuts` sont les longueurs (en scalaires Unicode) cumulées auxquelles
/// on livre le texte reçu jusque-là, puis le texte entier, puis `finish()`.
private func run(_ text: String, cuts: [Int] = []) -> (shown: String, signal: ReplySignal, steps: [String]) {
    let scalars = Array(text.unicodeScalars)
    var filter = ReplyFilter()
    var steps: [String] = []
    for cut in cuts where cut > 0 && cut < scalars.count {
        var prefix = String.UnicodeScalarView()
        prefix.append(contentsOf: scalars[0..<cut])
        steps.append(filter.feed(String(prefix)))
    }
    steps.append(filter.feed(text))
    steps.append(filter.finish())
    return (steps.joined(), filter.signal, steps)
}

/// Les six réponses du jeu de propriété, avec ce que le filtre doit rendre (écrit à la main, non recalculé par le code testé).
private let responses: [(text: String, shown: String, signal: ReplySignal)] = [
    ("[SUITE]\nQuelle est la contrainte principale ?", "Quelle est la contrainte principale ?", .continue),
    ("[PROPOSER]\nJ'ai tout ce qu'il faut. On peut conclure ?", "J'ai tout ce qu'il faut. On peut conclure ?", .propose),
    ("[CONCLURE]\nMerci, c'est noté.", "Merci, c'est noté.", .conclude),
    ("  [conclure] \n d'accord. Un autre [Suite] ici, puis [PROPOSER] là.\n", "d'accord. Un autre  ici, puis  là.\n", .conclude),
    ("Sans marqueur, avec [note de bas] et [AUTRE] ici, puis [CONCLURE] au milieu, fin [SU",
     "Sans marqueur, avec [note de bas] et [AUTRE] ici, puis  au milieu, fin [SU", .continue),
    ("[AUTRE]\nQuestion ? [SU[SUITE]ITE] et [CONCLURE] [PROPOSE", "Question ?  et  [PROPOSE", .continue),
]

@Suite struct ReplyFilterTests {
    // MARK: Marqueur de tête (règle 5)

    @Test(arguments: [
        ("[SUITE]", ReplySignal.continue), ("[PROPOSER]", .propose), ("[CONCLURE]", .conclude),
        ("[suite]", .continue), ("[proposer]", .propose), ("[conclure]", .conclude),
        ("[SuItE]", .continue), ("[pRoPoSeR]", .propose), ("[cOnClUrE]", .conclude),
    ], ["\n", " ", "\r\n", "\n\n", " \n "])
    func aLeadingMarkerIsRemovedWhateverItsCaseAndTheSeparator(marker: (String, ReplySignal), separator: String) {
        let result = run(marker.0 + separator + "Bonjour tout le monde.")

        #expect(result.shown == "Bonjour tout le monde.")
        #expect(result.signal == marker.1)
    }

    @Test func spacesBeforeTheLeadingMarkerAreRemovedToo() {
        let result = run("  \n [CONCLURE]\nMerci.")

        #expect(result.shown == "Merci." && result.signal == .conclude)
    }

    @Test func theMarkerIsRemovedEvenWithoutAnythingAfterIt() {
        let result = run("[CONCLURE]")

        #expect(result.shown == "" && result.signal == .conclude)
    }

    @Test func theSignalIsContinueUntilTheMarkerIsComplete() {
        var filter = ReplyFilter()
        #expect(filter.signal == .continue)
        _ = filter.feed("[CONCLUR")
        #expect(filter.signal == .continue)
        _ = filter.feed("[CONCLURE]")
        #expect(filter.signal == .conclude)
        _ = filter.feed("[CONCLURE]\nMerci.")
        #expect(filter.signal == .conclude)
    }

    // MARK: Coupé entre morceaux (règle 6) et jamais dit (règle 8)

    @Test(arguments: responses.indices)
    func theWholeReplyGivesTheExpectedTextAndSignal(index: Int) {
        let expected = responses[index]
        let result = run(expected.text)

        #expect(result.shown == expected.shown)
        #expect(result.signal == expected.signal)
    }

    /// Exhaustif : pour chacune des six réponses, chaque point de coupure en deux morceaux. Le texte rendu, le signal et le
    /// texte montré à chaque étape (qui doit toujours être un début du texte final : rien n'est montré puis retiré) sont ceux
    /// de la réponse d'un bloc.
    @Test(arguments: responses.indices)
    func everyCutInTwoGivesTheSameTextAndSignalAsTheWholeReply(index: Int) {
        let expected = responses[index]
        let count = expected.text.unicodeScalars.count
        for cut in 0...count {
            let result = run(expected.text, cuts: [cut])
            #expect(result.shown == expected.shown, "coupure à \(cut)")
            #expect(result.signal == expected.signal, "coupure à \(cut)")
            var soFar = ""
            for step in result.steps {
                soFar += step
                #expect(expected.shown.hasPrefix(soFar), "coupure à \(cut) : « \(soFar) » n'est pas un début du texte final")
            }
        }
    }

    /// Un caractère à la fois, et toutes les coupures en trois morceaux.
    @Test(arguments: responses.indices)
    func oneCharacterAtATimeAndEveryCutInThreeGiveTheSameTextAndSignalAsTheWholeReply(index: Int) {
        let expected = responses[index]
        let count = expected.text.unicodeScalars.count

        let single = run(expected.text, cuts: Array(1..<count))
        #expect(single.shown == expected.shown && single.signal == expected.signal)

        for first in 0...count {
            for second in first...count {
                let result = run(expected.text, cuts: [first, second])
                #expect(result.shown == expected.shown, "coupures à \(first) et \(second)")
                #expect(result.signal == expected.signal, "coupures à \(first) et \(second)")
            }
        }
    }

    @Test(arguments: responses.indices)
    func noRenderedTextEverContainsAMarkerOrItsStart(index: Int) {
        let text = responses[index].text
        let count = text.unicodeScalars.count
        let runs = [run(text)] + (0...count).map { run(text, cuts: [$0]) } + [run(text, cuts: Array(1..<count))]
        for result in runs {
            let lowered = result.shown.lowercased()
            for word in ["[suite", "[proposer", "[conclure"] {
                #expect(!lowered.contains(word), "« \(result.shown) » contient \(word)")
            }
            for step in result.steps {
                #expect(!step.lowercased().contains("[suite") && !step.lowercased().contains("[proposer") && !step.lowercased().contains("[conclure"))
            }
        }
    }

    // MARK: Rien retenu quand il n'y a rien à retenir

    @Test func aReplyWithoutAMarkerIsShownAsSoonAsItsHeadIsKnownToBeText() {
        var filter = ReplyFilter()
        #expect(filter.feed("Bon") == "Bon")
        #expect(filter.feed("Bonjour") == "jour")
        #expect(filter.feed("Bonjour tout") == " tout")
        #expect(filter.finish() == "")
        #expect(filter.signal == .continue)
    }

    @Test func anHeldMarkerStartIsReleasedAsSoonAsItCannotBecomeAMarker() {
        var filter = ReplyFilter()
        #expect(filter.feed("Bonjour [SU") == "Bonjour ")
        #expect(filter.feed("Bonjour [SUI") == "")
        #expect(filter.feed("Bonjour [SUIV") == "[SUIV")
        #expect(filter.finish() == "")
    }

    // MARK: Marqueurs imbriqués fournis par morceaux (contre-revue N1)

    /// Un marqueur connu écrit dans un autre, des préfixes longs, des suites qui recomposent un marqueur : tout ce que la retenue du
    /// filtre doit tenir pour que le texte rendu ne dépende pas du découpage.
    private static let nestedPieces = [
        "[CONC", "[PROPOSER]", "LURE]", "[SU", "[SUITE]", "ITE]", "[", "abcde", " ", "[conclure]", "[Pro", "poser]", "[SUIT", "E]",
    ]

    /// Les textes de la famille : tous les assemblages de 1 à 3 morceaux, et de 4 morceaux pris parmi les cinq premiers, précédés
    /// de « x » (la tête n'est donc pas un marqueur : seul le retrait « ailleurs » est en jeu), plus les cas de la contre-revue
    /// mot pour mot.
    private static let nestedTexts: [String] = {
        var texts = [
            "x [CONC[PROPOSER]LURE] et la suite",
            "a [SU[SUITE]ITE] b [CONC[PROPOSER]LURE] c",
            "Merci [SUIT[CONCLURE]E] au revoir",
            "Merci [CONC[PROPOSER]LURE]abcdeLURE] fin",
            "x [SU[SU[SUITE]ITE]ITE] fin", "x [CONC[PRO[PROPOSER]poser]LURE] fin", "x [[[[[[[[[[[[[[[[[[ y",
        ]
        for length in 1...3 {
            var partial: [String] = [""]
            for _ in 0..<length { partial = partial.flatMap { head in nestedPieces.map { head + $0 } } }
            texts += partial.map { "x " + $0 }
        }
        var four: [String] = [""]
        for _ in 0..<4 { four = four.flatMap { head in nestedPieces.prefix(5).map { head + $0 } } }
        return texts + four.map { "x " + $0 }
    }()

    /// Le texte attendu, calculé sans le filtre : retirer les trois marqueurs (casse ignorée) tant qu'il en reste. Le système de
    /// réécriture est confluent (aucun marqueur n'en contient un autre), l'ordre des retraits ne compte pas.
    private static func withoutMarkers(_ text: String) -> String {
        var current = text
        while true {
            var next = current
            for marker in ["[suite]", "[proposer]", "[conclure]"] {
                while let range = next.range(of: marker, options: .caseInsensitive) { next.removeSubrange(range) }
            }
            if next == current { return current }
            current = next
        }
    }

    private func checkNested(_ text: String, cuts: [Int], _ how: String) {
        let block = run(text)
        let chunked = run(text, cuts: cuts)
        #expect(block.shown == Self.withoutMarkers(text), "en bloc : \(text.debugDescription)")
        #expect(chunked.shown == block.shown, "\(how) : \(text.debugDescription) → \(chunked.shown.debugDescription), en bloc \(block.shown.debugDescription)")
        #expect(chunked.signal == block.signal, "\(how) : \(text.debugDescription) : signal")
        var soFar = ""
        for step in chunked.steps {
            soFar += step
            #expect(block.shown.hasPrefix(soFar), "\(how) : \(text.debugDescription) : « \(soFar) » n'est pas un début du texte final")
            let lowered = soFar.lowercased()
            #expect(!lowered.contains("[suite]") && !lowered.contains("[proposer]") && !lowered.contains("[conclure]"),
                    "\(how) : \(text.debugDescription) : un marqueur est sorti : \(soFar.debugDescription)")
        }
    }

    /// Le texte est fourni en deux morceaux, à chaque point de coupure : rendu, signal et chaque étape comme d'un bloc.
    @Test(.timeLimit(.minutes(2))) func nestedMarkersGiveTheSameTextForEveryCutInTwo() {
        for text in Self.nestedTexts {
            for cut in 0...text.unicodeScalars.count { checkNested(text, cuts: [cut], "coupure à \(cut)") }
        }
    }

    /// Le texte est fourni un scalaire à la fois.
    @Test(.timeLimit(.minutes(2))) func nestedMarkersGiveTheSameTextOneScalarAtATime() {
        for text in Self.nestedTexts {
            checkNested(text, cuts: Array(1..<max(text.unicodeScalars.count, 1)), "un scalaire à la fois")
        }
    }

    /// Les deux cas du relecteur, mot pour mot, avec ce qu'ils doivent rendre.
    @Test func theReviewersCasesGiveTheTextOfTheWholeReply() {
        for (text, expected) in [("x [CONC[PROPOSER]LURE] et la suite", "x  et la suite"),
                                 ("Merci [CONC[PROPOSER]LURE]abcdeLURE] fin", "Merci abcdeLURE] fin")] {
            let single = run(text, cuts: Array(1..<text.unicodeScalars.count))
            #expect(single.shown == expected)
            #expect(run(text).shown == expected)
        }
    }

    // MARK: Retenue non bornée (m-3 et m-4 parqués : la borne de `ca44394` a été retirée, voir N1)

    /// Une suite de `[` qui ne peut pas devenir un marqueur reste retenue jusqu'à `finish`, comme avant `ca44394` : c'est le prix
    /// d'un texte rendu indépendant du découpage. Les 42 `[` sortent à `finish`, dans l'ordre, sans rien perdre.
    @Test func aLongRunOfOpeningBracketsIsHeldUntilFinish() {
        let brackets = String(repeating: "[", count: 42)

        var filter = ReplyFilter()
        #expect(filter.feed("Bonjour " + brackets) == "Bonjour ")
        #expect(filter.finish() == brackets)
        #expect(filter.signal == .continue)

        // Même chose quand la réponse commence par les crochets : la tête n'est pas un marqueur, mais tout est retenu.
        var leading = ReplyFilter()
        #expect(leading.feed(brackets) == "")
        #expect(leading.finish() == brackets)
    }

    @Test func aLongRunOfMarkerStartsIsHeldUntilItCannotBecomeAMarkerOrUntilFinish() {
        let starts = String(repeating: "[s", count: 30)
        var filter = ReplyFilter()
        #expect(filter.feed("Voir " + starts) == "Voir ")
        #expect(filter.finish() == starts)

        var broken = ReplyFilter()
        #expect(broken.feed("Voir " + starts + "x") == "Voir " + starts + "x")
    }

    /// Ce qui est retiré ne dépend d'aucune fenêtre : un marqueur imbriqué sur plus de 12 caractères est retiré comme les autres.
    @Test func aMarkerNestedOverMoreThanTwelveCharactersIsStillRemoved() {
        #expect(run("a [SU[SUITE]ITE] b").shown == "a  b")
        #expect(run("a [SUITE] b [[SUITE]").shown == "a  b [")
        #expect(run("fin [SUIT", cuts: Array(1..<9)).shown == "fin [SUIT")
        #expect(run("x [SU[SU[SUITE]ITE]ITE] fin", cuts: Array(1..<27)).shown == "x  fin")
    }

    // MARK: Absent, inconnu, plus loin (règle 7)

    @Test func aReplyWithoutAMarkerIsShownWholeWithTheContinueSignal() {
        let result = run("Quelle est la contrainte principale ?")

        #expect(result.shown == "Quelle est la contrainte principale ?" && result.signal == .continue)
    }

    @Test func anUnknownLeadingMarkerIsRemovedAndTheSignalStaysContinue() {
        let result = run("[AUTRE]\nBonjour.")

        #expect(result.shown == "Bonjour." && result.signal == .continue)
    }

    @Test func aKnownMarkerFurtherInTheTextIsRemovedAndTheSignalDoesNotChange() {
        let plain = run("Bonjour. [CONCLURE] Merci.")
        #expect(plain.shown == "Bonjour.  Merci." && plain.signal == .continue)

        let afterAHead = run("[PROPOSER]\nBonjour. [CONCLURE] Merci. [suite]")
        #expect(afterAHead.shown == "Bonjour.  Merci. " && afterAHead.signal == .propose)

        let twoInARow = run("[SUITE][CONCLURE]\nBonjour.")
        #expect(twoInARow.shown == "Bonjour." && twoInARow.signal == .continue)
    }

    @Test func aBracketedPhraseThatIsNotAMarkerIsShownAsIs() {
        #expect(run("Voir la note [note de bas] pour le détail.").shown == "Voir la note [note de bas] pour le détail.")
        #expect(run("[note de bas] au début").shown == "[note de bas] au début")
        #expect(run("[1] Premier point").shown == "[1] Premier point")
        #expect(run("[] vide").shown == "[] vide")
        #expect(run("Une [AUTRE] chose").shown == "Une [AUTRE] chose")
    }

    @Test func aMarkerStartAtTheVeryEndOfTheStreamIsGivenBackByFinish() {
        var filter = ReplyFilter()
        #expect(filter.feed("Bonjour [SUI") == "Bonjour ")
        #expect(filter.finish() == "[SUI")

        var alone = ReplyFilter()
        #expect(alone.feed("[SUI") == "")
        #expect(alone.finish() == "[SUI")
        #expect(alone.signal == .continue)
    }

    @Test func aHeadThatIsOnlyWhitespaceOrAnOpeningBracketWaitsAndIsGivenBackByFinish() {
        var spaces = ReplyFilter()
        #expect(spaces.feed("  \n") == "")
        #expect(spaces.finish() == "  \n")

        var bracket = ReplyFilter()
        #expect(bracket.feed("[") == "")
        #expect(bracket.finish() == "[")
    }

    // MARK: La tête (algorithme)

    @Test func theHeadEndsAtTheFirstLineBreakEvenWithoutAClosingBracket() {
        var filter = ReplyFilter()
        #expect(filter.feed("[SUITE") == "")
        #expect(filter.feed("[SUITE\nQuelle") == "[SUITE\nQuelle")
        #expect(filter.signal == .continue)
    }

    @Test func theHeadEndsAtTheTwelfthCharacter() {
        var held = ReplyFilter()
        #expect(held.feed("[abcdefghij") == "")           // 11 caractères : la tête n'est pas décidée
        var decided = ReplyFilter()
        #expect(decided.feed("[abcdefghijk") == "[abcdefghijk")   // 12 caractères sans « ] » : ce n'est pas un marqueur
        var atTheLimit = ReplyFilter()
        #expect(atTheLimit.feed("[abcdefghij]x") == "x")   // « ] » est le 12ᵉ caractère : encore une tête
    }

    @Test func aLongUnknownWordInBracketsIsNotAHeadMarker() {
        let result = run("[abcdefghijklm] suite du texte")

        #expect(result.shown == "[abcdefghijklm] suite du texte")
    }

    // MARK: Texte cumulé qui ne prolonge pas le précédent

    @Test func aCumulativeTextThatDoesNotExtendThePreviousOneOnlyGivesWhatIsBeyondTheLengthAlreadyRead() {
        var filter = ReplyFilter()
        #expect(filter.feed("Bonjour") == "Bonjour")
        #expect(filter.feed("Bonsoir tout") == " tout")
        #expect(filter.feed("court") == "")
        #expect(filter.feed("") == "")
        #expect(filter.finish() == "")
    }

    @Test func feedingTheSameCumulativeTextAgainGivesNothingNew() {
        var filter = ReplyFilter()
        #expect(filter.feed("[SUITE]\nBonjour") == "Bonjour")
        #expect(filter.feed("[SUITE]\nBonjour") == "")
    }

    @Test func anEmptyReplyGivesNothing() {
        var filter = ReplyFilter()
        #expect(filter.feed("") == "")
        #expect(filter.finish() == "")
        #expect(filter.signal == .continue)
    }

    // MARK: Fixpoint

    /// Retirer un marqueur ne doit pas en fabriquer un autre : « [SU[SUITE]ITE] » ne rend rien de lisible comme marqueur.
    @Test func removingAMarkerNeverBuildsAnotherOne() {
        let result = run("a [SU[SUITE]ITE] b [CONC[PROPOSER]LURE] c")

        #expect(result.shown == "a  b  c")
    }

    @Test func theReplySignalsKeepTheirNamesAsTheModelWritesThem() {
        #expect(ReplySignal.continue.rawValue == "SUITE")
        #expect(ReplySignal.propose.rawValue == "PROPOSER")
        #expect(ReplySignal.conclude.rawValue == "CONCLURE")
    }
}
