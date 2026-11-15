import CoreGraphics
import Testing

@testable import SupervoxApp

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
        #expect(model.dictation.phase == .idle)
    }

    // MARK: - Dernier texte dicté

    @Test func copyingHandsTheWholeTextToTheHandlerAndRemembersIt() {
        let model = PanelModel(lastModeID: "dictee-brute")
        var copied: [String] = []
        model.onCopy = { copied.append($0) }
        let long = (1...300).map { "mot\($0)" }.joined(separator: " ")
        model.setTranscript(long)
        #expect(!model.transcriptCopied)

        model.copyTranscript()
        #expect(copied == [long])
        #expect(model.transcriptCopied)
    }

    @Test func copyingWithoutATranscriptDoesNothing() {
        let model = PanelModel(lastModeID: "dictee-brute")
        var copied = 0
        model.onCopy = { _ in copied += 1 }
        model.copyTranscript()
        model.setTranscript("  ")
        model.copyTranscript()
        #expect(copied == 0)
        #expect(!model.transcriptCopied)
        #expect(model.lastTranscript == nil)
    }

    @Test func withoutAnyWayToCopyNothingIsSaidToBeCopied() {
        let model = PanelModel(lastModeID: "dictee-brute")
        model.setTranscript("un texte")
        model.copyTranscript()
        #expect(!model.transcriptCopied)
    }

    @Test func aNewTranscriptOrClosingThePanelForgetsThatItWasCopied() {
        let model = PanelModel(lastModeID: "dictee-brute")
        model.onCopy = { _ in }
        model.setTranscript("premier")
        model.copyTranscript()
        #expect(model.transcriptCopied)
        model.setTranscript("second")
        #expect(!model.transcriptCopied)

        model.toggle()
        model.copyTranscript()
        #expect(model.transcriptCopied)
        model.close()
        #expect(!model.transcriptCopied)
        // Le texte, lui, reste : il est récupérable à la prochaine ouverture.
        #expect(model.lastTranscript == "second")

        model.toggle()
        model.copyTranscript()
        model.toggle()
        #expect(!model.transcriptCopied)
    }
}
