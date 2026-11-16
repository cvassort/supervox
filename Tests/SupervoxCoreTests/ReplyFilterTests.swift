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

    // MARK: Retenue bornée (m-3, m-4)

    /// Une suite de `[` qui ne peut pas devenir un marqueur n'est pas retenue sans borne : au plus 12 caractères restent en
    /// attente, le reste est rendu tout de suite ; `finish` rend ces 12 derniers.
    @Test func aLongRunOfOpeningBracketsIsReleasedAtOnceExceptTheLastTwelve() {
        let brackets = String(repeating: "[", count: 42)

        var filter = ReplyFilter()
        #expect(filter.feed("Bonjour " + brackets) == "Bonjour " + String(repeating: "[", count: 30))
        #expect(filter.finish() == String(repeating: "[", count: 12))
        #expect(filter.signal == .continue)

        // Même chose quand la réponse commence par les crochets (la tête est décidée au 12ᵉ caractère : ce n'est pas un marqueur).
        var leading = ReplyFilter()
        #expect(leading.feed(brackets) == String(repeating: "[", count: 30))
        #expect(leading.finish() == String(repeating: "[", count: 12))
    }

    @Test func aLongRunOfMarkerStartsIsReleasedAtOnceExceptTheLastTwelve() {
        let starts = String(repeating: "[s", count: 30)   // 60 caractères, chaque `[s` est un début de `[suite]`
        var filter = ReplyFilter()
        let shown = filter.feed("Voir " + starts)

        #expect(shown == "Voir " + String(starts.dropLast(12)))
        #expect(filter.finish() == String(starts.suffix(12)))
    }

    /// Le texte rendu est le même qu'avant la borne tant que le texte retenu tient dans les 12 caractères : le marqueur de la fin
    /// du flux coupé en deux, imbriqué sur moins de 12 caractères, reste retiré.
    @Test func theBoundDoesNotChangeWhatIsRemovedWithinTheTwelveCharacters() {
        #expect(run("a [SU[SUITE]ITE] b").shown == "a  b")
        #expect(run("a [SUITE] b [[SUITE]").shown == "a  b [")
        #expect(run("fin [SUIT", cuts: Array(1..<9)).shown == "fin [SUIT")
    }

    /// Pour chaque début de chacune des six réponses, ce que `finish` rend en plus de ce que `feed` a rendu tient en 12 scalaires.
    @Test(arguments: responses.indices)
    func whatIsHeldNeverExceedsTwelveCharacters(index: Int) {
        let scalars = Array(responses[index].text.unicodeScalars)
        for count in 0...scalars.count {
            var prefix = String.UnicodeScalarView()
            prefix.append(contentsOf: scalars[0..<count])
            var filter = ReplyFilter()
            _ = filter.feed(String(prefix))
            #expect(filter.finish().unicodeScalars.count <= 12, "début de \(count) caractères")
        }
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
