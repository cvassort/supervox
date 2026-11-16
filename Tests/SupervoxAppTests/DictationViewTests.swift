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

    @Test("M5 : la coupe ne sépare jamais une grappe de caractères : émoji composé, drapeau, marque combinante")
    func theCutNeverSplitsACharacterCluster() {
        let family = "👨‍👩‍👧‍👦"
        let flag = "🇫🇷"
        let combined = "e\u{0301}"
        for unit in [family, flag, combined] {
            let text = String(repeating: unit + " ", count: 200) + "fin"
            for limit in [20, 21, 50, 99, 260] {
                let cut = DictationText.tail(text, maxCharacters: limit)
                #expect(cut.count <= limit, "\(unit) \(limit)")
                #expect(cut.hasSuffix("fin"))
                // Tout ce qui reste entre « … » et « fin » est fait d'unités entières.
                let body = cut.dropFirst(2).dropLast(3).split(separator: " ").map(String.init)
                #expect(body.allSatisfy { $0 == unit }, "\(unit) \(limit) : \(body)")
                let heads = DictationText.head(text, maxCharacters: limit)
                let kept = heads.dropLast(2).split(separator: " ").map(String.init)
                #expect(kept.allSatisfy { $0 == unit }, "head \(unit) \(limit)")
            }
            // Sans aucune espace : la coupe franche tombe elle aussi sur une frontière de grappe.
            let solid = String(repeating: unit, count: 300)
            let cut = DictationText.tail(solid, maxCharacters: 40)
            #expect(cut.count <= 40)
            #expect(cut == "…" + String(repeating: unit, count: cut.count - 1), "\(unit) sans espace : \(cut.unicodeScalars.count)")
        }
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
        let reason = "Le texte est copié dans le presse-papiers : faites ⌘V."
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
    private func display(
        _ state: DictationViewState, copy: CopyState = .idle, panelHasKeyboard: Bool = false
    ) -> DictationDisplay {
        DictationDisplay(state: state, copy: copy, panelHasKeyboard: panelHasKeyboard)
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

    // MARK: Ligne d'aide et champ vide

    @Test func theHintsAndThePlaceholderHaveTheirExactWords() {
        #expect(
            DictationText.reviewNoKeyboardHint
                == "Cliquez dans le texte pour le corriger, ou sur « Coller » pour le coller. Échap ferme sans coller.")
        #expect(DictationText.reviewEmptyHint == "Tapez un texte, ou appuyez sur Échap pour fermer sans coller.")
        #expect(DictationText.reviewPlaceholder == "Le texte est vide.")
    }

    @Test func inReviewWithTheKeyboardTheHintAnnouncesCommandReturn() {
        let state = DictationViewState(stage: .review, notice: "Un avis du vocabulaire.", draft: "Un texte.")
        #expect(display(state, panelHasKeyboard: true).review?.hint == DictationText.reviewHint)
    }

    /// Le panneau n'a pas la frappe (un collage manqué, ou un clic dans une autre application la lui a retirée) : ⌘↩ partirait
    /// ailleurs, l'aide ne l'annonce pas, et dit comment coller quand même.
    @Test(arguments: [nil, "Une raison."])
    func inReviewWithoutTheKeyboardTheHintNoLongerAnnouncesCommandReturn(notice: String?) throws {
        let state = DictationViewState(stage: .review, notice: notice, draft: "Un texte.")
        let hint = try #require(display(state, panelHasKeyboard: false).review?.hint)
        #expect(hint == DictationText.reviewNoKeyboardHint)
        #expect(!hint.contains("⌘↩"))
        #expect(hint.contains("« Coller »"))
    }

    /// Ne rien dire de la frappe est le choix sûr : sans l'information, l'aide n'annonce pas ⌘↩.
    @Test func theKeyboardIsNotAssumedWhenNothingIsSaid() {
        let state = DictationViewState(stage: .review, draft: "Un texte.")
        #expect(DictationDisplay(state: state).review?.hint == DictationText.reviewNoKeyboardHint)
    }

    @Test(arguments: [false, true])
    func aBlankTextHasTheEmptyHintWhateverTheKeyboard(hasKeyboard: Bool) throws {
        for draft in ["", "  \n "] {
            let state = DictationViewState(stage: .review, draft: draft)
            let hint = try #require(display(state, panelHasKeyboard: hasKeyboard).review?.hint)
            #expect(hint == DictationText.reviewEmptyHint)
            #expect(!hint.contains("⌘↩"))
        }
    }

    @Test func whilePastingThereIsNoHint() {
        #expect(display(DictationViewState(stage: .pasting, draft: "a")).review?.hint == nil)
    }

    @Test func thePlaceholderIsOnlyForAnEmptyText() throws {
        #expect(try #require(display(DictationViewState(stage: .review, draft: "")).review).showsPlaceholder)
        // Un texte fait d'espaces n'est pas vide : le curseur et les espaces sont là, rien ne se superpose.
        #expect(!(try #require(display(DictationViewState(stage: .review, draft: " ")).review).showsPlaceholder))
        #expect(!(try #require(display(DictationViewState(stage: .review, draft: "a")).review).showsPlaceholder))
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
        // Un texte non blanc a une ligne de plus que le vide : l'aide de la correction. Le champ, lui, a la même hauteur.
        let correctionLine = short - height(" ")
        #expect(correctionLine > 0)
        #expect(height("") == height(" "))
        #expect(height("") + correctionLine == short)
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

    // MARK: « Copier » et « Coller » inactifs

    /// L'image de la rangée de boutons : un bouton inactif ne se dessine pas comme un bouton actif. Les boutons ne sont pas des
    /// `NSButton` ni des éléments d'accessibilité que l'on puisse interroger hors écran ; l'image est ce qui les distingue.
    private func actionsImage(_ review: DictationDisplay.Review) throws -> Data {
        let host = NSHostingView(rootView: ReviewActions(review: review, paste: {}, copy: {}).frame(width: 300).padding(8))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func buttons(
        paste: Bool, copy: Bool, correct: Bool = false, isPasting: Bool = false
    ) -> DictationDisplay.Review {
        DictationDisplay.Review(
            text: "a", isEditable: true, canPaste: paste, canCopy: copy, isPasting: isPasting, copy: .idle, hint: nil,
            showsPlaceholder: false, canCorrect: correct)
    }

    @Test func aDisabledButtonDoesNotLookLikeAnEnabledOne() throws {
        let both = try actionsImage(buttons(paste: true, copy: true))
        #expect(try actionsImage(buttons(paste: true, copy: true)) == both, "le rendu n'est pas reproductible")
        // Chaque bouton est inactif de son côté : retirer l'un des deux `.disabled` rend l'image de son cas identique à `both`.
        #expect(try actionsImage(buttons(paste: false, copy: true)) != both, "« Coller » reste actif")
        #expect(try actionsImage(buttons(paste: true, copy: false)) != both, "« Copier » reste actif")
        let neither = try actionsImage(buttons(paste: false, copy: false))
        #expect(neither != both)
        #expect(try actionsImage(buttons(paste: false, copy: true)) != neither)
        #expect(try actionsImage(buttons(paste: true, copy: false)) != neither)
    }

    @Test func theButtonsOfAReviewAndOfAPastingFollowTheDisplay() throws {
        let reviewing = try #require(review("Un texte.").review)
        let pasting = try #require(review("Un texte.", stage: .pasting).review)
        #expect(try actionsImage(reviewing) == actionsImage(buttons(paste: true, copy: true, correct: true)))
        #expect(try actionsImage(pasting) == actionsImage(buttons(paste: false, copy: false, isPasting: true)))
        #expect(try actionsImage(pasting) != actionsImage(reviewing))
    }

    // MARK: La mesure ne touche pas au champ

    /// La chaîne réelle : la frappe prévient le modèle, qui prévient le contrôleur, qui mesure le panneau (`fittingSize`) alors
    /// que la frappe est encore en cours. Le champ ne doit rien perdre : la mesure ne le réécrit pas.
    @Test func measuringThePanelDuringTheTypingKeepsWhatWasTyped() throws {
        let model = PanelModel(lastModeID: ModeChip.rawID)
        model.dictation = DictationViewState(stage: .review, draft: "Début.")
        let panel = NSHostingView(
            rootView: PanelView(
                model: model, permissions: PermissionsModel(probe: ReviewProbe()), openSettings: {}, quit: {}))
        panel.layoutSubtreeIfNeeded()
        let textView = try #require(field(in: panel))
        var heights: [CGFloat] = []
        // Ce que fait `PanelController.contentChanged` dans la chaîne réelle, au milieu de `textDidChange`.
        model.onDraftChange = { _ in heights.append(panel.fittingSize.height) }
        let typed = " suite\n" + lines(12)
        textView.insertText(typed, replacementRange: NSRange(location: textView.string.utf16.count, length: 0))
        #expect(textView.string == "Début." + typed)
        #expect(model.dictation.draft == "Début." + typed)
        #expect(heights.count == 1)
    }

    @Test func measuringATextLeavesTheLiveFieldUntouched() throws {
        let field = ReviewTextView.makeTextView()
        // Hors fenêtre, un champ n'a pas de gestionnaire d'annulation : un délégué lui en donne un.
        let provider = UndoProvider()
        field.delegate = provider
        field.string = "Un texte à garder."
        // De quoi annuler : une frappe, que la mesure ne doit pas défaire.
        let undo = provider.manager
        undo.beginUndoGrouping()
        field.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        field.setSelectedRange(NSRange(location: 3, length: 4))
        let canUndo = undo.canUndo
        let size = try #require(field.textContainer).size
        let storage = try #require(field.textContentStorage?.textStorage)
        let before = storage.copy() as! NSAttributedString

        let measured = ReviewTextView.contentHeight(of: lines(30), like: field, width: 300)

        #expect(measured > 100)
        #expect(field.string == "!Un texte à garder.")
        #expect(field.selectedRange() == NSRange(location: 3, length: 4))
        #expect(undo.canUndo == canUndo)
        #expect(undo.canUndo, "la frappe de départ n'est pas annulable : le test ne prouve rien sur la pile")
        #expect(try #require(field.textContainer).size == size)
        #expect(storage.isEqual(to: before))
    }

    @Test func measuringATextGivesWhatTheFieldWouldTakeForIt() {
        let live = ReviewTextView.makeTextView()
        for text in ["", "Une ligne.", lines(9), String(repeating: "des mots qui se suivent ", count: 40), "a\n"] {
            live.string = text
            let direct = ReviewTextView.contentHeight(of: live, width: 400)
            let disposable = ReviewTextView.contentHeight(of: text, like: ReviewTextView.makeTextView(), width: 400)
            #expect(direct == disposable, "« \(text.prefix(12)) »")
        }
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

@MainActor private final class UndoProvider: NSObject, NSTextViewDelegate {
    let manager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
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

// MARK: - Tâche 7 : « Mise en forme… » et la relecture après une panne du modèle

@MainActor @Suite struct DictationFormattingDisplayTests {
    private static let provider = "Fournisseur d'exemple"

    private func display(_ state: DictationViewState) -> DictationDisplay {
        DictationDisplay(state: state)
    }

    private func formatting(live: String = "", last: String? = "La transcription brute.") -> DictationViewState {
        DictationViewState(
            stage: .formatting, liveText: live, elapsed: 12.9,
            notice: DictationController.formattingNotice(provider: Self.provider), lastTranscript: last)
    }

    @Test("règle 1 : la mise en forme est une attente, sans forme d'onde, sans durée, sans carte « Dernière dictée »")
    func formattingIsAWaitWithoutWaveformDurationOrLastTranscriptCard() {
        let shown = display(formatting())
        #expect(shown.headline == "Mise en forme…")
        #expect(shown.mood == .working)
        #expect(shown.bars == nil)
        #expect(shown.duration == nil)
        #expect(shown.transcript == nil, "la transcription brute n'est pas « Dernière dictée » pendant la mise en forme")
        #expect(shown.review == nil)
        #expect(!shown.showsHotKey)
        #expect(shown.detail == DictationController.formattingNotice(provider: Self.provider))
    }

    @Test("règle 1 : tant que rien n'est arrivé, pas de texte en direct, et la vue montre l'attente de la réponse")
    func nothingReceivedYetShowsTheWaitingSentence() {
        #expect(DictationText.formattingWaiting == "En attente de la réponse du modèle…")
        for blank in ["", " ", "\n\t  "] {
            let shown = display(formatting(live: blank))
            #expect(shown.liveText == nil, "\(blank.debugDescription)")
            #expect(shown.waitingText == DictationText.formattingWaiting, "\(blank.debugDescription)")
        }
    }

    @Test("règle 1 : dès que du texte arrive, il remplace l'attente")
    func receivedTextReplacesTheWaitingSentence() {
        let shown = display(formatting(live: "Bonjour à tous,"))
        #expect(shown.liveText == "Bonjour à tous,")
        #expect(shown.waitingText == nil)
    }

    @Test("règle 1 : le texte reçu est montré par sa fin, avec la coupe du texte en direct")
    func theReceivedTextIsShownByItsEndLikeTheLiveText() throws {
        let long = (1...120).map { "mot\($0)" }.joined(separator: " ")
        let shown = display(formatting(live: long))
        let text = try #require(shown.liveText)
        #expect(text == DictationText.tail(long, maxCharacters: DictationText.liveTextLimit))
        #expect(text.hasPrefix("… "))
        #expect(text.hasSuffix("mot120"))
        #expect(text.count <= DictationText.liveTextLimit)
    }

    @Test("pendant l'attente, l'utilisateur sait qu'Échap annule, et que le texte brut n'est pas perdu")
    func theWaitSaysThatEscapeCancels() throws {
        let shown = display(formatting())
        let hint = try #require(shown.cancelHint)
        #expect(hint.contains("Échap"))
        #expect(hint == DictationText.formattingCancelHint)
        #expect(display(formatting(live: "du texte")).cancelHint == hint)
    }

    @Test("ni attente, ni aide d'annulation hors de la mise en forme")
    func theWaitingSentenceAndTheCancelHintBelongToFormattingOnly() {
        let stages: [DictationStage] = [
            .idle, .preparing, .recording, .finalizing, .review, .pasting, .copied, .cancelled,
            .failed(.noSpeech), .failed(.clipboard),
        ]
        for stage in stages {
            let shown = display(DictationViewState(stage: stage, liveText: "", elapsed: 1, draft: "t"))
            #expect(shown.waitingText == nil, "\(stage)")
            #expect(shown.cancelHint == nil, "\(stage)")
        }
    }

    @Test("la dictée en cours tient le panneau pendant la mise en forme")
    func formattingIsActiveAndHoldsThePanel() {
        #expect(DictationStage.formatting.isActive)
        #expect(DictationStage.formatting.holdsPanel)
    }

    // MARK: Tour de correction 1

    /// Une réponse du modèle à paragraphes et à puces, plus longue que la limite du texte en direct.
    private static let paragraphs: String = {
        let intro = "Bonjour à tous,\n\nVoici le compte rendu de la réunion de ce matin, avec les points à retenir.\n\n"
        let bullets = (1...9).map { "- point numéro \($0) à vérifier avant la fin de la semaine" }.joined(separator: "\n")
        return intro + bullets + "\n\n  Cordialement,\n"
    }()

    @Test("I1 : les sauts de ligne du texte en flux sont remplacés par une espace avant la coupe, la fin du texte se voit")
    func lineBreaksAreFlattenedSoThatTheEndOfTheStreamShows() throws {
        #expect(Self.paragraphs.count > DictationText.liveTextLimit, "le texte d'essai dépasse la limite")
        let shown = display(formatting(live: Self.paragraphs))
        let text = try #require(shown.liveText)
        #expect(!text.contains("\n"), "un saut de ligne ferait déborder les quatre lignes avant la fin du texte")
        #expect(text.hasSuffix("Cordialement,"))
        #expect(text.hasPrefix("… "))
        #expect(text.count <= DictationText.liveTextLimit)
        #expect(!text.contains("  "), "les suites de blancs sont une seule espace")
    }

    @Test("I1 : un texte à paragraphes qui tient est aplati lui aussi, sans changer un seul mot")
    func aShortTextWithParagraphsIsFlattenedWordForWord() {
        let shown = display(formatting(live: "Bonjour,\n\nVoici.\t\tMerci \n"))
        #expect(shown.liveText == "Bonjour, Voici. Merci")
    }

    @Test("I1 : la relecture qui suit garde la mise en page intacte")
    func theReviewKeepsTheLayoutOfTheFormattedText() {
        let state = DictationViewState(stage: .review, lastTranscript: "brut", draft: Self.paragraphs)
        #expect(display(state).review?.text == Self.paragraphs)
    }

    @Test("I1 : la prise et la transcription gardent leur texte tel quel (seul le flux de la mise en forme est aplati)")
    func recordingAndFinalizingKeepTheirLiveTextUntouched() {
        for stage in [DictationStage.recording, .finalizing] {
            let shown = display(DictationViewState(stage: stage, liveText: "un\ndeux", elapsed: 1))
            #expect(shown.liveText == "un\ndeux", "\(stage)")
        }
    }

    @Test("I3 : l'indicateur d'attente et le texte en flux ont chacun un libellé, qui ne porte jamais le texte")
    func theActivityAndTheStreamHaveTheirOwnAccessibilityLabels() throws {
        #expect(DictationText.formattingActivityLabel == "Mise en forme en cours")
        #expect(DictationText.formattingStreamLabel == "Réponse du modèle")
        for live in ["", "du texte reçu"] {
            let shown = display(formatting(live: live))
            #expect(shown.activityLabel == DictationText.formattingActivityLabel)
            #expect(shown.streamLabel == DictationText.formattingStreamLabel)
            #expect(shown.activityLabel?.contains("texte reçu") != true)
        }
    }

    @Test("I3 : ni libellé de mise en forme, ni libellé de flux hors de la mise en forme")
    func theFormattingLabelsBelongToFormattingOnly() {
        let stages: [DictationStage] = [
            .idle, .preparing, .recording, .finalizing, .review, .pasting, .copied, .cancelled, .failed(.noSpeech),
        ]
        for stage in stages {
            let shown = display(DictationViewState(stage: stage, liveText: "x", elapsed: 1, draft: "t"))
            #expect(shown.activityLabel == nil, "\(stage)")
            #expect(shown.streamLabel == nil, "\(stage)")
        }
    }

    @Test("M7 : la phrase Échap ne se coupe pas entre une espace et ses guillemets ou son point-virgule")
    func theCancelHintHasNonBreakingSpacesAroundItsPunctuation() {
        let hint = DictationText.formattingCancelHint
        #expect(!hint.contains("« ") && !hint.contains(" »") && !hint.contains(" ;"))
        #expect(hint.contains("\u{00A0};") && hint.contains("«\u{00A0}Dernière\u{00A0}dictée\u{00A0}»"))
    }

    // MARK: Règle 2

    /// Miroir de `RewriteFailure` sans valeurs associées. Exhaustif par construction : un cas ajouté à `RewriteFailure` casse la
    /// compilation de `kind(of:)` ; il faut alors ajouter un `Kind`, ce qui casse celle de `sample`, qui oblige à fournir
    /// l'échantillon ; et la boucle du test le mesure sans autre geste.
    private enum Kind: CaseIterable {
        case noModel, providerMissing, noKey, keychain, unauthorized, notFound, rejected, rateLimited, server, unreachable
        case redirected, interrupted, stalled, providerError, truncated, refused, empty, timedOut, malformed
    }

    private static func kind(of failure: RewriteFailure) -> Kind {
        switch failure {
        case .noModel: .noModel
        case .providerMissing: .providerMissing
        case .noKey: .noKey
        case .keychain: .keychain
        case .unauthorized: .unauthorized
        case .notFound: .notFound
        case .rejected: .rejected
        case .rateLimited: .rateLimited
        case .server: .server
        case .unreachable: .unreachable
        case .redirected: .redirected
        case .interrupted: .interrupted
        case .stalled: .stalled
        case .providerError: .providerError
        case .truncated: .truncated
        case .refused: .refused
        case .empty: .empty
        case .timedOut: .timedOut
        case .malformed: .malformed
        }
    }

    /// Un échantillon par genre, avec les nombres les plus longs plausibles (codes à trois chiffres, délais en secondes).
    private static func sample(_ kind: Kind, provider: String) -> RewriteFailure {
        switch kind {
        case .noModel: .noModel
        case .providerMissing: .providerMissing
        case .noKey: .noKey(provider: provider)
        case .keychain: .keychain
        case .unauthorized: .unauthorized(401)
        case .notFound: .notFound
        case .rejected: .rejected(422)
        case .rateLimited: .rateLimited
        case .server: .server(503)
        case .unreachable: .unreachable
        case .redirected: .redirected
        case .interrupted: .interrupted
        case .stalled: .stalled(120)
        case .providerError: .providerError
        case .truncated: .truncated
        case .refused: .refused
        case .empty: .empty
        case .timedOut: .timedOut(300)
        case .malformed: .malformed
        }
    }

    @Test("règle 2 : chaque phrase de panne suivie de rawTextNotice tient entière dans le détail de la relecture")
    func everyFailureSentenceAndTheRawTextNoticeFitTheDetailLimit() {
        // 60 caractères : la phrase de `noKey` cite le nom tel que `LiveRewriter` le donne, rogné par `Provider.shortName`.
        let sixty = String(repeating: "Fournisseur ", count: 5)
        #expect(sixty.count == 60)
        let name = Provider.shortName(sixty)
        #expect(name.count == Provider.shortNameLimit + 1, "le nom de 60 caractères est rogné")

        var longest = 0
        for kind in Kind.allCases {
            let failure = Self.sample(kind, provider: name)
            #expect(Self.kind(of: failure) == kind, "l'échantillon de \(kind) est d'un autre genre")
            let notice = failure.message + " " + DictationController.rawTextNotice
            longest = max(longest, notice.count)
            let state = DictationViewState(stage: .review, notice: notice, lastTranscript: "brut", draft: "brut")
            let shown = display(state)
            #expect(shown.detail == notice, "coupée : \(failure)")
            #expect(notice.count <= DictationText.detailLimit, "\(failure) : \(notice.count) caractères")
            #expect(shown.detail?.hasSuffix(DictationController.rawTextNotice) == true, "\(failure)")
        }
        #expect(longest <= DictationText.detailLimit)
    }

    @Test("règle 2 : les avis de la mise en forme tiennent aussi, avec un nom de 60 caractères")
    func theFormattingNoticesFitTheDetailLimitToo() {
        let name = String(repeating: "Fournisseur ", count: 5)
        let sending = DictationController.formattingNotice(provider: name)
        #expect(sending.count <= DictationText.detailLimit)
        let shown = display(DictationViewState(stage: .formatting, notice: sending))
        #expect(shown.detail == sending)
        let changed = display(
            DictationViewState(stage: .review, notice: DictationController.frontApplicationChangedNotice, draft: "t"))
        #expect(changed.detail == DictationController.frontApplicationChangedNotice)
    }

    @Test("règle 2 : un avis plus long que la limite est bien coupé, et la fin est perdue (la limite est réelle)")
    func aLongerNoticeIsStillCut() {
        let notice = String(repeating: "mot ", count: 100) + DictationController.rawTextNotice
        let shown = display(DictationViewState(stage: .review, notice: notice, draft: "t"))
        #expect(shown.detail != notice)
        #expect(shown.detail?.count ?? Int.max <= DictationText.detailLimit)
    }
}

// MARK: - Correction à la voix : ce que l'écran en montre (étape 5, tâche 9)

/// Les règles 1 à 3 de la tâche 9, côté affichage : ce que `DictationDisplay` décide pour la relecture, avant et pendant une
/// correction à la voix. La logique (contrôleur, versions, ⌘Z) est celle de la tâche 8 ; ici, seulement ce qui se montre.
@Suite struct DictationCorrectionDisplayTests {
    static let steps: [CorrectionStep] = [.preparing, .recording, .transcribing, .rewriting]

    private func display(_ state: DictationViewState, panelHasKeyboard: Bool = true) -> DictationDisplay {
        DictationDisplay(state: state, panelHasKeyboard: panelHasKeyboard)
    }

    private func correcting(
        _ step: CorrectionStep, draft: String = "Le brouillon.", live: String = "", notice: String? = nil
    ) -> DictationViewState {
        DictationViewState(
            stage: .correcting(step), liveText: live, levels: (0..<60).map { Float($0 % 10) / 10 }, elapsed: 7.4, notice: notice,
            lastTranscript: "Le texte d'avant.", draft: draft)
    }

    // MARK: Règle 1

    @Test("règle 1 : canCorrect seulement en relecture, avec un texte non blanc (jamais pendant le collage)")
    func canCorrectIsTrueOnlyForANonBlankReview() throws {
        #expect(try #require(display(DictationViewState(stage: .review, draft: "Un texte.")).review).canCorrect)
        for draft in ["", " ", "  \n\t ", "\u{00A0}"] {
            #expect(!(try #require(display(DictationViewState(stage: .review, draft: draft)).review).canCorrect), "« \(draft) »")
        }
        #expect(!(try #require(display(DictationViewState(stage: .pasting, draft: "Un texte.")).review).canCorrect))
    }

    /// Une seule règle, deux endroits : le modèle du panneau (qui agit) et l'affichage (qui montre le bouton) ne divergent pas.
    @MainActor @Test("règle 1 : le bouton est actif exactement quand `PanelModel.correct()` agit")
    func theCorrectButtonIsEnabledExactlyWhenThePanelModelActs() {
        var stages: [DictationStage] = [.idle, .review, .pasting, .copied, .failed(.clipboard)]
        stages += Self.steps.map { .correcting($0) }
        for stage in stages {
            for draft in ["", "  \n ", "Un texte."] {
                let state = DictationViewState(stage: stage, draft: draft)
                let model = PanelModel(lastModeID: ModeChip.rawID)
                model.dictation = state
                let shown = display(state).review
                #expect(
                    (shown?.canPressCorrect ?? false) == (model.canCorrect || model.canFinishCorrection),
                    "\(stage) « \(draft) »")
                #expect((shown?.canCorrect ?? false) == model.canCorrect, "\(stage) « \(draft) »")
            }
        }
    }

    @Test("règle 1 : pendant une correction, rien ne se colle ni ne s'écrit ; le champ reste là, sans aide ni ⌘↩")
    func whileCorrectingNothingCanBePastedOrTyped() throws {
        for step in Self.steps {
            let shown = display(correcting(step))
            let review = try #require(shown.review, "\(step)")
            #expect(!review.canPaste, "\(step)")
            #expect(!review.isEditable, "\(step)")
            #expect(!review.canCorrect, "\(step)")
            #expect(!review.isPasting, "\(step)")
            #expect(review.isCorrecting && review.correctionStep == step, "\(step)")
            #expect(review.hint == nil, "\(step)")
            #expect(review.canCopy, "\(step) : « Copier » copie le brouillon")
            #expect(shown.transcript == nil, "\(step) : la carte « Dernière dictée » ne se superpose pas")
        }
    }

    @Test("règle 1 : hors correction, ni étape ni drapeau de correction")
    func outsideACorrectionThereIsNoCorrectionStep() throws {
        for stage in [DictationStage.review, .pasting] {
            let review = try #require(display(DictationViewState(stage: stage, draft: "a")).review)
            #expect(!review.isCorrecting && review.correctionStep == nil, "\(stage)")
        }
    }

    @Test("règle 1 : le bouton devient « Terminer » à l'écoute, reste inactif ensuite ; absent pendant le collage")
    func theCorrectButtonBecomesFinishWhileListening() throws {
        let reviewing = try #require(display(DictationViewState(stage: .review, draft: "Un texte.")).review)
        #expect(reviewing.showsCorrectButton && reviewing.canPressCorrect)
        #expect(reviewing.correctTitle == "Corriger à la voix")
        // Un texte blanc : le bouton est là, inactif (comme « Copier » et « Coller »).
        let blank = try #require(display(DictationViewState(stage: .review, draft: " ")).review)
        #expect(blank.showsCorrectButton && !blank.canPressCorrect)
        let pasting = try #require(display(DictationViewState(stage: .pasting, draft: "Un texte.")).review)
        #expect(!pasting.showsCorrectButton && !pasting.canPressCorrect)

        let listening = try #require(display(correcting(.recording)).review)
        #expect(listening.correctTitle == "Terminer")
        #expect(listening.showsCorrectButton && listening.canPressCorrect)
        // La consigne n'est pas encore écoutée : « Terminer » est déjà là (la phrase du contrôleur le nomme), sans effet.
        let preparing = try #require(display(correcting(.preparing)).review)
        #expect(preparing.correctTitle == "Terminer")
        #expect(preparing.showsCorrectButton && !preparing.canPressCorrect)
        for step in [CorrectionStep.transcribing, .rewriting] {
            let review = try #require(display(correcting(step)).review)
            #expect(review.correctTitle == "Corriger à la voix", "\(step)")
            #expect(review.showsCorrectButton && !review.canPressCorrect, "\(step)")
        }
    }

    @Test("les titres de la correction sont ceux du brief")
    func theHeadlinesOfTheCorrectionAreFixed() {
        #expect(display(correcting(.preparing)).headline == "Préparation…")
        #expect(display(correcting(.recording)).headline == "Écoute de la consigne")
        #expect(display(correcting(.transcribing)).headline == "Transcription de la consigne…")
        #expect(display(correcting(.rewriting)).headline == "Réécriture…")
        #expect(display(correcting(.recording)).mood == .recording)
        for step in [CorrectionStep.preparing, .transcribing, .rewriting] {
            #expect(display(correcting(step)).mood == .working, "\(step)")
        }
    }

    @Test("pendant l'écoute : durée et forme d'onde ; aucune ni avant ni après")
    func onlyListeningHasADurationAndAWaveform() {
        let listening = display(correcting(.recording))
        #expect(listening.duration == DictationText.duration(7.4))
        #expect(listening.bars?.count == DictationViewState.levelCount)
        for step in [CorrectionStep.preparing, .transcribing, .rewriting] {
            let shown = display(correcting(step))
            #expect(shown.duration == nil && shown.bars == nil, "\(step)")
        }
    }

    @Test("la consigne en direct n'entre jamais dans le champ ; le texte reçu en flux le remplace seulement à la réécriture")
    func theTextShownIsTheDraftExceptTheStreamWhileRewriting() throws {
        let instruction = "mets cela au pluriel"
        for step in [CorrectionStep.preparing, .recording, .transcribing] {
            let shown = display(correcting(step, draft: "Le brouillon.", live: instruction))
            #expect(shown.review?.text == "Le brouillon.", "\(step)")
            #expect(shown.liveText == nil, "\(step)")
        }
        // La réécriture : le texte reçu, tel quel (sauts de ligne gardés : c'est le champ de relecture), à la place du brouillon.
        let streamed = "Les brouillons.\n\n- un\n- deux"
        let rewriting = display(correcting(.rewriting, draft: "Le brouillon.", live: streamed))
        #expect(rewriting.review?.text == streamed)
        #expect(rewriting.liveText == nil)
        // Rien reçu encore : le brouillon reste.
        for blank in ["", "  \n "] {
            #expect(display(correcting(.rewriting, draft: "Le brouillon.", live: blank)).review?.text == "Le brouillon.")
        }
        #expect(!(try #require(display(correcting(.rewriting, live: streamed)).review)).showsPlaceholder)
    }

    @Test("l'indicateur d'attente de la correction a un libellé qui ne porte jamais le texte ; l'écoute a le sien (le point rouge)")
    func theWorkingStepsOfACorrectionHaveAnAccessibilityLabel() {
        var seen: Set<String> = []
        for step in [CorrectionStep.preparing, .transcribing, .rewriting] {
            let label = display(correcting(step, draft: "Un secret.", live: "Un autre.")).activityLabel
            #expect(label?.isEmpty == false, "\(step)")
            #expect(label == DictationText.correctionActivityLabel(for: step), "\(step)")
            #expect(label?.contains("secret") != true && label?.contains("autre") != true, "\(step)")
            if let label { seen.insert(label) }
        }
        #expect(seen.count == 3, "chaque étape dit la sienne")
        #expect(display(correcting(.recording)).activityLabel == nil)
        #expect(DictationText.correctionActivityLabel(for: .recording) == nil)
    }

    @MainActor @Test("la phrase du contrôleur reste sous le champ, telle quelle")
    func theControllersSentenceIsTheDetail() {
        let listening = DictationController.correctionListeningNotice(hotKeyLabel: "⌃⌥Espace")
        #expect(display(correcting(.recording, notice: listening)).detail == listening)
        #expect(
            display(correcting(.rewriting, notice: DictationController.correctionRewritingNotice)).detail
                == DictationController.correctionRewritingNotice)
    }

    // MARK: Règle 2

    private struct Layout: KeyboardLayout {
        let characters: [UInt32: String]
        func character(forKeyCode keyCode: UInt32) -> String? { characters[keyCode] }
    }

    @Test("règle 2 : l'aide nomme le raccourci réel, sous deux dispositions de clavier, jamais un raccourci écrit en dur")
    func theCorrectionHintNamesTheRealShortcutUnderTwoLayouts() {
        // La même touche physique (code 0x00) porte « A » en QWERTY et « Q » en AZERTY : deux libellés pour un raccourci.
        let hotKey = HotKey(keyCode: 0x00, modifiers: [.command, .shift])
        let qwerty = hotKey.label(layout: Layout(characters: [0x00: "a"]))
        let azerty = hotKey.label(layout: Layout(characters: [0x00: "q"]))
        #expect(qwerty == "⇧⌘A" && azerty == "⇧⌘Q")
        let forQwerty = DictationText.correctionHint(hotKeyLabel: qwerty)
        let forAzerty = DictationText.correctionHint(hotKeyLabel: azerty)
        #expect(forQwerty.hasPrefix("⇧⌘A ou"))
        #expect(forAzerty.hasPrefix("⇧⌘Q ou"))
        #expect(forQwerty != forAzerty)
        for hint in [forQwerty, forAzerty] {
            #expect(!hint.contains("⌃⌥Espace") && !hint.contains("Espace"), "le raccourci par défaut ne doit pas être écrit en dur")
        }
    }

    @Test("règle 2 : le texte exact de l'aide, avec et sans raccourci (espaces insécables devant « : » et dans les guillemets)")
    func theCorrectionHintHasItsExactWords() {
        let nbsp = "\u{00A0}"
        #expect(
            DictationText.correctionHint(hotKeyLabel: "⌃⌥Espace")
                == "⌃⌥Espace ou «\(nbsp)Corriger\(nbsp)à\(nbsp)la\(nbsp)voix\(nbsp)»\(nbsp): dites ce qu'il faut changer.")
        let without = "«\(nbsp)Corriger\(nbsp)à\(nbsp)la\(nbsp)voix\(nbsp)»\(nbsp): dites ce qu'il faut changer."
        #expect(DictationText.correctionHint(hotKeyLabel: nil) == without)
        // Un libellé vide n'est pas un raccourci : la phrase ne commence pas par « ou ».
        #expect(DictationText.correctionHint(hotKeyLabel: "") == without)
        #expect(DictationText.correctionHint(hotKeyLabel: "  ") == without)
    }

    @Test("règle 2 : l'aide n'existe qu'en relecture d'un texte non blanc ; ni au collage, ni pendant la correction")
    func theCorrectionHintIsOnlyForAReviewOfAText() throws {
        let reviewing = try #require(display(DictationViewState(stage: .review, draft: "Un texte.")).review)
        #expect(reviewing.correctionHint(hotKeyLabel: "⌃⌥Espace") == DictationText.correctionHint(hotKeyLabel: "⌃⌥Espace"))
        #expect(reviewing.correctionHint(hotKeyLabel: nil) == DictationText.correctionHint(hotKeyLabel: nil))
        let pasting = try #require(display(DictationViewState(stage: .pasting, draft: "Un texte.")).review)
        #expect(pasting.correctionHint(hotKeyLabel: "⌃⌥Espace") == nil)
        let blank = try #require(display(DictationViewState(stage: .review, draft: "  ")).review)
        #expect(blank.correctionHint(hotKeyLabel: "⌃⌥Espace") == nil)
        for step in Self.steps {
            #expect(try #require(display(correcting(step)).review).correctionHint(hotKeyLabel: "⌃⌥Espace") == nil, "\(step)")
        }
    }

    // MARK: Règle 3

    @Test("règle 3 : « Version précédente » et « Version suivante » seulement si le contrôleur le dit, et seulement en relecture")
    func theVersionButtonsFollowTheState() throws {
        for (back, forward) in [(false, false), (true, false), (false, true), (true, true)] {
            let state = DictationViewState(stage: .review, draft: "Un texte.", canGoBack: back, canGoForward: forward)
            let review = try #require(display(state).review)
            #expect(review.canGoBack == back && review.canGoForward == forward, "\(back) \(forward)")
        }
        // Même si l'état le dit, ni pendant le collage ni pendant une correction : les versions ne se parcourent qu'en relecture.
        var stages: [DictationStage] = [.pasting]
        stages += Self.steps.map { .correcting($0) }
        for stage in stages {
            let state = DictationViewState(stage: stage, draft: "Un texte.", canGoBack: true, canGoForward: true)
            let review = try #require(display(state).review)
            #expect(!review.canGoBack && !review.canGoForward, "\(stage)")
        }
    }

    @Test("règle 3 : la vue ne montre jamais deux versions : un seul texte, le brouillon, quelles que soient les versions")
    func onlyOneVersionIsEverShown() throws {
        let state = DictationViewState(
            stage: .review, lastTranscript: "Une version plus ancienne.", draft: "La version courante.", canGoBack: true,
            canGoForward: true)
        let shown = display(state)
        #expect(shown.review?.text == "La version courante.")
        #expect(shown.transcript == nil, "pas de seconde carte avec l'autre texte")
        #expect(shown.liveText == nil)
    }

    @Test("les libellés des boutons de version et de correction")
    func theLabelsOfTheNewButtons() {
        #expect(DictationText.correctLabel == "Corriger à la voix")
        #expect(DictationText.finishCorrectionLabel == "Terminer")
        #expect(DictationText.previousVersionLabel == "Version précédente")
        #expect(DictationText.nextVersionLabel == "Version suivante")
    }
}

/// La vue elle-même, sans fenêtre : la rangée de boutons, l'aide et l'écoute dans le champ de relecture.
@MainActor @Suite struct CorrectionViewTests {
    private static let contentWidth: CGFloat = 520 - 2 * 16

    private func review(
        _ stage: DictationStage = .review, draft: String = "Un texte.", back: Bool = false, forward: Bool = false,
        copy: CopyState = .idle
    ) throws -> DictationDisplay.Review {
        try #require(
            DictationDisplay(
                state: DictationViewState(
                    stage: stage, elapsed: 3, draft: draft, canGoBack: back, canGoForward: forward), copy: copy
            ).review)
    }

    private func image(of view: some View) throws -> Data {
        let host = NSHostingView(rootView: view.padding(8))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func actions(_ review: DictationDisplay.Review) -> some View {
        ReviewActions(review: review, paste: {}, copy: {}, correct: {}, previousVersion: {}, nextVersion: {}).frame(width: 400)
    }

    // MARK: La rangée

    @Test("règle 3 : chaque bouton de version change la rangée, et seulement quand il est annoncé")
    func theVersionButtonsAppearOnlyWhenAnnounced() throws {
        let none = try image(of: actions(review()))
        #expect(try image(of: actions(review())) == none, "le rendu n'est pas reproductible")
        let back = try image(of: actions(review(back: true)))
        let forward = try image(of: actions(review(forward: true)))
        let both = try image(of: actions(review(back: true, forward: true)))
        #expect(back != none, "« Version précédente » n'apparaît pas")
        #expect(forward != none, "« Version suivante » n'apparaît pas")
        #expect(back != forward)
        #expect(both != back && both != forward)
    }

    @Test("« Corriger à la voix » : présent en relecture (même d'un texte blanc), absent au collage, « Terminer » à l'écoute")
    func theCorrectButtonFollowsTheStage() throws {
        let reviewing = try image(of: actions(review()))
        let blank = try image(of: actions(review(draft: " ")))
        let pasting = try image(of: actions(review(.pasting)))
        let listening = try image(of: actions(review(.correcting(.recording))))
        let transcribing = try image(of: actions(review(.correcting(.transcribing))))
        let preparing = try image(of: actions(review(.correcting(.preparing))))
        #expect(blank != reviewing, "un bouton inactif ne se dessine pas comme un actif")
        #expect(pasting != blank, "le bouton est absent pendant le collage")
        #expect(listening != reviewing, "« Terminer » n'est pas « Corriger à la voix »")
        #expect(listening != preparing, "« Terminer » est inactif tant que la consigne n'est pas écoutée")
        #expect(transcribing != reviewing && transcribing != listening)
        #expect(preparing != transcribing, "les deux libellés diffèrent")
    }

    @Test("règle 1 : « Coller » est inactif à toutes les étapes de la correction")
    func pasteIsInactiveWhileCorrecting() throws {
        let reviewing = try image(of: actions(review()))
        for step in DictationCorrectionDisplayTests.steps {
            let correcting = try review(.correcting(step))
            // La même rangée, à la main, avec « Coller » actif : si la correction laissait « Coller » actif, les deux seraient
            // identiques.
            var withActivePaste = correcting
            withActivePaste.canPaste = true
            #expect(
                try image(of: actions(correcting)) != image(of: actions(withActivePaste)),
                "\(step) : « Coller » ressemble à un bouton actif")
            #expect(try image(of: actions(correcting)) != reviewing, "\(step)")
        }
    }

    @Test("la rangée la plus large (deux versions, « Corriger à la voix », « Copie impossible », « Copier », « Coller ») tient dans le panneau")
    func theWidestRowFitsThePanel() throws {
        var widest: CGFloat = 0
        let cases: [DictationDisplay.Review] = try [
            review(back: true, forward: true, copy: .failed), review(back: true, forward: true),
            review(.correcting(.recording), copy: .failed), review(.pasting),
        ]
        for review in cases {
            let host = NSHostingView(
                rootView: ReviewActions(
                    review: review, paste: {}, copy: {}, correct: {}, previousVersion: {}, nextVersion: {}
                ).fixedSize())
            host.layoutSubtreeIfNeeded()
            widest = max(widest, host.fittingSize.width)
        }
        #expect(widest > 0)
        #expect(widest <= Self.contentWidth, "la rangée mesure \(widest) points, le panneau en laisse \(Self.contentWidth)")
    }

    // MARK: L'aide

    private func panelImage(_ stage: DictationStage, label: String?, draft: String = "Un texte.") throws -> Data {
        let model = PanelModel(lastModeID: ModeChip.rawID)
        model.hotKeyLabel = label
        model.panelHasKeyboard = true
        model.dictation = DictationViewState(stage: stage, draft: draft)
        let host = NSHostingView(
            rootView: PanelView(model: model, permissions: PermissionsModel(probe: ReviewProbe()), openSettings: {}, quit: {}))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test("règle 2 : le panneau dessine l'aide avec le raccourci du panneau ; pas d'aide au collage ni pendant la correction")
    func thePanelDrawsTheHintWithItsShortcut() throws {
        let one = try panelImage(.review, label: "⇧⌘A")
        #expect(try panelImage(.review, label: "⇧⌘A") == one, "le rendu n'est pas reproductible")
        #expect(try panelImage(.review, label: "⇧⌘Q") != one, "le raccourci du panneau n'est pas dans l'aide")
        #expect(try panelImage(.review, label: nil) != one)
        for stage in [DictationStage.pasting, .correcting(.recording), .correcting(.rewriting)] {
            #expect(
                try panelImage(stage, label: "⇧⌘A") == panelImage(stage, label: "⇧⌘Q"), "\(stage) : l'aide est affichée")
        }
        #expect(
            try panelImage(.review, label: "⇧⌘A", draft: " ") == panelImage(.review, label: "⇧⌘Q", draft: " "),
            "un texte blanc : pas d'aide de correction")
    }

    // MARK: L'écoute

    private func height(_ stage: DictationStage) throws -> CGFloat {
        let display = DictationDisplay(
            state: DictationViewState(stage: stage, levels: [0.2, 0.8], elapsed: 3, draft: "Un texte."))
        let host = NSHostingView(
            rootView: ReviewView(display: display, review: try #require(display.review), edit: { _ in }, paste: {}, copy: {})
                .frame(width: Self.contentWidth))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test("pendant l'écoute, la forme d'onde prend sa place au-dessus du champ ; pas avant ni après")
    func theWaveformTakesItsPlaceOnlyWhileListening() throws {
        let listening = try height(.correcting(.recording))
        #expect(listening - (try height(.correcting(.transcribing))) >= 32, "la forme d'onde mesure 32 points")
        #expect(listening - (try height(.correcting(.preparing))) >= 32)
        #expect(listening - (try height(.correcting(.rewriting))) >= 32)
    }
}
