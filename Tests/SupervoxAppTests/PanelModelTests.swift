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
}
