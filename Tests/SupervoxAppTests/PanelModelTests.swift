import CoreGraphics
import Testing

@testable import SupervoxApp

/// Ce que le presse-papiers double répond à une copie, modifiable par le test.
@MainActor final class Acceptance {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

@MainActor @Suite struct PanelModelTests {
    @Test func toggleOpensThenCloses() {
        let model = PanelModel(lastModeID: "dictee-brute")
        var openings = 0
        model.onOpen = { openings += 1 }
        #expect(!model.isOpen)

        model.toggle()
        #expect(model.isOpen)
        #expect(openings == 1)

        model.toggle()
        #expect(!model.isOpen)
        #expect(openings == 1)

        model.toggle()
        #expect(model.isOpen)
        #expect(openings == 2)
    }

    // MARK: - La frappe du panneau

    @Test func thePanelHasNoKeyboardUntilTheSurfaceSaysSo() {
        let model = PanelModel(lastModeID: "dictee-brute")
        #expect(!model.panelHasKeyboard)
        model.panelHasKeyboard = true
        #expect(model.panelHasKeyboard)
    }

    @Test(arguments: ["toggle", "close"])
    func aClosedPanelHasNoKeyboard(how: String) {
        let model = PanelModel(lastModeID: "dictee-brute")
        model.toggle()
        model.panelHasKeyboard = true
        if how == "toggle" { model.toggle() } else { model.close() }
        #expect(!model.isOpen)
        #expect(!model.panelHasKeyboard)
    }

    /// Ce que la vue montre suit la frappe du panneau, dans les deux sens : l'aide de la relecture n'annonce ⌘↩ que si le panneau
    /// est clé.
    @Test func theReviewHintFollowsThePanelKeyboardBothWays() throws {
        let model = PanelModel(lastModeID: "dictee-brute")
        model.dictation = DictationViewState(stage: .review, draft: "Un texte.")
        #expect(try #require(model.dictationDisplay.review).hint == DictationText.reviewNoKeyboardHint)
        model.panelHasKeyboard = true
        #expect(try #require(model.dictationDisplay.review).hint == DictationText.reviewHint)
        model.panelHasKeyboard = false
        #expect(try #require(model.dictationDisplay.review).hint == DictationText.reviewNoKeyboardHint)
    }

    @Test func closeOnAClosedPanelIsHarmless() {
        let model = PanelModel(lastModeID: "prompt")
        var openings = 0
        model.onOpen = { openings += 1 }

        model.close()
        #expect(!model.isOpen)
        #expect(model.selectedModeID == "prompt")
        #expect(openings == 0)

        // Une fermeture de trop ne rouvre rien au tour suivant.
        model.toggle()
        model.close()
        model.close()
        #expect(!model.isOpen)
        #expect(openings == 1)
    }

    @Test func unknownLastModeFallsBackToRawDictation() {
        #expect(PanelModel(lastModeID: "mode-disparu").selectedModeID == "dictee-brute")
        #expect(PanelModel(lastModeID: "").selectedModeID == "dictee-brute")
        // Un identifiant connu est repris tel quel.
        #expect(PanelModel(lastModeID: "entretien").selectedModeID == "entretien")
    }

    @Test func fixedModesAreTheFourOfThisStep() {
        #expect(PanelModel(lastModeID: "dictee-brute").modes.map(\.id)
            == ["dictee-brute", "dictee-nettoyee", "prompt", "entretien"])
    }

    @Test func selectingAModeReportsItForSaving() {
        let model = PanelModel(lastModeID: "dictee-brute")
        var reported: [String] = []
        model.onModeChanged = { reported.append($0) }

        model.select("entretien")
        #expect(model.selectedModeID == "entretien")
        #expect(reported == ["entretien"])

        // Choisir le mode déjà choisi n'est pas un changement : rien à sauver.
        model.select("entretien")
        #expect(reported == ["entretien"])
    }

    @Test func selectingAnUnknownModeChangesNothing() {
        let model = PanelModel(lastModeID: "prompt")
        var reported: [String] = []
        model.onModeChanged = { reported.append($0) }

        model.select("mode-inconnu")
        #expect(model.selectedModeID == "prompt")
        #expect(reported.isEmpty)
    }

    // MARK: - Les pastilles suivent les réglages

    private static let custom = [
        ModeChip(id: "dictee-brute", title: "Dictée brute"),
        ModeChip(id: "perso-un", title: "Un mode"),
        ModeChip(id: "perso-deux", title: "Un autre"),
    ]

    @Test func theChipsAreTheOnesGivenInTheirOrder() {
        let model = PanelModel(lastModeID: "dictee-brute", modes: Self.custom)
        #expect(model.modes == Self.custom)
        #expect(PanelModel(lastModeID: "perso-deux", modes: Self.custom).selectedModeID == "perso-deux")
        #expect(PanelModel(lastModeID: "prompt", modes: Self.custom).selectedModeID == "dictee-brute")
    }

    @Test func setModesReplacesTheChipsInTheirNewOrder() {
        let model = PanelModel(lastModeID: "dictee-brute")
        model.setModes(Self.custom.reversed())
        #expect(model.modes.map(\.id) == ["perso-deux", "perso-un", "dictee-brute"])
        model.setModes([ModeChip(id: "dictee-brute", title: "Brute"), Self.custom[1]])
        #expect(model.modes.map(\.title) == ["Brute", "Un mode"])
    }

    @Test func aChosenModeThatDisappearsFallsBackToRawWithoutSavingIt() {
        let model = PanelModel(lastModeID: "perso-un", modes: Self.custom)
        var reported: [String] = []
        model.onModeChanged = { reported.append($0) }

        model.setModes([Self.custom[0], Self.custom[2]])
        #expect(model.selectedModeID == ModeChip.fallbackID)
        #expect(reported.isEmpty)
    }

    @Test func aChosenModeThatStaysIsKeptEvenWhenRenamedOrMoved() {
        let model = PanelModel(lastModeID: "perso-un", modes: Self.custom)
        model.setModes([ModeChip(id: "perso-un", title: "Renommé"), Self.custom[0]])
        #expect(model.selectedModeID == "perso-un")
    }

    // MARK: - Avis

    @Test func noticesFromDifferentOriginsCoexistInAFixedOrder() {
        let model = PanelModel(lastModeID: "dictee-brute")
        model.setNotice("sauvegarde", for: .save)
        model.setNotice("chargement", for: .settingsLoad)
        model.setNotice("raccourci", for: .hotKey)

        #expect(model.notices.count == 3)
        // Ordre d'affichage stable, quel que soit l'ordre d'arrivée.
        #expect(model.noticeLines == ["chargement", "raccourci", "sauvegarde"])
    }

    @Test func clearingOneOriginLeavesTheOthers() {
        let model = PanelModel(lastModeID: "dictee-brute")
        model.setNotice("chargement", for: .settingsLoad)
        model.setNotice("Échap", for: .escape)

        model.setNotice(nil, for: .escape)
        #expect(model.notices == [.settingsLoad: "chargement"])

        // Un nouvel avis de la même origine remplace l'ancien, sans toucher aux autres.
        model.setNotice("raccourci 1", for: .hotKey)
        model.setNotice("raccourci 2", for: .hotKey)
        #expect(model.noticeLines == ["chargement", "raccourci 2"])
    }

    // MARK: - Placement

    /// Écran fictif dont la zone utile commence à (100, 50) : la position ne doit pas supposer
    /// une origine nulle (second écran, Dock à gauche).
    @Test func panelIsCenteredInTheUpperThirdOfTheScreen() {
        let visible = CGRect(x: 100, y: 50, width: 1200, height: 900)
        let frame = PanelController.frame(size: CGSize(width: 400, height: 120), in: visible)

        #expect(frame.size == CGSize(width: 400, height: 120))
        #expect(frame.midX == visible.midX)
        // Centre du tiers supérieur : un sixième de la hauteur sous le haut de la zone utile.
        #expect(frame.midY == visible.maxY - visible.height / 6)
    }

    @Test func panelTallerThanTheUpperThirdStaysOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 800, height: 300)
        let frame = PanelController.frame(size: CGSize(width: 400, height: 200), in: visible)
        // Centré au sixième du haut, il dépasserait de 50 points : il est ramené contre le haut.
        #expect(frame.size == CGSize(width: 400, height: 200))
        #expect(frame.maxY == visible.maxY)
        #expect(frame.midX == visible.midX)
    }

    @Test func theDictationStartsIdle() {
        let model = PanelModel(lastModeID: "dictee-brute")
        #expect(model.dictation == DictationViewState())
        #expect(model.dictation.stage == .idle)
    }

    // MARK: - Dernier texte dicté

    @Test func copyingWithoutATranscriptDoesNothing() {
        let model = PanelModel(lastModeID: "dictee-brute")
        var copied = 0
        model.onCopy = { _ in copied += 1; return true }
        model.copyTranscript()
        #expect(copied == 0)
        #expect(!model.transcriptCopied)
        #expect(model.dictation.lastTranscript == nil)
    }

    @Test func aCopyThatFailsSaysSoAndIsNeverShownAsCopied() {
        let model = PanelModel(lastModeID: "dictee-brute")
        let accepts = Acceptance(false)
        model.onCopy = { _ in accepts.value }
        model.setDictation(DictationViewState(lastTranscript: "un texte"))
        model.copyTranscript()
        #expect(model.copyState == .failed)
        #expect(!model.transcriptCopied)

        // Un nouvel essai qui réussit remplace l'échec.
        accepts.value = true
        model.copyTranscript()
        #expect(model.copyState == .copied)
        #expect(model.transcriptCopied)
    }

    @Test func theCopyStateGoesBackToNormalWithANewTextAClosingOrANewDictation() {
        let model = PanelModel(lastModeID: "dictee-brute")
        let accepts = Acceptance(true)
        model.onCopy = { _ in accepts.value }
        model.setDictation(DictationViewState(lastTranscript: "premier"))

        model.copyTranscript()
        model.setDictation(DictationViewState(lastTranscript: "second"))
        #expect(model.copyState == .idle)

        accepts.value = false
        model.copyTranscript()
        #expect(model.copyState == .failed)
        model.setDictation(DictationViewState(lastTranscript: "troisième"))
        #expect(model.copyState == .idle)

        accepts.value = true
        model.copyTranscript()
        model.setDictation(DictationViewState(stage: .failed(.noSpeech), notice: "x", lastTranscript: "troisième"))
        #expect(model.copyState == .copied, "un échec n'est pas une nouvelle dictée")
        model.setDictation(DictationViewState(stage: .preparing, lastTranscript: "troisième"))
        #expect(model.copyState == .idle)
        #expect(model.dictation.stage == .preparing)

        model.copyTranscript()
        model.setDictation(DictationViewState(stage: .recording, lastTranscript: "troisième"))
        #expect(model.copyState == .idle)

        accepts.value = false
        model.toggle()
        model.copyTranscript()
        #expect(model.copyState == .failed)
        model.close()
        #expect(model.copyState == .idle)
    }

    @Test func withoutAnyWayToCopyNothingIsSaidToBeCopied() {
        let model = PanelModel(lastModeID: "dictee-brute")
        model.setDictation(DictationViewState(lastTranscript: "un texte"))
        model.copyTranscript()
        #expect(!model.transcriptCopied)
    }

    @Test func aNewTranscriptOrClosingThePanelForgetsThatItWasCopied() {
        let model = PanelModel(lastModeID: "dictee-brute")
        model.onCopy = { _ in true }
        model.setDictation(DictationViewState(lastTranscript: "premier"))
        model.copyTranscript()
        #expect(model.transcriptCopied)
        model.setDictation(DictationViewState(lastTranscript: "second"))
        #expect(!model.transcriptCopied)

        model.toggle()
        model.copyTranscript()
        #expect(model.transcriptCopied)
        model.close()
        #expect(!model.transcriptCopied)
        // Le texte, lui, reste : il est récupérable à la prochaine ouverture.
        #expect(model.dictation.lastTranscript == "second")

        model.toggle()
        model.copyTranscript()
        model.toggle()
        #expect(!model.transcriptCopied)
    }

    // MARK: - Un seul dernier texte

    @Test func copyingHandsTheDictationsLastTranscriptToTheHandler() {
        let model = PanelModel(lastModeID: "dictee-brute")
        var copied: [String] = []
        model.onCopy = { copied.append($0); return true }
        let long = (1...300).map { "mot\($0)" }.joined(separator: " ")
        model.setDictation(DictationViewState(lastTranscript: long))
        #expect(!model.transcriptCopied)

        model.copyTranscript()
        #expect(copied == [long])
        #expect(model.copyState == .copied)
    }

    @Test func theCopyStateGoesBackToIdleWhenTheDictationsLastTranscriptChanges() {
        let model = PanelModel(lastModeID: "dictee-brute")
        model.onCopy = { _ in true }
        model.setDictation(DictationViewState(lastTranscript: "premier"))
        model.copyTranscript()
        #expect(model.copyState == .copied)

        // Le même texte dans un autre état d'écran : « Copié » reste.
        model.setDictation(DictationViewState(stage: .cancelled, notice: "x", lastTranscript: "premier"))
        #expect(model.copyState == .copied)

        // Un autre texte, sans dictée en cours : « Copier » revient.
        model.setDictation(DictationViewState(stage: .copied, notice: "x", lastTranscript: "second"))
        #expect(model.copyState == .idle)
    }

    @Test func theCopyStateGoesBackToIdleWhenAnActiveStageBeginsEvenWithTheSameText() {
        for stage in [DictationStage.preparing, .recording, .finalizing] {
            let model = PanelModel(lastModeID: "dictee-brute")
            model.onCopy = { _ in false }
            model.setDictation(DictationViewState(lastTranscript: "texte"))
            model.copyTranscript()
            #expect(model.copyState == .failed)
            model.setDictation(DictationViewState(stage: stage, lastTranscript: "texte"))
            #expect(model.copyState == .idle, "\(stage)")
        }
    }

    // MARK: - Relecture

    private func reviewing(_ draft: String, lastTranscript: String? = nil, stage: DictationStage = .review) -> PanelModel {
        let model = PanelModel(lastModeID: "dictee-brute")
        model.setDictation(DictationViewState(stage: stage, lastTranscript: lastTranscript ?? draft, draft: draft))
        return model
    }

    @Test("règle 9 : on ne peut coller qu'en relecture, avec un brouillon non blanc")
    func pastingIsPossibleOnlyInReviewWithATextToPaste() {
        #expect(reviewing("Un texte.").canPaste)
        #expect(!reviewing("").canPaste)
        #expect(!reviewing("  \n\t ").canPaste)
        for stage in [
            DictationStage.idle, .preparing, .recording, .finalizing, .pasting, .copied, .cancelled, .failed(.noSpeech),
        ] {
            #expect(!reviewing("Un texte.", stage: stage).canPaste, "\(stage)")
        }
    }

    @Test("règle 9 : paste() appelle le gestionnaire quand on peut coller, et seulement alors")
    func pasteCallsTheHandlerOnlyWhenPastingIsPossible() {
        var pasted = 0
        let model = reviewing("Un texte.")
        model.onPaste = { pasted += 1 }
        model.paste()
        #expect(pasted == 1)

        model.setDictation(DictationViewState(stage: .review, lastTranscript: "Un texte.", draft: " \n"))
        model.paste()
        model.setDictation(DictationViewState(stage: .pasting, lastTranscript: "Un texte.", draft: "Un texte."))
        model.paste()
        model.setDictation(DictationViewState(stage: .idle, lastTranscript: "Un texte."))
        model.paste()
        #expect(pasted == 1)
    }

    @Test("règle 4 : editDraft change le brouillon que la vue montre et prévient le contrôleur")
    func editingTheDraftUpdatesTheViewAndReportsIt() {
        let model = reviewing("Premier.")
        var reported: [String] = []
        model.onDraftChange = { reported.append($0) }
        model.editDraft("Premier, corrigé.")
        #expect(model.dictation.draft == "Premier, corrigé.")
        #expect(reported == ["Premier, corrigé."])
        #expect(model.dictation.stage == .review)
    }

    @Test("règle 4 : editDraft est ignoré hors relecture (aucun appel, le brouillon ne bouge pas)")
    func editingTheDraftOutsideTheReviewIsIgnored() {
        for stage in [DictationStage.idle, .recording, .pasting, .copied] {
            let model = reviewing("Premier.", stage: stage)
            var reported: [String] = []
            model.onDraftChange = { reported.append($0) }
            model.editDraft("Autre.")
            #expect(model.dictation.draft == "Premier.", "\(stage)")
            #expect(reported.isEmpty, "\(stage)")
        }
    }

    // MARK: - Correction à la voix

    @Test("canCorrect : seulement en relecture, avec un texte non blanc")
    func correctingIsPossibleOnlyInTheReviewWithAText() {
        #expect(reviewing("Un texte.").canCorrect)
        #expect(!reviewing("").canCorrect)
        #expect(!reviewing("  \n\t ").canCorrect)
        for stage in [
            DictationStage.idle, .preparing, .recording, .finalizing, .formatting, .pasting, .copied, .cancelled,
            .failed(.noSpeech), .correcting(.preparing), .correcting(.recording), .correcting(.transcribing),
            .correcting(.rewriting),
        ] {
            #expect(!reviewing("Un texte.", stage: stage).canCorrect, "\(stage)")
        }
    }

    @Test("correct() : « Corriger à la voix » en relecture, « Terminer » pendant l'écoute, et rien d'autre")
    func correctStartsThenFinishesAndNothingElse() {
        var started = 0
        var finished = 0
        func model(_ draft: String, _ stage: DictationStage) -> PanelModel {
            let model = reviewing(draft, stage: stage)
            model.onCorrect = { started += 1 }
            model.onFinishCorrection = { finished += 1 }
            return model
        }
        model("Un texte.", .review).correct()
        #expect((started, finished) == (1, 0))
        model("Un texte.", .correcting(.recording)).correct()
        #expect((started, finished) == (1, 1))
        #expect(model("Un texte.", .correcting(.recording)).canFinishCorrection)
        for (draft, stage) in [
            ("", DictationStage.review), ("  ", .review), ("Un texte.", .correcting(.preparing)),
            ("Un texte.", .correcting(.transcribing)), ("Un texte.", .correcting(.rewriting)), ("Un texte.", .pasting),
            ("Un texte.", .idle), ("Un texte.", .recording),
        ] {
            let other = model(draft, stage)
            other.correct()
            #expect(!other.canFinishCorrection || stage == .correcting(.recording))
        }
        #expect((started, finished) == (1, 1), "aucun autre appel")
    }

    @Test("règle 8 (tâche 9) : pendant la correction on ne peut ni coller, ni copier, ni écrire : le champ est en lecture seule")
    func duringTheCorrectionNothingPastesCopiesOrTypes() {
        for step in [CorrectionStep.preparing, .recording, .transcribing, .rewriting] {
            let model = PanelModel(lastModeID: "dictee-brute")
            model.setDictation(
                DictationViewState(
                    stage: .correcting(step), liveText: "Texte reçu en flux.", lastTranscript: "Le tout premier texte.",
                    draft: "Le texte courant."))
            var pasted = 0
            var copied: [String] = []
            var edits: [String] = []
            model.onPaste = { pasted += 1 }
            model.onCopy = { copied.append($0); return true }
            model.onDraftChange = { edits.append($0) }

            #expect(!model.canPaste, "\(step)")
            model.paste()
            model.editDraft("Autre chose.")
            model.copyTranscript()
            #expect(pasted == 0, "\(step)")
            #expect(edits.isEmpty, "\(step)")
            #expect(model.dictation.draft == "Le texte courant.", "\(step)")
            #expect(copied.isEmpty, "\(step) : on ne copie pas un texte que l'écran ne montre pas")
            #expect(model.copyState == .idle, "\(step)")
            let review = model.dictationDisplay.review
            #expect(review?.canPaste == false, "\(step)")
            #expect(review?.isEditable == false, "\(step)")
            #expect(review?.canCopy == false, "\(step)")
            #expect(review?.hint == nil, "\(step)")
            // La réécriture montre le texte reçu à la place du brouillon ; les autres étapes montrent le brouillon.
            #expect(review?.text == (step == .rewriting ? "Texte reçu en flux." : "Le texte courant."), "\(step)")
        }
    }

    @Test("la réécriture sans rien reçu montre encore le brouillon")
    func theRewritingStepShowsTheDraftUntilSomethingArrives() {
        let model = reviewing("Le texte courant.", stage: .correcting(.rewriting))
        #expect(model.dictationDisplay.review?.text == "Le texte courant.")
    }

    @Test("previousVersion() et nextVersion() relaient le contrôleur, seulement s'il y a une version de ce côté")
    func versionButtonsRelayOnlyWhenThereIsAVersion() {
        var back = 0
        var forward = 0
        let model = reviewing("Un texte.")
        model.onPreviousVersion = { back += 1 }
        model.onNextVersion = { forward += 1 }
        model.previousVersion()
        model.nextVersion()
        #expect((back, forward) == (0, 0))

        model.setDictation(DictationViewState(stage: .review, draft: "Un texte.", canGoBack: true))
        model.previousVersion()
        model.nextVersion()
        #expect((back, forward) == (1, 0))
        model.setDictation(DictationViewState(stage: .review, draft: "Un texte.", canGoForward: true))
        model.previousVersion()
        model.nextVersion()
        #expect((back, forward) == (1, 1))
    }

    @Test("règle 15 : « Copier » en relecture copie le brouillon entier, pas le dernier texte")
    func copyingInReviewCopiesTheWholeDraft() {
        let long = (1...300).map { "mot\($0)" }.joined(separator: " ")
        let model = reviewing(long, lastTranscript: "Le texte d'avant.")
        var copied: [String] = []
        model.onCopy = { copied.append($0); return true }
        model.copyTranscript()
        #expect(copied == [long])
        #expect(model.copyState == .copied)
    }

    @Test("règle 15 : hors relecture, « Copier » copie toujours le dernier texte, même pendant le collage")
    func copyingOutsideTheReviewCopiesTheLastTranscript() {
        for stage in [DictationStage.idle, .pasting, .copied, .failed(.noSpeech)] {
            let model = reviewing("Le brouillon.", lastTranscript: "Le dernier texte.", stage: stage)
            var copied: [String] = []
            model.onCopy = { copied.append($0); return true }
            model.copyTranscript()
            #expect(copied == ["Le dernier texte."], "\(stage)")
        }
    }

    @Test("règle 15 : une modification du texte remet « Copier » à neuf, un échec de copie aussi se reprend")
    func editingTheDraftResetsTheCopyState() {
        let model = reviewing("Premier.")
        let accepts = Acceptance(false)
        model.onCopy = { _ in accepts.value }
        model.copyTranscript()
        #expect(model.copyState == .failed)
        model.editDraft("Premier, corrigé.")
        #expect(model.copyState == .idle)

        accepts.value = true
        model.copyTranscript()
        #expect(model.copyState == .copied)
        model.editDraft("Premier, encore corrigé.")
        #expect(model.copyState == .idle)

        // Le même texte renvoyé par le contrôleur (écho de la modification) ne remet rien à zéro d'autre.
        model.copyTranscript()
        model.setDictation(DictationViewState(stage: .review, lastTranscript: "Premier.", draft: "Premier, encore corrigé."))
        #expect(model.copyState == .copied)
        // Une modification qui vient d'ailleurs que du panneau (le contrôleur) remet « Copier » à neuf aussi.
        model.setDictation(DictationViewState(stage: .review, lastTranscript: "Premier.", draft: "Autre."))
        #expect(model.copyState == .idle)
    }

    @Test("règle 9 : « Copier » d'un texte blanc ne copie rien et laisse « Copier » à neuf", arguments: ["", "  \n\t "])
    func copyingABlankTextDoesNothing(text: String) {
        for stage in [DictationStage.review, .idle] {
            let model = PanelModel(lastModeID: "dictee-brute")
            var copied = 0
            model.onCopy = { _ in copied += 1; return true }
            model.setDictation(
                DictationViewState(stage: stage, lastTranscript: stage == .review ? "Le dernier." : text, draft: stage == .review ? text : ""))
            model.copyTranscript()
            #expect(copied == 0, "\(stage)")
            #expect(model.copyState == .idle, "\(stage)")
        }
    }

    // MARK: - L'entretien (tâche 8)

    private static func interview(_ phase: InterviewPhase = .listening) -> InterviewViewState {
        var state = InterviewViewState(maxQuestions: 6, privacy: "La vie privée.")
        state.phase = phase
        return state
    }

    @Test func thereIsNoInterviewUntilOneIsSet() {
        let model = PanelModel(lastModeID: "dictee-brute")
        #expect(model.interview == nil)
        #expect(!model.holdsPanel && !model.modesLocked)
        model.setInterview(Self.interview())
        #expect(model.interview == Self.interview())
        model.setInterview(nil)
        #expect(model.interview == nil)
    }

    @Test("règle 3 : le panneau est tenu pendant tout l'entretien, quelle que soit la phase", arguments: InterviewTextTests.phases)
    func theInterviewHoldsThePanel(phase: InterviewPhase) {
        let model = PanelModel(lastModeID: "dictee-brute")
        model.setInterview(Self.interview(phase))
        #expect(model.holdsPanel)
        #expect(model.modesLocked)
        model.setInterview(nil)
        #expect(!model.holdsPanel && !model.modesLocked)
    }

    @Test("règle 3 : la dictée tient toujours le panneau comme avant, et ne verrouille pas les pastilles")
    func theDictationStillHoldsThePanelAsBefore() {
        for stage in [DictationStage.preparing, .recording, .finalizing, .formatting, .review, .pasting, .correcting(.recording)] {
            let model = PanelModel(lastModeID: "dictee-brute")
            model.setDictation(DictationViewState(stage: stage))
            #expect(model.holdsPanel, "\(stage)")
            #expect(!model.modesLocked, "\(stage) : le verrou des pastilles n'existait pas pour la dictée")
        }
        for stage in [DictationStage.idle, .copied, .cancelled, .failed(.clipboard)] {
            let model = PanelModel(lastModeID: "dictee-brute")
            model.setDictation(DictationViewState(stage: stage))
            #expect(!model.holdsPanel, "\(stage)")
        }
    }

    @Test("règle 3 : une pastille touchée pendant l'entretien ne change pas de mode ; elle le change de nouveau après")
    func aChipTouchedDuringTheInterviewChangesNothing() {
        let model = PanelModel(lastModeID: "prompt")
        var saved: [String] = []
        model.onModeChanged = { saved.append($0) }
        model.setInterview(Self.interview())
        model.select("dictee-nettoyee")
        #expect(model.selectedModeID == "prompt")
        #expect(saved.isEmpty, "le mode non changé a été enregistré")
        model.setInterview(nil)
        model.select("dictee-nettoyee")
        #expect(model.selectedModeID == "dictee-nettoyee")
        #expect(saved == ["dictee-nettoyee"])
    }

    @Test("règle 4 : « Conclure » appelle onConclude, sauf en préparation et en conclusion (bouton grisé)")
    func concludeCallsOnConcludeExceptWhilePreparingAndConcluding() {
        for phase in InterviewTextTests.phases {
            let model = PanelModel(lastModeID: "dictee-brute")
            var calls = 0
            model.onConclude = { calls += 1 }
            model.setInterview(Self.interview(phase))
            model.concludeInterview()
            #expect(calls == (phase == .preparing || phase == .concluding ? 0 : 1), "\(phase)")
        }
    }

    @Test("règle 4 : sans entretien « Conclure » ne fait rien")
    func concludeWithoutAnInterviewDoesNothing() {
        let model = PanelModel(lastModeID: "dictee-brute")
        var calls = 0
        model.onConclude = { calls += 1 }
        model.concludeInterview()
        #expect(calls == 0)
    }

    @Test("règle 5 : seul un changement de titre est annoncé, au rythme où l'état est posé")
    func onlyATitleChangeIsAnnounced() {
        let model = PanelModel(lastModeID: "dictee-brute")
        var announced: [String] = []
        model.onAnnounce = { announced.append($0) }
        model.setInterview(Self.interview(.preparing))
        var listening = Self.interview(.listening)
        model.setInterview(listening)
        for level: Float in [0.1, 0.5, 0.9] {  // le niveau arrive à chaque tranche : jamais annoncé
            listening.level = level
            model.setInterview(listening)
        }
        model.setInterview(Self.interview(.thinking))
        model.setInterview(nil)
        #expect(announced == ["Préparation de l'entretien…", "À vous", "Réflexion…"])
    }
}
