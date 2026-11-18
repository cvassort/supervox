import Foundation
import Testing
@testable import SupervoxCore

// La fin d'un entretien : conclure, annuler, tomber en panne. À chaque fin, quelle qu'elle soit : le micro est arrêté une seule
// fois et a rendu la main avant `.finished`, aucune lecture n'est en cours, aucune tâche n'est vivante (les attentes de l'aperçu et
// du chien de garde, la requête au modèle, la synthèse, la transcription ont été annulées : leurs portes ne s'ouvrent qu'à
// l'annulation), `.finished` est émis une seule fois, en dernier, et le flux se termine juste après.

private let twoTurns = [TurnScript(base: 0), TurnScript(base: 1_000_000)]

/// Ce qui doit être vrai de toute fin d'entretien.
func expectCleanEnd(_ h: ConversationHarness, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let log = h.log else {
        Issue.record("l'entretien n'a pas été démarré", sourceLocation: sourceLocation)
        return
    }
    #expect(h.journal.count(of: "audio.stop") == 1, "le micro est arrêté une seule fois", sourceLocation: sourceLocation)
    #expect(!h.audio.inner.isRunning, sourceLocation: sourceLocation)
    if let stopReturned = h.journal.index(of: "audio.stop.returned"), let finished = h.journal.index(of: "event.finished") {
        #expect(stopReturned < finished, "`.finished` après le retour de stop()", sourceLocation: sourceLocation)
    } else {
        Issue.record("`audio.stop()` n'a pas rendu la main, ou `.finished` n'a pas été émis", sourceLocation: sourceLocation)
    }
    #expect(!h.previewSleeper.isSleeping && !h.watchdogSleeper.isSleeping && !h.transcriptionSleeper.isSleeping,
            sourceLocation: sourceLocation)
    #expect(log.count(isFinished) == 1 && log.items.last.map(isFinished) == true, sourceLocation: sourceLocation)
    #expect(log.items.dropLast().last == .state(.finished), sourceLocation: sourceLocation)
    #expect(log.ended, sourceLocation: sourceLocation)
    #expect(h.audio.inner.stopPlaybackCount == h.journal.count(of: "audio.stopPlayback"), sourceLocation: sourceLocation)
}

@Suite(.timeLimit(.minutes(1)))
struct ConversationCancelTests {
    @Test func cancelWhileListeningEndsCancelledWithEverythingClosed() async {
        let h = ConversationHarness()
        let log = await h.start()
        await log.wait(.state(.listening))
        await h.previewSleeper.waitForSleeps(1)
        await h.watchdogSleeper.waitForSleeps(1)

        await h.cancel()

        // À son retour, plus rien ne tourne : la surveillance et l'aperçu ont été annulés et attendus.
        #expect(!h.previewSleeper.isSleeping && !h.watchdogSleeper.isSleeping)
        #expect(h.previewSleeper.cancelled == 1 && h.watchdogSleeper.cancelled == 1)
        await log.waitForEnd()
        #expect(log.end == .cancelled)
        #expect(h.strong.calls == 0)
        expectCleanEnd(h)
    }

    @Test func cancelWhileThinkingCancelsTheRequestAndNeverAsksTheStrongModel() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [ScriptedModel([])])
        let log = await h.start()
        await h.say(0)
        await h.fast.model(at: 0).started.wait()   // la requête est partie, rien ne vient

        await h.cancel()

        await h.fast.model(at: 0).terminated.wait()
        #expect(h.fast.model(at: 0).wasCancelled)
        await log.waitForEnd()
        #expect(log.end == .cancelled && h.strong.calls == 0)
        expectCleanEnd(h)
    }

    @Test func cancelWhileASentenceIsBeingSynthesizedCancelsTheSynthesis() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [question("Une question ?")],
                                    speech: ScriptedSpeech(reply: { _, _ in .hold }))
        let log = await h.start()
        await h.say(0)
        await h.speech.waitForCalls(1)

        await h.cancel()

        #expect(h.speech.cancelledCalls == 1)
        await log.waitForEnd()
        #expect(log.end == .cancelled && h.audio.inner.played.isEmpty)
        #expect(!log.items.contains(where: isSpeakingStarted))   // rien n'a été dit, aucun début de parole à clore
        expectCleanEnd(h)
    }

    @Test func cancelWhileAClipIsPlayingStopsThePlaybackAndClosesTheSpeech() async throws {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [question("Une question ?")],
                                    completion: .manual)
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        await h.cancel()

        await log.waitForEnd()
        #expect(h.audio.inner.stopPlaybackCount == 1)   // la lecture est coupée une fois
        let events = log.items
        #expect(!events.contains { if case .sentencePlayed = $0 { true } else { false } })
        let ended = try #require(events.firstIndex(of: .speakingEnded(heard: "")))
        let finished = try #require(events.firstIndex(where: isFinished))
        #expect(ended < finished)
        #expect(log.end == .cancelled)
        expectCleanEnd(h)
    }

    @Test func cancelWhileTheTurnIsBeingTranscribedCancelsTheTranscription() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: { _ in .hold })
        let log = await h.start()
        await h.say(0)
        await h.transcriber.waitForCalls(1)

        await h.cancel()

        await h.transcriber.cancellation(of: 0).wait()
        await log.waitForEnd()
        #expect(log.end == .cancelled && h.fast.calls == 0)
        expectCleanEnd(h)
    }

    @Test func cancelWhileConcludingCancelsTheStrongRequestAndAConcludeDuringConclusionChangesNothing() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [modelReply("[CONCLURE]\nMerci.")],
                                    strong: [ScriptedModel([])])
        let log = await h.start()
        await h.say(0)
        await h.strong.model(at: 0).started.wait()

        await h.chain.conclude()
        #expect(h.strong.calls == 1)
        await h.cancel()

        await h.strong.model(at: 0).terminated.wait()
        #expect(h.strong.model(at: 0).wasCancelled)
        await log.waitForEnd()
        #expect(log.end == .cancelled)
        expectCleanEnd(h)
    }

    @Test func aSecondCancelAndALateConcludeChangeNothing() async {
        let h = ConversationHarness()
        let log = await h.start()
        await log.wait(.state(.listening))

        await h.cancel()
        await h.cancel()
        await h.chain.conclude()

        await log.waitForEnd()
        #expect(log.end == .cancelled)
        expectCleanEnd(h)
    }

    @Test func aSecondConcludeChangesNothing() async {
        let h = ConversationHarness()
        let log = await h.start()
        await log.wait(.state(.listening))

        await h.chain.conclude()
        await h.chain.conclude()

        await log.waitForEnd()
        #expect(log.end == .nothingSaid)
        expectCleanEnd(h)
    }

    @Test func releasingTheEventStreamCancelsTheEntretienAndClosesTheMicrophone() async {
        let h = ConversationHarness()
        let stream = await h.chain.start()
        let consumer = Task { for await _ in stream {} }
        await h.watchdogSleeper.waitForSleeps(1)   // le micro est ouvert

        consumer.cancel()

        await h.audio.stopped.wait()
        #expect(!h.audio.inner.isRunning && h.journal.count(of: "audio.stop") == 1)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ConversationConcludeTests {
    /// `conclude()` a fini la conversation ; pendant que `run` arrête le chien de garde (une attente sourde à l'annulation), `cancel()`
    /// arrive : la fin est `.cancelled`, et l'entretien n'a jamais annoncé qu'il concluait.
    /// Depuis le tour de correction 1 de la tâche 6 (I-1), la conclusion est annoncée dès que la fin la prend en charge : un
    /// `cancel()` arrivé ensuite, pendant l'arrêt du chien de garde, l'emporte encore. Fin annulée, modèle fort jamais sollicité, et
    /// `.concluding` dit une seule fois, avant la fin.
    @Test func aCancelThatArrivesWhileTheWatchdogIsBeingStoppedEndsCancelledWithoutAskingTheStrongModel() async {
        let latch = DeafLatch()
        let h = ConversationHarness(watchdogSleep: { _ in await latch.wait() })
        let log = await h.start()
        await log.wait(.state(.listening))
        await h.chain.conclude()
        _ = await waitUntil { await h.chain.isClosing }   // `run` attend maintenant la tâche du chien de garde, qui ne répond pas
        let cancelling = Task { await h.cancel() }
        _ = await waitUntil { await h.chain.cancelIsRequested }

        latch.open()
        // Rend la main à la limite de temps de la suite (revue finale, I-B) : `cancelling` est une tâche non structurée, que
        // l'annulation du test n'atteint pas seule. Annulée ici, son `h.cancel()` rend la main, et le test échoue au lieu de pendre.
        await withTaskCancellationHandler { await cancelling.value } onCancel: { cancelling.cancel() }

        await log.waitForEnd()
        #expect(log.end == .cancelled)
        #expect(log.items.filter { $0 == .state(.concluding) }.count == 1)
        #expect(h.strong.calls == 0)
        expectCleanEnd(h)
    }

    @Test func concludeWhileThinkingCancelsTheFastRequestAndConcludesWithWhatWasSaid() async throws {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [ScriptedModel([])])
        let log = await h.start()
        await h.say(0)
        await h.fast.model(at: 0).started.wait()

        await h.chain.conclude()

        await log.waitForEnd()
        #expect(h.fast.model(at: 0).wasCancelled)
        #expect(log.end == .prompt("Prompt final", conversation("t1")))
        let request = try #require(h.strong.requests.first)
        #expect(request.input.contains("Vous : t1"))
        expectCleanEnd(h)
    }

    @Test func concludeWhileSpeakingCutsThePlaybackAndKeepsOnlyThePlayedSentences() async throws {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [question("Un. Deux.")],
                                    completion: .manual)
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.wait(.sentencePlayed("Un."))
        await h.audio.plays.wait(atLeast: 2)   // la deuxième phrase est en file, pas jouée

        await h.chain.conclude()

        await log.waitForEnd()
        #expect(h.audio.inner.stopPlaybackCount == 1)
        #expect(log.trace.contains(.speakingEnded(heard: "Un.")))
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Un.")))   // « Deux. » mise en file mais coupée : absente
        let request = try #require(h.strong.requests.first).input
        #expect(request.contains("Supervox : Un.") && !request.contains("Deux."))
        expectCleanEnd(h)
    }

    @Test func concludeWhileTheTurnIsBeingTranscribedKeepsTheTurnAndAsksNoFastModel() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: { _ in .hold })
        let log = await h.start()
        await h.say(0)
        await h.transcriber.waitForCalls(1)

        await h.chain.conclude()
        h.transcriber.release(call: 0, text: "ce que j'ai dit")

        await log.waitForEnd()
        #expect(log.items.contains(.turnEnded("ce que j'ai dit")))
        #expect(h.fast.calls == 0)
        #expect(log.end == .prompt("Prompt final", conversation("ce que j'ai dit")))
        expectCleanEnd(h)
    }

    @Test func concludeWhileListeningAfterATurnConcludesWithTheTwoSides() async {
        let h = ConversationHarness(turns: twoTurns, transcripts: texts("t1"), fast: [question("Une question ?")])
        let log = await h.start()
        await h.say(0)
        await log.wait(.state(.listening), count: 2)

        await h.chain.conclude()

        await log.waitForEnd()
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Une question ?")))
        #expect(h.fast.calls == 1)
        expectCleanEnd(h)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ConversationBreakdownTests {
    // Toute panne après au moins un tour rend la conversation : l'appelant ne perd rien de ce qui a été dit.

    @Test func aTranscriptionThatThrowsEndsFailedWithTheConversationSoFar() async {
        let h = ConversationHarness(
            turns: twoTurns, transcripts: { $0 == 0 ? .text("t1") : .fail(TranscriberError.engine("texte secret de la personne")) },
            fast: [question("Une question ?")])
        let log = await h.start()
        await h.say(0)
        await log.wait(.state(.listening), count: 2)

        await h.say(1)
        await log.waitForEnd()

        // La raison est un code, jamais le message de l'erreur.
        #expect(log.end == .failed(.engine("transcriptionFailed"), conversation("t1", "Une question ?")))
        #expect(h.strong.calls == 0)
        expectCleanEnd(h)
    }

    @Test func aDetectorThatThrowsEndsFailedWithAnEmptyConversation() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], detectorFailure: (block: 1, error: TestFailure("boum")))
        let log = await h.start()

        await h.say(0)
        await log.waitForEnd()

        #expect(log.end == .failed(.engine("detectorFailed"), Conversation()))
        expectCleanEnd(h)
    }

    @Test func aResamplerThatCannotBeBuiltEndsFailedOnTheMicrophone() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], makeResampler: { _, _ in nil })
        let log = await h.start()

        await h.say(0)
        await log.waitForEnd()

        #expect(log.end == .failed(.microphone("unusableSampleRate"), Conversation()))
        expectCleanEnd(h)
    }

    @Test func aSilentMicrophoneEndsFailedAfterTheFirstChunkDelay() async {
        let h = ConversationHarness()
        let log = await h.start()
        await log.wait(.state(.listening))
        await h.watchdogSleeper.waitForSleeps(1)

        h.clock.advance(by: 2)   // moins que les 3 s accordées à la première tranche
        h.watchdogSleeper.tick()
        await h.watchdogSleeper.waitForSleeps(2)
        #expect(log.end == nil)
        h.clock.advance(by: 2)
        h.watchdogSleeper.tick()

        await log.waitForEnd()
        #expect(log.end == .failed(.microphone("silent"), Conversation()))
        expectCleanEnd(h)
    }

    @Test func theFirstChunkDelayCountsFromTheMomentTheMicrophoneOpens() async {
        // La préparation dure (ici : cent secondes d'horloge) : le délai de la première tranche ne court pas pendant elle.
        let h = ConversationHarness()
        let preparation = Gate()
        h.detector.prepareRelease = preparation
        let log = await h.start()
        await h.detector.prepareEntered.wait()
        h.clock.advance(by: 100)
        preparation.open()
        await log.wait(.state(.listening))
        await h.watchdogSleeper.waitForSleeps(1)

        h.clock.advance(by: 2)   // moins que les 3 s accordées à la première tranche, depuis l'ouverture du micro
        h.watchdogSleeper.tick()
        await h.watchdogSleeper.waitForSleeps(2)

        #expect(log.end == nil)
        await finish(h)
    }

    @Test func aMicrophoneThatStopsAfterATurnEndsFailedWithTheConversation() async {
        let h = ConversationHarness(turns: twoTurns, transcripts: texts("t1"), fast: [question("Une question ?")])
        let log = await h.start()
        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        await h.watchdogSleeper.waitForSleeps(1)

        h.clock.advance(by: 10)
        h.watchdogSleeper.tick()

        await log.waitForEnd()
        #expect(log.end == .failed(.microphone("silent"), conversation("t1", "Une question ?")))
        expectCleanEnd(h)
    }

    @Test func aMicrophoneThatStopsWhileTheToolSpeaksCutsThePlaybackAndKeepsTheTurn() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [question("Une question ?")],
                                    completion: .manual)
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        h.clock.advance(by: 10)
        h.watchdogSleeper.tick()

        await log.waitForEnd()
        #expect(log.end == .failed(.microphone("silent"), conversation("t1")))
        #expect(h.audio.inner.stopPlaybackCount == 1)
        expectCleanEnd(h)
    }

    // MARK: Le modèle rapide

    @Test func aFailingFastModelGivesANoticeKeepsTheTurnAndMergesTheNextAnswer() async {
        let h = ConversationHarness(
            turns: twoTurns, transcripts: texts("t1", "t2"),
            fast: [ScriptedModel([.fail(CompletionError.provider(type: "surcharge"))]), question("Une question ?")])
        let log = await h.start()

        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        #expect(log.trace == [.state(.preparing), .state(.listening), .turnEnded("t1"), .state(.thinking),
                              .notice(.modelFailed(.providerError)), .state(.listening)])
        await h.say(1)
        await log.wait(.state(.listening), count: 3)
        await h.chain.conclude()
        await log.waitForEnd()

        #expect(h.fast.requests.map(\.input) == ["t1", "t1 t2"])   // la réponse suivante est fusionnée au tour resté sans réponse
        #expect(h.fast.requests.map(\.instruction) == Array(repeating: InterviewPrompt.instruction(remainingQuestions: 8), count: 2))
        #expect(log.end == .prompt("Prompt final", conversation("t1 t2", "Une question ?")))
    }

    @Test func aFastModelThatFailsAfterASentenceKeepsTheSentenceThatWasHeard() async throws {
        let h = ConversationHarness(
            turns: twoTurns, transcripts: texts("t1", "t2"),
            fast: [ScriptedModel([.text("[SUITE]\nUne phrase. Une deuxième"), .fail(CompletionError.provider(type: "surcharge"))]),
                   modelReply("[CONCLURE]\nMerci.")])
        let log = await h.start()

        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        await h.say(1)
        await log.waitForEnd()

        #expect(h.speech.texts.first == "Une phrase.")   // le morceau coupé n'est pas dit
        let trace = log.trace
        let ended = try #require(trace.firstIndex(of: .speakingEnded(heard: "Une phrase.")))
        let notice = try #require(trace.firstIndex(of: .notice(.modelFailed(.providerError))))
        #expect(ended < notice)
        let second = try #require(h.fast.requests.dropFirst().first)
        #expect(second.history.last == CompletionTurn(role: .assistant, text: "Une phrase."))
        #expect(second.instruction == InterviewPrompt.instruction(remainingQuestions: 7))   // la question a été posée
    }

    @Test func aReplyWithNothingToSayIsAFailureNotASilentQuestion() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [modelReply("[SUITE]")])
        let log = await h.start()

        await h.say(0)
        await log.wait(.state(.listening), count: 2)

        #expect(log.trace.contains(.notice(.modelFailed(.empty))))
        #expect(!log.items.contains(where: isSpeakingStarted))
        await finish(h)
    }

    // MARK: La voix

    /// Toutes les phrases d'une réplique ne donnent rien à dire (`SpeechError.empty`) : ni dite ni montrée, la réplique n'est pas une
    /// question muette. Même avis qu'une réponse vide du modèle ; la question n'est pas comptée et la réponse suivante est fusionnée.
    @Test func aReplyWhoseEverySentenceHasNothingToSayIsAFailureNotASilentQuestion() async throws {
        let h = ConversationHarness(
            turns: twoTurns, transcripts: texts("t1", "t2"), fast: [question("Un. Deux."), modelReply("[CONCLURE]\nMerci.")],
            speech: ScriptedSpeech(reply: { _, _ in .fail(SpeechError.empty) }))
        let log = await h.start()

        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        #expect(log.trace.contains(.notice(.modelFailed(.empty))))
        #expect(!log.items.contains(where: isSpeakingStarted))
        #expect(!log.items.contains { if case .notice(.voiceUnavailable) = $0 { true } else { false } })   // la voix n'est pas en panne
        await h.say(1)
        await log.waitForEnd()

        #expect(h.fast.requests.map(\.input) == ["t1", "t1 t2"])
        #expect(h.fast.requests.map(\.instruction) == Array(repeating: InterviewPrompt.instruction(remainingQuestions: 8), count: 2))
        #expect(log.end == .prompt("Prompt final", conversation("t1 t2")))
    }

    @Test func aSentenceWithNothingToSayIsSkippedAndTheVoiceStays() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [question("Un. Deux.")],
                                    speech: ScriptedSpeech(reply: { index, _ in index == 0 ? .fail(SpeechError.empty) : .clip }))
        let log = await h.start()

        await h.say(0)
        await log.wait(.state(.listening), count: 2)

        #expect(h.speech.texts == ["Un.", "Deux."])
        #expect(!log.items.contains { if case .notice = $0 { true } else { false } })   // ce n'est la panne d'aucune voix
        #expect(log.trace.contains(.speakingEnded(heard: "Deux.")))   // la phrase sautée n'a pas été entendue
        #expect(h.audio.inner.played.count == 1)
        await finish(h)
    }

    @Test func aVoiceThatFailsGivesOneNoticeThenTheTextAloneIsShownAndCountedAsHeard() async throws {
        let h = ConversationHarness(
            turns: twoTurns, transcripts: texts("t1", "t2"), fast: [question("Un. Deux. Trois."), question("Quatre.")],
            speech: ScriptedSpeech(reply: { index, _ in index == 0 ? .fail(SpeechError.noVoice(language: "fr-FR")) : .clip }))
        let log = await h.start()

        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        await h.say(1)
        await log.wait(.state(.listening), count: 3)

        #expect(h.speech.texts == ["Un."])   // plus aucune synthèse après la panne, à la réplique suivante non plus
        #expect(log.count { $0 == .notice(.voiceUnavailable) } == 1)
        #expect(h.audio.inner.played.isEmpty)
        #expect(log.trace.contains(.speakingEnded(heard: "Un. Deux. Trois.")))
        #expect(log.trace.contains(.speakingEnded(heard: "Quatre.")))
        let trace = log.trace
        let notice = try #require(trace.firstIndex(of: .notice(.voiceUnavailable)))
        let started = try #require(trace.firstIndex(of: .speakingStarted(question: 1)))
        #expect(notice < started)
        let replies = log.items.compactMap { event -> String? in
            if case .replyText(let text) = event { return text }
            return nil
        }
        #expect(replies.contains("Un. Deux. Trois."))   // la réplique entière est affichée
        await finish(h)
    }

    @Test func aLaterVoiceFallbackIsAnnouncedOnlyOncePerEntretien() async {
        let h = ConversationHarness(turns: twoTurns, transcripts: texts("t1", "t2"), fast: [question("Un."), question("Deux.")],
                                    speech: ScriptedSpeech(reply: { _, _ in .fellBack }))
        let log = await h.start()

        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        await h.say(1)
        await log.wait(.state(.listening), count: 3)

        #expect(log.count { $0 == .notice(.voiceFellBack) } == 1)
        #expect(h.audio.inner.played.count == 2)   // la voix de secours parle bien
        await finish(h)
    }

    @Test func aPlaybackThatCannotStartFallsBackToTheTextAlone() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [question("Un. Deux.")])
        h.audio.failPlays(with: AudioCaptureError.engineFailed("x"))
        let log = await h.start()

        await h.say(0)
        await log.wait(.state(.listening), count: 2)

        #expect(log.count { $0 == .notice(.voiceUnavailable) } == 1)
        #expect(log.trace.contains(.speakingEnded(heard: "Un. Deux.")))
        await finish(h)
    }
}

/// Les doubles eux-mêmes : un test qui demande plus de réponses que prévu échoue tout de suite, il n'attend pas la limite de la suite.
@Suite(.timeLimit(.minutes(1)))
struct ConversationDoublesTests {
    @Test func aRequestToAModelWithNoReplyLeftRecordsAnIssueAndEndsTheEntretienAtOnce() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [])

        // Le problème enregistré par le double est attendu ici : sans lui, `withKnownIssue` fait échouer le test. L'entretien est
        // démarré DANS le bloc : ses tâches héritent du contexte du test qui les crée, et c'est lui qui rattache le problème.
        await withKnownIssue("requête de trop au modèle rapide : voulue par ce test") {
            let log = await h.start()
            await h.say(0)
            await log.waitForEnd()
        }

        let log = h.log
        #expect(log?.end == .cancelled)   // l'entretien a été arrêté par le double, sans attendre la limite de temps
        expectCleanEnd(h)
    }
}

// MARK: - La transcription d'un tour : délai, annulation, panne du micro

@Suite(.timeLimit(.minutes(1)))
struct ConversationTranscriptionTests {
    // MARK: Annulation (I-2)

    /// Un moteur de transcription peut être sourd à l'annulation (`Deadline.swift` le dit) : `cancel()` rend quand même la main, et le
    /// micro est fermé. Le test est borné par la limite de la suite et `h.cancel()` rend la main à l'annulation du test.
    @Test func cancelReturnsAndClosesTheMicrophoneEvenWhenTheTranscriptionEngineIgnoresCancellation() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: { _ in .hold }, transcriberHonorsCancellation: false)
        let log = await h.start()
        await h.say(0)
        await h.transcriber.waitForCalls(1)

        await h.cancel()

        #expect(log.end == .cancelled)   // la fin est arrivée : `cancel()` n'a pas attendu le moteur
        #expect(!h.audio.inner.isRunning)
        h.transcriber.release(call: 0, text: "arrivé trop tard")   // le moteur répond enfin : rien n'en sort
        #expect(!log.items.contains { if case .turnEnded = $0 { true } else { false } })
        expectCleanEnd(h)
    }

    /// Le détecteur finit le passage pendant que `cancel()` arrive : le tour fermé ne part pas au moteur de transcription. (Le bloc qui
    /// ferme le passage est retenu ; l'annulation de la tâche le libère, comme le ferait un détecteur qui l'écoute.)
    @Test func noTranscriptionStartsAfterACancelThatArrivedWhileTheClosingBlockWasProcessed() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"))
        let closing = h.detector.hold(block: 5)   // le dernier bloc du tour : le détecteur y annonce la fin du passage
        let log = await h.start()
        await h.say(0)
        await closing.entered.wait()

        await h.cancel()

        #expect(h.transcriber.calls.isEmpty)
        #expect(!log.items.contains { if case .turnEnded = $0 { true } else { false } })
        #expect(log.end == .cancelled)
        expectCleanEnd(h)
    }

    // MARK: Délai (I-2)

    @Test func aTranscriptionThatNeverAnswersEndsFailedAfterTheTimeoutAndKeepsTheEarlierTurns() async {
        let h = ConversationHarness(
            turns: twoTurns, transcripts: { $0 == 0 ? .text("t1") : .hold }, fast: [question("Une question ?")],
            transcriberHonorsCancellation: false)
        let log = await h.start()
        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        await h.say(1)
        await h.transcriber.waitForCalls(2)
        await h.transcriptionSleeper.waitForSleeps(2)   // une limite par tour : la seconde est celle du tour retenu

        h.transcriptionSleeper.tick()

        await log.waitForEnd()
        #expect(log.end == .failed(.engine("transcriptionTimedOut"), conversation("t1", "Une question ?")))
        #expect(h.transcriptionSleeper.requested == [12.5, 12.5])   // la valeur vient de la configuration
        h.transcriber.release(call: 1, text: "arrivé trop tard")
        expectCleanEnd(h)
    }

    @Test func aPreviewThatNeverAnswersIsAbandonedAfterTheTimeoutAndTheNextOneGoesOut() async {
        let h = ConversationHarness(
            turns: [TurnScript(blocks: 6, start: 1, end: 4, base: 0)], transcripts: { $0 == 0 ? .hold : .text("bon") },
            transcriberHonorsCancellation: false)
        let log = await h.start()
        await log.wait(.state(.listening))
        await h.previewSleeper.waitForSleeps(1)
        for block in 0..<3 { h.audio.inner.push(rampChunk((block * 1000)..<((block + 1) * 1000))) }   // la voix commence au bloc 1
        await log.wait(3, where: isLevel)
        h.previewSleeper.tick()
        await h.transcriber.waitForCalls(1)   // le premier aperçu est retenu dans le moteur
        await h.transcriptionSleeper.waitForSleeps(1)

        h.transcriptionSleeper.tick()   // sa limite de temps est écoulée
        await h.previewSleeper.waitForSleeps(2)   // la passe est finie : l'attente de la suivante commence
        h.previewSleeper.tick()
        await log.wait(.partialTranscript("bon"))   // la seconde passe a répondu

        #expect(h.transcriber.calls.count == 2)
        #expect(h.transcriptionSleeper.requested == [12.5, 12.5])
        h.transcriber.release(call: 0, text: "arrivé trop tard")
        await h.cancel()
        await log.waitForEnd()
        #expect(log.items.filter(isPartial) == [.partialTranscript("bon")])   // l'aperçu abandonné n'a rien montré
    }

    // MARK: Panne du micro pendant la transcription (I-1)

    /// Le casque se débranche pendant qu'un tour est transcrit : la transcription (d'un audio déjà capté) va à son terme, et le tour
    /// est dans la conversation que rend la fin.
    @Test func aMicrophoneThatDiesWhileTheTurnIsBeingTranscribedDoesNotLoseThatTurn() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: { _ in .hold })
        let log = await h.start()
        await h.say(0)
        await h.transcriber.waitForCalls(1)
        await h.watchdogSleeper.waitForSleeps(1)

        h.clock.advance(by: 10)
        h.watchdogSleeper.tick()
        _ = await waitUntil { await h.chain.failureIsPending }   // la panne est vue, la transcription est encore en cours
        #expect(log.end == nil)
        h.transcriber.release(call: 0, text: "ce que j'ai dit")

        await log.waitForEnd()
        #expect(log.items.contains(.turnEnded("ce que j'ai dit")))
        #expect(log.end == .failed(.microphone("silent"), conversation("ce que j'ai dit")))
        #expect(h.fast.calls == 0)   // la panne ne lance pas de réflexion
        expectCleanEnd(h)
    }

    /// Si en plus le moteur ne répond jamais, le délai tranche : la fin porte la panne du micro (la première cause) et tout ce qui a
    /// déjà été transcrit ; le tour en cours, que le moteur n'a pas rendu dans le délai, est perdu.
    @Test func aMicrophoneThatDiesWhileAnEngineNeverAnswersEndsOnTheMicrophoneAfterTheTimeout() async {
        let h = ConversationHarness(
            turns: twoTurns, transcripts: { $0 == 0 ? .text("t1") : .hold }, fast: [question("Une question ?")],
            transcriberHonorsCancellation: false)
        let log = await h.start()
        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        await h.say(1)
        await h.transcriber.waitForCalls(2)
        await h.transcriptionSleeper.waitForSleeps(2)
        await h.watchdogSleeper.waitForSleeps(1)

        h.clock.advance(by: 10)
        h.watchdogSleeper.tick()
        _ = await waitUntil { await h.chain.failureIsPending }
        h.transcriptionSleeper.tick()

        await log.waitForEnd()
        #expect(log.end == .failed(.microphone("silent"), conversation("t1", "Une question ?")))
        h.transcriber.release(call: 1, text: "arrivé trop tard")
        expectCleanEnd(h)
    }
}
