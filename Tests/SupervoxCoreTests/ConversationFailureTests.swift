import Foundation
import Testing
@testable import SupervoxCore

// Pannes et fin propre à chaque état (règles 7 à 11 de la tâche 6). Les cas déjà couverts par la tâche 5 restent dans
// `ConversationChainLifecycleTests.swift` (conclure ou annuler pendant la transcription, la réflexion, la lecture ; second appel ;
// voix en panne ou de secours) ; ceux-ci ajoutent les états qui manquaient, le délai du modèle piloté, le passage ouvert, et la
// façade. « Aucune tâche vivante » est relevé à l'instant de `.finished` (`atFinish`), par des portes qui ne s'ouvrent qu'à
// l'annulation, pas après coup.

private let twoTurns = [TurnScript(base: 0), TurnScript(base: 1_000_000)]

/// Pousse les blocs `blocks` du tour `turn` (rampe), sans le finir.
private func pushPart(of turn: TurnScript, blocks: Range<Int>, into h: ConversationHarness) {
    for block in blocks { h.audio.inner.push(rampChunk((turn.base + block * 1000)..<(turn.base + (block + 1) * 1000))) }
}

/// Ce qui vit encore à l'instant de `.finished` : les attentes de l'aperçu, du chien de garde et de la limite de transcription, et le
/// micro.
private struct Remains: Equatable, Sendable {
    var preview = false
    var watchdog = false
    var transcriptionDeadline = false
    var microphone = false
}

private func remainsAtFinish(_ h: ConversationHarness) -> CallbackBox<Remains> {
    let box = CallbackBox<Remains>()
    let (preview, watchdog, deadline, audio) = (h.previewSleeper, h.watchdogSleeper, h.transcriptionSleeper, h.audio)
    h.atFinish {
        box.set(Remains(preview: preview.isSleeping, watchdog: watchdog.isSleeping, transcriptionDeadline: deadline.isSleeping,
                        microphone: audio.inner.isRunning))
    }
    return box
}

@Suite(.timeLimit(.minutes(1)))
struct ConversationFailureTests {
    // MARK: Règle 7 : le modèle rapide se tait

    /// Le modèle ne dit rien : le délai de la politique de tour (17 s dans la configuration de test, attente pilotée) tranche. Un avis,
    /// le retour à l'écoute, le tour reste dans la conversation et la réponse suivante lui est fusionnée.
    @Test func aSilentFastModelTimesOutAfterTheTurnPolicyDelayAndTheNextAnswerIsMerged() async {
        let h = ConversationHarness(turns: twoTurns, transcripts: texts("t1", "t2"),
                                    fast: [ScriptedModel([]), modelReply("[CONCLURE]\nMerci.")])
        let log = await h.start()
        await h.say(0)
        await h.fast.model(at: 0).started.wait()
        await h.turnSleeper.waitForSleeps(1)
        #expect(h.turnSleeper.requested == [17])
        #expect(log.end == nil && !log.items.contains { if case .notice = $0 { true } else { false } })

        h.turnSleeper.tick()
        await log.wait(.state(.listening), count: 2)

        #expect(log.trace.suffix(2) == [.notice(.modelFailed(.timedOut(17))), .state(.listening)])
        await h.fast.model(at: 0).terminated.wait()
        #expect(h.fast.model(at: 0).wasCancelled)   // la requête abandonnée est fermée
        await h.say(1)
        await log.waitForEnd()
        #expect(h.fast.requests.map(\.input) == ["t1", "t1 t2"])
        #expect(log.end == .prompt("Prompt final", conversation("t1 t2", "Merci.")))
    }

    // MARK: Règle 9 : le micro se tait pendant que la personne parle

    /// Le casque se débranche au milieu d'une phrase : ce qui a été capté du passage ouvert est transcrit, et la fin le rend.
    @Test func aMicrophoneThatStopsWhileThePersonSpeaksKeepsWhatWasAlreadyCaptured() async throws {
        let turn = TurnScript(base: 0)
        let h = ConversationHarness(turns: [turn], transcripts: texts("ce que je disais"))
        let log = await h.start()
        await log.wait(.state(.listening))
        pushPart(of: turn, blocks: 0..<3, into: h)   // la voix s'ouvre au bloc 1, rien ne la ferme
        await log.wait(3, where: isLevel)
        await h.watchdogSleeper.waitForSleeps(1)

        h.clock.advance(by: 10)
        h.watchdogSleeper.tick()
        await log.waitForEnd()

        let call = try #require(h.transcriber.calls.first)
        #expect(call.clip == AudioClip(samples: rampSamples(1000..<3000), sampleRate: 16000))
        #expect(log.end == .failed(.microphone("silent"), conversation("ce que je disais")))
        expectCleanEnd(h)
    }

    // MARK: Règle 10 : conclure et annuler à chaque état

    /// Pendant la préparation (le détecteur se prépare encore) : le micro n'a jamais été ouvert, il ne l'est pas, rien n'a été dit.
    @Test func concludeWhilePreparingEndsWithNothingSaidAndNeverOpensTheMicrophone() async {
        let h = ConversationHarness()
        h.detector.prepareRelease = Gate()   // ne s'ouvre qu'à l'annulation de la préparation
        let log = await h.start()
        await h.detector.prepareEntered.wait()

        await h.chain.conclude()
        let events = await log.waitForEnd()

        #expect(events == [.state(.preparing), .state(.concluding), .state(.finished), .finished(.nothingSaid)])
        #expect(h.audio.inner.log.isEmpty && !h.audio.inner.isRunning)
        #expect(h.previewSleeper.started == 0 && h.watchdogSleeper.started == 0)
        #expect(h.strong.calls == 0)
    }

    @Test func cancelWhilePreparingEndsCancelledAndNeverOpensTheMicrophone() async {
        let h = ConversationHarness()
        h.detector.prepareRelease = Gate()
        let log = await h.start()
        await h.detector.prepareEntered.wait()

        await h.cancel()
        let events = await log.waitForEnd()

        #expect(events == [.state(.preparing), .state(.finished), .finished(.cancelled)])
        #expect(h.audio.inner.log.isEmpty && !h.audio.inner.isRunning)
        #expect(h.previewSleeper.started == 0 && h.watchdogSleeper.started == 0)
    }

    /// Revue de la tâche 6, I-1 (sonde S1) : « conclure » en pleine phrase, transcription finale retenue. Avant même que cette
    /// transcription parte, le micro est arrêté (`stop()` a rendu la main) et la conclusion est annoncée, une seule fois ; la suite
    /// tourne micro fermé. Le chien de garde qui se réveille alors, longtemps après la dernière tranche, ne fait pas de la conclusion
    /// demandée une panne : le modèle fort rédige le prompt.
    @Test func concludeInTheMiddleOfAPassageStopsTheMicrophoneAndAnnouncesTheConclusionBeforeTheFinalTranscription() async throws {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: { _ in .hold })
        let log = await h.start()
        await log.wait(.state(.listening))
        for block in 0..<3 { h.audio.inner.push(rampChunk((block * 1000)..<((block + 1) * 1000))) }
        await log.wait(3, where: isLevel)

        await h.chain.conclude()
        await h.transcriber.waitForCalls(1)   // la fin transcrit le passage ouvert : elle est retenue
        #expect(!h.audio.inner.isRunning && h.journal.count(of: "audio.stop.returned") == 1)
        #expect(log.items.contains(.state(.concluding)))
        for block in 3..<6 { h.audio.inner.push(rampChunk((block * 1000)..<((block + 1) * 1000))) }   // micro fermé : rien n'est livré
        await h.watchdogSleeper.waitForSleeps(1)
        h.clock.advance(by: 10)
        h.watchdogSleeper.tick()
        h.transcriber.release(call: 0, text: "mon besoin")
        await log.waitForEnd()

        #expect(log.end == .prompt("Prompt final", conversation("mon besoin")))
        #expect(h.strong.calls == 1)
        let trace = log.trace
        #expect(trace.filter { $0 == .state(.concluding) }.count == 1)
        let concluding = try #require(trace.firstIndex(of: .state(.concluding)))
        let turnEnded = try #require(trace.firstIndex(of: .turnEnded("mon besoin")))
        #expect(concluding < turnEnded)
        expectCleanEnd(h)
    }

    /// Le moment d'avant : `conclude()` pendant la parole, la fin range la réplique (elle attend la synthèse de la deuxième phrase,
    /// sourde à l'annulation), micro encore ouvert. Le chien de garde s'éveille alors après 10 s sans tranche : une conclusion
    /// demandée ne devient pas une panne du micro.
    @Test func aMicrophoneThatFallsSilentWhileTheReplyIsCutForTheConclusionDoesNotTurnItIntoAFailure() async throws {
        let latch = DeafLatch()
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [question("Un. Deux.")],
                                    speech: ScriptedSpeech(reply: { index, _ in index == 1 ? .deaf(latch) : .clip }),
                                    completion: .manual)
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)
        await h.speech.waitForCalls(2)
        let watchdog = try #require(await h.chain.watchdogTask)

        await h.chain.conclude()
        _ = await waitUntil { await !h.chain.replyActive }   // la fin range la réplique, retenue par la synthèse
        #expect(h.audio.inner.isRunning)
        await h.watchdogSleeper.waitForSleeps(1)
        h.clock.advance(by: 10)
        h.watchdogSleeper.tick()
        await untilDoneOrCancelled { await watchdog.value }   // le chien de garde a regardé le micro, et s'est arrêté
        #expect(await !h.chain.failureIsPending)
        latch.open()
        await log.waitForEnd()

        #expect(log.end == .prompt("Prompt final", conversation("t1")))
        #expect(h.strong.calls == 1)
        expectCleanEnd(h)
    }

    /// I-4 : la personne dicte son besoin et appuie sur « conclure » avant que le silence ait fermé le passage. Le passage est
    /// transcrit et ajouté : la fin n'est pas `.nothingSaid`.
    @Test func concludeWithAnOpenPassageBeforeAnyTurnTranscribesItAndIsNotNothingSaid() async throws {
        let turn = TurnScript(base: 0)
        let h = ConversationHarness(turns: [turn], transcripts: texts("mon besoin"))
        let remains = remainsAtFinish(h)
        let log = await h.start()
        await log.wait(.state(.listening))
        pushPart(of: turn, blocks: 0..<3, into: h)
        await log.wait(3, where: isLevel)

        await h.chain.conclude()
        await log.waitForEnd()

        let call = try #require(h.transcriber.calls.first)
        #expect(call.clip == AudioClip(samples: rampSamples(1000..<3000), sampleRate: 16000))
        #expect(log.items.contains(.turnEnded("mon besoin")))
        #expect(log.end == .prompt("Prompt final", conversation("mon besoin")))
        #expect(h.fast.calls == 0)
        #expect(remains.value == Remains())
        expectCleanEnd(h)
    }

    @Test func concludeWithAnOpenPassageAfterATurnAddsItAfterTheReply() async throws {
        let h = ConversationHarness(turns: twoTurns, transcripts: texts("t1", "t2"), fast: [question("Une question ?")])
        let log = await h.start()
        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        pushPart(of: twoTurns[1], blocks: 0..<3, into: h)   // la voix s'ouvre au bloc 1 du second tour
        await log.wait(9, where: isLevel)

        await h.chain.conclude()
        await log.waitForEnd()

        let call = try #require(h.transcriber.calls.dropFirst().first)
        #expect(call.clip == AudioClip(samples: rampSamples(1_001_000..<1_003_000), sampleRate: 16000))
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Une question ?", "t2")))
        expectCleanEnd(h)
    }

    /// Revue de la tâche 6, m-5 : « conclure » après un tour, avec un passage ouvert dont la transcription échoue. Les tours déjà là
    /// suffisent : le prompt est rédigé sans cette dernière phrase, et un avis le dit (avant la fin), au lieu d'une panne.
    @Test func concludeWhenTheLastWordsCannotBeTranscribedConcludesWithTheEarlierTurnsAndSaysSo() async throws {
        let second = try #require(twoTurns.dropFirst().first)
        let h = ConversationHarness(turns: twoTurns, transcripts: { $0 == 0 ? .text("t1") : .fail(TranscriberError.engine("panne")) },
                                    fast: [question("Une question ?")])
        let log = await h.start()
        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        pushPart(of: second, blocks: 0..<3, into: h)
        await log.wait(9, where: isLevel)

        await h.chain.conclude()
        await log.waitForEnd()

        #expect(h.transcriber.calls.count == 2)
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Une question ?")))
        #expect(log.items.filter { $0 == .notice(.lastWordsLost) }.count == 1)
        #expect(h.strong.calls == 1)
        expectCleanEnd(h)
    }

    /// La même chose quand la transcription de ces derniers mots dépasse son délai (attente pilotée, jamais un vrai délai).
    @Test func concludeWhenTheLastWordsTimeOutConcludesWithTheEarlierTurnsAndSaysSo() async throws {
        let second = try #require(twoTurns.dropFirst().first)
        let h = ConversationHarness(turns: twoTurns, transcripts: { $0 == 0 ? .text("t1") : .hold }, fast: [question("Une question ?")])
        let log = await h.start()
        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        pushPart(of: second, blocks: 0..<3, into: h)
        await log.wait(9, where: isLevel)

        await h.chain.conclude()
        await h.transcriber.waitForCalls(2)
        await h.transcriptionSleeper.waitForSleeps(2)   // la limite de la transcription finale attend
        h.transcriptionSleeper.tick()
        await log.waitForEnd()

        #expect(log.end == .prompt("Prompt final", conversation("t1", "Une question ?")))
        #expect(log.items.contains(.notice(.lastWordsLost)))
        expectCleanEnd(h)
    }

    /// Sans aucun tour avant, il n'y a rien pour conclure : la panne de la transcription reste une panne, sans cet avis.
    @Test func concludeWhenTheOnlyWordsCannotBeTranscribedStillEndsFailed() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: { _ in .fail(TranscriberError.engine("panne")) })
        let log = await h.start()
        await log.wait(.state(.listening))
        for block in 0..<3 { h.audio.inner.push(rampChunk((block * 1000)..<((block + 1) * 1000))) }
        await log.wait(3, where: isLevel)

        await h.chain.conclude()
        await log.waitForEnd()

        #expect(log.end == .failed(.engine(ConversationFailure.Code.transcriptionFailed), Conversation()))
        #expect(!log.items.contains(.notice(.lastWordsLost)))
        #expect(h.strong.calls == 0)
        expectCleanEnd(h)
    }

    @Test func cancelWithAnOpenPassageTranscribesNothing() async {
        let turn = TurnScript(base: 0)
        let h = ConversationHarness(turns: [turn], transcripts: texts("jamais"))
        let log = await h.start()
        await log.wait(.state(.listening))
        pushPart(of: turn, blocks: 0..<3, into: h)
        await log.wait(3, where: isLevel)

        await h.cancel()
        await log.waitForEnd()

        #expect(h.transcriber.calls.isEmpty)
        #expect(log.end == .cancelled && !log.items.contains(where: isTurnEnded))
        expectCleanEnd(h)
    }

    /// Pendant la synthèse de la première phrase : la synthèse est annulée et attendue avant `.finished` (relevé à cet instant), rien
    /// n'a été dit, la conclusion part avec le tour de la personne.
    @Test func concludeWhileTheFirstSentenceIsSynthesizedCancelsTheSynthesisBeforeTheEnd() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [question("Un. Deux.")],
                                    speech: ScriptedSpeech(reply: { _, _ in .hold }))
        let cancelledAtFinish = CallbackBox<Int>()
        let speech = h.speech
        h.atFinish { cancelledAtFinish.set(speech.cancelledCalls) }
        let log = await h.start()
        await h.say(0)
        await h.speech.waitForCalls(1)

        await h.chain.conclude()
        await log.waitForEnd()

        #expect(cancelledAtFinish.value == 1)
        #expect(h.speech.texts == ["Un."] && h.audio.inner.played.isEmpty)
        #expect(!log.items.contains(where: isSpeakingStarted))
        #expect(log.end == .prompt("Prompt final", conversation("t1")))
        expectCleanEnd(h)
    }

    /// Même instant, `cancel()` : la synthèse est annulée et attendue avant `.finished` (relevé à cet instant), rien n'est joué,
    /// aucune question n'est comptée, et le modèle fort n'est jamais sollicité.
    @Test func cancelWhileTheFirstSentenceIsSynthesizedCancelsTheSynthesisBeforeTheEnd() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [question("Un. Deux.")],
                                    speech: ScriptedSpeech(reply: { _, _ in .hold }))
        let cancelledAtFinish = CallbackBox<Int>()
        let speech = h.speech
        h.atFinish { cancelledAtFinish.set(speech.cancelledCalls) }
        let log = await h.start()
        await h.say(0)
        await h.speech.waitForCalls(1)

        await h.cancel()
        await log.waitForEnd()

        #expect(cancelledAtFinish.value == 1)
        #expect(h.speech.texts == ["Un."] && h.audio.inner.played.isEmpty)
        #expect(!log.items.contains(where: isSpeakingStarted))
        #expect(log.end == .cancelled && h.strong.calls == 0)
        expectCleanEnd(h)
    }

    /// Revue de la tâche 6, I-4 (sonde S5) : `conclude()` avec un passage ouvert, moteur de transcription sourd à l'annulation et
    /// retenu ; `cancel()` arrive pendant que la fin attend cette transcription. Il rend la main sans attendre le moteur (seule la
    /// ligne `transcription?.task.cancel()` de `cancel()` le permet : la fin attend la tâche directement), micro fermé, `.cancelled`,
    /// le modèle fort jamais sollicité.
    @Test func cancelDuringTheFinalTranscriptionOfAConclusionWithADeafEngineReturnsAtOnce() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: { _ in .hold }, transcriberHonorsCancellation: false)
        let log = await h.start()
        await log.wait(.state(.listening))
        for block in 0..<3 { h.audio.inner.push(rampChunk((block * 1000)..<((block + 1) * 1000))) }
        await log.wait(3, where: isLevel)
        await h.chain.conclude()
        await h.transcriber.waitForCalls(1)

        await h.cancel()
        await log.waitForEnd()

        #expect(log.end == .cancelled)
        #expect(!h.audio.inner.isRunning)
        #expect(h.strong.calls == 0)
        expectCleanEnd(h)
        h.transcriber.release(call: 0, text: "trop tard")
    }

    /// Pendant la réflexion : à l'instant de `.finished`, aucune attente de l'entretien ne vit (aperçu, chien de garde, limite de
    /// transcription) et le micro est arrêté ; la requête au modèle rapide est fermée par l'annulation. Elle l'est **après** coup :
    /// l'appel au modèle vit dans la tâche de travail de `Deadline`, que `Deadline` annule sans l'attendre (un moteur peut être sourd) ;
    /// relevée à l'instant de `.finished`, sa porte peut être encore fermée (mesuré : fermée lors d'un lancement, le 2026-11-17).
    @Test func cancelWhileThinkingLeavesNoWaitAliveAtTheEndAndClosesTheRequest() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [ScriptedModel([])])
        let remains = remainsAtFinish(h)
        let log = await h.start()
        await h.say(0)
        await h.fast.model(at: 0).started.wait()

        await h.cancel()
        await log.waitForEnd()

        #expect(remains.value == Remains())
        await h.fast.model(at: 0).terminated.wait()
        #expect(h.fast.model(at: 0).wasCancelled)
        #expect(log.end == .cancelled && h.strong.calls == 0)
        expectCleanEnd(h)
    }

    /// Pendant la transcription d'un tour : même chose, la transcription étant annulée (sa porte ne s'ouvre qu'à l'annulation).
    @Test func cancelWhileTheTurnIsTranscribedLeavesNoWaitAliveAtTheEndAndCancelsTheTranscription() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: { _ in .hold })
        let remains = remainsAtFinish(h)
        let log = await h.start()
        await h.say(0)
        await h.transcriber.waitForCalls(1)
        await h.transcriptionSleeper.waitForSleeps(1)   // la limite de temps de la transcription attend

        await h.cancel()
        await log.waitForEnd()

        #expect(remains.value == Remains())
        await h.transcriber.cancellation(of: 0).wait()
        #expect(log.end == .cancelled)
        expectCleanEnd(h)
    }

    // MARK: Règle 11 : la façade

    /// L'appelant ne tient que la façade ; il la lâche sans `cancel()` en lisant encore le flux : l'entretien est annulé, le micro
    /// arrêté une fois, le flux finit sur `.finished(.cancelled)`.
    @Test func aSessionReleasedWithoutCancelStopsTheMicrophoneAndEndsCancelled() async throws {
        let h = ConversationHarness()
        var session: ConversationSession? = ConversationSession(h.chain)
        let stream = try #require(await session?.start())
        let log = EventLog.reading(stream)
        await log.wait(.state(.listening))
        await h.watchdogSleeper.waitForSleeps(1)   // le micro est ouvert

        session = nil
        await log.waitForEnd()

        #expect(session == nil)
        #expect(log.end == .cancelled)
        #expect(h.journal.count(of: "audio.stop") == 1 && !h.audio.inner.isRunning)
        #expect(log.items.last.map(isFinished) == true && log.ended)
    }
}
