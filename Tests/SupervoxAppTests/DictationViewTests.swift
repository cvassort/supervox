import SupervoxCore
import Testing

@testable import SupervoxApp

// Les textes et les choix de la vue de dictée : tout ce qui se décide sans dessiner (durée, coupe du texte, libellés,
// ce que montre chaque état). La vue SwiftUI ne fait qu'afficher `DictationDisplay`.

@Suite struct DictationTextTests {
    // MARK: Durée

    @Test(arguments: [
        (0.0, "0:00"), (0.4, "0:00"), (7.0, "0:07"), (7.9, "0:07"), (59.99, "0:59"), (60.0, "1:00"), (65.0, "1:05"),
        (600.0, "10:00"), (3_599.0, "59:59"),
    ])
    func aDurationIsMinutesAndTwoDigitSeconds(seconds: Double, expected: String) {
        #expect(DictationText.duration(seconds) == expected)
    }

    @Test(arguments: [-3.0, Double.nan, -Double.infinity])
    func anUnusableDurationIsZero(seconds: Double) {
        #expect(DictationText.duration(seconds) == "0:00")
    }

    // MARK: Fin du texte

    @Test func aTextShorterThanTheLimitIsUnchanged() {
        #expect(DictationText.tail("une phrase courte", maxCharacters: 40) == "une phrase courte")
        // À la limite exacte : inchangé aussi.
        #expect(DictationText.tail("abcde fghij", maxCharacters: 11) == "abcde fghij")
    }

    @Test func aTextOneCharacterOverTheLimitIsCut() {
        let text = "abcde fghij"   // 11 caractères
        let result = DictationText.tail(text, maxCharacters: 10)
        #expect(result.count <= 10)
        #expect(result.hasPrefix("…") && result.hasSuffix("fghij"))
    }

    @Test func aLongTextKeepsItsEndAndStartsAtAWordBoundary() {
        let text = "un deux trois quatre cinq six sept huit neuf dix"
        let result = DictationText.tail(text, maxCharacters: 24)
        #expect(result.hasPrefix("… "))
        #expect(result.hasSuffix("neuf dix"))
        #expect(result.count <= 24)
        // Chaque mot gardé est un mot entier du texte d'origine, jamais un morceau.
        let words = Set(text.split(separator: " ").map(String.init))
        for word in result.dropFirst(2).split(separator: " ") { #expect(words.contains(String(word)), "\(word)") }
    }

    @Test func theCutNeverSplitsAWordEvenWhenTheCutFallsInsideOne() {
        // Les 12 derniers caractères commenceraient au milieu de « extraordinaire ».
        let result = DictationText.tail("un mot extraordinaire fini", maxCharacters: 14)
        #expect(result == "… fini")
    }

    @Test func aTextWithoutAnySpaceIsCutHardRatherThanErased() {
        let result = DictationText.tail(String(repeating: "x", count: 50), maxCharacters: 10)
        #expect(result.hasPrefix("…"))
        #expect(result.count == 10)
        #expect(result.hasSuffix("xxxxxxxxx"))
    }

    @Test func accentsSurviveTheCut() {
        let result = DictationText.tail("il était une fois une forêt très éloignée où l'été dure", maxCharacters: 30)
        #expect(result.hasSuffix("où l'été dure"))
        #expect(result.count <= 30)
    }

    @Test func aTinyLimitStillGivesSomethingSensible() {
        #expect(DictationText.tail("bonjour tout le monde", maxCharacters: 1) == "…")
        #expect(DictationText.tail("", maxCharacters: 10) == "")
    }

    // MARK: Début du texte

    @Test func theStartOfALongMessageIsKeptWithAnEllipsisAtTheEnd() {
        let text = "un deux trois quatre cinq six sept huit neuf dix"
        let result = DictationText.head(text, maxCharacters: 24)
        #expect(result.hasPrefix("un deux trois"))
        #expect(result.hasSuffix(" …"))
        #expect(result.count <= 24)
        #expect(DictationText.head("court", maxCharacters: 24) == "court")
    }

    // MARK: Libellés

    @Test func everyStageHasANonEmptyLabelAndTheFixedOnesAreExact() {
        let stages: [DictationStage] = [
            .idle, .preparing, .recording, .finalizing, .review, .pasting, .copied, .cancelled,
            .failed(.noSpeech), .failed(.microphone("m")), .failed(.engine("e")), .failed(.clipboard),
        ]
        for stage in stages { #expect(!DictationText.status(for: stage).isEmpty, "\(stage)") }
        #expect(DictationText.status(for: .idle) == "Prêt")
        #expect(DictationText.status(for: .preparing) == "Préparation…")
        #expect(DictationText.status(for: .recording) == "Enregistrement")
        #expect(DictationText.status(for: .finalizing) == "Transcription…")
        #expect(DictationText.status(for: .copied) == "Texte copié")
        #expect(DictationText.status(for: .cancelled) == "Dictée interrompue")
        #expect(DictationText.status(for: .failed(.noSpeech)) == "Rien à transcrire")
        #expect(DictationText.status(for: .failed(.clipboard)) == "Texte non copié")
    }

    @Test func theLabelOfACopiedTextNeverCarriesTheDictatedText() {
        let state = DictationViewState(stage: .copied, lastTranscript: "un texte privé")
        #expect(!DictationText.status(for: state.stage).contains("privé"))
        #expect(!DictationDisplay(state: state).headline.contains("privé"))
    }

    @Test func theLabelsUseNoJargon() {
        let stages: [DictationStage] = [
            .idle, .preparing, .recording, .finalizing, .review, .pasting, .copied, .cancelled,
            .failed(.noSpeech), .failed(.microphone("m")), .failed(.engine("e")),
        ]
        for stage in stages {
            let label = DictationText.status(for: stage).lowercased()
            for word in ["jeton", "tokenizer", "prompt", "token"] { #expect(!label.contains(word), "\(label)") }
        }
    }

    // MARK: Forme d'onde

    @Test func theWaveformIsAlwaysFortyEightBarsOldestFirstPaddedWithSilenceOnTheLeft() {
        #expect(DictationText.bars([]).count == 48)
        #expect(DictationText.bars([]).allSatisfy { $0 == 0 })
        let few = DictationText.bars([0.2, 0.9])
        #expect(few.count == 48)
        #expect(Array(few.suffix(2)) == [0.2, 0.9])
        #expect(few.dropLast(2).allSatisfy { $0 == 0 })
    }

    @Test func aLongerHistoryKeepsTheMostRecentBarsAndClampsTheLevels() {
        let levels = (0..<60).map { Float($0) / 59 }
        let bars = DictationText.bars(levels)
        #expect(bars.count == 48)
        #expect(bars.last == levels.last)
        #expect(bars.first == levels[12])
        #expect(DictationText.bars([-1, 2, .nan]).suffix(3) == [0, 1, 0])
    }
}

@Suite struct DictationDisplayTests {
    private func display(_ state: DictationViewState) -> DictationDisplay {
        DictationDisplay(state: state)
    }

    // MARK: Prêt

    @Test func anIdleDictationIsReadyAndShowsTheShortcut() {
        let shown = display(DictationViewState())
        #expect(shown.headline == "Prêt")
        #expect(shown.mood == .ready)
        #expect(shown.showsHotKey)
        #expect(shown.detail == nil && shown.liveText == nil && shown.bars == nil && shown.duration == nil)
        #expect(shown.transcript == nil)
    }

    @Test func aNoticeInTheIdleStateReplacesReadyAndHidesTheShortcut() {
        let shown = display(DictationViewState(notice: "Ce mode arrive à une étape suivante."))
        #expect(shown.headline == "Ce mode arrive à une étape suivante.")
        #expect(shown.mood == .info)
        #expect(!shown.showsHotKey)
        #expect(shown.detail == nil)
    }

    // MARK: Préparation

    @Test func preparingShowsTheDownloadNoticeAndNothingElse() {
        let shown = display(DictationViewState(stage: .preparing, notice: "Téléchargement du modèle…"))
        #expect(shown.headline == "Préparation…")
        #expect(shown.mood == .working)
        #expect(shown.detail == "Téléchargement du modèle…")
        #expect(shown.bars == nil && shown.liveText == nil && shown.duration == nil)
        #expect(!shown.showsHotKey)
    }

    // MARK: Enregistrement

    @Test func recordingShowsTheDurationTheWaveformAndTheEndOfTheLiveText() throws {
        let long = (1...80).map { "mot\($0)" }.joined(separator: " ")
        let shown = display(
            DictationViewState(stage: .recording, liveText: long, levels: [0.5, 0.7], elapsed: 65.4))
        #expect(shown.headline == "Enregistrement")
        #expect(shown.mood == .recording)
        #expect(shown.duration == "1:05")
        #expect(shown.bars?.count == 48)
        #expect(shown.bars?.suffix(2) == [0.5, 0.7])
        let text = try #require(shown.liveText)
        #expect(text.hasPrefix("… "))
        #expect(text.hasSuffix("mot80"))
        #expect(text.count <= DictationText.liveTextLimit)
    }

    @Test func recordingWithoutAnyTextShowsNoTextAreaYet() {
        let shown = display(DictationViewState(stage: .recording, liveText: "", levels: [0.1], elapsed: 0))
        #expect(shown.liveText == nil)
        #expect(shown.bars?.count == 48)
        #expect(shown.duration == "0:00")
    }

    @Test func aShortLiveTextIsShownAsIs() {
        let shown = display(DictationViewState(stage: .recording, liveText: "bonjour à tous", elapsed: 2))
        #expect(shown.liveText == "bonjour à tous")
    }

    @Test func recordingKeepsTheVocabularyNoticeAsDetail() {
        let shown = display(DictationViewState(stage: .recording, elapsed: 1, notice: "Vocabulaire trop long."))
        #expect(shown.detail == "Vocabulaire trop long.")
    }

    // MARK: Transcription

    @Test func finalizingKeepsTheTextAndTheDurationButNoWaveform() {
        let shown = display(
            DictationViewState(stage: .finalizing, liveText: "bonjour à tous", levels: [0.4], elapsed: 12))
        #expect(shown.headline == "Transcription…")
        #expect(shown.mood == .working)
        #expect(shown.duration == "0:12")
        #expect(shown.liveText == "bonjour à tous")
        #expect(shown.bars == nil)
    }

    // MARK: Échecs, copie, interruption

    @Test func aFailureShowsItsLabelAndItsMessageAndNoShortcut() {
        let shown = display(DictationViewState(stage: .failed(.noSpeech), notice: "Aucune parole n'a été entendue."))
        #expect(shown.headline == "Rien à transcrire")
        #expect(shown.mood == .failure)
        #expect(shown.detail == "Aucune parole n'a été entendue.")
        #expect(!shown.showsHotKey)
    }

    @Test func aTextCopiedForWantOfAccessibilityShowsItsReasonAndTheTextOnce() {
        let reason = "Le texte dicté est copié dans le presse-papiers : faites ⌘V."
        let shown = display(
            DictationViewState(stage: .copied, notice: reason, lastTranscript: "Bonjour à tous."))
        #expect(shown.headline == "Texte copié")
        #expect(shown.mood == .success)
        #expect(shown.detail == reason)
        #expect(shown.transcript?.text == "Bonjour à tous.")
        // Le texte n'est ni dans le titre ni dans le détail : une seule fois, dans la carte.
        #expect(!shown.headline.contains("Bonjour") && shown.detail?.contains("Bonjour") == false)
        // Pas d'étiquette « dernière dictée » : c'est le texte de cette dictée-ci.
        #expect(shown.transcript?.label == nil)
    }

    @Test func aCancelledDictationSaysSo() {
        let shown = display(DictationViewState(stage: .cancelled, notice: "La dictée a été interrompue."))
        #expect(shown.headline == "Dictée interrompue")
        #expect(shown.detail == "La dictée a été interrompue.")
    }

    @Test func aVeryLongMessageIsBoundedSoThatItCannotBreakTheFixedHeight() {
        let long = String(repeating: "une raison très longue ", count: 60)
        let shown = display(DictationViewState(stage: .failed(.engine("x")), notice: long))
        #expect((shown.detail?.count ?? .max) <= DictationText.detailLimit)
        #expect(shown.detail?.hasSuffix("…") == true)
    }

    // MARK: Texte récupérable

    @Test func theLastTranscriptIsOfferedWhenNoDictationIsRunning() {
        let text = "Le texte d'avant."
        for state in [
            DictationViewState(lastTranscript: text),
            DictationViewState(stage: .failed(.noSpeech), notice: "x", lastTranscript: text),
            DictationViewState(stage: .cancelled, notice: "y", lastTranscript: text),
            DictationViewState(notice: "mode", lastTranscript: text),
        ] {
            let card = display(state).transcript
            #expect(card?.text == text, "\(state.stage)")
            #expect(card?.label == "Dernière dictée", "\(state.stage)")
        }
    }

    @Test func theLastTranscriptIsHiddenWhileADictationRuns() {
        for stage in [DictationStage.preparing, .recording, .finalizing] {
            let state = DictationViewState(stage: stage, lastTranscript: "Le texte d'avant.")
            #expect(display(state).transcript == nil, "\(stage)")
        }
    }

    /// La vue de relecture (tâche 5) se pose par-dessus : la carte « Dernière dictée » ne doit pas se montrer en même temps
    /// qu'elle, ni pendant le collage.
    @Test(arguments: [DictationStage.review, .pasting])
    func theLastTranscriptCardIsHiddenWhileTheTextIsReviewedOrPasted(_ stage: DictationStage) {
        let state = DictationViewState(stage: stage, lastTranscript: "Le texte d'avant.", draft: "Le texte relu.")
        #expect(display(state).transcript == nil, "\(stage)")
    }

    @Test func theToneAndTheHeadlineOfReviewAndPastingAreFixed() {
        let review = display(DictationViewState(stage: .review, lastTranscript: "t", draft: "t"))
        #expect(review.mood == .info)
        #expect(review.headline == "À relire")
        #expect(review.showsHotKey == false)
        let pasting = display(DictationViewState(stage: .pasting, lastTranscript: "t", draft: "t"))
        #expect(pasting.mood == .working)
        #expect(pasting.headline == "Collage…")
        #expect(pasting.showsHotKey == false)
    }

    @Test func reviewKeepsItsNoticeAsDetailAndNeverShowsTheDraftInTheHeadline() {
        let shown = display(DictationViewState(stage: .review, notice: "Un avis.", draft: "Texte privé"))
        #expect(shown.detail == "Un avis.")
        #expect(!shown.headline.contains("Texte privé"))
    }

    @Test func theDraftIsEmptyByDefaultAndPartOfTheState() {
        #expect(DictationViewState().draft == "")
        #expect(DictationViewState(stage: .review, draft: "a") != DictationViewState(stage: .review, draft: "b"))
    }

    @Test func noTranscriptNoCardAndABlankOneNeither() {
        #expect(display(DictationViewState()).transcript == nil)
        #expect(display(DictationViewState(lastTranscript: "")).transcript == nil)
        #expect(display(DictationViewState(lastTranscript: "  \n ")).transcript == nil)
    }

    @Test func theCardCarriesTheCopyState() {
        for copy in [CopyState.idle, .copied, .failed] {
            let card = DictationDisplay(state: DictationViewState(lastTranscript: "Un texte."), copy: copy).transcript
            #expect(card?.copy == copy)
        }
        #expect(DictationDisplay(state: DictationViewState(lastTranscript: "Un texte.")).transcript?.copy == .idle)
    }

    @Test func theCopyFailureHasItsOwnPlainWords() {
        #expect(DictationText.copyLabel(for: .idle) == "Copier")
        #expect(DictationText.copyLabel(for: .copied) == "Copié")
        #expect(DictationText.copyLabel(for: .failed) == "Copier")
        #expect(DictationText.copyFailure == "Copie impossible")
    }

    @Test func theCardShowsTheEndOfALongTranscript() {
        let long = (1...200).map { "mot\($0)" }.joined(separator: " ")
        let card = display(DictationViewState(lastTranscript: long)).transcript
        #expect(card?.text.hasPrefix("… ") == true)
        #expect(card?.text.hasSuffix("mot200") == true)
        #expect((card?.text.count ?? .max) <= DictationText.transcriptLimit)
    }
}

@Suite struct DictationStageTests {
    private static let stages: [DictationStage] = [
        .idle, .preparing, .recording, .finalizing, .review, .pasting, .copied, .cancelled,
        .failed(.noSpeech), .failed(.microphone("m")), .failed(.engine("e")), .failed(.clipboard),
    ]

    @Test func onlyThePreparationTheRecordingAndTheFinalizationAreActive() {
        for stage in Self.stages {
            let expected = [DictationStage.preparing, .recording, .finalizing].contains(stage)
            #expect(stage.isActive == expected, "\(stage)")
        }
    }

    @Test func thePanelIsHeldWhileActiveOrInReviewOrPasting() {
        for stage in Self.stages {
            let expected = [DictationStage.preparing, .recording, .finalizing, .review, .pasting].contains(stage)
            #expect(stage.holdsPanel == expected, "\(stage)")
        }
    }

    @Test func everyStageHasANonEmptyLabelAndTheNewOnesAreExact() {
        for stage in Self.stages { #expect(!DictationText.status(for: stage).isEmpty, "\(stage)") }
        #expect(DictationText.status(for: .review) == "À relire")
        #expect(DictationText.status(for: .pasting) == "Collage…")
        #expect(DictationText.status(for: .copied) == "Texte copié")
    }
}
