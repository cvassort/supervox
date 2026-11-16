import Foundation
import Testing
import SupervoxCore

@testable import SupervoxApp

/// Le déroulé d'un mode à consigne dans le contrôleur de dictée : après la dictée, le texte part au modèle (étape `formatting`),
/// puis passe en relecture ou se colle ; si le modèle échoue, la transcription brute revient en relecture avec une phrase.
/// Sessions, presse-papiers, touches, attentes et mise en forme doubles : aucun micro, aucun ⌘V, aucun réseau. Chaque test porte
/// le numéro de la règle de la tâche qu'il prouve.
@MainActor @Suite(.timeLimit(.minutes(1))) struct DictationFormattingTests {
    static let mode = "perso-un"
    static let raw = "euh bonjour tout le monde voici la dictée"
    static let formatted = "Bonjour tout le monde, voici la dictée."
    static let instruction = "Résume en une phrase."
    static let rewrite = ModeRun.rewrite(instruction: instruction, model: nil, engine: nil)

    private func harness(
        run: ModeRun = DictationFormattingTests.rewrite, review: Bool = false, trusted: Bool = true, limit: Int = 1000,
        wait: (@MainActor (Double) async -> Void)? = nil
    ) -> DictationHarness {
        let h = DictationHarness(trusted: trusted, wait: wait, limit: limit)
        h.knobs.modeID = Self.mode
        h.knobs.modeRuns[Self.mode] = run
        if review { h.knobs.reviewing = [Self.mode] }
        return h
    }

    /// Une dictée menée jusqu'au texte final de la session : le contrôleur passe à la mise en forme.
    @discardableResult
    private func dictate(_ h: DictationHarness, _ text: String = DictationFormattingTests.raw, index: Int = 0) async -> FakeSession {
        let session = await h.startRecording(index: index)
        session.emit(.finalizing)
        session.emit(.finished(text))
        return session
    }

    /// Une dictée menée jusqu'à la mise en forme, dont l'appel est attendu.
    private func formatting(
        _ h: DictationHarness, _ text: String = DictationFormattingTests.raw
    ) async -> RewriteCall {
        await dictate(h, text)
        #expect(await until { h.controller.view.stage == .formatting })
        return await h.rewriter.call()
    }

    // MARK: - Règle 1 : le mode est lu une fois, à l'appui

    @Test("règle 1 : la consigne et le modèle sont lus à l'appui ; les changer ou supprimer le mode pendant la dictée ne change pas cette dictée")
    func theInstructionAndModelAreReadAtThePress() async {
        let model = ModelChoice(providerID: UUID(), model: "modele-exemple")
        let h = harness(run: .rewrite(instruction: "Consigne d'origine.", model: model, engine: nil))
        let session = await h.startRecording()
        #expect(h.knobs.modeReads == [Self.mode])
        h.knobs.modeRuns[Self.mode] = .rewrite(instruction: "Consigne changée.", model: nil, engine: nil)
        session.emit(.finished(Self.raw))
        let call = await h.rewriter.call()

        #expect(call.job.instruction.hasPrefix("Consigne d'origine."))
        #expect(!call.job.instruction.contains("Consigne changée."))
        #expect(call.job.model == model)
        #expect(h.knobs.modeReads == [Self.mode], "lu une seule fois")
        #expect(h.rewriter.nameAsks == [model])
    }

    @Test("règle 1 : un mode supprimé pendant la dictée ne change pas cette dictée")
    func aModeRemovedDuringTheDictationStillFormatsIt() async {
        let h = harness()
        let session = await h.startRecording()
        h.knobs.modeRuns[Self.mode] = nil   // le mode n'existe plus : `legacy` dirait « plus tard »
        session.emit(.finished(Self.raw))
        let call = await h.rewriter.call()

        #expect(call.job.instruction.hasPrefix(Self.instruction))
        #expect(h.controller.view.stage == .formatting)
    }

    @Test("règle 1 : le choix de relecture est lu à l'appui ; le changer pendant la dictée ne change pas cette dictée", arguments: [true, false])
    func theReviewChoiceIsReadAtThePress(reviewedAtPress: Bool) async {
        let h = harness(review: reviewedAtPress)
        let session = await h.startRecording()
        h.knobs.reviewing = reviewedAtPress ? [] : [Self.mode]
        session.emit(.finished(Self.raw))
        let call = await h.rewriter.call()
        call.finish(.rewritten(Self.formatted))

        if reviewedAtPress {
            #expect(await until { h.controller.view.stage == .review })
            #expect(h.pasted.isEmpty)
        } else {
            #expect(await until { h.pasted == [Self.formatted] })
            #expect(h.controller.view.stage != .review)
        }
        #expect(h.knobs.reviewReads == [Self.mode], "lu une seule fois")
    }

    @Test("règle 1 : le moteur du mode remplace celui de l'onglet Transcription pour cette dictée seulement")
    func theModesEngineReplacesTheTabsEngineForThisDictationOnly() async {
        let h = harness(run: .rewrite(instruction: Self.instruction, model: nil, engine: .parakeet))
        h.knobs.settings.engine = .whisperKit
        await dictate(h)
        _ = await h.rewriter.call()
        #expect(h.engines.settingsSeen.map(\.engine) == [.parakeet])
        #expect(h.knobs.settings.engine == .whisperKit)

        // Un mode sans moteur : celui de l'onglet.
        let other = harness()
        other.knobs.settings.engine = .parakeet
        await dictate(other)
        _ = await other.rewriter.call()
        #expect(other.engines.settingsSeen.map(\.engine) == [.parakeet])
    }

    @Test("règle 1 : le moteur d'un mode sans consigne s'applique aussi")
    func aModeWithoutAnInstructionAlsoUsesItsEngine() async {
        let h = harness(run: .raw(engine: .parakeet))
        h.knobs.settings.engine = .whisperKit
        _ = await h.startRecording()
        #expect(h.engines.settingsSeen.map(\.engine) == [.parakeet])
    }

    // MARK: - Règle 2 : le déroulé

    @Test("règle 2 : le texte final part au modèle ; formatting, avis du fournisseur, texte brut gardé, aucune insertion")
    func theFinalTextIsSentToTheModelWhileTheScreenSaysSo() async {
        let h = harness()
        h.rewriter.providerName = "Fournisseur exemple"
        await dictate(h)
        #expect(await until { h.controller.view.stage == .formatting })
        let call = await h.rewriter.call()

        #expect(h.controller.view.notice == DictationController.formattingNotice(provider: "Fournisseur exemple"))
        #expect(h.controller.view.notice == "Le texte est envoyé à « Fournisseur exemple » pour être mis en forme.")
        #expect(h.controller.lastTranscript == Self.raw)
        #expect(h.controller.view.lastTranscript == Self.raw)
        #expect(h.controller.isBusy, "le modèle sert encore")
        let expected = RewritePrompt.format(instruction: Self.instruction, text: Self.raw, vocabulary: [])
        #expect(call.job == RewriteJob(instruction: expected.instruction, input: expected.input, model: nil))
        await settle()
        #expect(h.writtenTexts == 0)
        #expect(h.pasted.isEmpty)
        #expect(h.rewriter.calls.count == 1)
    }

    @Test("règle 2 : le vocabulaire est celui de cette dictée, rogné s'il l'a été")
    func theJobCarriesTheEffectiveVocabulary() async {
        // Limite à un terme : le comptage ne garde que le premier terme sur deux.
        let h = harness(limit: 1)
        h.knobs.settings.vocabulary = ["Supervox", "Kubernetes"]
        await dictate(h)
        #expect(await until { h.controller.view.stage == .formatting })
        let call = await h.rewriter.call()

        #expect(h.engines.settingsSeen.last?.vocabulary == ["Supervox"], "le moteur n'a reçu que le terme gardé")
        let expected = RewritePrompt.format(instruction: Self.instruction, text: Self.raw, vocabulary: ["Supervox"])
        #expect(call.job.instruction == expected.instruction)
        #expect(!call.job.instruction.contains("Kubernetes"))
    }

    @Test("règle 2 : le vocabulaire entier part avec la consigne quand il tient")
    func aVocabularyThatFitsIsSentWhole() async {
        let h = harness()
        h.knobs.settings.vocabulary = ["Supervox", "Kubernetes"]
        let call = await formatting(h)
        let expected = RewritePrompt.format(instruction: Self.instruction, text: Self.raw, vocabulary: ["Supervox", "Kubernetes"])
        #expect(call.job.instruction == expected.instruction)
    }

    @Test("règle 2 : chaque morceau reçu met le texte en direct à jour")
    func eachChunkUpdatesTheLiveText() async {
        let h = harness()
        let call = await formatting(h)
        #expect(h.controller.view.liveText == "")

        call.onText("Bonjour")
        #expect(h.controller.view.liveText == "Bonjour")
        call.onText("Bonjour tout le monde")
        #expect(h.controller.view.liveText == "Bonjour tout le monde")
        #expect(h.controller.view.stage == .formatting)
        #expect(h.controller.view.notice == DictationController.formattingNotice(provider: "Fournisseur exemple"))
        #expect(h.pasted.isEmpty)
    }

    @Test("règle 2 : sans fournisseur connu l'avis est vide ; un texte blanc ne part pas au modèle")
    func noProviderMeansNoNoticeAndBlankTextIsNotSent() async {
        let h = harness()
        h.rewriter.providerName = nil
        _ = await formatting(h)
        #expect(h.controller.view.notice == nil)

        let blank = harness()
        await dictate(blank, "   \n")
        #expect(await until { blank.controller.view.stage == .failed(.noSpeech) })
        #expect(blank.rewriter.calls.isEmpty)
        #expect(blank.rewriter.nameAsks.isEmpty)
    }

    @Test("règle 2 : la phrase de l'avis rogne le nom d'un fournisseur à quarante caractères")
    func theNoticeTrimsALongProviderName() {
        let long = String(repeating: "N", count: 60)
        let notice = DictationController.formattingNotice(provider: long)
        #expect(notice == "Le texte est envoyé à « \(Provider.shortName(long)) » pour être mis en forme.")
        #expect(!notice.contains(long))
        #expect(DictationController.formattingNotice(provider: "Court") == "Le texte est envoyé à « Court » pour être mis en forme.")
    }

    // MARK: - Règle 3 : succès avec relecture

    @Test("règle 3 : le texte mis en forme passe en relecture, le panneau prend la frappe, la transcription brute est la version précédente")
    func aFormattedTextGoesToTheReview() async {
        let h = harness(review: true)
        let call = await formatting(h)
        call.onText(Self.formatted)
        call.finish(.rewritten(Self.formatted))

        #expect(await until { h.controller.view.stage == .review })
        #expect(h.controller.view.draft == Self.formatted)
        #expect(h.controller.lastTranscript == Self.formatted)
        #expect(h.controller.view.lastTranscript == Self.formatted)
        #expect(h.panel.keyboards.last == .focused)
        #expect(h.controller.reviewPreviousText == Self.raw)
        #expect(!h.controller.isBusy)
        await settle()
        #expect(h.writtenTexts == 0)
        #expect(h.pasted.isEmpty)
        #expect(h.panel.isOpen)
        #expect(h.rewriter.calls.count == 1)
    }

    @Test("règle 3 : « Coller » colle le texte mis en forme, par la file existante")
    func theFormattedTextPastesFromTheReview() async {
        let h = harness(review: true)
        let call = await formatting(h)
        call.finish(.rewritten(Self.formatted))
        #expect(await until { h.controller.view.stage == .review })

        h.controller.pasteReview()
        #expect(await until { h.pasted == [Self.formatted] })
        #expect(await until { h.controller.view.stage == .idle && !h.panel.isOpen })
    }

    // MARK: - Règle 4 : succès sans relecture

    @Test("règle 4 : le texte mis en forme est inséré une seule fois, comme une dictée brute ; collé, le panneau se ferme")
    func aFormattedTextIsInsertedOnceWithoutReview() async {
        let h = harness()
        let call = await formatting(h)
        call.finish(.rewritten(Self.formatted))

        #expect(await until { h.pasted == [Self.formatted] })
        #expect(await until { h.controller.view.stage == .idle && !h.panel.isOpen })
        #expect(h.writtenTexts == 1)
        #expect(h.controller.lastTranscript == Self.formatted)
        #expect(!h.controller.isBusy)
    }

    @Test("règle 4 : un texte copié faute de collage reste affiché avec sa raison")
    func aFormattedTextThatCouldNotBePastedStaysCopied() async {
        let h = harness(trusted: false)
        let call = await formatting(h)
        call.finish(.rewritten(Self.formatted))

        #expect(await until { h.controller.view.stage == .copied })
        #expect(h.controller.view.notice?.isEmpty == false)
        #expect(h.panel.isOpen)
        #expect(h.pasted.isEmpty)
        #expect(h.controller.lastTranscript == Self.formatted)
    }

    // MARK: - Règle 5 : échec du modèle

    nonisolated static let failures: [RewriteFailure] = [
        .noKey(provider: "Fournisseur exemple"), .server(503), .timedOut(120), .truncated, .refused,
    ]

    @Test("règle 5 : une panne ramène la transcription brute en relecture avec sa phrase, rien n'est inséré", arguments: failures)
    func aFailureBringsTheRawTextBackToTheReview(failure: RewriteFailure) async {
        let h = harness(review: true)
        let call = await formatting(h)
        call.finish(.failed(failure))

        #expect(await until { h.controller.view.stage == .review })
        #expect(h.controller.view.draft == Self.raw)
        #expect(h.controller.view.notice == failure.message + " " + DictationController.rawTextNotice)
        #expect(h.controller.lastTranscript == Self.raw)
        #expect(h.panel.keyboards.last == .focused)
        #expect(!h.controller.isBusy)
        #expect(h.controller.reviewPreviousText == nil)
        await settle()
        #expect(h.writtenTexts == 0)
        #expect(h.pasted.isEmpty)
        #expect(h.panel.isOpen)
    }

    @Test("règle 5 : un mode sans relecture passe aussi en relecture quand le modèle échoue", arguments: failures)
    func aModeWithoutReviewStillReviewsTheRawTextOnFailure(failure: RewriteFailure) async {
        let h = harness(review: false)
        let call = await formatting(h)
        call.finish(.failed(failure))

        #expect(await until { h.controller.view.stage == .review })
        #expect(h.controller.view.draft == Self.raw, "le texte brut, jamais collé à l'insu de l'utilisateur")
        #expect(h.controller.view.notice == failure.message + " " + DictationController.rawTextNotice)
        #expect(h.panel.keyboards.last == .focused)
        await settle()
        #expect(h.writtenTexts == 0)
        #expect(h.pasted.isEmpty)
        // La relecture se colle comme une autre.
        h.controller.pasteReview()
        #expect(await until { h.pasted == [Self.raw] })
    }

    @Test("règle 5 : une issue « annulée » alors que la dictée vit encore est une interruption, le texte brut revient")
    func aCancelledOutcomeOfALiveDictationIsAnInterruption() async {
        let h = harness()
        let call = await formatting(h)
        call.finish(.cancelled)

        #expect(await until { h.controller.view.stage == .review })
        #expect(h.controller.view.draft == Self.raw)
        #expect(h.controller.view.notice == RewriteFailure.interrupted.message + " " + DictationController.rawTextNotice)
    }

    @Test("règle 5 : les phrases fixes du contrôleur")
    func theFixedSentences() {
        #expect(DictationController.rawTextNotice == "Le texte ci-dessus est la transcription brute : corrigez-la, collez-la ou copiez-la.")
        #expect(DictationText.status(for: .formatting) == "Mise en forme…")
        #expect(DictationStage.formatting.isActive)
        #expect(DictationStage.formatting.holdsPanel)
    }

    // MARK: - Règle 7 : Échap et fermeture pendant la mise en forme

    enum Closing: CaseIterable, CustomTestStringConvertible {
        case escape, panelClosed
        var testDescription: String { self == .escape ? "Échap" : "fermeture du panneau" }
    }

    private func close(_ h: DictationHarness, by closing: Closing) {
        switch closing {
        case .escape: h.controller.escapePressed()
        case .panelClosed: h.controller.panelClosedByUser()
        }
    }

    @Test("règle 7 : Échap pendant la mise en forme annule la réécriture, ferme le panneau, n'insère ni ne copie rien, garde le texte brut",
        arguments: Closing.allCases)
    func closingDuringFormattingCancelsTheRewrite(closing: Closing) async {
        let h = harness()
        let call = await formatting(h)
        close(h, by: closing)

        #expect(await until { call.sawCancellation }, "le double voit l'annulation")
        #expect(h.controller.view.stage == .idle)
        #expect(!h.controller.isBusy)
        #expect(h.controller.lastTranscript == Self.raw)
        if closing == .escape { #expect(!h.panel.isOpen) }
        await settle()
        #expect(h.writtenTexts == 0)
        #expect(h.pasted.isEmpty)
        #expect(h.controller.view.lastTranscript == Self.raw)
    }

    @Test("règle 7 : un texte ou une issue qui arrive après l'annulation ne change ni l'écran ni le panneau", arguments: Closing.allCases)
    func lateTextAndOutcomeAfterTheCancellationAreIgnored(closing: Closing) async {
        let h = harness(review: true)
        h.rewriter.ignoresCancellation = true   // un modèle sourd : l'issue ne vient que quand le test la rend
        let call = await formatting(h)
        close(h, by: closing)
        let before = h.controller.view
        let opened = h.panel.openCount
        let keyboards = h.panel.keyboards

        call.onText("Texte tardif")
        call.finish(.rewritten("Texte tardif complet"))
        await settle()

        #expect(h.controller.view == before)
        #expect(h.panel.openCount == opened)
        #expect(h.panel.keyboards == keyboards)
        #expect(h.controller.lastTranscript == Self.raw)
        #expect(h.writtenTexts == 0)
        #expect(h.pasted.isEmpty)
    }

    @Test("règle 7 : une panne tardive après l'annulation ne ramène pas le texte en relecture")
    func aLateFailureAfterTheCancellationIsIgnored() async {
        let h = harness()
        h.rewriter.ignoresCancellation = true
        let call = await formatting(h)
        h.controller.escapePressed()
        let before = h.controller.view

        call.finish(.failed(.server(503)))
        await settle()

        #expect(h.controller.view == before)
        #expect(h.controller.view.stage == .idle)
        #expect(!h.panel.isOpen)
    }

    @Test("règle 7 : un texte et une issue de l'ancienne dictée ne touchent pas la nouvelle, même en cours d'enregistrement")
    func lateResultsDoNotTouchANewDictation() async {
        let h = harness()
        h.rewriter.ignoresCancellation = true
        let old = await formatting(h)
        h.controller.escapePressed()
        let session = await h.startRecording(index: 1)
        session.emit(.recording, liveText: "nouvelle dictée", level: 0.5, elapsed: 1)
        #expect(await until { h.controller.view.liveText == "nouvelle dictée" })
        let before = h.controller.view

        old.onText("Texte de l'ancienne")
        old.finish(.rewritten("Texte de l'ancienne"))
        await settle()

        #expect(h.controller.view == before)
        #expect(h.controller.view.stage == .recording)
        #expect(h.writtenTexts == 0)
        #expect(h.pasted.isEmpty)
        #expect(h.rewriter.calls.count == 1, "la nouvelle dictée n'a pas encore de texte final")
    }

    @Test("règle 7 : un onText appelé après l'issue ne change plus l'écran", arguments: [true, false])
    func anOnTextCalledAfterTheOutcomeIsIgnored(review: Bool) async {
        // Sans relecture, l'insertion reste en route (son attente est retenue) le temps du test.
        let gate = TestGate()
        defer { gate.open() }
        var hold: (@MainActor (Double) async -> Void)?
        if !review { hold = { _ in await gate.wait() } }
        let h = harness(review: review, wait: hold)
        let call = await formatting(h)
        call.onText(Self.formatted)
        call.finish(.rewritten(Self.formatted))
        if review {
            #expect(await until { h.controller.view.stage == .review })
        } else {
            #expect(await until { h.controller.lastTranscript == Self.formatted })
            #expect(h.controller.view.stage == .formatting, "l'insertion est en route")
            #expect(h.controller.view.liveText == Self.formatted)
        }
        let before = h.controller.view

        call.onText("Dernier morceau tardif")
        await settle()

        #expect(h.controller.view == before)
        #expect(h.controller.view.draft != "Dernier morceau tardif")
        #expect(h.controller.view.liveText != "Dernier morceau tardif")
    }

    // MARK: - Règle 8 : les raccourcis pendant la mise en forme

    @Test("règle 8 : un raccourci pendant la mise en forme est ignoré, appui comme relâchement", arguments: [HotKeyBehavior.toggle, .hold])
    func shortcutsAreIgnoredWhileFormatting(behavior: HotKeyBehavior) async {
        let h = harness()
        h.knobs.behavior = behavior
        h.knobs.modeModifiers[Self.mode] = [.control, .option]
        h.controller.modeHotKeyPressed(Self.mode)
        let session = await h.driveToRecording()
        if behavior == .hold { h.controller.modeHotKeyReleased(Self.mode) } else { h.controller.modeHotKeyPressed(Self.mode) }
        #expect(await until { session.count(of: "finish") == 1 })
        session.emit(.finalizing)
        session.emit(.finished(Self.raw))
        #expect(await until { h.controller.view.stage == .formatting })
        let call = await h.rewriter.call()
        let before = h.controller.view

        h.controller.hotKeyPressed()
        h.controller.hotKeyReleased()
        h.controller.modeHotKeyPressed(Self.mode)
        h.controller.modeHotKeyReleased(Self.mode)
        h.controller.modeHotKeyPressed(ModeChip.rawID)
        h.controller.modeHotKeyReleased(ModeChip.rawID)
        await settle()

        #expect(h.controller.view == before)
        #expect(h.controller.view.stage == .formatting)
        #expect(!call.sawCancellation)
        #expect(h.engines.sessions.count == 1)
        #expect(h.knobs.selectedModes.isEmpty)
        #expect(h.panel.closeCount == 0)
        #expect(session.count(of: "cancel") == 0)
    }

    // MARK: - Règle 9 : sans consigne, rien ne change

    @Test("règle 9 : un mode sans consigne se colle comme une dictée brute, sans appeler le modèle")
    func aModeWithoutAnInstructionNeverCallsTheModel() async {
        let h = harness(run: .raw(engine: nil))
        await dictate(h)

        #expect(await until { h.pasted == [Self.raw] })
        #expect(h.rewriter.calls.isEmpty)
        #expect(h.rewriter.nameAsks.isEmpty)
        #expect(h.controller.view.stage != .formatting)
        #expect(!h.views.contains { $0.stage == .formatting })
    }

    @Test("règle 9 : la dictée brute par défaut (sans table de modes) ne touche pas au modèle")
    func rawDictationByDefaultNeverCallsTheModel() async {
        let h = DictationHarness()
        let session = await h.startRecording()
        session.emit(.finished(Self.raw))
        #expect(await until { h.pasted == [Self.raw] })
        #expect(h.rewriter.calls.isEmpty)
        #expect(h.knobs.modeReads == [ModeChip.rawID])
    }
}
