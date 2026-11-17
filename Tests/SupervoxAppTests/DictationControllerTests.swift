import Foundation
import Testing
import SupervoxCore

@testable import SupervoxApp

/// Le contrôleur de dictée, piloté par des sessions doubles : le test émet les instantanés, le contrôleur y répond.
/// Aucun micro, aucun presse-papiers du système, aucune touche postée, aucune attente réelle.
@MainActor @Suite(.timeLimit(.minutes(1))) struct DictationControllerTests {
    // MARK: - Bascule

    @Test func firstPressOpensThePanelAndStartsTheDictationAtOnce() async {
        let h = DictationHarness()
        h.controller.hotKeyPressed()

        #expect(h.panel.isOpen)
        // Posé tout de suite : un second appui qui arrive avant la première session est déjà ignoré.
        #expect(h.controller.view.stage == .preparing)
        let session = await h.session()
        #expect(await until { session.calls == ["start"] })
    }

    @Test func secondPressFinishesTheDictation() async {
        let h = DictationHarness()
        let session = await h.startRecording()

        h.controller.hotKeyPressed()
        #expect(await until { session.count(of: "finish") == 1 })
        #expect(session.finishPhases == [.recording])
        #expect(h.engines.sessions.count == 1)
    }

    @Test func pressDuringFinalizingIsIgnored() async {
        let h = DictationHarness()
        let session = await h.startRecording()
        session.emit(.finalizing)
        #expect(await until { h.controller.view.stage == .finalizing })

        h.controller.hotKeyPressed()
        await settle()
        #expect(session.count(of: "finish") == 0)
        #expect(h.engines.sessions.count == 1)
        #expect(h.controller.view.stage == .finalizing)
    }

    @Test func pressDuringPreparingIsIgnored() async {
        let h = DictationHarness()
        h.controller.hotKeyPressed()
        let session = await h.session()
        session.emit(.preparing)

        h.controller.hotKeyPressed()
        await settle()
        #expect(session.count(of: "finish") == 0)
        #expect(session.count(of: "start") == 1)
        #expect(h.engines.sessions.count == 1)
    }

    // MARK: - Maintien

    @Test func holdPressStartsAndReleaseFinishes() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startRecording()
        #expect(session.count(of: "finish") == 0)

        h.controller.hotKeyReleased()
        #expect(await until { session.count(of: "finish") == 1 })
        #expect(session.finishPhases == [.recording])
    }

    @Test func releaseWithoutADictationIsIgnored() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        h.controller.hotKeyReleased()
        await settle()
        #expect(h.engines.sessions.isEmpty)
        #expect(!h.panel.isOpen)
        #expect(h.controller.view.stage == .idle)
    }

    @Test func releaseAfterTheDictationEndedIsIgnored() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startRecording()
        session.emit(.failed(.noSpeech))
        #expect(await until { h.controller.view.stage == .failed(.noSpeech) })

        h.controller.hotKeyReleased()
        await settle()
        #expect(session.count(of: "finish") == 0)
        #expect(h.engines.sessions.count == 1)
    }

    @Test func releaseInToggleModeDoesNothing() async {
        let h = DictationHarness()
        h.knobs.behavior = .toggle
        let session = await h.startRecording()

        h.controller.hotKeyReleased()
        await settle()
        #expect(session.count(of: "finish") == 0)
        #expect(h.controller.view.stage == .recording)
    }

    @Test func releaseDuringPreparingCallsFinish() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        h.controller.hotKeyPressed()
        let session = await h.session()
        session.emit(.preparing)
        #expect(await until { session.calls.contains("start") })
        await settle()

        h.controller.hotKeyReleased()
        #expect(await until { session.count(of: "finish") == 1 })
        #expect(session.finishPhases == [.preparing])
    }

    /// Le contrat de la session : un `finish()` reçu avant `start()` est perdu. Une touche relâchée avant même que la
    /// session existe est donc retenue, puis rejouée une fois la préparation commencée.
    @Test func releaseBeforeTheSessionExistsIsReplayedOnceThePreparationStarted() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let gate = TestGate()
        defer { gate.open() }
        h.engines.configure { $0.makeGate = gate }
        h.controller.hotKeyPressed()
        h.controller.hotKeyReleased()
        await settle()
        #expect(h.engines.sessions.isEmpty)

        gate.open()
        let session = await h.session()
        #expect(await until { session.calls.contains("start") })
        await settle()
        // La session est encore `idle` : un `finish()` serait perdu.
        #expect(session.count(of: "finish") == 0)

        session.emit(.preparing)
        #expect(await until { session.count(of: "finish") == 1 })
        #expect(session.finishPhases == [.preparing])
    }

    /// La session existe et `start()` a été appelé, mais elle n'a pas encore annoncé `preparing` : elle est encore `idle`
    /// pour elle-même, et y perdrait aussi le `finish()`.
    @Test func releaseAfterStartButBeforeTheFirstPreparingSnapshotIsReplayed() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        h.controller.hotKeyPressed()
        let session = await h.session()
        #expect(await until { session.calls.contains("start") })

        h.controller.hotKeyReleased()
        await settle()
        #expect(session.count(of: "finish") == 0)

        session.emit(.preparing)
        #expect(await until { session.count(of: "finish") == 1 })
        #expect(session.finishPhases == [.preparing])
    }

    @Test func repeatedPressWhileHoldingIsIgnored() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startRecording()

        h.controller.hotKeyPressed()
        await settle()
        #expect(session.count(of: "finish") == 0)
        #expect(h.engines.sessions.count == 1)
        #expect(h.controller.view.stage == .recording)
    }

    // MARK: - Le comportement d'une dictée ne change pas en cours de route (m4)

    /// Commencée en bascule, la dictée se termine par un appui même si les réglages passent au maintien entre-temps.
    @Test func aToggleDictationStillEndsOnAPressAfterTheSettingChangesToHold() async {
        let h = DictationHarness()
        h.knobs.behavior = .toggle
        let session = await h.startRecording()

        h.knobs.behavior = .hold
        h.controller.hotKeyPressed()
        #expect(await until { session.count(of: "finish") == 1 })
        // Le relâchement qui suit n'est pas celui d'un maintien : ignoré.
        h.controller.hotKeyReleased()
        await settle()
        #expect(session.count(of: "finish") == 1)
    }

    /// Commencée en maintien, la dictée se termine au relâchement même si les réglages passent à la bascule entre-temps, et un
    /// appui n'y met pas fin.
    @Test func aHoldDictationStillEndsOnTheReleaseAfterTheSettingChangesToToggle() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startRecording()

        h.knobs.behavior = .toggle
        h.controller.hotKeyPressed()
        await settle()
        #expect(session.count(of: "finish") == 0)
        #expect(h.controller.view.stage == .recording)

        h.controller.hotKeyReleased()
        #expect(await until { session.count(of: "finish") == 1 })
    }

    /// Le comportement lu pour une NOUVELLE dictée est bien celui des réglages du moment.
    @Test func aNewDictationReadsTheCurrentBehavior() async {
        let h = DictationHarness()
        h.knobs.behavior = .toggle
        let first = await h.startRecording()
        h.controller.hotKeyPressed()
        #expect(await until { first.count(of: "finish") == 1 })
        first.emit(.finalizing)
        first.emit(.failed(.noSpeech))
        #expect(await until { !h.controller.isBusy })

        h.knobs.behavior = .hold
        h.controller.hotKeyPressed()
        let second = await h.driveToRecording(index: 1)
        h.controller.hotKeyReleased()
        #expect(await until { second.count(of: "finish") == 1 })
    }

    // MARK: - Maintien : relâchement perdu

    /// Les modificateurs lâchés avant la touche principale : le système peut ne jamais livrer le relâchement. La
    /// surveillance, interrogée à chaque « tic », y met fin.
    @Test func aLostReleaseIsCaughtWhenTheModifiersAreNoLongerHeld() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startRecording()
        #expect(await until { h.holdSleeper.isSleeping })

        // Tant que les modificateurs sont tenus, rien ne se passe, tic après tic.
        h.holdSleeper.release()
        #expect(await until { h.knobs.probes.count == 1 && h.holdSleeper.isSleeping })
        h.holdSleeper.release()
        #expect(await until { h.knobs.probes.count == 2 && h.holdSleeper.isSleeping })
        #expect(session.count(of: "finish") == 0)
        #expect(h.knobs.probes.allSatisfy { $0 == [.control, .option] })

        // Relâchés : le tic suivant termine la dictée.
        h.knobs.modifiersHeld = false
        h.holdSleeper.release()
        #expect(await until { session.count(of: "finish") == 1 })
        #expect(session.finishPhases == [.recording])
    }

    @Test func modifiersReleasedDuringPreparationEndTheDictationToo() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        h.controller.hotKeyPressed()
        let session = await h.session()
        session.emit(.preparing)
        #expect(await until { session.calls.contains("start") && h.holdSleeper.isSleeping })
        await settle()

        h.knobs.modifiersHeld = false
        h.holdSleeper.release()
        #expect(await until { session.count(of: "finish") == 1 })
        #expect(session.finishPhases == [.preparing])
    }

    @Test func aReleaseThatDoesComeAndTheWatchTogetherFinishOnlyOnce() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startRecording()
        #expect(await until { h.holdSleeper.isSleeping })

        h.controller.hotKeyReleased()
        h.knobs.modifiersHeld = false
        h.holdSleeper.release()
        await settle()
        #expect(session.count(of: "finish") == 1)
    }

    @Test func inToggleModeTheProbeIsNeverAsked() async {
        let h = DictationHarness()
        h.knobs.behavior = .toggle
        h.knobs.modifiersHeld = false
        let session = await h.startRecording()
        await settle()
        #expect(!h.holdSleeper.isSleeping)
        h.holdSleeper.release()
        await settle()
        #expect(h.knobs.probes.isEmpty)
        #expect(session.count(of: "finish") == 0)

        h.controller.hotKeyPressed()
        #expect(await until { session.count(of: "finish") == 1 })
        session.emit(.finalizing)
        session.emit(.finished("texte"))
        #expect(await until { h.pasted == ["texte"] })
        #expect(h.knobs.probes.isEmpty)
    }

    /// Un raccourci sans touche de modification (réglages illisibles, fichier écrit à la main) : la sonde ne peut rien dire,
    /// elle est inactive. Pas de coupure à 0,25 s : la dictée s'arrête au relâchement que le système livre.
    @Test func aHotKeyWithoutModifiersGetsNoWatchAndEndsOnTheSystemsRelease() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        h.knobs.hotKeyModifiers = []
        h.knobs.modifiersHeld = false
        let session = await h.startRecording()
        await settle()
        #expect(!h.holdSleeper.isSleeping)
        h.holdSleeper.release()
        await settle()
        #expect(h.knobs.probes.isEmpty)
        #expect(session.count(of: "finish") == 0)
        #expect(h.controller.view.stage == .recording)

        h.controller.hotKeyReleased()
        #expect(await until { session.count(of: "finish") == 1 })
    }

    // MARK: - Maintien : Échap (I2)

    /// En maintien, Échap tapé avec ⌃⌥ encore tenus part à l'application de dessous (le raccourci réservé est Échap seul) :
    /// la sonde du maintien lit donc aussi la touche, et l'annulation a le même effet que `escapePressed()`.
    @Test func escapeHeldDuringTheRecordingOfAHoldDictationCancelsAndPastesNothing() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startRecording()
        #expect(await until { h.holdSleeper.isSleeping })

        h.knobs.escapeHeld = true
        h.holdSleeper.release()
        #expect(await until { session.count(of: "cancel") == 1 })
        #expect(!h.panel.isOpen)
        #expect(h.controller.view == DictationViewState())
        #expect(session.count(of: "finish") == 0)
        // Un texte qui arrive encore de la session n'est ni inséré ni montré.
        session.emit(.finished("texte"))
        await settle()
        #expect(h.pasted.isEmpty)
        #expect(h.writtenTexts == 0)
    }

    @Test func escapeHeldDuringThePreparationOfAHoldDictationCancelsToo() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        h.controller.hotKeyPressed()
        let session = await h.session()
        session.emit(.preparing)
        #expect(await until { session.calls.contains("start") && h.holdSleeper.isSleeping })

        h.knobs.escapeHeld = true
        h.holdSleeper.release()
        #expect(await until { session.count(of: "cancel") == 1 })
        #expect(!h.panel.isOpen)
        session.emit(.finished("texte"))
        await settle()
        #expect(h.pasted.isEmpty)
        #expect(h.writtenTexts == 0)
    }

    /// Échap et modificateurs relâchés au même tic : Échap gagne (annuler, pas terminer et coller).
    @Test func escapeWinsOverReleasedModifiersInTheSameTick() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startRecording()
        #expect(await until { h.holdSleeper.isSleeping })

        h.knobs.escapeHeld = true
        h.knobs.modifiersHeld = false
        h.holdSleeper.release()
        #expect(await until { session.count(of: "cancel") == 1 })
        #expect(session.count(of: "finish") == 0)
    }

    @Test func escapeIsAskedAtEveryTickAndNothingHappensWhileItIsNotHeld() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startRecording()
        #expect(await until { h.holdSleeper.isSleeping })
        h.holdSleeper.release()
        #expect(await until { h.knobs.escapeProbes == 1 && h.holdSleeper.isSleeping })
        h.holdSleeper.release()
        #expect(await until { h.knobs.escapeProbes == 2 && h.holdSleeper.isSleeping })
        #expect(session.count(of: "cancel") == 0)
        #expect(h.panel.isOpen)
    }

    /// En bascule, Échap garde son chemin (le raccourci réservé) : la sonde n'est jamais interrogée.
    @Test func inToggleModeEscapeIsNeverProbed() async {
        let h = DictationHarness()
        h.knobs.behavior = .toggle
        h.knobs.escapeHeld = true
        let session = await h.startRecording()
        await settle()
        h.holdSleeper.release()
        await settle()
        #expect(h.knobs.escapeProbes == 0)
        #expect(session.count(of: "cancel") == 0)
        #expect(h.controller.view.stage == .recording)
    }

    /// Une fois la prise finie, la surveillance s'arrête : Échap tenu pendant la transcription ou le collage n'est plus lu ici
    /// (Échap seul, lui, est le raccourci réservé du panneau).
    @Test func escapeIsNotProbedOnceTheRecordingHasEnded() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startRecording()
        #expect(await until { h.holdSleeper.isSleeping })
        session.emit(.finalizing)
        #expect(await until { !h.holdSleeper.isSleeping })
        h.knobs.escapeHeld = true
        await settle()
        #expect(h.knobs.escapeProbes == 0)
        #expect(session.count(of: "cancel") == 0)
    }

    /// Un Échap franc dure quelques dixièmes de seconde au plus : l'état de la touche est lu plus d'une fois toutes les 0,1 s.
    @Test func theWatchSamplesTheKeyboardOftenEnoughToSeeAnEscapeTap() {
        #expect(HoldWatch.system.interval <= 0.1)
    }

    @Test func theWatchStopsWhenTheRecordingEnds() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startRecording()
        #expect(await until { h.holdSleeper.isSleeping })

        session.emit(.finalizing)
        // Plus de sommeil en cours : la tâche de surveillance est annulée et sortie, sans autre sondage.
        #expect(await until { !h.holdSleeper.isSleeping })
        h.knobs.modifiersHeld = false
        await settle()
        #expect(h.knobs.probes.isEmpty)
        #expect(session.count(of: "finish") == 0)
    }

    @Test func theWatchStopsWhenTheDictationFails() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startRecording()
        #expect(await until { h.holdSleeper.isSleeping })

        session.emit(.failed(.noSpeech))
        #expect(await until { !h.holdSleeper.isSleeping })
        await settle()
        #expect(h.knobs.probes.isEmpty)
    }

    @Test func theWatchStopsOnCancellation() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        _ = await h.startRecording()
        #expect(await until { h.holdSleeper.isSleeping })

        h.controller.escapePressed()
        #expect(await until { !h.holdSleeper.isSleeping })
        h.knobs.modifiersHeld = false
        await settle()
        #expect(h.knobs.probes.isEmpty)
    }

    @Test func theWatchStopsWhenThePanelIsClosedByAnotherPath() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        _ = await h.startRecording()
        #expect(await until { h.holdSleeper.isSleeping })

        h.panel.close()
        #expect(await until { !h.holdSleeper.isSleeping })
        #expect(h.knobs.probes.isEmpty)
    }

    // MARK: - Fin d'une dictée

    @Test func successInRawModePastesOnceAndClosesThePanel() async {
        let h = DictationHarness()
        let session = await h.startRecording()
        session.emit(.finalizing)
        session.emit(.finished("Bonjour à tous."))

        #expect(await until { !h.panel.isOpen })
        #expect(h.pasted == ["Bonjour à tous."])
        #expect(h.writtenTexts == 1)
        #expect(h.controller.view == DictationViewState(lastTranscript: "Bonjour à tous."))
        #expect(h.controller.lastTranscript == "Bonjour à tous.")
    }

    @Test func copiedKeepsThePanelOpenAndShowsTheReason() async {
        let h = DictationHarness(trusted: false)
        let session = await h.startRecording()
        session.emit(.finished("Texte dicté."))

        #expect(await until { h.controller.view.stage == .copied })
        #expect(h.panel.isOpen)
        let notice = h.controller.view.notice ?? ""
        #expect(notice.contains("Accessibilité"))
        #expect(!notice.contains("Texte dicté"))
        #expect(h.pasted.isEmpty)
        // Le texte est resté dans le presse-papiers double, et dans la mémoire du contrôleur.
        #expect(h.rig.board.text == "Texte dicté.")
        #expect(h.controller.lastTranscript == "Texte dicté.")
    }

    /// m3 : le presse-papiers refuse le texte. Rien n'est collé, le contenu d'origine est rendu, le panneau reste ouvert et ne dit
    /// pas « Texte copié » : il dit que le presse-papiers a refusé, et le texte reste dans « Dernière dictée ».
    @Test func aPasteboardThatRefusesTheTextFailsTheDictationWithoutPretendingItWasCopied() async {
        let h = DictationHarness()
        h.rig.board.refusesTextWrites = true
        let session = await h.startRecording()
        session.emit(.finished("Texte dicté."))

        #expect(await until { h.controller.view.stage == .failed(.clipboard) })
        #expect(h.panel.isOpen)
        #expect(h.controller.view.notice == DictationFailure.clipboard.message)
        #expect(DictationText.status(for: h.controller.view.stage) == "Texte non copié")
        #expect(h.pasted.isEmpty)
        #expect(h.rig.board.contents == FakeInsertion.original)
        // Récupérable par « Dernière dictée ».
        #expect(h.controller.lastTranscript == "Texte dicté.")
        #expect(!h.controller.isBusy)
    }

    @Test(arguments: [
        DictationFailure.noSpeech, .microphone("accès refusé"), .engine("moteur indisponible"),
    ])
    func failureKeepsThePanelOpenWithTheMessageAndPastesNothing(_ failure: DictationFailure) async {
        let h = DictationHarness()
        let session = await h.startRecording()
        session.emit(.finalizing)
        session.emit(.failed(failure))

        #expect(await until { h.controller.view.stage == .failed(failure) })
        #expect(h.panel.isOpen)
        #expect(h.controller.view.notice == failure.message)
        #expect(h.pasted.isEmpty)
        #expect(h.writtenTexts == 0)
        #expect(h.controller.lastTranscript == nil)

        // Un nouvel appui relance une dictée.
        h.controller.hotKeyPressed()
        #expect(h.controller.view.stage == .preparing)
        #expect(h.controller.view.notice == nil)
        let second = await h.session(1)
        #expect(await until { second.calls.contains("start") })
    }

    @Test func aLaterFailureNeverErasesTheLastTranscript() async {
        let h = DictationHarness()
        let first = await h.startRecording()
        first.emit(.finished("Premier texte."))
        #expect(await until { !h.panel.isOpen })
        #expect(h.controller.lastTranscript == "Premier texte.")

        let second = await h.startRecording(index: 1)
        second.emit(.failed(.noSpeech))
        #expect(await until { h.controller.view.stage == .failed(.noSpeech) })
        #expect(h.controller.lastTranscript == "Premier texte.")
    }

    /// Une session qui s'annule seule (rien ne le demandait) : le panneau le dit au lieu de rester vide sur « Prêt ».
    @Test func aSessionThatCancelsItselfIsSaidAndTheNextPressStartsAgain() async {
        let h = DictationHarness()
        let session = await h.startRecording()
        session.emit(.cancelled)

        #expect(await until { h.controller.view.stage == .cancelled })
        #expect(h.panel.isOpen)
        #expect(h.controller.view.notice == "La dictée a été interrompue.")
        #expect(!h.controller.isBusy)
        #expect(h.pasted.isEmpty)

        h.controller.hotKeyPressed()
        #expect(h.controller.view.stage == .preparing)
        _ = await h.session(1)
    }

    @Test func aBlankResultIsAFailureAndNeverCrashes() async {
        let h = DictationHarness()
        let session = await h.startRecording()
        session.emit(.finished("   "))

        #expect(await until { h.controller.view.stage == .failed(.noSpeech) })
        #expect(h.panel.isOpen)
        #expect(h.pasted.isEmpty)
        // Un texte d'espaces n'est pas une dictée réussie : rien à récupérer.
        #expect(h.controller.lastTranscript == nil)
    }

    // MARK: - Échap et fermeture du panneau

    @Test(arguments: [DictationPhase.preparing, .recording, .finalizing])
    func escapeCancelsPastesNothingAndClosesThePanel(_ phase: DictationPhase) async {
        let h = DictationHarness()
        let session = await drive(h, to: phase)

        h.controller.escapePressed()
        #expect(!h.panel.isOpen)
        #expect(h.controller.view == DictationViewState())
        #expect(await until { session.count(of: "cancel") == 1 })

        // Un moteur qui ignore l'annulation rend son texte : il n'est ni collé ni copié.
        session.emit(.finished("tardif"))
        await settle()
        #expect(h.pasted.isEmpty)
        #expect(h.writtenTexts == 0)
        #expect(h.controller.view == DictationViewState())
        #expect(h.controller.lastTranscript == nil)
    }

    /// Une dictée neuve menée jusqu'à `phase`.
    private func drive(_ h: DictationHarness, to phase: DictationPhase) async -> FakeSession {
        switch phase {
        case .preparing:
            h.controller.hotKeyPressed()
            let session = await h.session()
            session.emit(.preparing)
            #expect(await until { session.calls.contains("start") })
            return session
        case .finalizing:
            let session = await h.startRecording()
            session.emit(.finalizing)
            #expect(await until { h.controller.view.stage == .finalizing })
            return session
        default:
            return await h.startRecording()
        }
    }

    /// Échap annule par lui-même : il ne compte pas sur le panneau pour prévenir de sa fermeture.
    @Test func escapeCancelsEvenWhenThePanelDoesNotReportItsClosing() async {
        let h = DictationHarness()
        h.panel.onClosed = nil
        let session = await h.startRecording()

        h.controller.escapePressed()
        #expect(await until { session.count(of: "cancel") == 1 })
        session.emit(.finished("tardif"))
        await settle()
        #expect(h.pasted.isEmpty)
        #expect(h.controller.view == DictationViewState())
    }

    @Test func escapeBeforeTheSessionExistsNeverStartsIt() async {
        let h = DictationHarness()
        let gate = TestGate()
        defer { gate.open() }
        h.engines.configure { $0.makeGate = gate }
        h.controller.hotKeyPressed()
        #expect(h.panel.isOpen)
        // La fabrication est en route (suspendue) quand Échap arrive.
        #expect(await until { !h.engines.settingsSeen.isEmpty })

        h.controller.escapePressed()
        #expect(!h.panel.isOpen)
        gate.open()
        let session = await h.session()
        await settle()
        // Une session fabriquée trop tard n'est jamais démarrée : aucun micro ne s'ouvre, panneau fermé.
        #expect(session.count(of: "start") == 0)
        // Et l'annulation est arrivée jusqu'à la fabrication, pour qu'un moteur qui la respecte s'arrête.
        #expect(h.engines.cancelledDuringMake)
        #expect(h.controller.view == DictationViewState())
    }

    @Test func escapeOutsideADictationJustClosesThePanel() async {
        let h = DictationHarness()
        let session = await h.startRecording()
        session.emit(.failed(.noSpeech))
        #expect(await until { h.controller.view.stage == .failed(.noSpeech) })

        h.controller.escapePressed()
        #expect(!h.panel.isOpen)
        #expect(h.controller.view == DictationViewState())
        await settle()
        #expect(session.count(of: "cancel") == 0)
    }

    @Test func closingThePanelFromTheMenuDuringADictationCancelsIt() async {
        let h = DictationHarness()
        let session = await h.startRecording()

        // Le menu, « Réglages… » ou Quitter ferment le panneau lui-même ; il prévient le contrôleur.
        h.panel.close()
        #expect(await until { session.count(of: "cancel") == 1 })
        #expect(h.controller.view == DictationViewState())
        session.emit(.finished("tardif"))
        await settle()
        #expect(h.pasted.isEmpty)
    }

    /// Échap pendant l'attente du relâchement des modificateurs (avant ⌘V) : l'annulation arrive jusqu'au `TextInserter`, qui ne
    /// colle rien et rend le presse-papiers de l'utilisateur.
    @Test func escapeBeforeTheShortcutIsPostedPastesNothingAndGivesTheClipboardBack() async {
        let log = CallLog()
        let sleeper = SleepingWait(log: log)
        let h = DictationHarness(wait: { await sleeper.wait($0) }, log: log, heldModifiers: [true])
        let session = await h.startRecording()
        session.emit(.finished("texte"))
        #expect(await until { sleeper.isSleeping })
        #expect(h.rig.board.text == "texte")

        h.controller.escapePressed()
        #expect(await until { h.rig.board.contents == FakeInsertion.original })
        #expect(h.pasted.isEmpty)
        #expect(!log.entries.contains { $0.hasPrefix("postPaste") })
        #expect(h.controller.view == DictationViewState(lastTranscript: "texte"))
        #expect(!h.panel.isOpen)
    }

    // MARK: - Résultat tardif

    /// Un moteur peut ignorer l'annulation : `finish()` ne rend jamais la main, puis le texte arrive quand même. Le
    /// contrôleur n'attend rien de lui.
    @Test func aResultArrivingAfterACancelIsNeverPastedNorShown() async {
        let h = DictationHarness()
        let stuck = TestGate()
        defer { stuck.open() }
        h.engines.configure { $0.queue = [FakeSession(finishGate: stuck)] }
        let session = await h.startRecording()
        h.controller.hotKeyPressed()
        #expect(await until { session.count(of: "finish") == 1 })
        session.emit(.finalizing)

        h.controller.escapePressed()
        #expect(!h.panel.isOpen)
        #expect(h.controller.view == DictationViewState())

        session.emit(.finished("texte rendu trop tard"))
        await settle()
        #expect(h.pasted.isEmpty)
        #expect(h.writtenTexts == 0)
        #expect(h.controller.view == DictationViewState())
        #expect(h.controller.lastTranscript == nil)
        stuck.open()
    }

    @Test func aResultFromACancelledDictationNeverTouchesTheNewOne() async {
        let h = DictationHarness()
        let old = await h.startRecording()
        h.controller.escapePressed()

        let new = await h.startRecording(index: 1)
        old.emit(.finished("ancienne dictée"))
        old.emit(.failed(.engine("ancien échec")))
        await settle()
        #expect(h.pasted.isEmpty)
        #expect(h.controller.view.stage == .recording)
        #expect(h.controller.view.notice == nil)
        #expect(h.panel.isOpen)

        new.emit(.finished("nouvelle dictée"))
        #expect(await until { h.pasted == ["nouvelle dictée"] })
        #expect(h.controller.lastTranscript == "nouvelle dictée")
    }

    // MARK: - Un seul collage à la fois

    /// L'ancienne dictée est annulée pendant son collage (⌘V posté, restauration du presse-papiers en attente) ; la nouvelle
    /// finit aussitôt. Son collage attend la fin du premier : le journal montre `restauration` avant la seconde lecture.
    @Test func twoInsertionsNeverOverlap() async {
        let log = CallLog()
        let sleeper = SleepingWait(log: log)
        let h = DictationHarness(wait: { await sleeper.wait($0) }, log: log)
        let first = await h.startRecording()
        first.emit(.finished("premier"))
        #expect(await until { sleeper.isSleeping })
        #expect(h.pasted == ["premier"])

        h.controller.escapePressed()
        let second = await h.startRecording(index: 1)
        second.emit(.finished("second"))
        await settle()
        // Tant que la restauration du premier n'a pas eu lieu, le second ne touche pas au presse-papiers.
        #expect(h.pasted == ["premier"])
        #expect(log.entries.filter { $0 == "read" }.count == 1)

        // La restauration du premier a lieu, puis seulement le second colle.
        sleeper.release()
        #expect(await until { h.pasted == ["premier", "second"] })
        #expect(await until { sleeper.isSleeping })
        sleeper.release()
        #expect(await until { log.entries.filter { $0 == "write" }.count == 2 })
        let entries = log.entries
        let firstRestore = entries.firstIndex(of: "write")
        let secondRead = entries.lastIndex(of: "read")
        #expect(firstRestore != nil && secondRead != nil && firstRestore! < secondRead!)
        #expect(entries.filter { $0.hasPrefix("writeText") }.count == 2)
    }

    /// Le collage d'une dictée annulée qui se termine pendant qu'une nouvelle écoute ne ferme pas le panneau.
    @Test func aStaleInsertionFinishingNeverClosesThePanelOfTheNewDictation() async {
        let log = CallLog()
        let sleeper = SleepingWait(log: log)
        let h = DictationHarness(wait: { await sleeper.wait($0) }, log: log)
        let first = await h.startRecording()
        first.emit(.finished("premier"))
        #expect(await until { sleeper.isSleeping })
        h.controller.escapePressed()
        let second = await h.startRecording(index: 1)

        sleeper.release()
        await settle()
        #expect(h.panel.isOpen)
        #expect(second.count(of: "cancel") == 0)
        #expect(h.controller.view.stage == .recording)
    }

    // MARK: - Mode, micro, modèle

    /// Sans entretien branché (`interview: nil`, cas de ce banc seulement), le mode Entretien le dit, sans micro.
    @Test func theInterviewModeWithoutAnInterviewOpensThePanelWithoutADictationAndSaysSo() async {
        let h = DictationHarness()
        h.knobs.modeID = ModeChip.interviewID
        h.controller.hotKeyPressed()

        #expect(h.panel.isOpen)
        #expect(h.controller.view == DictationViewState(notice: "L'entretien n'a pas pu démarrer\u{00A0}: relancez Supervox."))
        await settle()
        #expect(h.engines.sessions.isEmpty)

        // Un second appui referme le panneau, comme avant la dictée.
        h.controller.hotKeyPressed()
        #expect(!h.panel.isOpen)
        #expect(h.controller.view == DictationViewState())
    }

    @Test func withoutMicrophonePermissionNoSessionAndThePanelOpens() async {
        let h = DictationHarness()
        h.knobs.microphoneAllowed = false
        h.controller.hotKeyPressed()

        #expect(h.panel.isOpen)
        #expect(h.controller.view == DictationViewState())
        await settle()
        #expect(h.engines.sessions.isEmpty)

        // Relue à chaque appui : une fois accordée, l'appui suivant dicte.
        h.knobs.microphoneAllowed = true
        h.controller.hotKeyPressed()
        #expect(h.controller.view.stage == .preparing)
        _ = await h.session()
    }

    /// I4 (b) : « Téléchargement du modèle… » n'est montré que pendant le téléchargement ; ensuite, tant que les moteurs se
    /// chargent en mémoire, c'est « Chargement du modèle… » ; à l'enregistrement, plus aucune mention.
    @Test func theDownloadMentionIsShownOnlyDuringTheDownloadThenTheLoadingMentionUntilRecording() async {
        let h = DictationHarness()
        let download = TestGate()
        let make = TestGate()
        defer {
            download.open()
            make.open()
        }
        h.engines.configure {
            $0.modelMissing = true
            $0.enginesLoaded = false
            $0.downloadGate = download
            $0.makeGate = make
        }
        h.controller.hotKeyPressed()
        #expect(await until { h.controller.view.notice == DictationController.downloadNotice })
        #expect(h.controller.view.stage == .preparing)

        download.open()
        #expect(await until { h.controller.view.notice == DictationController.loadingNotice })
        #expect(h.controller.view.stage == .preparing)

        // La session se fabrique, puis prépare : la mention de chargement reste, celle de téléchargement ne revient pas.
        make.open()
        let session = await h.session()
        session.emit(.preparing)
        #expect(await until { session.calls.contains("start") })
        await settle()
        #expect(h.controller.view.notice == DictationController.loadingNotice)

        session.emit(.recording)
        #expect(await until { h.controller.view.stage == .recording })
        #expect(h.controller.view.notice == nil)
        // Aucun état montré n'a porté les deux mentions à la fois.
        #expect(h.views.allSatisfy { ($0.notice ?? "").contains("Téléchargement") == false || ($0.notice ?? "").contains("Chargement") == false })
    }

    /// Des moteurs déjà chargés (préchargement au lancement, ou dictée précédente) : la préparation est instantanée, aucune mention
    /// de chargement ne s'affiche, même brièvement.
    @Test func loadedEnginesShowNoLoadingMentionAtAll() async {
        let h = DictationHarness()
        h.engines.configure { $0.enginesLoaded = true }
        let session = await h.startRecording()
        #expect(session.calls.contains("start"))
        #expect(h.views.allSatisfy { !($0.notice ?? "").contains("Chargement") })
        #expect(h.controller.view.notice == nil)
    }

    /// Rien à télécharger, moteurs froids : seule la mention de chargement, jamais celle de téléchargement.
    @Test func coldEnginesWithNothingToDownloadShowOnlyTheLoadingMention() async {
        let h = DictationHarness()
        let make = TestGate()
        defer { make.open() }
        h.engines.configure {
            $0.enginesLoaded = false
            $0.makeGate = make
        }
        h.controller.hotKeyPressed()
        #expect(await until { h.controller.view.notice == DictationController.loadingNotice })
        make.open()
        _ = await h.session()
        #expect(h.views.allSatisfy { !($0.notice ?? "").contains("Téléchargement") })
    }

    /// Un téléchargement fait, des moteurs que l'on dit chargés : plus aucune mention.
    @Test func afterTheDownloadNoMentionRemainsWhenTheEnginesAreLoaded() async {
        let h = DictationHarness()
        let make = TestGate()
        defer { make.open() }
        h.engines.configure {
            $0.modelMissing = true
            $0.enginesLoaded = true
            $0.makeGate = make
        }
        h.controller.hotKeyPressed()
        #expect(await until { h.engines.events.contains("make") })
        await settle()
        #expect(h.controller.view.notice == nil)
    }

    /// La mention de chargement ne remplace pas l'avis sur le vocabulaire : les deux se lisent.
    @Test func theLoadingMentionAndTheVocabularyNoticeAreShownTogether() async {
        let h = DictationHarness()
        h.engines.configure {
            $0.enginesLoaded = false
            $0.tokenCount = { _, _ in nil }
        }
        h.knobs.settings = TranscriptionSettings(
            engine: .whisperKit, whisperModel: "base", language: "fr", vocabulary: ["a", "b"])
        h.controller.hotKeyPressed()
        _ = await h.session()
        let notice = h.controller.view.notice ?? ""
        #expect(notice.contains(DictationController.loadingNotice))
        #expect(notice.contains("vocabulaire n'a pas servi"))
    }

    /// I5 : un modèle qui manque se télécharge par le catalogue, avant que la session soit fabriquée.
    @Test func aMissingModelIsDownloadedThroughTheCatalogueBeforeTheSessionIsBuilt() async {
        let h = DictationHarness()
        h.engines.configure { $0.modelMissing = true }
        h.knobs.settings = TranscriptionSettings(
            engine: .parakeet, whisperModel: "base", language: "fr", vocabulary: ["terme"])
        h.controller.hotKeyPressed()
        _ = await h.session()

        #expect(h.engines.events == ["download", "make"])
        #expect(h.engines.downloadedFor == [h.knobs.settings])
    }

    /// N1 : le petit modèle de vocabulaire ne s'est pas téléchargé alors que le reste est là : la dictée a lieu quand même,
    /// sans vocabulaire, avec une notice en mots simples.
    @Test(arguments: TranscriptionEngine.allCases)
    func aVocabularyModelThatCouldNotBeDownloadedLeavesTheVocabularyOutAndTheDictationGoesOn(engine: TranscriptionEngine) async {
        let h = DictationHarness()
        h.engines.configure {
            $0.modelMissing = true
            $0.downloadOutcome = ModelDownloadOutcome(vocabularyModelUnavailable: true)
        }
        h.knobs.settings = TranscriptionSettings(
            engine: engine, whisperModel: "base", language: "fr", vocabulary: ["a", "b"])
        h.controller.hotKeyPressed()
        let session = await h.session()

        #expect(h.engines.settingsSeen.map(\.vocabulary) == [[]])
        #expect(await until { session.calls.contains("start") })
        let notice = h.controller.view.notice ?? ""
        #expect(notice.contains("vocabulaire n'a pas servi"))
        #expect(notice.contains("petit modèle"))
        #expect(h.controller.view.stage == .preparing)
        // Le comptage n'a plus d'objet : la liste ne part pas.
        #expect(!h.engines.events.contains("count"))

        session.emit(.recording)
        #expect(await until { h.controller.view.stage == .recording })
        #expect(h.controller.view.notice?.contains("vocabulaire n'a pas servi") == true)
    }

    @Test func aCompleteDownloadLeavesTheVocabularyAlone() async {
        let h = DictationHarness()
        h.engines.configure { $0.modelMissing = true }
        h.knobs.settings = TranscriptionSettings(
            engine: .parakeet, whisperModel: "base", language: "fr", vocabulary: ["a", "b"])
        h.controller.hotKeyPressed()
        _ = await h.session()
        #expect(h.engines.settingsSeen.map(\.vocabulary) == [["a", "b"]])
    }

    @Test func nothingIsDownloadedWhenNothingIsMissing() async {
        let h = DictationHarness()
        h.controller.hotKeyPressed()
        _ = await h.session()
        #expect(h.engines.events == ["make"])
    }

    @Test func theVocabularyIsCountedAfterTheDownloadBecauseItBringsTheTokenizer() async {
        let h = DictationHarness()
        h.engines.configure { $0.modelMissing = true }
        h.knobs.settings = TranscriptionSettings(
            engine: .whisperKit, whisperModel: "base", language: "fr", vocabulary: ["a", "b"])
        h.controller.hotKeyPressed()
        _ = await h.session()
        #expect(h.engines.events == ["download", "count", "make"])
    }

    /// I1 / M4 : quand le moteur ne se charge pas pendant la préparation alors que le modèle est indiqué « Prêt », le panneau
    /// renvoie à l'onglet Transcription (supprimer puis télécharger de nouveau, ce qui demande une connexion : le conseil ne
    /// laisse pas croire qu'on peut le faire hors ligne) et ne montre jamais la raison brute de l'échec. Parcours réel : la session
    /// échoue pendant `preparing`.
    @Test func aPreparationFailureSendsTheUserToDeleteThenDownloadAgainAndSaysItNeedsAConnection() async {
        let h = DictationHarness()
        h.controller.hotKeyPressed()
        let session = await h.session()
        session.emit(.preparing)
        session.emit(.failed(.engine("raison brute https://exemple.invalid/clé")))

        #expect(await until { h.controller.view.stage.isTerminal })
        #expect(h.panel.isOpen)
        let notice = h.controller.view.notice ?? ""
        #expect(notice == DictationController.preparationFailedNotice)
        #expect(notice.contains("onglet Transcription"))
        #expect(notice.contains("« Prêt »"))
        #expect(notice.contains("supprimer"))
        #expect(notice.contains("de nouveau"))
        #expect(notice.contains("connexion à Internet"))
        #expect(!notice.contains("exemple.invalid"))
    }

    @Test func aDownloadThatFailsFailsThePreparationWithTheFixedPhraseAndBuildsNoSession() async {
        let h = DictationHarness()
        h.engines.configure {
            $0.modelMissing = true
            $0.downloadError = LeakyError()
        }
        h.controller.hotKeyPressed()

        #expect(await until { h.controller.view.stage.isTerminal })
        #expect(h.panel.isOpen)
        let notice = h.controller.view.notice ?? ""
        #expect(notice == DictationController.preparationFailedNotice)
        #expect(notice.contains("Transcription"))
        #expect(!notice.contains("exemple.invalid"))
        #expect(!notice.contains("sk-123"))
        await settle()
        #expect(h.engines.sessions.isEmpty)
        #expect(!h.engines.events.contains("make"))
        // Un nouvel appui retente.
        h.engines.configure { $0.downloadError = nil }
        h.controller.hotKeyPressed()
        _ = await h.session()
    }

    @Test func escapeDuringTheDownloadNeverBuildsTheSession() async {
        let h = DictationHarness()
        let gate = TestGate()
        defer { gate.open() }
        h.engines.configure {
            $0.modelMissing = true
            $0.downloadGate = gate
        }
        h.controller.hotKeyPressed()
        #expect(await until { h.engines.events == ["download"] })

        h.controller.escapePressed()
        gate.open()
        await settle()
        #expect(h.engines.events == ["download"])
        #expect(h.engines.sessions.isEmpty)
        #expect(h.controller.view == DictationViewState())
    }

    @Test func theControllerSaysWhenADictationIsInProgress() async {
        let h = DictationHarness()
        #expect(!h.controller.isBusy)
        let session = await h.startRecording()
        #expect(h.controller.isBusy)
        session.emit(.finalizing)
        #expect(h.controller.isBusy)
        session.emit(.finished("texte"))
        #expect(await until { !h.controller.isBusy })

        h.controller.hotKeyPressed()
        #expect(h.controller.isBusy)
        h.controller.escapePressed()
        #expect(!h.controller.isBusy)

        let failing = await h.startRecording(index: 1)
        failing.emit(.failed(.noSpeech))
        #expect(await until { !h.controller.isBusy })
    }

    @Test func aReadyModelShowsNoDownloadMention() async {
        let h = DictationHarness()
        let session = await h.startRecording()
        _ = session
        #expect(h.views.allSatisfy { $0.notice == nil })
    }

    @Test func aPreparationFailureSendsBackToTheTranscriptionTabWithoutTheEnginesWords() async {
        let h = DictationHarness()
        h.controller.hotKeyPressed()
        let session = await h.session()
        session.emit(.preparing)
        session.emit(.failed(.engine("échec de https://exemple.invalid/modele avec la clé sk-123")))

        #expect(await until { h.controller.view.stage.isTerminal })
        #expect(h.panel.isOpen)
        let notice = h.controller.view.notice ?? ""
        #expect(notice.contains("Transcription"))
        #expect(!notice.contains("exemple.invalid"))
        #expect(!notice.contains("sk-123"))
    }

    @Test func aMicrophoneFailureDuringPreparationDoesNotBlameTheModel() async {
        let h = DictationHarness()
        h.controller.hotKeyPressed()
        let session = await h.session()
        session.emit(.preparing)
        session.emit(.failed(.microphone("aucun micro utilisable n'a été trouvé")))

        #expect(await until { h.controller.view.stage.isTerminal })
        let notice = h.controller.view.notice ?? ""
        #expect(notice == DictationFailure.microphone("aucun micro utilisable n'a été trouvé").message)
        #expect(!notice.contains("Transcription"))
    }

    private struct LeakyError: LocalizedError {
        var errorDescription: String? { "échec vers https://exemple.invalid/v1 avec la clé sk-123" }
    }

    @Test func aSessionThatCannotBeBuiltSaysSoWithoutTheErrorText() async {
        let h = DictationHarness()
        h.engines.configure { $0.makeError = LeakyError() }
        h.controller.hotKeyPressed()

        #expect(await until { h.controller.view.stage.isTerminal })
        #expect(h.panel.isOpen)
        let notice = h.controller.view.notice ?? ""
        #expect(notice.contains("Transcription"))
        #expect(!notice.contains("exemple.invalid"))
        #expect(!notice.contains("sk-123"))
        #expect(h.engines.sessions.isEmpty)
    }

    // MARK: - Réglages relus à chaque dictée

    @Test func settingsAreReadAgainAtEveryDictation() async {
        let h = DictationHarness()
        let first = TranscriptionSettings(
            engine: .whisperKit, whisperModel: "base", language: "fr", vocabulary: ["alpha"])
        h.knobs.settings = first
        let one = await h.startRecording()
        one.emit(.failed(.noSpeech))
        #expect(await until { h.controller.view.stage.isTerminal })

        let second = TranscriptionSettings(
            engine: .parakeet, whisperModel: "small", language: "en", vocabulary: ["beta", "gamma"])
        h.knobs.settings = second
        h.controller.hotKeyPressed()
        _ = await h.session(1)
        #expect(h.engines.settingsSeen == [first, second])
    }

    // MARK: - Vocabulaire trop long

    @Test func aTooLongVocabularyIsCutToTheFirstTermsThatFitAndTheDictationGoesOn() async {
        let h = DictationHarness(limit: 25)
        h.engines.configure {
            $0.tokenCount = { terms, _ in terms.count * 10 }
        }
        h.knobs.settings = TranscriptionSettings(
            engine: .whisperKit, whisperModel: "base", language: "fr", vocabulary: ["a", "b", "c", "d", "e"])
        h.controller.hotKeyPressed()
        let session = await h.session()

        #expect(h.engines.settingsSeen.map(\.vocabulary) == [["a", "b"]])
        #expect(await until { session.calls.contains("start") })
        let notice = h.controller.view.notice ?? ""
        #expect(notice.contains("2 premiers termes sur 5"))
        #expect(notice.contains("Transcription"))
        // La dictée va au bout, avec l'avis toujours là.
        session.emit(.recording)
        #expect(await until { h.controller.view.stage == .recording })
        #expect(h.controller.view.notice?.contains("2 premiers termes sur 5") == true)
    }

    @Test func aVocabularyThatFitsIsLeftAloneWithoutAnyNotice() async {
        let h = DictationHarness(limit: 25)
        h.engines.configure {
            $0.tokenCount = { terms, _ in terms.count * 10 }
        }
        h.knobs.settings = TranscriptionSettings(
            engine: .whisperKit, whisperModel: "base", language: "fr", vocabulary: ["a", "b"])
        h.controller.hotKeyPressed()
        _ = await h.session()
        #expect(h.engines.settingsSeen.map(\.vocabulary) == [["a", "b"]])
        #expect(h.controller.view.notice == nil)
    }

    @Test func parakeetHasNoVocabularyLimit() async {
        let h = DictationHarness(limit: 5)
        h.engines.configure {
            $0.tokenCount = { terms, _ in terms.count * 10 }
        }
        h.knobs.settings = TranscriptionSettings(
            engine: .parakeet, whisperModel: "base", language: "fr", vocabulary: ["a", "b", "c"])
        h.controller.hotKeyPressed()
        _ = await h.session()
        #expect(h.engines.settingsSeen.map(\.vocabulary) == [["a", "b", "c"]])
        #expect(h.engines.countCalls == 0)
        #expect(h.controller.view.notice == nil)
    }

    @Test func aFirstTermAloneTooLongLeavesNoVocabularyAndSaysSo() async {
        let h = DictationHarness(limit: 5)
        h.engines.configure {
            $0.tokenCount = { terms, _ in terms.count * 10 }
        }
        h.knobs.settings = TranscriptionSettings(
            engine: .whisperKit, whisperModel: "base", language: "fr", vocabulary: ["a", "b"])
        h.controller.hotKeyPressed()
        _ = await h.session()
        #expect(h.engines.settingsSeen.map(\.vocabulary) == [[]])
        #expect(h.controller.view.notice?.contains("aucun terme") == true)
    }

    /// Longueur impossible à compter (tokenizer absent) et modèle à télécharger : la liste ne part pas, la dictée n'est pas
    /// bloquée par un refus du moteur après coup, et l'avis le dit.
    @Test func anUncountableVocabularyWithAModelToDownloadIsLeftOutOfThisDictation() async {
        let h = DictationHarness()
        h.engines.configure {
            $0.modelMissing = true
            $0.tokenCount = { _, _ in nil }
        }
        h.knobs.settings = TranscriptionSettings(
            engine: .whisperKit, whisperModel: "base", language: "fr", vocabulary: ["a", "b"])
        h.controller.hotKeyPressed()
        _ = await h.session()
        #expect(h.engines.settingsSeen.map(\.vocabulary) == [[]])
        let notice = h.controller.view.notice ?? ""
        // Le téléchargement est fini : sa mention ne reste pas pendant la préparation.
        #expect(!notice.contains("Téléchargement"))
        #expect(notice.contains("vocabulaire n'a pas servi"))
    }

    /// Décision 6 : la dictée n'échoue jamais à cause du vocabulaire. Longueur incomptable avec le modèle prêt (tokenizer
    /// introuvable, nom de variante dont il ne se déduit pas) : la liste ne part pas, et la notice le dit, en mots simples.
    @Test func anUncountableVocabularyWithTheModelOnDiskIsLeftOutAndSaysSo() async {
        let h = DictationHarness()
        h.engines.configure { $0.tokenCount = { _, _ in nil } }
        h.knobs.settings = TranscriptionSettings(
            engine: .whisperKit, whisperModel: "base", language: "fr", vocabulary: ["a", "b"])
        h.controller.hotKeyPressed()
        _ = await h.session()
        #expect(h.engines.settingsSeen.map(\.vocabulary) == [[]])
        let notice = h.controller.view.notice ?? ""
        #expect(notice.contains("vocabulaire n'a pas servi"))
        #expect(!notice.contains("Téléchargement"))
        #expect(!notice.contains("jeton"))
    }

    // MARK: - État montré

    @Test func theViewMirrorsTheSessionAndKeepsTheLast48Levels() async {
        let h = DictationHarness()
        let session = await h.startRecording()
        for index in 1...60 {
            session.emit(.recording, liveText: "texte \(index)", level: Float(index) / 100, elapsed: Double(index) / 10)
        }
        #expect(await until { h.controller.view.liveText == "texte 60" })
        let view = h.controller.view
        #expect(view.elapsed == 6.0)
        #expect(view.levels.count == DictationViewState.levelCount)
        #expect(view.levels.last == 0.6)
        #expect(view.levels.first == 0.13)
    }

    @Test func everyChangeOfTheViewIsAnnounced() async {
        let h = DictationHarness()
        _ = await h.startRecording()
        #expect(h.views.last == h.controller.view)
        #expect(h.views.first?.stage == .preparing)
    }

    // MARK: - Un seul dernier texte

    /// Ce qui arrive après une première dictée réussie, sans jamais effacer son texte.
    enum LaterEvent: CaseIterable, Sendable { case failure, sessionCancelled, escape, panelClosed, newDictation }

    @Test(arguments: LaterEvent.allCases)
    func theViewKeepsCarryingTheControllersLastTranscript(_ event: LaterEvent) async {
        let h = DictationHarness()
        let first = await h.startRecording()
        first.emit(.finished("Premier texte."))
        #expect(await until { !h.panel.isOpen })
        #expect(h.controller.view == DictationViewState(lastTranscript: "Premier texte."))

        switch event {
        case .failure:
            let second = await h.startRecording(index: 1)
            second.emit(.failed(.noSpeech))
            #expect(await until { h.controller.view.stage == .failed(.noSpeech) })
        case .sessionCancelled:
            let second = await h.startRecording(index: 1)
            second.emit(.cancelled)
            #expect(await until { h.controller.view.stage == .cancelled })
        case .escape:
            _ = await h.startRecording(index: 1)
            h.controller.escapePressed()
        case .panelClosed:
            _ = await h.startRecording(index: 1)
            h.panel.close()
        case .newDictation:
            h.controller.hotKeyPressed()
            #expect(h.controller.view.stage == .preparing)
        }
        #expect(h.controller.lastTranscript == "Premier texte.")
        #expect(h.controller.view.lastTranscript == h.controller.lastTranscript)
    }

    @Test func aPastedTextIsInTheViewOnceThePanelHasClosed() async {
        let h = DictationHarness()
        let session = await h.startRecording()
        session.emit(.finished("Bonjour à tous."))
        #expect(await until { !h.panel.isOpen })
        #expect(h.controller.view == DictationViewState(lastTranscript: "Bonjour à tous."))
        #expect(h.controller.view.lastTranscript == h.controller.lastTranscript)
    }

    /// Le repli sur la copie : l'écran dit « copié », avec la raison, et porte le texte.
    @Test func aCopiedTextIsAScreenStageThatCarriesTheReasonAndTheText() async {
        let h = DictationHarness(trusted: false)
        let session = await h.startRecording()
        session.emit(.finished("Texte dicté."))

        #expect(await until { h.controller.view.stage == .copied })
        let view = h.controller.view
        #expect(view.notice?.contains("Accessibilité") == true)
        #expect(view.lastTranscript == "Texte dicté.")
        #expect(view.lastTranscript == h.controller.lastTranscript)
        #expect(DictationText.status(for: view.stage) == "Texte copié")
        #expect(h.panel.isOpen)
    }

    @Test func aRefusedPasteboardLeavesTheTextInTheView() async {
        let h = DictationHarness()
        h.rig.board.refusesTextWrites = true
        let session = await h.startRecording()
        session.emit(.finished("Texte dicté."))

        #expect(await until { h.controller.view.stage == .failed(.clipboard) })
        #expect(h.controller.view.lastTranscript == "Texte dicté.")
        #expect(h.controller.view.lastTranscript == h.controller.lastTranscript)
    }

    /// Le panneau garde « Copier » à jour dès que la session rend le texte, sans attendre la fin de l'insertion.
    @Test func theTextIsAnnouncedAsSoonAsTheSessionHandsItOver() async {
        let h = DictationHarness()
        let session = await h.startRecording()
        session.emit(.finalizing)
        session.emit(.finished("Annoncé."))
        #expect(await until { !h.panel.isOpen })
        #expect(h.views.contains { $0.stage == .finalizing && $0.lastTranscript == "Annoncé." })
    }

    // MARK: - Raccourci propre à un mode

    static let raw = ModeChip.rawID
    static let interview = ModeChip.interviewID

    /// Une dictée menée jusqu'à la relecture, commencée par le raccourci du mode `raw`.
    private func reviewing(_ h: DictationHarness) async {
        h.knobs.reviewing = [Self.raw]
        h.controller.modeHotKeyPressed(Self.raw)
        let session = await h.driveToRecording()
        session.emit(.finished("Texte."))
        #expect(await until { h.controller.view.stage == .review })
        h.knobs.selectedModes.removeAll()
    }

    @Test func aModesHotKeyWithTheClosedPanelSelectsTheModeAndStartsTheDictation() async {
        let h = DictationHarness()
        h.knobs.modeID = Self.interview
        #expect(!h.panel.isOpen)

        h.controller.modeHotKeyPressed(Self.raw)
        #expect(h.knobs.selectedModes == [Self.raw])
        #expect(h.panel.isOpen)
        #expect(h.controller.view.stage == .preparing)
        _ = await h.session()
    }

    @Test func aModesHotKeyWithThePanelOpenOnAnotherModeAtRestSelectsAndStartsToo() async {
        let h = DictationHarness()
        h.knobs.modeID = Self.interview
        h.panel.open()

        h.controller.modeHotKeyPressed(Self.raw)
        #expect(h.knobs.selectedModes == [Self.raw])
        #expect(h.panel.isOpen)
        #expect(h.panel.closeCount == 0)
        _ = await h.session()
        #expect(h.controller.view.stage == .preparing)
    }

    @Test func aModesHotKeyOnTheModeAlreadyChosenSelectsNothingAgain() async {
        let h = DictationHarness()
        h.controller.modeHotKeyPressed(Self.raw)
        #expect(h.knobs.selectedModes.isEmpty)
        _ = await h.session()
    }

    @Test func theInterviewHotKeyWithoutAnInterviewOpensThePanelOnInterviewWithTheCouldNotStartSentence() async {
        let h = DictationHarness()
        h.controller.modeHotKeyPressed(Self.interview)

        #expect(h.knobs.selectedModes == [Self.interview])
        #expect(h.panel.isOpen)
        #expect(h.controller.view == DictationViewState(notice: InterviewText.couldNotStart))
        await settle()
        #expect(h.engines.sessions.isEmpty)
    }

    @Test func theInterviewHotKeyWithThePanelOpenOnAnotherModeShowsTheSentenceInsteadOfClosing() async {
        let h = DictationHarness()
        h.panel.open()
        h.controller.modeHotKeyPressed(Self.interview)

        #expect(h.panel.isOpen)
        #expect(h.panel.closeCount == 0)
        #expect(h.controller.view == DictationViewState(notice: InterviewText.couldNotStart))
        // Déjà sur ce mode : le même raccourci referme le panneau, comme le raccourci global.
        h.controller.modeHotKeyPressed(Self.interview)
        #expect(!h.panel.isOpen)
        #expect(h.knobs.selectedModes == [Self.interview])
    }

    @Test func aModesHotKeyWithoutMicrophonePermissionSelectsTheModeAndOpensThePanelWithoutASession() async {
        let h = DictationHarness()
        h.knobs.modeID = Self.interview
        h.knobs.microphoneAllowed = false
        h.controller.modeHotKeyPressed(Self.raw)
        #expect(h.knobs.selectedModes == [Self.raw])
        #expect(h.panel.isOpen)
        await settle()
        #expect(h.engines.sessions.isEmpty)
    }

    // MARK: - Pendant une dictée

    @Test func theHotKeyOfTheModeThatStartedTheDictationFinishesItInToggle() async {
        let h = DictationHarness()
        let session = await h.startModeRecording(Self.raw)
        h.controller.modeHotKeyPressed(Self.raw)
        #expect(await until { session.count(of: "finish") == 1 })
        #expect(h.engines.sessions.count == 1)
    }

    @Test func theHotKeyOfAnotherModeDuringADictationIsIgnoredAndTheModeStays() async {
        let h = DictationHarness()
        let session = await h.startModeRecording(Self.raw)
        h.knobs.selectedModes.removeAll()

        h.controller.modeHotKeyPressed("perso-un")
        h.controller.modeHotKeyPressed(Self.interview)
        h.controller.modeHotKeyReleased("perso-un")
        await settle()
        #expect(session.count(of: "finish") == 0)
        #expect(h.engines.sessions.count == 1)
        #expect(h.knobs.selectedModes.isEmpty, "le mode n'a pas changé")
        #expect(h.knobs.modeID == Self.raw)
        #expect(h.controller.view.stage == .recording)
    }

    @Test func theGlobalHotKeyDuringADictationStartedByAModeIsIgnored() async {
        let h = DictationHarness()
        let session = await h.startModeRecording(Self.raw)
        h.controller.hotKeyPressed()
        h.controller.hotKeyReleased()
        await settle()
        #expect(session.count(of: "finish") == 0)
        #expect(h.controller.view.stage == .recording)
    }

    @Test func aModesHotKeyDuringADictationStartedByTheGlobalHotKeyIsIgnored() async {
        let h = DictationHarness()
        let session = await h.startRecording()
        h.controller.modeHotKeyPressed(Self.raw)
        h.controller.modeHotKeyReleased(Self.raw)
        await settle()
        #expect(session.count(of: "finish") == 0)
        #expect(h.engines.sessions.count == 1)
        // Le global, lui, la termine toujours.
        h.controller.hotKeyPressed()
        #expect(await until { session.count(of: "finish") == 1 })
    }

    @Test func inHoldTheReleaseOfTheModeThatStartedTheDictationFinishesIt() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startModeRecording(Self.raw)

        // Ni un autre mode ni le global ne la terminent.
        h.controller.modeHotKeyReleased("perso-un")
        h.controller.hotKeyReleased()
        h.controller.modeHotKeyPressed(Self.raw)
        await settle()
        #expect(session.count(of: "finish") == 0)

        h.controller.modeHotKeyReleased(Self.raw)
        #expect(await until { session.count(of: "finish") == 1 })
    }

    @Test func inHoldTheGlobalReleaseDoesNotFinishADictationStartedByTheGlobalWhenAModeReleases() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startRecording()
        h.controller.modeHotKeyReleased(Self.raw)
        await settle()
        #expect(session.count(of: "finish") == 0)
        h.controller.hotKeyReleased()
        #expect(await until { session.count(of: "finish") == 1 })
    }

    @Test func theHoldWatchReadsTheModifiersOfTheHotKeyThatStartedTheDictation() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        h.knobs.hotKeyModifiers = [.control, .option]
        h.knobs.modeModifiers = [Self.raw: [.command, .shift]]
        _ = await h.startModeRecording(Self.raw)
        #expect(await until { h.holdSleeper.isSleeping })
        h.holdSleeper.release()
        #expect(await until { !h.knobs.probes.isEmpty })
        #expect(h.knobs.probes.allSatisfy { $0 == [.command, .shift] })
        #expect(h.knobs.modeModifierReads == [Self.raw])
    }

    @Test func theHoldWatchOfAGlobalDictationStillReadsTheGlobalModifiers() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        h.knobs.hotKeyModifiers = [.control, .option]
        h.knobs.modeModifiers = [Self.raw: [.command, .shift]]
        _ = await h.startRecording()
        #expect(await until { h.holdSleeper.isSleeping })
        h.holdSleeper.release()
        #expect(await until { !h.knobs.probes.isEmpty })
        #expect(h.knobs.probes.allSatisfy { $0 == [.control, .option] })
        #expect(h.knobs.modeModifierReads.isEmpty)
    }

    // MARK: - Le propriétaire n'a plus de raccourci

    /// Une dictée en bascule dont le raccourci propriétaire n'existe plus (mode supprimé, raccourci retiré) ne reste pas sans
    /// issue : le raccourci global la termine, et le texte arrive comme d'habitude.
    @Test func aToggleDictationWhoseOwnerHasNoHotKeyAnymoreEndsWithTheGlobalHotKey() async {
        let h = DictationHarness()
        let session = await h.startModeRecording(Self.raw)
        h.knobs.unbound = [.mode(Self.raw)]

        h.controller.hotKeyPressed()
        #expect(await until { session.count(of: "finish") == 1 })
        session.emit(.finalizing)
        session.emit(.finished("Texte."))
        #expect(await until { h.pasted == ["Texte."] }, "le texte n'est pas perdu")
    }

    @Test func aToggleDictationStartedByTheGlobalWhoseHotKeyIsGoneCanEndWithAModesHotKeyWithoutChangingTheMode() async {
        let h = DictationHarness()
        let session = await h.startRecording()
        h.knobs.unbound = [.global]

        h.controller.modeHotKeyPressed("perso-un")
        #expect(await until { session.count(of: "finish") == 1 })
        #expect(h.knobs.selectedModes.isEmpty)
        #expect(h.knobs.modeID == Self.raw)
    }

    /// L'exception de la dictée orpheline ne vaut qu'en bascule : en maintien, l'appui d'un autre raccourci est ignoré et seul le
    /// relâchement du propriétaire termine (le README le dit).
    @Test func aHoldDictationWhoseOwnerHasNoHotKeyAnymoreIgnoresEveryOtherHotKey() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startModeRecording(Self.raw)
        h.knobs.unbound = [.mode(Self.raw)]

        h.controller.hotKeyPressed()
        h.controller.modeHotKeyPressed("perso-un")
        h.controller.hotKeyReleased()
        h.controller.modeHotKeyReleased("perso-un")
        await settle()
        #expect(session.count(of: "finish") == 0)

        h.controller.modeHotKeyReleased(Self.raw)
        #expect(await until { session.count(of: "finish") == 1 })
    }

    @Test func aDictationWhoseOwnerStillHasItsHotKeyKeepsIgnoringTheOthers() async {
        let h = DictationHarness()
        let session = await h.startModeRecording(Self.raw)
        h.controller.hotKeyPressed()
        await settle()
        #expect(session.count(of: "finish") == 0)
    }

    // MARK: - Pendant la relecture

    @Test(arguments: [DictationStage.review, .pasting])
    func aModesHotKeyIsIgnoredDuringTheReview(stage: DictationStage) async {
        let h = DictationHarness()
        h.handover.holds = stage == .pasting
        await reviewing(h)
        if stage == .pasting {
            h.controller.pasteReview()
            #expect(await until { h.handover.sleeper.isSleeping })
        }
        let before = h.controller.view

        h.controller.modeHotKeyPressed(Self.raw)
        h.controller.modeHotKeyPressed(Self.interview)
        h.controller.modeHotKeyReleased(Self.raw)
        await settle()
        #expect(h.knobs.selectedModes.isEmpty, "le mode n'a pas changé")
        #expect(h.controller.view == before)
        #expect(h.engines.sessions.count == 1)
        #expect(h.panel.isOpen)
        #expect(h.panel.closeCount == 0)
        h.handover.sleeper.release()
    }
}
