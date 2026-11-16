import AppKit
import Foundation
import Testing
import SupervoxCore

@testable import SupervoxApp

/// La correction à la voix dans le contrôleur de dictée : en relecture, on dit ce qu'il faut changer, le modèle fort réécrit le
/// texte, la version d'avant reste récupérable. Sessions, presse-papiers, touches, attentes et réécriture doubles : aucun micro,
/// aucun ⌘V, aucun réseau, aucune durée réelle. Chaque test porte le numéro de la règle de la tâche qu'il prouve.
@MainActor @Suite(.timeLimit(.minutes(1))) struct DictationCorrectionTests {
    static let original = "Bonjour à tous, voici la dictée."
    static let rewritten = "Bonjour à toutes et à tous, voici la dictée."
    static let change = "Mets le début au féminin."
    static let kept = "Le texte n'a pas changé."

    /// Le harnais : la dictée brute passe par la relecture.
    private func harness() -> DictationHarness {
        let h = DictationHarness()
        h.knobs.reviewing = [ModeChip.rawID]
        return h
    }

    /// Une dictée menée jusqu'à la relecture de `text` (session n° 0).
    @discardableResult
    private func review(_ h: DictationHarness, _ text: String = DictationCorrectionTests.original) async -> FakeSession {
        let session = await h.startRecording()
        session.emit(.finished(text))
        #expect(await until { h.controller.view.stage == .review })
        return session
    }

    /// La correction dont la session n° `index` est menée jusqu'à l'enregistrement.
    @discardableResult
    private func driveToRecording(_ h: DictationHarness, index: Int = 1) async -> FakeSession {
        let session = await h.session(index)
        #expect(await until { session.calls.contains("start") })
        session.emit(.preparing)
        session.emit(.recording)
        #expect(await until { h.controller.view.stage == .correcting(.recording) })
        return session
    }

    /// `startCorrection()`, puis l'enregistrement.
    @discardableResult
    private func correcting(_ h: DictationHarness, index: Int = 1) async -> FakeSession {
        h.controller.startCorrection()
        return await driveToRecording(h, index: index)
    }

    /// La consigne est dite et terminée : la session rend `text`, le modèle reçoit son travail (appel n° `call`).
    private func speak(
        _ h: DictationHarness, _ session: FakeSession, _ text: String = DictationCorrectionTests.change, call: Int = 0
    ) async -> RewriteCall {
        h.controller.finishCorrection()
        session.emit(.finalizing)
        #expect(await until { h.controller.view.stage == .correcting(.transcribing) })
        session.emit(.finished(text))
        let rewrite = await h.rewriter.call(call)
        #expect(await until { h.controller.view.stage == .correcting(.rewriting) })
        return rewrite
    }

    /// Une correction réussie : le texte devient `text`, l'ancien est la version précédente.
    private func corrected(_ h: DictationHarness, to text: String, index: Int = 1, call: Int = 0) async {
        let session = await correcting(h, index: index)
        let rewrite = await speak(h, session, call: call)
        rewrite.finish(.rewritten(text))
        #expect(await until { h.controller.view.stage == .review })
    }

    // MARK: - Les phrases

    @Test("les phrases fixes de la correction, mot pour mot ; le libellé du raccourci est celui qu'on donne, jamais un libellé en dur")
    func theSentences() {
        #expect(
            DictationController.correctionListeningNotice(hotKeyLabel: "⌃⌥Espace")
                == "Dites ce qu'il faut changer, puis appuyez de nouveau sur ⌃⌥Espace ou cliquez sur « Terminer ».")
        #expect(
            DictationController.correctionListeningNotice(hotKeyLabel: "⌘⇧K")
                == "Dites ce qu'il faut changer, puis appuyez de nouveau sur ⌘⇧K ou cliquez sur « Terminer ».")
        #expect(
            DictationController.correctionListeningNotice(hotKeyLabel: nil)
                == "Dites ce qu'il faut changer, puis cliquez sur « Terminer ».")
        #expect(DictationController.correctionRewritingNotice == "Réécriture du texte selon votre consigne…")
        #expect(
            DictationController.correctionEmptyNotice == "Aucune consigne n'a été entendue : le texte n'a pas changé.")
        #expect(DictationController.correctionUnchangedNotice == "Le modèle n'a rien changé au texte.")
        #expect(
            DictationController.correctionNoModelNotice
                == "Aucun modèle fort n'est choisi : choisissez-en un en tête de Réglages, onglet Modes, pour corriger à la voix. Le texte n'a pas changé.")
    }

    @Test("l'étape correcting : isActive faux, holdsPanel vrai, pour chacune des quatre étapes")
    func theStage() {
        for step in [CorrectionStep.preparing, .recording, .transcribing, .rewriting] {
            #expect(!DictationStage.correcting(step).isActive)
            #expect(DictationStage.correcting(step).holdsPanel)
        }
        #expect(DictationViewState().canGoBack == false)
        #expect(DictationViewState().canGoForward == false)
    }

    // MARK: - Règle 1 : démarrer

    @Test("règle 1 : startCorrection() en relecture : correcting(preparing) puis recording, avec la phrase du raccourci ; rien n'est inséré ni copié, le brouillon reste")
    func startCorrectionBegins() async {
        let h = harness()
        await review(h)
        h.rig.log.entries.removeAll()

        h.controller.startCorrection()
        #expect(h.controller.view.stage == .correcting(.preparing))
        #expect(h.controller.view.draft == Self.original)
        #expect(h.controller.view.notice == DictationController.correctionListeningNotice(hotKeyLabel: "⌘⇧K"))
        #expect(h.controller.isBusy)
        let session = await driveToRecording(h)
        #expect(h.controller.view.draft == Self.original)
        #expect(h.controller.view.notice == DictationController.correctionListeningNotice(hotKeyLabel: "⌘⇧K"))
        #expect(h.controller.lastTranscript == Self.original)
        #expect(h.controller.isBusy)
        #expect(h.panel.isOpen)
        #expect(session.calls == ["start"])
        await settle()
        #expect(h.writtenTexts == 0)
        #expect(h.pasted.isEmpty)
        #expect(h.rig.log.entries.allSatisfy { $0.hasPrefix("keyboard") }, "ni lecture ni écriture du presse-papiers, ni touche")
    }

    @Test("règle 1 : sans raccourci global, la phrase ne cite que le bouton")
    func theNoticeWithoutAHotKey() async {
        let h = harness()
        h.knobs.hotKeyLabel = nil
        await review(h)
        await correcting(h)
        #expect(h.controller.view.notice == "Dites ce qu'il faut changer, puis cliquez sur « Terminer ».")
    }

    @Test("règle 1 : l'appui global en relecture commence la correction, en bascule comme en maintien",
        arguments: [HotKeyBehavior.toggle, .hold])
    func theGlobalHotKeyStartsTheCorrection(behavior: HotKeyBehavior) async {
        let h = harness()
        await review(h)
        h.knobs.behavior = behavior
        h.controller.hotKeyPressed()
        #expect(h.controller.view.stage == .correcting(.preparing))
        await driveToRecording(h)
        #expect(h.engines.sessions.count == 2)
        #expect(h.panel.closeCount == 0)
    }

    @Test("règle 1 : texte blanc, collage en cours, hors relecture ou correction déjà en cours : ignoré",
        arguments: ["", "  ", "\n\t "])
    func startCorrectionIsIgnoredWhenItCannotApply(blank: String) async {
        // Texte blanc.
        let h = harness()
        await review(h)
        h.controller.reviewEdited(blank)
        let before = h.controller.view
        h.controller.startCorrection()
        h.controller.hotKeyPressed()
        await settle()
        #expect(h.controller.view == before)
        #expect(h.engines.sessions.count == 1)

        // Collage en cours.
        let pasting = harness()
        pasting.handover.holds = true
        await review(pasting)
        pasting.controller.pasteReview()
        #expect(await until { pasting.handover.sleeper.isSleeping })
        let during = pasting.controller.view
        pasting.controller.startCorrection()
        pasting.controller.hotKeyPressed()
        await settle()
        #expect(pasting.controller.view == during)
        #expect(pasting.controller.view.stage == .pasting)
        #expect(pasting.engines.sessions.count == 1)
        pasting.handover.sleeper.release()

        // Hors relecture : au repos et pendant la dictée.
        let idle = harness()
        idle.controller.startCorrection()
        await settle()
        #expect(idle.engines.sessions.isEmpty)
        #expect(idle.controller.view == DictationViewState())
        let recording = harness()
        await recording.startRecording()
        recording.controller.startCorrection()
        await settle()
        #expect(recording.engines.sessions.count == 1)
        #expect(recording.controller.view.stage == .recording)
    }

    @Test("règle 1 : une correction déjà en cours : un second startCorrection() ou appui de début ne change rien")
    func aSecondStartIsIgnored() async {
        let h = harness()
        await review(h)
        await correcting(h)
        h.controller.startCorrection()
        await settle()
        #expect(h.engines.sessions.count == 2)
        #expect(h.controller.view.stage == .correcting(.recording))
    }

    @Test("règle 1 : le champ est en lecture seule : une frappe pendant la correction ne change pas le brouillon")
    func typingDuringTheCorrectionIsIgnored() async {
        let h = harness()
        await review(h)
        await correcting(h)
        h.controller.reviewEdited("Autre texte tapé.")
        #expect(h.controller.view.draft == Self.original)
    }

    @Test("règle 1 : sans micro autorisé, la relecture reste telle quelle")
    func noMicrophoneKeepsTheReview() async {
        let h = harness()
        await review(h)
        h.knobs.microphoneAllowed = false
        let before = h.controller.view
        h.controller.startCorrection()
        await settle()
        #expect(h.controller.view == before)
        #expect(h.engines.sessions.count == 1)
    }

    @Test("règle 1 : la correction marche aussi dans la relecture d'un mode sans relecture dont l'application au premier plan a changé")
    func correctionWorksInTheFrontApplicationChangedReview() async {
        let h = DictationHarness()
        h.knobs.modeID = "perso-un"
        h.knobs.modeRuns["perso-un"] = .rewrite(instruction: "Résume.", model: nil, engine: nil)
        h.knobs.front = 100
        let session = await h.startRecording()
        session.emit(.finished("brut"))
        let format = await h.rewriter.call(0)
        h.knobs.front = 200
        format.finish(.rewritten("Mis en forme."))
        #expect(await until { h.controller.view.stage == .review })
        #expect(h.controller.view.notice == DictationController.frontApplicationChangedNotice)

        let listening = await correcting(h)
        let rewrite = await speak(h, listening, call: 1)
        rewrite.finish(.rewritten("Mis en forme, corrigé."))
        #expect(await until { h.controller.view.stage == .review })
        #expect(h.controller.view.draft == "Mis en forme, corrigé.")
        #expect(h.controller.view.canGoBack)
        h.controller.previousVersion()
        #expect(h.controller.view.draft == "Mis en forme.")
        h.controller.previousVersion()
        #expect(h.controller.view.draft == "brut")
    }

    // MARK: - Règle 2 : terminer

    @Test("règle 2 : bascule : le second appui global termine ; la session finit, puis transcribing, puis rewriting avec le travail de RewritePrompt.correction et le modèle fort")
    func theSecondPressFinishesAndTheJobIsTheCorrectionPrompt() async {
        let h = harness()
        h.knobs.settings.vocabulary = ["Supervox"]
        await review(h)
        let session = await correcting(h)

        h.controller.hotKeyPressed()
        #expect(await until { session.count(of: "finish") == 1 })
        #expect(session.finishPhases == [.recording])
        session.emit(.finalizing)
        #expect(await until { h.controller.view.stage == .correcting(.transcribing) })
        #expect(h.controller.isBusy)
        session.emit(.finished(Self.change))
        let call = await h.rewriter.call()
        #expect(await until { h.controller.view.stage == .correcting(.rewriting) })

        let expected = RewritePrompt.correction(text: Self.original, change: Self.change, vocabulary: ["Supervox"])
        #expect(call.job == RewriteJob(instruction: expected.instruction, input: expected.input, model: nil))
        #expect(call.job.model == nil, "toujours le modèle fort des réglages")
        #expect(h.rewriter.nameAsks.isEmpty, "aucun fournisseur nommé : la phrase ne cite pas de modèle")
        #expect(h.controller.view.notice == DictationController.correctionRewritingNotice)
        #expect(h.controller.view.draft == Self.original)
        #expect(!h.controller.isBusy, "la session ne tient plus le modèle pendant la réécriture")
        #expect(h.pasted.isEmpty)
    }

    @Test("règle 2 : le bouton (finishCorrection) termine comme le second appui ; hors enregistrement il ne fait rien")
    func finishCorrectionFinishesTheSession() async {
        let h = harness()
        await review(h)
        // Ni correction ni enregistrement : sans effet.
        h.controller.finishCorrection()
        let session = await correcting(h)
        h.controller.finishCorrection()
        #expect(await until { session.count(of: "finish") == 1 })
        h.controller.finishCorrection()
        await settle()
        #expect(session.count(of: "finish") == 1, "une seule fin")
    }

    @Test("règle 2 : une correction commencée par le bouton en réglage « maintien » se termine comme en bascule")
    func aButtonStartedCorrectionInHoldModeEndsByAPress() async {
        let h = harness()
        await review(h)
        h.knobs.behavior = .hold
        let session = await correcting(h)
        await settle()
        #expect(!h.holdSleeper.isSleeping, "aucune touche tenue : rien à surveiller")
        h.controller.hotKeyPressed()
        #expect(await until { session.count(of: "finish") == 1 })
    }

    @Test("règle 2 : maintien : seul le relâchement termine, et l'appui en cours d'enregistrement est ignoré")
    func holdReleaseFinishes() async {
        let h = harness()
        await review(h)
        h.knobs.behavior = .hold
        h.controller.hotKeyPressed()
        let session = await driveToRecording(h)
        h.controller.hotKeyPressed()
        await settle()
        #expect(session.count(of: "finish") == 0)
        h.controller.hotKeyReleased()
        #expect(await until { session.count(of: "finish") == 1 })
        #expect(session.finishPhases == [.recording])
    }

    @Test("règle 2 : maintien : le relâchement du raccourci d'un mode ne termine pas")
    func aModeReleaseDoesNotFinishAHoldCorrection() async {
        let h = harness()
        await review(h)
        h.knobs.behavior = .hold
        h.controller.hotKeyPressed()
        let session = await driveToRecording(h)
        h.controller.modeHotKeyReleased(ModeChip.rawID)
        h.controller.modeHotKeyReleased("perso-un")
        await settle()
        #expect(session.count(of: "finish") == 0)
    }

    @Test("règle 2 : maintien : les modificateurs du raccourci global lâchés (relâchement perdu) terminent ; ce sont ceux du raccourci global")
    func holdWatchFinishes() async {
        let h = harness()
        h.knobs.hotKeyModifiers = [.command, .shift]
        await review(h)
        h.knobs.behavior = .hold
        h.controller.hotKeyPressed()
        let session = await driveToRecording(h)
        #expect(await until { h.holdSleeper.isSleeping })
        h.holdSleeper.release()
        #expect(await until { h.knobs.probes.count == 1 && h.holdSleeper.isSleeping })
        #expect(h.knobs.probes == [[.command, .shift]])
        #expect(session.count(of: "finish") == 0)

        h.knobs.modifiersHeld = false
        h.holdSleeper.release()
        #expect(await until { session.count(of: "finish") == 1 })
    }

    @Test("règle 2 : les réglages de transcription sont ceux de la dictée relue, même changés depuis ; le moteur du mode compris")
    func theCorrectionUsesTheReviewedDictationsSettings() async {
        let h = harness()
        h.knobs.modeRuns[ModeChip.rawID] = .raw(engine: .parakeet)
        h.knobs.settings.engine = .whisperKit
        h.knobs.settings.vocabulary = ["Supervox"]
        await review(h)
        h.knobs.settings.engine = .whisperKit
        h.knobs.settings.vocabulary = ["Autre"]
        h.knobs.settings.language = "en"
        await correcting(h)

        #expect(h.engines.settingsSeen.count == 2)
        #expect(h.engines.settingsSeen[1] == h.engines.settingsSeen[0])
        #expect(h.engines.settingsSeen[1].engine == .parakeet)
        #expect(h.engines.settingsSeen[1].vocabulary == ["Supervox"])
    }

    @Test("règle 2 : le texte reçu en flux est montré à la place du brouillon, que le brouillon n'a pas quitté")
    func theStreamedTextIsShown() async {
        let h = harness()
        await review(h)
        let session = await correcting(h)
        let call = await speak(h, session)
        #expect(h.controller.view.liveText == "")

        call.onText("Bonjour à toutes")
        #expect(h.controller.view.liveText == "Bonjour à toutes")
        call.onText(Self.rewritten)
        #expect(h.controller.view.liveText == Self.rewritten)
        #expect(h.controller.view.stage == .correcting(.rewriting))
        #expect(h.controller.view.draft == Self.original, "le brouillon n'est remplacé qu'à la réussite")
    }

    // MARK: - Règle 3 : succès

    @Test("règle 3 : succès : review, nouveau texte, l'ancien en version précédente, lastTranscript inchangé, rien d'inséré")
    func aSuccessfulCorrection() async {
        let h = harness()
        await review(h)
        #expect(!h.controller.view.canGoBack)
        let session = await correcting(h)
        let call = await speak(h, session)
        call.onText(Self.rewritten)
        call.finish(.rewritten(Self.rewritten))

        #expect(await until { h.controller.view.stage == .review })
        #expect(h.controller.view.draft == Self.rewritten)
        #expect(h.controller.view.liveText == "")
        #expect(h.controller.view.notice == nil)
        #expect(h.controller.view.canGoBack)
        #expect(!h.controller.view.canGoForward)
        #expect(h.controller.lastTranscript == Self.original, "inchangé jusqu'à la fermeture ou au collage")
        #expect(h.controller.view.lastTranscript == Self.original)
        #expect(!h.controller.isBusy)
        #expect(h.panel.isOpen)
        await settle()
        #expect(h.writtenTexts == 0)
        #expect(h.pasted.isEmpty)

        h.controller.previousVersion()
        #expect(h.controller.view.draft == Self.original)
    }

    @Test("règle 3 : le texte tapé avant la correction est celui que le modèle reçoit, et la version précédente le garde")
    func typedTextIsWhatTheModelGets() async {
        let h = harness()
        await review(h)
        h.controller.reviewEdited("Texte retouché à la main.")
        let session = await correcting(h)
        let call = await speak(h, session)
        #expect(call.job.input.contains("Texte retouché à la main."))
        call.finish(.rewritten("Texte retouché et corrigé."))
        #expect(await until { h.controller.view.stage == .review })
        h.controller.previousVersion()
        #expect(h.controller.view.draft == "Texte retouché à la main.")
    }

    @Test("règle 3 : une nouvelle correction vide les versions suivantes")
    func aNewCorrectionClearsTheNextVersions() async {
        let h = harness()
        await review(h)
        await corrected(h, to: Self.rewritten)
        h.controller.previousVersion()
        #expect(h.controller.view.canGoForward)

        await corrected(h, to: "Une autre version.", index: 2, call: 1)
        #expect(h.controller.view.draft == "Une autre version.")
        #expect(!h.controller.view.canGoForward)
        h.controller.nextVersion()
        #expect(h.controller.view.draft == "Une autre version.")
        // L'original est encore derrière, une seule fois.
        h.controller.previousVersion()
        #expect(h.controller.view.draft == Self.original)
        #expect(!h.controller.view.canGoBack)
    }

    @Test("règle 3 : le collage après correction colle la nouvelle version, et lastTranscript la devient")
    func pastingAfterACorrection() async {
        let h = harness()
        await review(h)
        await corrected(h, to: Self.rewritten)
        h.controller.pasteReview()
        #expect(await until { h.pasted == [Self.rewritten] })
        #expect(h.controller.lastTranscript == Self.rewritten)
    }

    // MARK: - Règle 4 : rien perdu en cas d'échec

    enum Failure: CaseIterable {
        case noModel, blankChange, noSpeech, modelDown, identical, partialThenDown
    }

    /// Une relecture déjà corrigée une fois (une version précédente), puis retouchée à la main, puis une correction qui échoue
    /// de cette façon. Rend la phrase attendue.
    private func failedCorrection(_ failure: Failure, _ h: DictationHarness) async -> String {
        await review(h)
        await corrected(h, to: Self.rewritten)
        h.controller.reviewEdited(Self.rewritten + " Mot tapé.")
        let session = await correcting(h, index: 2)
        switch failure {
        case .noSpeech:
            session.emit(.failed(.noSpeech))
            #expect(await until { h.controller.view.stage == .review })
            return DictationController.correctionEmptyNotice
        case .blankChange:
            session.emit(.finalizing)
            session.emit(.finished("  \n "))
            #expect(await until { h.controller.view.stage == .review })
            return DictationController.correctionEmptyNotice
        case .noModel:
            let call = await speak(h, session, call: 1)
            call.finish(.failed(.noModel))
            #expect(await until { h.controller.view.stage == .review })
            return DictationController.correctionNoModelNotice
        case .modelDown:
            let call = await speak(h, session, call: 1)
            call.finish(.failed(.unreachable))
            #expect(await until { h.controller.view.stage == .review })
            return RewriteFailure.unreachable.message + " " + Self.kept
        case .partialThenDown:
            let call = await speak(h, session, call: 1)
            call.onText("Réponse partielle du mod")
            call.finish(.failed(.interrupted))
            #expect(await until { h.controller.view.stage == .review })
            return RewriteFailure.interrupted.message + " " + Self.kept
        case .identical:
            let call = await speak(h, session, call: 1)
            call.finish(.rewritten("  " + Self.rewritten + " Mot tapé.\n"))
            #expect(await until { h.controller.view.stage == .review })
            return DictationController.correctionUnchangedNotice
        }
    }

    @Test("règle 4 : aucun modèle fort, consigne blanche, session « aucune parole », modèle en panne, réponse partielle puis panne, réponse identique : review, brouillon identique (texte tapé compris), versions inchangées, la phrase de l'échec",
        arguments: Failure.allCases)
    func nothingIsLostOnFailure(failure: Failure) async {
        let h = harness()
        let notice = await failedCorrection(failure, h)

        #expect(h.controller.view.stage == .review)
        #expect(h.controller.view.draft == Self.rewritten + " Mot tapé.", "le texte tapé reste, la réponse du modèle n'est pas montrée")
        #expect(h.controller.view.liveText == "")
        #expect(h.controller.view.notice == notice)
        #expect(h.controller.lastTranscript == Self.original)
        #expect(!h.controller.isBusy)
        #expect(h.panel.isOpen)
        #expect(h.controller.view.canGoBack)
        #expect(!h.controller.view.canGoForward)
        await settle()
        #expect(h.pasted.isEmpty)
        #expect(h.writtenTexts == 0)
        // Les versions sont celles d'avant : l'original derrière, rien devant, le texte tapé revient en allant et venant.
        h.controller.previousVersion()
        #expect(h.controller.view.draft == Self.original)
        #expect(!h.controller.view.canGoBack)
        #expect(h.controller.view.canGoForward)
        h.controller.nextVersion()
        #expect(h.controller.view.draft == Self.rewritten + " Mot tapé.")
        #expect(!h.controller.view.canGoForward)
    }

    @Test("règle 4 : les phrases de l'échec : le message du modèle puis « Le texte n'a pas changé. », sauf noModel")
    func theFailureSentences() async {
        let h = harness()
        let notice = await failedCorrection(.modelDown, h)
        #expect(notice == "Le serveur est injoignable : vérifiez la connexion et l'adresse du fournisseur. Le texte n'a pas changé.")
        #expect(h.controller.view.notice == notice)

        let none = harness()
        _ = await failedCorrection(.noModel, none)
        #expect(!(none.controller.view.notice ?? "").contains("dans Réglages, onglet Modes."), "pas la phrase des modes à consigne")
        #expect(none.controller.view.notice?.hasPrefix("Aucun modèle fort n'est choisi") == true)
    }

    @Test("règle 4 : une réponse blanche du modèle est « le modèle n'a rien rendu », le texte reste")
    func aBlankResponseKeepsTheText() async {
        let h = harness()
        await review(h)
        let session = await correcting(h)
        let call = await speak(h, session)
        call.finish(.rewritten("  \n"))
        #expect(await until { h.controller.view.stage == .review })
        #expect(h.controller.view.draft == Self.original)
        #expect(h.controller.view.notice == RewriteFailure.empty.message + " " + Self.kept)
        #expect(!h.controller.view.canGoBack)
    }

    @Test("règle 4 : une préparation en échec ou une session interrompue ramène la relecture avec la phrase et « Le texte n'a pas changé. »")
    func preparationFailureAndInterruptionKeepTheReview() async {
        let h = harness()
        await review(h)
        h.engines.configure { $0.makeError = DictationUnavailable() }
        h.controller.startCorrection()
        #expect(await until { h.controller.view.stage == .review })
        #expect(h.controller.view.draft == Self.original)
        #expect(h.controller.view.notice == DictationController.preparationFailedNotice + " " + Self.kept)
        #expect(!h.controller.isBusy)

        let other = harness()
        await review(other)
        let session = await correcting(other)
        session.emit(.cancelled)
        #expect(await until { other.controller.view.stage == .review })
        #expect(other.controller.view.draft == Self.original)
        #expect(other.controller.view.notice == DictationController.interruptedNotice + " " + Self.kept)
        #expect(!other.controller.isBusy)
    }

    // MARK: - Règle 5 : versions

    @Test("règle 5 : previousVersion et nextVersion : aucune version ne se perd en allant et venant, le texte tapé voyage avec sa version")
    func versionsTravel() async {
        let h = harness()
        await review(h)
        await corrected(h, to: "B")
        h.controller.reviewEdited("B+")
        await corrected(h, to: "C", index: 2, call: 1)
        h.controller.reviewEdited("C+")
        // Versions : A, B+, [C+].
        h.controller.previousVersion()
        #expect(h.controller.view.draft == "B+")
        #expect(h.controller.view.canGoBack)
        #expect(h.controller.view.canGoForward)
        h.controller.reviewEdited("B++")
        h.controller.previousVersion()
        #expect(h.controller.view.draft == Self.original)
        #expect(!h.controller.view.canGoBack)
        h.controller.previousVersion()
        #expect(h.controller.view.draft == Self.original, "sans version précédente : sans effet")
        h.controller.nextVersion()
        #expect(h.controller.view.draft == "B++")
        h.controller.nextVersion()
        #expect(h.controller.view.draft == "C+")
        #expect(!h.controller.view.canGoForward)
        h.controller.nextVersion()
        #expect(h.controller.view.draft == "C+", "sans version suivante : sans effet")
        #expect(h.controller.lastTranscript == Self.original)
    }

    @Test("règle 5 : sans version, previousVersion et nextVersion ne changent rien (ni la vue, ni le panneau)")
    func noVersionNoEffect() async {
        let h = harness()
        await review(h)
        let before = h.controller.view
        h.controller.previousVersion()
        h.controller.nextVersion()
        #expect(h.controller.view == before)
        #expect(h.controller.view.stage == .review)
    }

    @Test("règle 5 : hors relecture (correction, collage, repos) : sans effet, les versions restent")
    func versionsOnlyInTheReview() async {
        let h = harness()
        await review(h)
        await corrected(h, to: Self.rewritten)
        await correcting(h, index: 2)
        let during = h.controller.view
        h.controller.previousVersion()
        h.controller.nextVersion()
        #expect(h.controller.view == during)
        #expect(h.controller.view.draft == Self.rewritten)
        #expect(!h.controller.view.canGoBack, "le bouton n'est pas actif pendant la correction")

        let pasting = harness()
        pasting.handover.holds = true
        await review(pasting)
        await corrected(pasting, to: Self.rewritten)
        pasting.controller.pasteReview()
        #expect(await until { pasting.handover.sleeper.isSleeping })
        pasting.controller.previousVersion()
        #expect(pasting.controller.view.draft == Self.rewritten)
        #expect(pasting.controller.view.stage == .pasting)
        pasting.handover.sleeper.release()

        let idle = harness()
        idle.controller.previousVersion()
        idle.controller.nextVersion()
        #expect(idle.controller.view == DictationViewState())
    }

    @Test("règle 5 : après une mise en forme, la transcription brute est la première version précédente, puis la correction s'empile")
    func theRawTranscriptIsTheFirstPreviousVersion() async {
        let h = DictationHarness()
        h.knobs.modeID = "perso-un"
        h.knobs.modeRuns["perso-un"] = .rewrite(instruction: "Résume.", model: nil, engine: nil)
        h.knobs.reviewing = ["perso-un"]
        let session = await h.startRecording()
        session.emit(.finished("brut"))
        let format = await h.rewriter.call(0)
        format.finish(.rewritten("Mis en forme."))
        #expect(await until { h.controller.view.stage == .review })
        #expect(h.controller.view.canGoBack)
        #expect(!h.controller.view.canGoForward)
        #expect(h.controller.reviewPreviousText == "brut")

        await corrected(h, to: "Mis en forme, corrigé.", call: 1)
        h.controller.previousVersion()
        #expect(h.controller.view.draft == "Mis en forme.")
        h.controller.previousVersion()
        #expect(h.controller.view.draft == "brut")
        #expect(!h.controller.view.canGoBack)
        h.controller.nextVersion()
        h.controller.nextVersion()
        #expect(h.controller.view.draft == "Mis en forme, corrigé.")
    }

    @Test("règle 5 : sans mise en forme, une dictée relue n'a aucune version précédente")
    func aPlainReviewHasNoPreviousVersion() async {
        let h = harness()
        await review(h)
        #expect(!h.controller.view.canGoBack)
        #expect(!h.controller.view.canGoForward)
    }

    // MARK: - Règle 7 : Échap

    enum Step: CaseIterable { case preparing, recording, transcribing, rewriting }

    /// Une relecture corrigée jusqu'à cette étape ; rend la session et l'appel de réécriture s'il y en a un.
    private func drive(_ h: DictationHarness, to step: Step) async -> (FakeSession, RewriteCall?) {
        await review(h)
        h.controller.reviewEdited(Self.original + " Mot tapé.")
        h.controller.startCorrection()
        let session = await h.session(1)
        #expect(await until { session.calls.contains("start") })
        if step == .preparing {
            #expect(h.controller.view.stage == .correcting(.preparing))
            return (session, nil)
        }
        session.emit(.preparing)
        session.emit(.recording)
        #expect(await until { h.controller.view.stage == .correcting(.recording) })
        if step == .recording { return (session, nil) }
        h.controller.finishCorrection()
        session.emit(.finalizing)
        #expect(await until { h.controller.view.stage == .correcting(.transcribing) })
        if step == .transcribing { return (session, nil) }
        session.emit(.finished(Self.change))
        let call = await h.rewriter.call()
        #expect(await until { h.controller.view.stage == .correcting(.rewriting) })
        return (session, call)
    }

    @Test("règle 7 : Échap pendant la correction l'annule seulement : session et requête annulées, rien d'inséré, review, texte intact, panneau ouvert ; une issue tardive ne touche plus rien ; un second Échap ferme",
        arguments: Step.allCases)
    func escapeCancelsOnlyTheCorrection(step: Step) async {
        let h = harness()
        let (session, call) = await drive(h, to: step)
        let draft = Self.original + " Mot tapé."

        h.controller.escapePressed()
        #expect(h.controller.view.stage == .review)
        #expect(h.controller.view.draft == draft)
        #expect(h.controller.view.liveText == "")
        #expect(h.panel.isOpen)
        #expect(h.panel.closeCount == 0)
        #expect(!h.controller.isBusy)
        #expect(await until { session.count(of: "cancel") == 1 })
        if let call { #expect(await until { call.sawCancellation }, "la requête est annulée") }
        let after = h.controller.view

        // Tout ce qui arrive ensuite n'appartient plus à la correction.
        session.emit(.finalizing)
        session.emit(.finished("Une consigne tardive."))
        if let call {
            call.onText("Texte tardif")
            call.finish(.rewritten("Texte tardif"))
        }
        await settle()
        #expect(h.controller.view == after)
        #expect(h.controller.view.draft == draft)
        #expect(h.rewriter.calls.count == (call == nil ? 0 : 1), "aucune réécriture n'est lancée par une consigne tardive")
        #expect(h.writtenTexts == 0)
        #expect(h.pasted.isEmpty)
        #expect(h.panel.isOpen)

        // Un second Échap ferme, comme à l'étape 4 : le brouillon devient le dernier texte.
        h.controller.escapePressed()
        #expect(!h.panel.isOpen)
        #expect(h.controller.view == DictationViewState(lastTranscript: draft))
        #expect(h.controller.lastTranscript == draft)
        #expect(h.pasted.isEmpty)
    }

    @Test("règle 7 : une correction annulée, une nouvelle peut commencer ; l'issue de l'ancienne ne touche pas la nouvelle")
    func aLateOutcomeDoesNotTouchTheNextCorrection() async {
        let h = harness()
        await review(h)
        let first = await correcting(h)
        let oldCall = await speak(h, first)
        h.controller.escapePressed()

        let second = await correcting(h, index: 2)
        let before = h.controller.view
        oldCall.onText("Texte de l'ancienne")
        oldCall.finish(.rewritten("Texte de l'ancienne"))
        await settle()
        #expect(h.controller.view == before)
        #expect(h.controller.view.stage == .correcting(.recording))
        _ = second
    }

    @Test("règle 7 : un modèle sourd à l'annulation rend son texte puis son issue longtemps après Échap ou la fermeture : rien ne bouge, même pendant une nouvelle correction",
        arguments: ["escape", "closed"], [true, false])
    func aDeafModelsLateTextAndOutcomeAreIgnored(how: String, startsANewCorrection: Bool) async {
        let h = harness()
        h.rewriter.ignoresCancellation = true
        await review(h)
        let session = await correcting(h)
        let call = await speak(h, session)
        if how == "escape" { h.controller.escapePressed() } else { h.panel.close() }
        await settle()
        #expect(call.sawCancellation, "la tâche a bien été annulée, le modèle sourd rend pourtant son issue plus tard")
        var fresh: FakeSession?
        if startsANewCorrection, how == "escape" { fresh = await correcting(h, index: 2) }
        let after = h.controller.view

        call.onText("Texte tardif")
        call.finish(.rewritten("Texte tardif"))
        await settle()
        #expect(h.controller.view == after)
        #expect(h.controller.view.draft == (how == "escape" ? Self.original : ""))
        #expect(h.pasted.isEmpty)
        if fresh != nil { #expect(h.controller.view.stage == .correcting(.recording)) }
    }

    @Test("règle 7 : le texte et l'issue d'une réécriture qui arrivent après la fin de la correction sont ignorés")
    func aLateTextAfterTheOutcomeIsIgnored() async {
        let h = harness()
        await review(h)
        let session = await correcting(h)
        let call = await speak(h, session)
        call.finish(.rewritten(Self.rewritten))
        #expect(await until { h.controller.view.stage == .review })
        let after = h.controller.view
        call.onText("Texte tardif")
        call.finish(.failed(.unreachable))
        await settle()
        #expect(h.controller.view == after)
        #expect(h.controller.view.draft == Self.rewritten)
        #expect(h.controller.view.liveText == "")
    }

    @Test("règle 7 : la fermeture du panneau pendant la correction ferme tout : correction annulée, lastTranscript = brouillon",
        arguments: Step.allCases)
    func closingThePanelClosesEverything(step: Step) async {
        let h = harness()
        let (session, call) = await drive(h, to: step)
        let draft = Self.original + " Mot tapé."

        h.panel.close()
        #expect(h.controller.view == DictationViewState(lastTranscript: draft))
        #expect(h.controller.lastTranscript == draft)
        #expect(!h.controller.isBusy)
        #expect(await until { session.count(of: "cancel") == 1 })
        if let call { #expect(await until { call.sawCancellation }) }
        if let call { call.finish(.rewritten("Tardif")) }
        session.emit(.finished("Tardive"))
        await settle()
        #expect(h.controller.view == DictationViewState(lastTranscript: draft))
        #expect(h.pasted.isEmpty)
        #expect(!h.panel.isOpen)
    }

    // MARK: - Règle 8 : collage et copie pendant la correction

    @Test("règle 8 : « Coller » (pasteReview) pendant la correction n'a aucun effet")
    func pastingDuringTheCorrectionDoesNothing() async {
        let h = harness()
        let (_, call) = await drive(h, to: .rewriting)
        let before = h.controller.view
        h.controller.pasteReview()
        await settle()
        #expect(h.controller.view == before)
        #expect(h.pasted.isEmpty)
        #expect(h.writtenTexts == 0)
        #expect(!h.controller.isInserting)
        _ = call
    }

    // MARK: - Règle 9 : pastille et raccourcis de mode

    @Test("règle 9 : changer de pastille pendant la correction est sans effet sur elle, et le raccourci global la termine toujours")
    func aChipChangeDoesNotTouchTheCorrection() async {
        let h = harness()
        await review(h)
        let session = await correcting(h)
        let before = h.controller.view
        h.knobs.modeID = ModeChip.promptID
        await settle()
        #expect(h.controller.view == before)
        h.controller.hotKeyPressed()
        #expect(await until { session.count(of: "finish") == 1 })
        #expect(h.knobs.selectedModes.isEmpty)
        #expect(h.panel.closeCount == 0)
    }

    @Test("règle 9 : un changement de pastille en relecture : l'appui global commence la correction, il ne ferme ni ne change le mode")
    func aChipChangeInTheReviewDoesNotStopTheCorrection() async {
        let h = harness()
        await review(h)
        h.knobs.modeID = ModeChip.promptID
        h.controller.hotKeyPressed()
        #expect(h.controller.view.stage == .correcting(.preparing))
        #expect(h.panel.closeCount == 0)
        #expect(h.knobs.selectedModes.isEmpty)
    }

    @Test("règle 1 et 2 : le raccourci d'un mode, appui comme relâchement, est ignoré pendant la relecture et pendant la correction, même sans raccourci global",
        arguments: [HotKeyBehavior.toggle, .hold])
    func aModeHotKeyIsIgnoredThroughTheReviewAndTheCorrection(behavior: HotKeyBehavior) async {
        let h = harness()
        await review(h)
        h.knobs.behavior = behavior
        h.knobs.unbound = [.global]
        let reviewView = h.controller.view
        h.controller.modeHotKeyPressed(ModeChip.rawID)
        h.controller.modeHotKeyReleased(ModeChip.rawID)
        h.controller.modeHotKeyPressed("perso-un")
        await settle()
        #expect(h.controller.view == reviewView)
        #expect(h.engines.sessions.count == 1)
        #expect(h.knobs.selectedModes.isEmpty)

        // Le bouton commence la correction ; le raccourci d'un mode ne la termine pas, même si le global n'en a plus.
        let session = await correcting(h)
        h.controller.modeHotKeyPressed(ModeChip.rawID)
        h.controller.modeHotKeyReleased(ModeChip.rawID)
        h.controller.modeHotKeyPressed("perso-un")
        await settle()
        #expect(session.count(of: "finish") == 0)
        #expect(h.controller.view.stage == .correcting(.recording))
        #expect(h.knobs.selectedModes.isEmpty)
        #expect(h.engines.sessions.count == 2)

        h.controller.finishCorrection()
        #expect(await until { session.count(of: "finish") == 1 })
    }

    @Test("règle 1 : la relecture d'une dictée commencée par le raccourci d'un mode : le raccourci global commence la correction, celui du mode non")
    func aModeOwnedReviewIsCorrectedByTheGlobalHotKey() async {
        let h = harness()
        h.knobs.modeRuns["perso-un"] = .raw(engine: nil)
        h.knobs.reviewing = ["perso-un"]
        let session = await h.startModeRecording("perso-un")
        session.emit(.finished(Self.original))
        #expect(await until { h.controller.view.stage == .review })

        h.controller.modeHotKeyPressed("perso-un")
        await settle()
        #expect(h.controller.view.stage == .review)
        h.controller.hotKeyPressed()
        #expect(h.controller.view.stage == .correcting(.preparing))
    }

    // MARK: - isBusy

    @Test("isBusy : vrai pendant preparing, recording, transcribing d'une correction ; faux pendant rewriting et après",
        arguments: Step.allCases)
    func isBusyFollowsTheSession(step: Step) async {
        let h = harness()
        let (_, _) = await drive(h, to: step)
        #expect(h.controller.isBusy == (step != .rewriting))
    }

    // MARK: - Règle 6 : le champ (sans fenêtre)

    /// Un champ de relecture avec sa pile propre (celle de son coordinateur), sans fenêtre, et ce que `onHistoryEnd` a reçu.
    @MainActor final class Field {
        let textView: FocusingTextView
        let coordinator: ReviewTextView.Coordinator
        var ends: [EditingCommand] = []

        init(text: String = "") {
            let view = ReviewTextView(text: text, isEditable: true, takesFocus: false, onEdit: { _ in }, onHistoryEnd: { _ in })
            coordinator = view.makeCoordinator()
            textView = FocusingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
            textView.allowsUndo = true
            textView.isRichText = false
            textView.delegate = coordinator
            ReviewTextView.update(textView, text: text, isEditable: true, takesFocus: false)
            textView.onHistoryEnd = { [unowned self] in ends.append($0) }
        }

        func type(_ text: String) {
            textView.insertText(text, replacementRange: NSRange(location: textView.string.utf16.count, length: 0))
        }
    }

    @Test("règle 6 : un texte remplacé de l'extérieur (nouvelle version) vide la pile du champ, y compris ce qu'il aurait pu refaire")
    func aReplacedTextClearsTheFieldsStack() throws {
        let field = Field(text: "Version A.")
        field.type(" Mot.")
        try #require(field.textView.undoManager?.canUndo == true)
        field.textView.undoManager?.undo()
        #expect(field.textView.string == "Version A.")
        try #require(field.textView.undoManager?.canRedo == true, "le test ne prouve rien sans un refaire possible")
        field.type(" Autre.")

        ReviewTextView.update(field.textView, text: "Version B, plus courte.", isEditable: true, takesFocus: false)
        #expect(field.textView.string == "Version B, plus courte.")
        #expect(field.textView.undoManager?.canUndo == false)
        #expect(field.textView.undoManager?.canRedo == false)
        // Un ⌘Z ou ⇧⌘Z qui suit n'a plus rien à défaire dans le champ : il ne touche pas au texte, et ne lève rien.
        field.textView.undoOrPreviousVersion()
        field.textView.redoOrNextVersion()
        #expect(field.textView.string == "Version B, plus courte.")
        #expect(field.ends == [.undo, .redo])
    }

    @Test("règle 6 : le même texte ne vide pas la pile (la frappe remonte au modèle, qui redonne le même texte)")
    func theSameTextKeepsTheStack() {
        let field = Field(text: "Version A.")
        field.type(" Mot.")
        ReviewTextView.update(field.textView, text: field.textView.string, isEditable: true, takesFocus: false)
        #expect(field.textView.undoManager?.canUndo == true)
    }

    @Test("règle 6 : pas de réécriture pendant un texte marqué, et la pile reste")
    func markedTextKeepsTheStackAndTheText() throws {
        let field = Field(text: "ab")
        field.type("c")
        field.textView.setMarkedText(
            "^", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(field.textView.hasMarkedText())
        ReviewTextView.update(field.textView, text: "autre", isEditable: true, takesFocus: false)
        #expect(field.textView.string == "abc^")
        #expect(field.textView.undoManager?.canUndo == true)
    }

    @Test("règle 6 : ⌘Z défait la frappe du champ d'abord, et seulement quand la pile est vide prévient le panneau ; de même ⇧⌘Z")
    func undoAndRedoUseTheFieldsStackFirst() {
        let field = Field(text: "Version A.")
        field.type(" Mot.")
        field.textView.undoOrPreviousVersion()
        #expect(field.textView.string == "Version A.")
        #expect(field.ends.isEmpty, "la pile du champ avait quelque chose à défaire")
        field.textView.undoOrPreviousVersion()
        #expect(field.textView.string == "Version A.")
        #expect(field.ends == [.undo])

        field.textView.redoOrNextVersion()
        #expect(field.textView.string == "Version A. Mot.")
        #expect(field.ends == [.undo], "la pile du champ avait quelque chose à refaire")
        field.textView.redoOrNextVersion()
        #expect(field.ends == [.undo, .redo])
        #expect(field.textView.string == "Version A. Mot.")
    }

    @Test("règle 6 : les sélecteurs undo: et redo: que le panneau envoie au champ passent par la pile puis par les versions")
    func theUndoAndRedoSelectorsReachTheFieldsHistory() {
        let field = Field(text: "Version A.")
        field.type(" Mot.")
        #expect(field.textView.tryToPerform(NSSelectorFromString("undo:"), with: nil))
        #expect(field.textView.string == "Version A.")
        #expect(field.ends.isEmpty)
        #expect(field.textView.tryToPerform(NSSelectorFromString("undo:"), with: nil))
        #expect(field.ends == [.undo])
        #expect(field.textView.tryToPerform(NSSelectorFromString("redo:"), with: nil))
        #expect(field.textView.string == "Version A. Mot.")
        #expect(field.textView.tryToPerform(NSSelectorFromString("redo:"), with: nil))
        #expect(field.ends == [.undo, .redo])
        // Les autres sélecteurs ne sont pas interceptés.
        field.textView.setSelectedRange(NSRange(location: 0, length: 3))
        #expect(field.textView.tryToPerform(NSSelectorFromString("selectAll:"), with: nil))
        #expect(field.textView.selectedRange() == NSRange(location: 0, length: field.textView.string.utf16.count))
    }

    @Test("règle 6 : ⌘Z et ⇧⌘Z ne font rien dans un champ en lecture seule (pendant la correction) : ni défaire, ni changer de version")
    func undoAndRedoDoNothingInAReadOnlyField() {
        let field = Field(text: "Version A.")
        field.type(" Mot.")
        field.textView.isEditable = false
        _ = field.textView.tryToPerform(NSSelectorFromString("undo:"), with: nil)
        field.textView.undoOrPreviousVersion()
        #expect(field.textView.string == "Version A. Mot.")
        #expect(field.ends.isEmpty)
        field.textView.isEditable = true
        field.textView.undoOrPreviousVersion()
        field.textView.isEditable = false
        field.textView.redoOrNextVersion()
        _ = field.textView.tryToPerform(NSSelectorFromString("redo:"), with: nil)
        #expect(field.textView.string == "Version A.")
        #expect(field.ends.isEmpty)
    }

    @Test("une version qui remplace un texte par le même texte laisse la pile du champ (documenté : seul un texte différent la vide)")
    func anIdenticalVersionKeepsTheStack() {
        let field = Field(text: "Version A.")
        field.type(" Mot.")
        field.textView.undoOrPreviousVersion()
        // Le champ montre « Version A. » : une version identique ne remplace rien, la pile (le refaire) reste.
        ReviewTextView.update(field.textView, text: "Version A.", isEditable: true, takesFocus: false)
        #expect(field.textView.undoManager?.canRedo == true)
    }
}
