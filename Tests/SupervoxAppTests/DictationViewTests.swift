import AppKit
import Foundation
import SupervoxCore
import SwiftUI
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

    // MARK: Champ de relecture

    @Test func theEditorHasItsBoundsAndItsHint() {
        #expect(DictationText.editorMinHeight == 62)
        #expect(DictationText.editorMaxHeight == 242)
        #expect(
            DictationText.reviewHint
                == "⌘↩ colle le texte. Échap ferme sans coller ; le texte reste dans « Dernière dictée ».")
    }

    @Test(arguments: [
        (0.0, 62.0), (100.0, 100.0), (10_000.0, 242.0), (-5.0, 62.0), (61.9, 62.0), (62.0, 62.0), (241.9, 241.9),
        (242.0, 242.0), (242.1, 242.0), (-Double.infinity, 62.0),
    ])
    func theEditorHeightFollowsTheContentBetweenItsBounds(content: Double, expected: Double) {
        #expect(DictationText.editorHeight(contentHeight: CGFloat(content)) == CGFloat(expected))
    }

    @Test func anUnusableContentHeightGivesTheLowerBound() {
        #expect(DictationText.editorHeight(contentHeight: .nan) == 62)
        #expect(DictationText.editorHeight(contentHeight: .infinity) == 62)
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
        #expect(review.mood == .review)
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

@Suite struct DictationReviewDisplayTests {
    private func display(_ state: DictationViewState, copy: CopyState = .idle) -> DictationDisplay {
        DictationDisplay(state: state, copy: copy)
    }

    @Test(arguments: [DictationStage.review, .pasting])
    func reviewAndPastingShowTheReviewAndNeitherTheLastTranscriptNorLiveText(_ stage: DictationStage) {
        let state = DictationViewState(
            stage: stage, liveText: "texte en direct", notice: "Un avis.", lastTranscript: "Le texte d'avant.",
            draft: "Le texte relu.")
        let shown = display(state)
        #expect(shown.review != nil, "\(stage)")
        #expect(shown.transcript == nil, "\(stage)")
        #expect(shown.liveText == nil, "\(stage)")
        #expect(shown.detail == "Un avis.", "\(stage)")
        #expect(shown.duration == nil && shown.bars == nil, "\(stage)")
    }

    @Test func theNoticeOfAReviewIsTheDetailEvenWhenNone() {
        #expect(display(DictationViewState(stage: .review, draft: "a")).detail == nil)
        #expect(display(DictationViewState(stage: .pasting, draft: "a")).detail == nil)
    }

    @Test func outsideTheReviewThereIsNoReviewEvenWithADraft() {
        let stages: [DictationStage] = [
            .idle, .preparing, .recording, .finalizing, .copied, .cancelled, .failed(.noSpeech), .failed(.clipboard),
        ]
        for stage in stages {
            #expect(display(DictationViewState(stage: stage, draft: "Un reste.")).review == nil, "\(stage)")
        }
    }

    @Test func theReviewCarriesTheWholeDraftUntouched() {
        // Plus long que toute coupe, avec des espaces et des sauts de ligne aux deux bouts : rien n'est rogné ni coupé.
        let draft = "  \n" + String(repeating: "mot « guillemets » -- tiret   espaces\n", count: 80) + "  "
        #expect(draft.count > DictationText.liveTextLimit)
        #expect(display(DictationViewState(stage: .review, draft: draft)).review?.text == draft)
        #expect(display(DictationViewState(stage: .pasting, draft: draft)).review?.text == draft)
    }

    @Test func inReviewTheTextCanBeEditedPastedAndCopied() throws {
        let review = try #require(display(DictationViewState(stage: .review, draft: "Un texte.")).review)
        #expect(review.isEditable && review.canPaste && review.canCopy)
        #expect(!review.isPasting)
    }

    @Test func whilePastingNothingCanBeEditedPastedOrCopied() throws {
        let review = try #require(display(DictationViewState(stage: .pasting, draft: "Un texte.")).review)
        #expect(!review.isEditable && !review.canPaste && !review.canCopy)
        #expect(review.isPasting)
    }

    @Test(arguments: ["", " ", "  \n\t ", "\u{00A0}"])
    func aBlankDraftCanNeitherBePastedNorCopied(_ draft: String) throws {
        let review = try #require(display(DictationViewState(stage: .review, draft: draft)).review)
        #expect(!review.canPaste && !review.canCopy)
        // Mais on peut encore y écrire.
        #expect(review.isEditable)
    }

    @Test func theReviewCarriesTheCopyState() throws {
        for copy in [CopyState.idle, .copied, .failed] {
            #expect(display(DictationViewState(stage: .review, draft: "a"), copy: copy).review?.copy == copy)
        }
    }

    @Test func theReviewToneIsItsOwnAndPastingKeepsTheWaitingTone() {
        #expect(display(DictationViewState(stage: .review, draft: "a")).mood == .review)
        #expect(display(DictationViewState(stage: .pasting, draft: "a")).mood == .working)
    }

    /// Une seule règle, deux endroits : le modèle du panneau et l'affichage ne doivent pas diverger.
    @MainActor @Test func canPasteAgreesWithThePanelModelForEveryStageAndDraft() {
        let stages: [DictationStage] = [.idle, .review, .pasting, .copied, .failed(.clipboard)]
        for stage in stages {
            for draft in ["", "  \n ", "Un texte.", " a "] {
                let state = DictationViewState(stage: stage, draft: draft)
                let model = PanelModel(lastModeID: ModeChip.rawID)
                model.dictation = state
                #expect(
                    (display(state).review?.canPaste ?? false) == model.canPaste, "\(stage) « \(draft) »")
            }
        }
    }
}

/// La vue de relecture elle-même, sans fenêtre : des vues d'hébergement que l'on met en page et que l'on interroge.
@MainActor @Suite struct ReviewViewTests {
    private static let width: CGFloat = 520

    private func lines(_ count: Int) -> String {
        (1...count).map { "ligne \($0)" }.joined(separator: "\n")
    }

    private func review(_ text: String, stage: DictationStage = .review) -> DictationDisplay {
        DictationDisplay(state: DictationViewState(stage: stage, draft: text))
    }

    private func hosting(
        _ text: String, stage: DictationStage = .review, edit: @escaping @MainActor (String) -> Void = { _ in }
    ) -> NSHostingView<some View> {
        let display = review(text, stage: stage)
        let view = ReviewView(display: display, review: display.review!, edit: edit, paste: {}, copy: {})
            .frame(width: Self.width)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func height(_ text: String, stage: DictationStage = .review) -> CGFloat {
        hosting(text, stage: stage).fittingSize.height
    }

    private func field(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for sub in view.subviews { if let found = field(in: sub) { return found } }
        return nil
    }

    // MARK: Mesure du texte

    @Test func theMeasuredHeightGrowsWithTheNumberOfLines() {
        let field = ReviewTextView.makeTextView()
        var previous: CGFloat = 0
        for count in [1, 2, 5, 10, 20] {
            field.string = lines(count)
            let measured = ReviewTextView.contentHeight(of: field, width: 480)
            #expect(measured > previous, "\(count) lignes : \(measured) après \(previous)")
            previous = measured
        }
    }

    @Test func aLineThatWrapsIsTallerThanTheSameLineWithRoom() {
        let field = ReviewTextView.makeTextView()
        field.string = String(repeating: "des mots qui se suivent ", count: 12)
        let wide = ReviewTextView.contentHeight(of: field, width: 900)
        let narrow = ReviewTextView.contentHeight(of: field, width: 200)
        #expect(narrow > wide * 2, "étroit \(narrow), large \(wide)")
    }

    @Test func aFinalNewlineAddsALineToTheMeasure() {
        let field = ReviewTextView.makeTextView()
        field.string = "bonjour"
        let without = ReviewTextView.contentHeight(of: field, width: 480)
        field.string = "bonjour\n"
        #expect(ReviewTextView.contentHeight(of: field, width: 480) > without)
    }

    @Test func measuringKeepsTheFieldOnTextKitTwo() {
        let field = ReviewTextView.makeTextView()
        field.string = lines(3)
        _ = ReviewTextView.contentHeight(of: field, width: 480)
        #expect(field.textLayoutManager != nil)
    }

    // MARK: Hauteur dans la vue

    @Test func theFieldKeepsItsLowerBoundForAShortOrEmptyText() {
        // Le champ seul : ni plus bas que la borne, ni plus haut pour une ligne.
        let short = height("Bonjour.")
        #expect(short == height(""))
        #expect(short == height(lines(2)))
        #expect(short == height(lines(3)))
    }

    @Test func theViewGrowsWithTheTextThenStopsAtTheUpperBound() {
        let short = height(lines(3))
        let ten = height(lines(10))
        let twelve = height(lines(12))
        let huge = height(lines(300))
        let enormous = height(lines(3_000))
        #expect(ten > short)
        #expect(twelve > ten)
        #expect(huge > twelve)
        // Au-delà de la borne haute, le champ défile : la vue ne grandit plus.
        #expect(huge == enormous)
        #expect(huge - short == DictationText.editorMaxHeight - DictationText.editorMinHeight)
    }

    @Test func theFieldIsReadOnlyWhilePastingAndEditableInReview() throws {
        let editable = try #require(field(in: hosting("Un texte.")))
        #expect(editable.isEditable)
        #expect(editable.string == "Un texte.")
        let locked = try #require(field(in: hosting("Un texte.", stage: .pasting)))
        #expect(!locked.isEditable)
    }

    // MARK: La frappe arrive telle quelle

    /// Ce que le champ donne arrive tel quel, tout de suite, au modèle : ni rognage, ni normalisation, ni report.
    @Test func whatIsTypedReachesThePanelModelAtOnceAndUntouched() throws {
        let model = PanelModel(lastModeID: ModeChip.rawID)
        model.dictation = DictationViewState(stage: .review, draft: "")
        var told: [String] = []
        model.onDraftChange = { told.append($0) }
        let panel = NSHostingView(
            rootView: PanelView(
                model: model, permissions: PermissionsModel(probe: ReviewProbe()), openSettings: {}, quit: {}))
        panel.layoutSubtreeIfNeeded()
        let textView = try #require(field(in: panel))
        let typed = "  « guillemets » -- tirets   espaces\n"
        textView.insertText(typed, replacementRange: NSRange(location: 0, length: 0))
        // Aucun tour de boucle d'événements entre la frappe et ces vérifications.
        #expect(model.dictation.draft == typed)
        #expect(told == [typed])
    }
}

private struct ReviewProbe: PermissionsProbe {
    func microphone() -> PermissionState { .granted }
    func accessibility() -> PermissionState { .granted }
    func requestMicrophone() async -> Bool { true }
    func promptAccessibility() {}
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
