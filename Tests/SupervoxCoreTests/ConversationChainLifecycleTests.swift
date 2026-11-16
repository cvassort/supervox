import Foundation
import Testing
@testable import SupervoxCore

// La fin d'un entretien : conclure, annuler, tomber en panne. À chaque fin, quelle qu'elle soit : le micro est arrêté une seule
// fois et a rendu la main avant `.finished`, aucune lecture n'est en cours, aucune tâche n'est vivante (les attentes de l'aperçu et
// du chien de garde, la requête au modèle, la synthèse, la transcription ont été annulées : leurs portes ne s'ouvrent qu'à
// l'annulation), `.finished` est émis une seule fois, en dernier, et le flux se termine juste après.

private let twoTurns = [TurnScript(base: 0), TurnScript(base: 1_000_000)]

/// Ce qui doit être vrai de toute fin d'entretien.
private func expectCleanEnd(_ h: ConversationHarness, sourceLocation: SourceLocation = #_sourceLocation) {
    let log = h.log!
    #expect(h.journal.count(of: "audio.stop") == 1, "le micro est arrêté une seule fois", sourceLocation: sourceLocation)
    #expect(!h.audio.inner.isRunning, sourceLocation: sourceLocation)
    let stopReturned = h.journal.index(of: "audio.stop.returned"), finished = h.journal.index(of: "event.finished")
    #expect(stopReturned != nil && finished != nil && stopReturned! < finished!, "`.finished` après le retour de stop()",
            sourceLocation: sourceLocation)
    #expect(!h.previewSleeper.isSleeping && !h.watchdogSleeper.isSleeping, sourceLocation: sourceLocation)
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

        await h.chain.cancel()

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

        await h.chain.cancel()

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

        await h.chain.cancel()

        #expect(h.speech.cancelledCalls == 1)
        await log.waitForEnd()
        #expect(log.end == .cancelled && h.audio.inner.played.isEmpty)
        #expect(!log.items.contains(where: isSpeakingStarted))   // rien n'a été dit, aucun début de parole à clore
        expectCleanEnd(h)
    }

    @Test func cancelWhileAClipIsPlayingStopsThePlaybackAndClosesTheSpeech() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [question("Une question ?")],
                                    completion: .manual)
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        await h.chain.cancel()

        await log.waitForEnd()
        #expect(h.audio.inner.stopPlaybackCount == 1)   // la lecture est coupée une fois
        let events = log.items
        #expect(!events.contains { if case .sentencePlayed = $0 { true } else { false } })
        let ended = events.firstIndex(of: .speakingEnded(heard: ""))
        let finished = events.firstIndex(where: isFinished)
        #expect(ended != nil && finished != nil && ended! < finished!)
        #expect(log.end == .cancelled)
        expectCleanEnd(h)
    }

    @Test func cancelWhileTheTurnIsBeingTranscribedCancelsTheTranscription() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: { _ in .hold })
        let log = await h.start()
        await h.say(0)
        await h.transcriber.waitForCalls(1)

        await h.chain.cancel()

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
        await h.chain.cancel()

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

        await h.chain.cancel()
        await h.chain.cancel()
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
    @Test func concludeWhileThinkingCancelsTheFastRequestAndConcludesWithWhatWasSaid() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [ScriptedModel([])])
        let log = await h.start()
        await h.say(0)
        await h.fast.model(at: 0).started.wait()

        await h.chain.conclude()

        await log.waitForEnd()
        #expect(h.fast.model(at: 0).wasCancelled)
        #expect(log.end == .prompt("Prompt final", conversation("t1")))
        #expect(h.strong.requests[0].input.contains("Vous : t1"))
        expectCleanEnd(h)
    }

    @Test func concludeWhileSpeakingCutsThePlaybackAndKeepsOnlyThePlayedSentences() async {
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
        let request = h.strong.requests[0].input
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
struct ConversationFailureTests {
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
        #expect(log.end == .failed(.engine("transcription : engine"), conversation("t1", "Une question ?")))
        #expect(h.strong.calls == 0)
        expectCleanEnd(h)
    }

    @Test func aDetectorThatThrowsEndsFailedWithAnEmptyConversation() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], detectorFailure: (block: 1, error: TestFailure("boum")))
        let log = await h.start()

        await h.say(0)
        await log.waitForEnd()

        #expect(log.end == .failed(.engine("erreur inattendue"), Conversation()))
        expectCleanEnd(h)
    }

    @Test func aResamplerThatCannotBeBuiltEndsFailedOnTheMicrophone() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], makeResampler: { _, _ in nil })
        let log = await h.start()

        await h.say(0)
        await log.waitForEnd()

        #expect(log.end == .failed(.microphone("fréquence du micro inutilisable (16000 Hz)"), Conversation()))
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
        #expect(log.end == .failed(.microphone("le micro s'est arrêté pendant l'entretien"), Conversation()))
        expectCleanEnd(h)
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
        #expect(log.end == .failed(.microphone("le micro s'est arrêté pendant l'entretien"), conversation("t1", "Une question ?")))
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
        #expect(log.end == .failed(.microphone("le micro s'est arrêté pendant l'entretien"), conversation("t1")))
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

    @Test func aFastModelThatFailsAfterASentenceKeepsTheSentenceThatWasHeard() async {
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
        let ended = trace.firstIndex(of: .speakingEnded(heard: "Une phrase."))
        let notice = trace.firstIndex(of: .notice(.modelFailed(.providerError)))
        #expect(ended != nil && notice != nil && ended! < notice!)
        #expect(h.fast.requests[1].history.last == CompletionTurn(role: .assistant, text: "Une phrase."))
        #expect(h.fast.requests[1].instruction == InterviewPrompt.instruction(remainingQuestions: 7))   // la question a été posée
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

    @Test func aVoiceThatFailsGivesOneNoticeThenTheTextAloneIsShownAndCountedAsHeard() async {
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
        #expect(trace.firstIndex(of: .notice(.voiceUnavailable))! < trace.firstIndex(of: .speakingStarted(question: 1))!)
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
