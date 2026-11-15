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
        #expect(h.controller.view.phase == .preparing)
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
        #expect(await until { h.controller.view.phase == .finalizing })

        h.controller.hotKeyPressed()
        await settle()
        #expect(session.count(of: "finish") == 0)
        #expect(h.engines.sessions.count == 1)
        #expect(h.controller.view.phase == .finalizing)
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
        #expect(h.controller.view.phase == .idle)
    }

    @Test func releaseAfterTheDictationEndedIsIgnored() async {
        let h = DictationHarness()
        h.knobs.behavior = .hold
        let session = await h.startRecording()
        session.emit(.failed(.noSpeech))
        #expect(await until { h.controller.view.phase == .failed(.noSpeech) })

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
        #expect(h.controller.view.phase == .recording)
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
        #expect(h.controller.view.phase == .recording)
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
        #expect(h.controller.view == DictationViewState())
        #expect(h.controller.lastTranscript == "Bonjour à tous.")
    }

    @Test func copiedKeepsThePanelOpenAndShowsTheReason() async {
        let h = DictationHarness(trusted: false)
        let session = await h.startRecording()
        session.emit(.finished("Texte dicté."))

        #expect(await until { h.controller.view.phase == .finished("Texte dicté.") })
        #expect(h.panel.isOpen)
        let notice = h.controller.view.notice ?? ""
        #expect(notice.contains("Accessibilité"))
        #expect(!notice.contains("Texte dicté"))
        #expect(h.pasted.isEmpty)
        // Le texte est resté dans le presse-papiers double, et dans la mémoire du contrôleur.
        #expect(h.rig.board.text == "Texte dicté.")
        #expect(h.controller.lastTranscript == "Texte dicté.")
    }

    @Test(arguments: [
        DictationFailure.noSpeech, .microphone("accès refusé"), .engine("moteur indisponible"),
    ])
    func failureKeepsThePanelOpenWithTheMessageAndPastesNothing(_ failure: DictationFailure) async {
        let h = DictationHarness()
        let session = await h.startRecording()
        session.emit(.finalizing)
        session.emit(.failed(failure))

        #expect(await until { h.controller.view.phase == .failed(failure) })
        #expect(h.panel.isOpen)
        #expect(h.controller.view.notice == failure.message)
        #expect(h.pasted.isEmpty)
        #expect(h.writtenTexts == 0)
        #expect(h.controller.lastTranscript == nil)

        // Un nouvel appui relance une dictée.
        h.controller.hotKeyPressed()
        #expect(h.controller.view.phase == .preparing)
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
        #expect(await until { h.controller.view.phase == .failed(.noSpeech) })
        #expect(h.controller.lastTranscript == "Premier texte.")
    }

    @Test func aBlankResultIsAFailureAndNeverCrashes() async {
        let h = DictationHarness()
        let session = await h.startRecording()
        session.emit(.finished("   "))

        #expect(await until { h.controller.view.phase == .failed(.noSpeech) })
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
            #expect(await until { h.controller.view.phase == .finalizing })
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
        #expect(await until { h.controller.view.phase == .failed(.noSpeech) })

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
        #expect(h.controller.view == DictationViewState())
        #expect(!h.panel.isOpen)
    }

    // MARK: - Résultat tardif

    /// Un moteur peut ignorer l'annulation : `finish()` ne rend jamais la main, puis le texte arrive quand même. Le
    /// contrôleur n'attend rien de lui.
    @Test func aResultArrivingAfterACancelIsNeverPastedNorShown() async {
        let h = DictationHarness()
        let stuck = TestGate()
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
        #expect(h.controller.view.phase == .recording)
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
        #expect(h.controller.view.phase == .recording)
    }

    // MARK: - Mode, micro, modèle

    @Test func anotherModeOpensThePanelWithoutADictationAndSaysSo() async {
        let h = DictationHarness()
        h.knobs.modeID = "prompt"
        h.controller.hotKeyPressed()

        #expect(h.panel.isOpen)
        #expect(h.controller.view == DictationViewState(notice: "Ce mode arrive à une étape suivante."))
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
        #expect(h.controller.view.phase == .preparing)
        _ = await h.session()
    }

    @Test func aMissingModelShowsTheDownloadMentionOnlyWhilePreparing() async {
        let h = DictationHarness()
        h.engines.configure { $0.modelMissing = true }
        h.controller.hotKeyPressed()
        let session = await h.session()
        #expect(await until { h.controller.view.notice == "Téléchargement du modèle…" })
        #expect(h.controller.view.phase == .preparing)

        session.emit(.preparing)
        session.emit(.recording)
        #expect(await until { h.controller.view.phase == .recording })
        #expect(h.controller.view.notice == nil)
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

        #expect(await until { h.controller.view.phase.isTerminal })
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

        #expect(await until { h.controller.view.phase.isTerminal })
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

        #expect(await until { h.controller.view.phase.isTerminal })
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
            engine: "whisperkit", whisperModel: "base", language: "fr", vocabulary: ["alpha"])
        h.knobs.settings = first
        let one = await h.startRecording()
        one.emit(.failed(.noSpeech))
        #expect(await until { h.controller.view.phase.isTerminal })

        let second = TranscriptionSettings(
            engine: "parakeet", whisperModel: "small", language: "en", vocabulary: ["beta", "gamma"])
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
            engine: "whisperkit", whisperModel: "base", language: "fr", vocabulary: ["a", "b", "c", "d", "e"])
        h.controller.hotKeyPressed()
        let session = await h.session()

        #expect(h.engines.settingsSeen.map(\.vocabulary) == [["a", "b"]])
        #expect(await until { session.calls.contains("start") })
        let notice = h.controller.view.notice ?? ""
        #expect(notice.contains("2 premiers termes sur 5"))
        #expect(notice.contains("Transcription"))
        // La dictée va au bout, avec l'avis toujours là.
        session.emit(.recording)
        #expect(await until { h.controller.view.phase == .recording })
        #expect(h.controller.view.notice?.contains("2 premiers termes sur 5") == true)
    }

    @Test func aVocabularyThatFitsIsLeftAloneWithoutAnyNotice() async {
        let h = DictationHarness(limit: 25)
        h.engines.configure {
            $0.tokenCount = { terms, _ in terms.count * 10 }
        }
        h.knobs.settings = TranscriptionSettings(
            engine: "whisperkit", whisperModel: "base", language: "fr", vocabulary: ["a", "b"])
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
            engine: "parakeet", whisperModel: "base", language: "fr", vocabulary: ["a", "b", "c"])
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
            engine: "whisperkit", whisperModel: "base", language: "fr", vocabulary: ["a", "b"])
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
            engine: "whisperkit", whisperModel: "base", language: "fr", vocabulary: ["a", "b"])
        h.controller.hotKeyPressed()
        _ = await h.session()
        #expect(h.engines.settingsSeen.map(\.vocabulary) == [[]])
        let notice = h.controller.view.notice ?? ""
        #expect(notice.contains("Téléchargement du modèle…"))
        #expect(notice.contains("vocabulaire"))
    }

    @Test func anUncountableVocabularyWithTheModelOnDiskIsPassedAsIs() async {
        let h = DictationHarness()
        h.engines.configure { $0.tokenCount = { _, _ in nil } }
        h.knobs.settings = TranscriptionSettings(
            engine: "whisperkit", whisperModel: "base", language: "fr", vocabulary: ["a", "b"])
        h.controller.hotKeyPressed()
        _ = await h.session()
        #expect(h.engines.settingsSeen.map(\.vocabulary) == [["a", "b"]])
        #expect(h.controller.view.notice == nil)
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
        #expect(h.views.first?.phase == .preparing)
    }
}
