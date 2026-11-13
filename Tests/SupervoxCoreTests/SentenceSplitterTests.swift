import Testing
@testable import SupervoxCore

/// Phrases rendues par `feed` sur chaque morceau, puis le reste rendu par `flush`.
private func run(_ fragments: [String]) -> (sentences: [String], tail: String?) {
    var splitter = SentenceSplitter()
    var sentences: [String] = []
    for fragment in fragments { sentences += splitter.feed(fragment) }
    return (sentences, splitter.flush())
}

private func run(_ text: String) -> (sentences: [String], tail: String?) { run([text]) }

@Suite("SentenceSplitterTests")
struct SentenceSplitterTests {
    // MARK: Les trois tests du cahier des charges

    @Test func splitsOnSentenceEndAcrossFragments() {
        var s = SentenceSplitter()
        #expect(s.feed("D'accord. Quel est l'obj") == ["D'accord."])
        #expect(s.feed("ectif ? Et la") == ["Quel est l'objectif ?"])
        #expect(s.flush() == "Et la")
        #expect(s.flush() == nil)
    }

    @Test func doesNotSplitInsideAbbreviationsDecimalsOrEllipsis() {
        var s = SentenceSplitter()
        #expect(s.feed("M. Dupont utilise la version 3.5 du SDK, etc. ") == [])
        #expect(s.feed("Attends… je vérifie. ") == ["M. Dupont utilise la version 3.5 du SDK, etc. Attends… je vérifie."])
    }

    @Test func handlesEmptyAndWhitespaceOnlyFragments() {
        var s = SentenceSplitter()
        #expect(s.feed("") == [] && s.feed("   \n") == [] && s.flush() == nil)
    }

    // MARK: Fermants et espaces insécables

    @Test func closingQuoteOrParenthesisStaysWithItsSentence() {
        #expect(run("Il a dit « Pars ! » Puis il est parti.") == (["Il a dit « Pars ! »"], "Puis il est parti."))
        #expect(run("Il dit \"Pars.\" Puis rien. ") == (["Il dit \"Pars.\"", "Puis rien."], nil))
        #expect(run("(Il part.) Puis il revient") == (["(Il part.)"], "Puis il revient"))
        #expect(run("Voir le fichier (main.swift). Suite") == (["Voir le fichier (main.swift)."], "Suite"))
        #expect(run("Lis [la doc !] Merci. ") == (["Lis [la doc !]", "Merci."], nil))
    }

    @Test func openingQuoteAfterATerminatorStartsTheNextSentence() {
        #expect(run("Bonjour. « Tu viens ? » Oui. ") == (["Bonjour.", "« Tu viens ? »", "Oui."], nil))
    }

    @Test func nonBreakingSpacesBeforeTheTerminatorAndBeforeTheClosingGuillemetAreKept() {
        #expect(run("Quel est l'objectif\u{00A0}? Et la suite") == (["Quel est l'objectif\u{00A0}?"], "Et la suite"))
        #expect(run("Super\u{202F}! Merci. ") == (["Super\u{202F}!", "Merci."], nil))
        #expect(run("« Tu viens\u{00A0}?\u{00A0}» Oui. ") == (["« Tu viens\u{00A0}?\u{00A0}»", "Oui."], nil))
        #expect(run("« Tu viens ? » Oui. ") == (["« Tu viens ? »", "Oui."], nil))
    }

    // MARK: Plusieurs terminateurs, points de suspension

    @Test func aRunOfTerminatorsIsOneBoundary() {
        #expect(run("Vraiment ?! Oui !!! Non. ") == (["Vraiment ?!", "Oui !!!", "Non."], nil))
        #expect(run("Quoi ?!") == ([], "Quoi ?!"))     // rien après : c'est `flush` qui le rend
    }

    @Test func ellipsisNeverEndsASentence() {
        #expect(run("Attends... voyons. ") == (["Attends... voyons."], nil))
        #expect(run("Hmm… oui. ") == (["Hmm… oui."], nil))
        #expect(run("Bon.. d'accord. ") == (["Bon.. d'accord."], nil))
        #expect(run("Je ne sais pas... ") == ([], "Je ne sais pas..."))
    }

    @Test func aQuestionOrExclamationAfterAnEllipsisDoesEndTheSentence() {
        #expect(run("Vraiment...? Oui. ") == (["Vraiment...?", "Oui."], nil))
        #expect(run("Ah…! Super. ") == (["Ah…!", "Super."], nil))
    }

    // MARK: Noms de fichiers, versions, adresses

    @Test func dotsGluedToWhatFollowsNeverEndASentence() {
        let text = "Ouvre main.swift puis lance v2.1 avec node.js sur https://exemple.test/a.b?x=1&y=2 maintenant. Fin. "
        #expect(run(text) == (["Ouvre main.swift puis lance v2.1 avec node.js sur https://exemple.test/a.b?x=1&y=2 maintenant.", "Fin."], nil))
        #expect(run("Ouvre main.swift. Puis node.js. ") == (["Ouvre main.swift.", "Puis node.js."], nil))
        #expect(run("Version 3.5.1 sortie. ") == (["Version 3.5.1 sortie."], nil))
        #expect(run("Lis https://exemple.test/doc?lang=fr maintenant. ") == (["Lis https://exemple.test/doc?lang=fr maintenant."], nil))
    }

    // MARK: Terminateur coupé entre deux morceaux

    @Test func aTerminatorSplitAcrossFragmentsIsJudgedOnTheWholeText() {
        var s = SentenceSplitter()
        // « ... » arrive en trois morceaux d'un point : aucune coupe à la première, ni à la deuxième.
        #expect(s.feed("Attends") == [])
        #expect(s.feed(".") == [])
        #expect(s.feed(".") == [])
        #expect(s.feed(".") == [])
        #expect(s.feed(" voilà. ") == ["Attends... voilà."])

        #expect(run(["Version 3.", "5 est sortie. "]) == (["Version 3.5 est sortie."], nil))
        #expect(run(["M", ".", " Dupont arrive. "]) == (["M. Dupont arrive."], nil))
        #expect(run(["Il y a des pommes, etc", ".", " Puis des poires. "]) == (["Il y a des pommes, etc. Puis des poires."], nil))
        #expect(run(["C'est à dire, i.", "e", ". ", "la fin. "]) == (["C'est à dire, i.e. la fin."], nil))
        #expect(run(["Quoi?", "! Oui. "]) == (["Quoi?!", "Oui."], nil))
        #expect(run(["Il dit « Pars !", " », puis il part. "]) == (["Il dit « Pars ! », puis il part."], nil))
    }

    @Test func aTerminatorAtTheVeryEndWaitsForTheNextFragmentAndIsReleasedByFlush() {
        var s = SentenceSplitter()
        #expect(s.feed("Fin.") == [])
        #expect(s.flush() == "Fin.")
        #expect(s.feed("Fin. ") == ["Fin."])
        #expect(s.feed("Fin.\n") == ["Fin."])
    }

    /// Limite assumée : si l'espace qui précède `»` est le dernier caractère d'un morceau, la phrase sort sans lui.
    @Test func closingGuillemetSeparatedByAFragmentBoundaryStartsTheNextSentence() {
        #expect(run(["« Tu viens ? ", "» Oui. "]) == (["« Tu viens ?", "» Oui."], nil))
        #expect(run(["« Tu viens ?", " » Oui. "]) == (["« Tu viens ? »", "Oui."], nil))    // coupé ailleurs : correct
    }

    /// Limite assumée : après `?` ou `!`, la suite en minuscule (incise de dialogue, parenthèse) ne retient pas la coupe.
    /// Pas de règle « minuscule = même phrase » : elle ne peut pas se décider quand le morceau s'arrête sur l'espace.
    @Test func aQuestionOrExclamationFollowedByTheSameSentenceStillCuts() {
        #expect(run("« Tu viens ? » demanda-t-il. Oui. ") == (["« Tu viens ? »", "demanda-t-il.", "Oui."], nil))
        #expect(run("(peut-être ?) demain. ") == (["(peut-être ?)", "demain."], nil))
        #expect(run("Super ! et ensuite. ") == (["Super !", "et ensuite."], nil))
    }

    // MARK: Fins de ligne

    @Test func aNewlineEndsASentenceEvenWithoutATerminator() {
        let text = "Voici les étapes\n1. Ouvrir le fichier\n2. Lancer le test\nFini. "
        #expect(run(text) == (["Voici les étapes", "1. Ouvrir le fichier", "2. Lancer le test", "Fini."], nil))
        #expect(run("Ligne un\r\nLigne deux\r\n") == (["Ligne un", "Ligne deux"], nil))
        #expect(run("Ligne un\rLigne deux\r") == (["Ligne un", "Ligne deux"], nil))
        #expect(run("A\n\n\n  B\n") == (["A", "B"], nil))
        // Même après une abréviation ou des points de suspension : une fin de ligne est une pause.
        #expect(run("Des pommes, etc.\nPuis rien…\nFin") == (["Des pommes, etc.", "Puis rien…"], "Fin"))
    }

    @Test func aCRLFSplitAcrossFragmentsIsOneBoundary() {
        #expect(run(["Ligne un\r", "\nLigne deux\r", "\n"]) == (["Ligne un", "Ligne deux"], nil))
    }

    @Test func aNumberAloneAtTheStartOfASentenceIsAListMarker() {
        #expect(run("1. Ouvrir le fichier. 2. Lancer le test. ") == (["1. Ouvrir le fichier.", "2. Lancer le test."], nil))
        #expect(run("12. Dernier point. ") == (["12. Dernier point."], nil))
        // Un nombre qui termine une phrase ordinaire coupe bien.
        #expect(run("J'en ai 3. Puis rien. ") == (["J'en ai 3.", "Puis rien."], nil))
    }

    // MARK: Abréviations

    @Test(arguments: [
        "M.", "Mme.", "Mlle.", "MM.", "Mr.", "Mrs.", "Dr.", "Pr.", "St.", "etc.", "ex.", "cf.", "p.", "pp.", "vs.", "env.", "approx.", "fig.", "i.e.", "e.g.",
        "ETC.", "Cf.", "I.E.",
    ])
    func listedAbbreviationsDoNotEndASentence(abbreviation: String) {
        #expect(run("Voir \(abbreviation) Suite de la phrase. ") == (["Voir \(abbreviation) Suite de la phrase."], nil))
        #expect(run("\(abbreviation) Suite de la phrase. ") == (["\(abbreviation) Suite de la phrase."], nil))
    }

    @Test func wordsThatOnlyLookLikeAbbreviationsDoEndASentence() {
        #expect(run("C'est un exemple. Puis un appel. ") == (["C'est un exemple.", "Puis un appel."], nil))
        #expect(run("Il est parti. Moi, je reste. ") == (["Il est parti.", "Moi, je reste."], nil))
        #expect(run("Prends le plan B. Puis pars. ") == (["Prends le plan B.", "Puis pars."], nil))
        #expect(run("Je dis non. Il dit oui. ") == (["Je dis non.", "Il dit oui."], nil))
    }

    @Test func numeroSignNeedsNoSpecialCase() {
        #expect(run("Voir le n° 12 et le n° 13. Merci. ") == (["Voir le n° 12 et le n° 13.", "Merci."], nil))
    }

    /// Limite assumée par le cahier des charges : une phrase qui se termine vraiment par « etc. » est collée à la suivante.
    @Test func aSentenceReallyEndingWithEtcIsJoinedToTheNextOne() {
        #expect(run("Il y a des pommes, des poires, etc. Ensuite on part. ") == (["Il y a des pommes, des poires, etc. Ensuite on part."], nil))
    }

    // MARK: Sans terminateur, texte très long

    @Test func textWithoutTerminatorComesOutOnlyWithFlush() {
        var s = SentenceSplitter()
        #expect(s.feed("Bonjour tout le monde") == [])
        #expect(s.feed(" et bienvenue") == [])
        #expect(s.flush() == "Bonjour tout le monde et bienvenue")
        #expect(s.flush() == nil)
        // Le découpeur reste utilisable après `flush`.
        #expect(s.feed("Encore. ") == ["Encore."])
    }

    @Test func partsWithoutLetterOrDigitAreDropped() {
        #expect(run("— \n… \n?! Bonjour. ") == (["Bonjour."], nil))
        #expect(run("—") == ([], nil))
        #expect(run("...") == ([], nil))
    }

    @Test func aVeryLongRunIsCutAtTheLastCommaOnceItExceedsTheLimit() {
        let limit = SentenceSplitter.maxPendingLength
        let text = String(repeating: "mot, ", count: 200)         // 1000 caractères, aucune phrase possible
        var splitter = SentenceSplitter()
        var sentences = splitter.feed(text)
        let tail = splitter.flush()
        #expect(!sentences.isEmpty)
        #expect(sentences.allSatisfy { $0.hasSuffix(",") && $0.count <= limit })
        #expect((tail?.count ?? 0) <= limit)
        // Rien n'est perdu ni inventé : les morceaux recollés redonnent le texte.
        sentences += tail.map { [$0] } ?? []
        #expect(sentences.joined(separator: " ") == text.trimmingCharacters(in: .whitespaces))

        // Même résultat en recevant le texte mot à mot, comme un flux.
        var streamed = SentenceSplitter()
        var pieces: [String] = []
        for word in text.split(separator: " ", omittingEmptySubsequences: false) { pieces += streamed.feed(String(word) + " ") }
        pieces += streamed.flush().map { [$0] } ?? []
        #expect(pieces.allSatisfy { $0.count <= limit })
        #expect(pieces.joined(separator: " ") == text.trimmingCharacters(in: .whitespaces))
    }

    @Test func theLimitIsNotReachedAtExactlyTheLimitAndAColonWithoutSpaceIsNotABreak() {
        let limit = SentenceSplitter.maxPendingLength
        let exact = String(repeating: "a, ", count: limit / 3)       // exactement `limit` caractères avec l'espace final
        #expect(exact.count == limit)
        #expect(run(exact).sentences == [])
        let over = exact + "b, c"
        #expect(run(over).sentences.count == 1)
        // Une heure (12:30) ou une adresse (http://…) n'est pas une pause.
        let noBreak = String(repeating: "12:30 ", count: 100)
        #expect(run(noBreak).sentences == [])
    }

    @Test func aVeryLongRunWithoutAnyBreakPunctuationWaitsForFlush() {
        let text = String(repeating: "mot ", count: 200).trimmingCharacters(in: .whitespaces)
        #expect(run(text) == ([], text))
    }

    // MARK: Le découpage ne dépend pas de la façon dont le texte arrive

    private static let texts = [
        "D'accord. Quel est l'objectif ? Et la suite arrive bientôt.",
        "M. Dupont utilise la version 3.5 du SDK, etc. Attends… je vérifie. Voilà.",
        "Il a dit « Pars!» Puis il est parti. Bonjour. « Tu viens?» Oui. Il dit \"Non.\" Puis il part.",
        "Ouvre main.swift puis lance v2.1 avec node.js sur https://exemple.test/a.b?x=1&y=2 maintenant. Fin.",
        "Vraiment ?! Oui !!! Non. Attends... voyons. Hmm… oui.",
        "Voici les étapes\n1. Ouvrir le fichier\r\n2. Lancer le test\nFini. 3. Dernier.",
        "Quel est l'objectif\u{00A0}? Super\u{202F}! Merci. (Il part.) Puis il revient.",
        "C'est à dire, i.e. la fin, e.g. celle-ci, cf. page 12. Ok. ",
        "Un exemple. Mme. Martin arrive. Dr. Who aussi. Le plan B. Puis pars.",
        "Pas de terminateur du tout, juste du texte",
    ]

    /// (Les textes n'ont aucun espace entre un terminateur et un `»` : c'est la limite testée plus haut, qui dépend du découpage.)
    ///
    /// Toutes les coupes en deux morceaux, le texte lettre par lettre et plusieurs découpages irréguliers donnent
    /// exactement les mêmes phrases et le même reste que le texte reçu d'un bloc.
    @Test(arguments: SentenceSplitterTests.texts)
    func fragmentationNeverChangesTheResult(text: String) {
        let whole = run(text)
        let characters = text.map(String.init)
        #expect(run(characters) == whole, "lettre par lettre : \(text)")
        for cut in 0...characters.count {
            let pair = [characters[..<cut].joined(), characters[cut...].joined()]
            #expect(run(pair) == whole, "coupe en deux après \(cut) caractères : \(text)")
        }
        for step in [2, 3, 5, 7, 11] {
            let chunks = stride(from: 0, to: characters.count, by: step).map { characters[$0..<min($0 + step, characters.count)].joined() }
            #expect(run(chunks) == whole, "morceaux de \(step) : \(text)")
        }
    }

    /// Le test précédent n'est pas creux : les textes donnent bien plusieurs phrases, pas seulement un reste.
    @Test func sampleTextsDoProduceSentences() {
        let counts = SentenceSplitterTests.texts.map { run($0).sentences.count }
        #expect(counts == [2, 1, 6, 1, 4, 4, 4, 2, 4, 0])
    }
}
