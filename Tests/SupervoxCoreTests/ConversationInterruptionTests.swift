import Foundation
import Testing
@testable import SupervoxCore

// L'interruption (règles 2 à 6 et 12 de la tâche 6). Tout tourne sur des doubles, compté en échantillons, jamais en temps machine.
//
// Repères : le tour 0 (`TurnScript(base: 0)`) occupe les blocs globaux 0 à 5 du détecteur. Son passage fermé, l'écoute repart d'une
// ligne de temps neuve : le bloc global 6 porte les échantillons 0 à 999 de cette ligne, le bloc 7 les échantillons 1 000 à 1 999,
// etc. (et c'est encore vrai à la réflexion, qui renouvelle la ligne si aucun passage n'est ouvert). Les événements du détecteur
// (`events:`) sont donnés par rang global de bloc. La porte des tests : 0,30 s à −30 dB, soit 15 trames de 320 échantillons.

private let firstTurn = [TurnScript(base: 0)]

/// Pousse `count` tranches fortes de 1 000 échantillons, la première au rang `from` de la ligne de temps.
private func pushLoud(_ h: ConversationHarness, from: Int, count: Int) {
    for k in 0..<count { h.audio.inner.push(loudChunk((from + k * 1000)..<(from + (k + 1) * 1000))) }
}

private func pushQuiet(_ h: ConversationHarness, from: Int, count: Int) {
    for k in 0..<count { h.audio.inner.push(quietChunk((from + k * 1000)..<(from + (k + 1) * 1000))) }
}

/// Une tranche à −40 dB dont les trames de 320 échantillons de rang multiple de 10 (depuis l'échantillon 0 de la ligne de temps)
/// sont à −20 dB : un clic de 20 ms toutes les 200 ms (sonde S3 de la revue de la tâche 6).
private func clickyChunk(_ range: Range<Int>) -> AudioChunk {
    AudioChunk(samples: range.map { ($0 / 320) % 10 == 0 ? Float(0.1) : Float(0.01) }, sampleRate: 16000)
}

func isInterrupted(_ event: ConversationEvent) -> Bool {
    if case .interrupted = event { return true }
    return false
}

func isSpeakingEnded(_ event: ConversationEvent) -> Bool {
    if case .speakingEnded = event { return true }
    return false
}

func isTurnEnded(_ event: ConversationEvent) -> Bool {
    if case .turnEnded = event { return true }
    return false
}

/// Revue finale, I-A : le premier tour en 5 tranches de 1 500 échantillons (rampe 0..<7 500). Le détecteur reçoit les blocs 0 à 6 ;
/// la voix s'ouvre au bloc 1 (échantillon 1 000) et se ferme au bloc 6 (échantillon 6 000), rendu par la 5e tranche : un rang
/// impair, donc il reste 1 500 × 5 mod 1 000 = 500 échantillons (7 000..<7 500) qui ne remplissent pas encore un bloc.
private let firstTurnInChunksOf1500: [Int: VoiceEvent] = [1: .speechStart(sample: 1000), 6: .speechEnd(sample: 6000)]

private func pushFirstTurnInChunksOf1500(_ h: ConversationHarness, _ log: EventLog) async {
    await log.wait(.state(.listening))
    for k in 0..<5 { h.audio.inner.push(rampChunk((k * 1500)..<((k + 1) * 1500))) }
}

extension ConversationChain {
    /// Pour le test de m-C (revue finale) : sur une réplique vierge, une phrase enregistrée dans la file sans texte, puis `advance()`.
    /// Rend l'état de la file, le sort de la phrase et si la file est libre ; la réplique est remise à neuf ensuite.
    func advanceOverASentenceWithoutText() -> (snapshot: ReplySnapshot, outcome: SentenceOutcome?, idle: Bool) {
        reply = ReplyState()
        let index = reply.queue.register()
        advance()
        let result = (replySnapshot(), reply.outcomes[index], reply.queue.isIdle)
        reply = ReplyState()
        return result
    }

    /// Pour le test de la décision du contrôleur sur I-A : l'état de la ligne d'écoute (échantillons comptés, durée de la ligne de
    /// temps, et si la porte passe depuis l'échantillon 0 sur ce qu'elle a reçu).
    func listeningLineState() -> (samples: Int, duration: Double, gatePassesFromZero: Bool) {
        (timelineSamples, timeline.duration, gate.passes(from: 0, to: .max))
    }
}

/// Termine les clips en file un à un (mode `.manual`), jusqu'au `upTo`-ième accepté par `play`.
private func playAll(_ h: ConversationHarness, upTo plays: Int) async {
    for played in stride(from: 1, through: plays, by: 1) {   // vide pour 0 ou moins, jamais fatal
        await h.audio.plays.wait(atLeast: played)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ConversationInterruptionTests {
    // MARK: Règle 2 : l'écho

    /// Pendant la parole, le détecteur annonce de la voix sur 5 s d'un signal à −40 dB (l'écho de l'outil) : la parole n'est jamais
    /// coupée, la réplique est lue en entier.
    @Test func anEchoBelowTheLevelNeverInterruptsAndTheReplyIsReadInFull() async {
        let h = ConversationHarness(turns: firstTurn, transcripts: texts("t1"), fast: [question("Un. Deux.")], completion: .manual,
                                    events: [6: .speechStart(sample: 0)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        for _ in 0..<80 { h.audio.inner.push(constantChunk(0.01)) }   // 80 × 1 000 échantillons = 5 s
        await log.wait(6 + 80, where: isLevel)

        #expect(h.detector.blocks.count == 86)   // l'écho est bien passé au détecteur, qui l'annonce comme de la voix
        #expect(h.audio.inner.stopPlaybackCount == 0)
        #expect(!log.items.contains(where: isInterrupted))
        await playAll(h, upTo: 2)
        await log.wait(.speakingEnded(heard: "Un. Deux."))
        #expect(h.audio.inner.stopPlaybackCount == 0)
        await finish(h)
    }

    /// Le même détecteur sur un signal à −20 dB coupe la parole dès que 0,30 s de ce signal a été reçu depuis le début du passage :
    /// 4 000 échantillons ne suffisent pas, 5 000 (dont 15 trames complètes) oui.
    @Test func theSameVoiceAboveTheLevelInterruptsAfterThirtyHundredthsOfASecondOfSamples() async {
        let h = ConversationHarness(turns: firstTurn, transcripts: texts("t1"), fast: [question("Un. Deux.")], completion: .manual,
                                    events: [6: .speechStart(sample: 0)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        for _ in 0..<4 { h.audio.inner.push(constantChunk(0.1)) }
        await log.wait(6 + 4, where: isLevel)
        #expect(h.audio.inner.stopPlaybackCount == 0 && !log.items.contains(where: isInterrupted))

        h.audio.inner.push(constantChunk(0.1))
        await log.wait(where: isInterrupted)
        #expect(h.audio.inner.stopPlaybackCount == 1)
        #expect(h.detector.blocks.count == 11)   // c'est le cinquième bloc qui a décidé
        await finish(h)
    }

    /// La durée et le niveau viennent de la configuration : à 0,1 s et −45 dB, un signal à −40 dB coupe après 2 000 échantillons (6
    /// trames) et pas après 1 000 (3 trames). Avec la porte par défaut des autres tests (0,30 s, −30 dB), il ne couperait jamais.
    @Test func theInterruptionNumbersAreThoseOfTheConfiguration() async {
        let h = ConversationHarness(turns: firstTurn, transcripts: texts("t1"), fast: [question("Un. Deux.")], completion: .manual,
                                    config: makeConversationConfig(interruptMinDuration: 0.1, interruptLevel: -45),
                                    events: [6: .speechStart(sample: 0)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        h.audio.inner.push(constantChunk(0.01))
        await log.wait(6 + 1, where: isLevel)
        #expect(!log.items.contains(where: isInterrupted))
        h.audio.inner.push(constantChunk(0.01))
        await log.wait(where: isInterrupted)
        #expect(h.audio.inner.stopPlaybackCount == 1)
        await finish(h)
    }

    /// Revue de la tâche 6, I-2 (sonde S3) : un passage ouvert par le détecteur sur l'écho (−40 dB), et un clic de 20 ms à −20 dB
    /// toutes les 200 ms pendant 3,2 s (16 clics, plus que les 15 trames de la porte). Dispersés, ils ne coupent jamais : il n'y en a
    /// jamais plus de 3 dans la fenêtre de 0,60 s. La réplique est lue en entier.
    @Test func clicksSpreadOverAnEchoPassageNeverInterrupt() async {
        let h = ConversationHarness(turns: firstTurn, transcripts: texts("t1"), fast: [question("Un. Deux.")], completion: .manual,
                                    events: [6: .speechStart(sample: 0)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        for k in 0..<50 { h.audio.inner.push(clickyChunk((k * 1000)..<((k + 1) * 1000))) }
        await log.wait(6 + 50, where: isLevel)

        #expect(h.detector.blocks.count == 56)
        #expect(h.audio.inner.stopPlaybackCount == 0)
        #expect(!log.items.contains(where: isInterrupted))
        await playAll(h, upTo: 2)
        await log.wait(.speakingEnded(heard: "Un. Deux."))
        await finish(h)
    }

    // MARK: Règle 3 : au milieu d'une phrase

    @Test func anInterruptionInTheMiddleOfASentenceStopsThePlaybackOnceAndKeepsWhatWasHeard() async throws {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "t2"),
            fast: [question("Un. Deux. Trois. Quatre. Cinq."), modelReply("[CONCLURE]\nMerci.")], completion: .manual,
            events: [6: .speechStart(sample: 0), 13: .speechEnd(sample: 8000)])
        let log = await h.start()
        await h.say(0)
        await playAll(h, upTo: 2)
        await log.wait(.sentencePlayed("Deux."))
        await h.audio.plays.wait(atLeast: 4)   // « Trois. » joue, « Quatre. » attend derrière, « Cinq. » attend sa synthèse

        h.audio.inner.scriptedPosition = 0.002   // « Trois. » est coupée à 20 % de sa durée : moins de la moitié, pas entendue
        pushLoud(h, from: 0, count: 5)
        await log.wait(where: isInterrupted)

        #expect(h.audio.inner.stopPlaybackCount == 1)
        #expect(log.items.filter(isInterrupted) == [.interrupted(heard: "Un. Deux.")])
        await log.wait(.state(.listening), count: 2)
        let trace = log.trace
        let interrupted = try #require(trace.firstIndex(where: isInterrupted))
        let listening = try #require(trace.lastIndex(of: .state(.listening)))
        #expect(interrupted < listening)
        #expect(!trace.contains(where: isSpeakingEnded))   // la réplique coupée n'a pas de fin ordinaire
        pushLoud(h, from: 5000, count: 3)   // le passage qui a coupé continue, puis se ferme
        await h.audio.plays.wait(atLeast: 5)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.waitForEnd()

        // La file a été vidée : rien après « Quatre. », ni synthèse ni lecture, hors de la réplique suivante.
        #expect(h.speech.texts == ["Un.", "Deux.", "Trois.", "Quatre.", "Merci."])
        #expect(h.audio.inner.played.count == 5)
        let second = try #require(h.fast.requests.dropFirst().first)
        #expect(second.input == "t2")
        #expect(second.history == [CompletionTurn(role: .user, text: "t1"), CompletionTurn(role: .assistant, text: "Un. Deux.")])
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Un. Deux.", "t2", "Merci.")))
    }

    /// Revue de la tâche 6, m-2 : `conclude()` arrive pendant que la réplique coupée se range (elle attend la synthèse de la deuxième
    /// phrase, sourde à l'annulation). L'écoute ne reprend pas : aucun `.state(.listening)` après l'interruption, la conclusion suit.
    @Test func aConcludeThatArrivesWhileTheInterruptedReplyIsPutAwayDoesNotResumeListening() async throws {
        let latch = DeafLatch()
        let h = ConversationHarness(turns: firstTurn, transcripts: texts("t1", "t2"), fast: [question("Un. Deux.")],
                                    speech: ScriptedSpeech(reply: { index, _ in index == 1 ? .deaf(latch) : .clip }),
                                    completion: .manual, events: [6: .speechStart(sample: 0)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)
        await h.speech.waitForCalls(2)   // « Deux. » est en synthèse, sourde

        pushLoud(h, from: 0, count: 5)
        _ = await waitUntil { await !h.chain.replyActive }   // la porte a coupé : la réplique se range, retenue par la synthèse
        await h.chain.conclude()
        latch.open()
        await log.waitForEnd()

        let trace = log.trace
        let interrupted = try #require(trace.firstIndex(where: isInterrupted))
        #expect(!trace[interrupted...].contains(.state(.listening)))
        #expect(trace.contains(.state(.concluding)))
        #expect(log.end == .prompt("Prompt final", conversation("t1 t2")))   // rien d'entendu : le tour qui coupe est fusionné
    }

    // MARK: Règle 4 : le passage qui coupe est gardé

    /// Le passage commence au milieu d'une trame (échantillon 1 000) : la porte ne compte que les trames qui commencent après, et coupe
    /// au sixième bloc fort. Le passage est ensuite transcrit depuis son début, remplissage compris (ici 1 000 échantillons, l'audio
    /// faible qui le précède), pas depuis l'instant où il a coupé.
    @Test func thePassageThatInterruptsIsTranscribedFromItsStartMinusThePadding() async throws {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "t2"), fast: [question("Un."), modelReply("[CONCLURE]\nMerci.")],
            completion: .manual, config: makeConversationConfig(padding: 0.0625),
            events: [7: .speechStart(sample: 1000), 14: .speechEnd(sample: 9000)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        pushQuiet(h, from: 0, count: 1)
        pushLoud(h, from: 1000, count: 5)
        await log.wait(6 + 6, where: isLevel)
        #expect(!log.items.contains(where: isInterrupted))   // trames 4 à 17 : 14 seulement
        pushLoud(h, from: 6000, count: 1)
        await log.wait(where: isInterrupted)
        pushLoud(h, from: 7000, count: 2)
        await log.wait(.turnEnded("t2"))

        let call = try #require(h.transcriber.calls.dropFirst().first)
        #expect(call.clip == AudioClip(samples: quietSamples(0..<1000) + loudSamples(1000..<9000), sampleRate: 16000))
        await finish(h)
    }

    // MARK: Règle 5 : rien de capté pendant la parole n'est transcrit sans interruption

    @Test func aPassageOpenedAndClosedDuringTheSpeechBelowTheLevelIsNeverTranscribed() async {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "t2"), fast: [question("Un."), modelReply("[CONCLURE]\nMerci.")],
            completion: .manual,
            events: [6: .speechStart(sample: 0), 9: .speechEnd(sample: 3000), 11: .speechStart(sample: 1000), 15: .speechEnd(sample: 4000)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        pushQuiet(h, from: 0, count: 4)   // blocs 6 à 9 : un passage faible, ouvert et fermé pendant la parole
        await log.wait(6 + 4, where: isLevel)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.wait(.speakingEnded(heard: "Un."))
        for block in 0..<6 { h.audio.inner.push(rampChunk((1_000_000 + block * 1000)..<(1_000_000 + (block + 1) * 1000))) }
        await h.audio.plays.wait(atLeast: 2)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.waitForEnd()

        #expect(h.audio.inner.stopPlaybackCount == 0)
        #expect(h.transcriber.calls.map(\.clip) == [
            h.expectedClip(turn: 0), AudioClip(samples: rampSamples(1_001_000..<1_004_000), sampleRate: 16000)])
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Un.", "t2", "Merci.")))
    }

    /// Règle 5 amendée (revue de la tâche 6, I-3) : un passage encore ouvert à la fin de la parole ne compte qu'à partir de là
    /// (échantillon 2 000), et seulement si la porte passe sur ce qui suit. Ici l'écho (−40 dB) continue 6 000 échantillons : plus long
    /// que 0,30 s, mais jamais au niveau. Il est jeté : ni transcription, ni « pas compris », ni tour fantôme.
    @Test func anEchoPassageStillOpenAtTheEndOfTheSpeechIsDroppedHoweverLongItLasts() async {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "fantôme"), fast: [question("Un.")], completion: .manual,
            events: [6: .speechStart(sample: 0), 13: .speechEnd(sample: 8000)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        pushQuiet(h, from: 0, count: 2)
        h.audio.inner.finishPlayback(.played)   // après les deux tranches, dans l'ordre du flux : la parole finit à l'échantillon 2 000
        h.audio.inner.flushEnds()
        await log.wait(.speakingEnded(heard: "Un."))
        pushQuiet(h, from: 2000, count: 6)
        await log.wait(6 + 8, where: isLevel)   // le bloc qui ferme le passage est traité
        await h.chain.conclude()   // la fin attend toute transcription lancée : un tour fantôme y serait
        await log.waitForEnd()

        #expect(h.transcriber.calls.map(\.clip) == [h.expectedClip(turn: 0)])
        #expect(!log.items.contains(.notice(.notUnderstood)))
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Un.")))
    }

    /// La borne : 15 trames au niveau qui commencent après la fin de la parole (trames 7 à 21, de 2 240 à 7 040) et finissent avec le
    /// passage (échantillon 7 040) suffisent. Le passage est transcrit depuis la fin de la parole jusqu'à sa fin plus le remplissage
    /// (1 000 échantillons), sans rien de ce qui a été capté pendant la parole.
    @Test func aPassageStillOpenAtTheEndOfTheSpeechWithExactlyTheGateAfterItIsKeptWithThePadding() async throws {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "t2"), fast: [question("Un."), modelReply("[CONCLURE]\nMerci.")],
            completion: .manual, config: makeConversationConfig(padding: 0.0625),
            events: [6: .speechStart(sample: 0), 14: .speechEnd(sample: 7040)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        pushQuiet(h, from: 0, count: 2)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.wait(.speakingEnded(heard: "Un."))
        pushLoud(h, from: 2000, count: 7)
        await log.wait(.turnEnded("t2"))

        let call = try #require(h.transcriber.calls.dropFirst().first)
        #expect(call.clip == AudioClip(samples: loudSamples(2000..<8040), sampleRate: 16000))
        await finish(h)
    }

    /// Une trame de moins : le passage se ferme à 6 720, 14 trames au niveau seulement entre la fin de la parole et sa fin (la trame
    /// forte qui suit la fin du passage ne compte pas). Il est jeté.
    @Test func aPassageStillOpenAtTheEndOfTheSpeechOneFrameShortOfTheGateIsDropped() async {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "t2"), fast: [question("Un.")], completion: .manual,
            events: [6: .speechStart(sample: 0), 13: .speechEnd(sample: 6720)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        pushQuiet(h, from: 0, count: 2)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.wait(.speakingEnded(heard: "Un."))
        pushLoud(h, from: 2000, count: 6)
        await log.wait(6 + 8, where: isLevel)
        await h.chain.conclude()
        await log.waitForEnd()

        #expect(h.transcriber.calls.map(\.clip) == [h.expectedClip(turn: 0)])
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Un.")))
    }

    /// Revue finale, m-F : le cas positif à la fin de l'entretien. Le passage, encore ouvert à la fin de la parole (échantillon
    /// 2 000), continue au niveau sur 7 000 échantillons sans se fermer : la porte passe sur ce qui suit la fin de la parole.
    /// « Conclure » le transcrit depuis la fin de la parole jusqu'au dernier échantillon reçu, et la conclusion le contient.
    @Test func aPassageStillOpenAtTheEndOfTheSpeechThatPassesTheGateIsTranscribedWhenConcluding() async throws {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "t2"), fast: [question("Un.")], completion: .manual,
            events: [6: .speechStart(sample: 0)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        pushQuiet(h, from: 0, count: 2)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.wait(.speakingEnded(heard: "Un."))
        pushLoud(h, from: 2000, count: 7)
        await log.wait(6 + 9, where: isLevel)
        await h.chain.conclude()
        await log.waitForEnd()

        let call = try #require(h.transcriber.calls.dropFirst().first)
        #expect(call.clip == AudioClip(samples: loudSamples(2000..<9000), sampleRate: 16000))
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Un.", "t2")))
    }

    /// L'aperçu ne montre pas non plus un passage rebasé tant que la porte n'a pas passé : l'écho qui traîne après la parole n'est
    /// jamais envoyé au moteur de transcription.
    @Test func anEchoPassageStillOpenAtTheEndOfTheSpeechIsNeverPreviewed() async {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "fantôme"), fast: [question("Un.")], completion: .manual,
            events: [6: .speechStart(sample: 0)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        pushQuiet(h, from: 0, count: 2)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.wait(.speakingEnded(heard: "Un."))
        pushQuiet(h, from: 2000, count: 6)
        await log.wait(6 + 8, where: isLevel)
        _ = await waitUntil { () async -> Bool in h.previewSleeper.isSleeping }   // l'aperçu a repris avec l'écoute
        let sleeps = h.previewSleeper.started
        h.previewSleeper.tick()
        await h.previewSleeper.waitForSleeps(sleeps + 1)   // la passe est finie, la suivante attend

        #expect(h.transcriber.calls.map(\.clip) == [h.expectedClip(turn: 0)])
        #expect(!log.items.contains(where: isPartial))
        await finish(h)
    }

    // MARK: Règle 6 : coupé avant la première phrase

    @Test func anInterruptionWhileThinkingCancelsTheRequestAddsNothingAndMergesTheNextTurn() async {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "t2"), fast: [ScriptedModel([]), modelReply("[CONCLURE]\nMerci.")],
            events: [6: .speechStart(sample: 0), 12: .speechEnd(sample: 7000)])
        let log = await h.start()
        await h.say(0)
        await h.fast.model(at: 0).started.wait()   // la requête est partie, rien ne vient

        pushLoud(h, from: 0, count: 5)
        await log.wait(where: isInterrupted)
        await h.fast.model(at: 0).terminated.wait()
        #expect(h.fast.model(at: 0).wasCancelled)
        #expect(log.items.filter(isInterrupted) == [.interrupted(heard: "")])
        #expect(!log.items.contains(where: isSpeakingStarted))
        pushLoud(h, from: 5000, count: 2)
        await log.waitForEnd()

        #expect(h.fast.requests.map(\.input) == ["t1", "t1 t2"])   // rien pour l'intervieweur : la réponse est fusionnée
        #expect(h.fast.requests.map(\.instruction) == Array(repeating: InterviewPrompt.instruction(remainingQuestions: 8), count: 2))
        #expect(log.items.filter(isSpeakingStarted) == [.speakingStarted(question: 0)])   // seule la phrase de fin, aucune question
        #expect(log.end == .prompt("Prompt final", conversation("t1 t2", "Merci.")))
    }

    @Test func anInterruptionWhileTheFirstSentenceIsSynthesizedCancelsTheRequestAndTheSynthesis() async {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "t2"),
            fast: [ScriptedModel([.text("[SUITE]\nUn. Deux.")]), modelReply("[CONCLURE]\nMerci.")],
            speech: ScriptedSpeech(reply: { index, _ in index == 0 ? .hold : .clip }),
            events: [6: .speechStart(sample: 0), 12: .speechEnd(sample: 7000)])
        let log = await h.start()
        await h.say(0)
        await h.speech.waitForCalls(1)

        pushLoud(h, from: 0, count: 5)
        await log.wait(where: isInterrupted)

        #expect(h.speech.cancelledCalls == 1)
        await h.fast.model(at: 0).terminated.wait()
        #expect(h.fast.model(at: 0).wasCancelled)
        #expect(h.speech.texts == ["Un."] && h.audio.inner.played.isEmpty)
        #expect(log.items.filter(isInterrupted) == [.interrupted(heard: "")])
        #expect(!log.items.contains(where: isSpeakingStarted))
        pushLoud(h, from: 5000, count: 2)
        await log.waitForEnd()

        #expect(h.fast.requests.map(\.input) == ["t1", "t1 t2"])
        #expect(h.fast.requests.map(\.instruction) == Array(repeating: InterviewPrompt.instruction(remainingQuestions: 8), count: 2))
        #expect(log.end == .prompt("Prompt final", conversation("t1 t2", "Merci.")))
    }

    /// La première phrase a commencé à être jouée (son clip est parti à `play()`, la file était vide), puis la personne coupe avant
    /// qu'elle finisse : la question compte (elle a commencé à être entendue), mais rien n'en est entendu en entier, donc rien n'entre
    /// pour l'intervieweur et la réponse suivante est fusionnée au tour d'avant.
    /// Règles 3 et 6 amendées (revue de la tâche 6, m-9 et m-10) : la première phrase (« Un. », un clip de 0,01 s) est coupée à 40 %
    /// de sa durée (position lue avant `stopPlayback()`). Moins de la moitié : rien n'est entendu, la question ne compte pas (la
    /// requête suivante a encore 8 questions), le tour suivant est fusionné au précédent.
    @Test func anInterruptionBeforeHalfOfTheFirstSentenceHearsNothingAndDoesNotCountTheQuestion() async {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "t2"), fast: [question("Un. Deux."), modelReply("[CONCLURE]\nMerci.")],
            completion: .manual, events: [6: .speechStart(sample: 0), 12: .speechEnd(sample: 7000)])
        let log = await h.start()
        await h.say(0)
        await log.wait(.speakingStarted(question: 1))

        h.audio.inner.scriptedPosition = 0.004   // 40 % de 160 échantillons à 16 kHz
        pushLoud(h, from: 0, count: 5)
        await log.wait(where: isInterrupted)
        #expect(log.items.filter(isInterrupted) == [.interrupted(heard: "")])
        pushLoud(h, from: 5000, count: 2)
        await h.audio.plays.wait(atLeast: 3)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.waitForEnd()

        #expect(h.fast.requests.map(\.input) == ["t1", "t1 t2"])
        #expect(h.fast.requests.map(\.instruction) == [InterviewPrompt.instruction(remainingQuestions: 8),
                                                       InterviewPrompt.instruction(remainingQuestions: 8)])
        #expect(log.end == .prompt("Prompt final", conversation("t1 t2", "Merci.")))
    }

    /// La même coupure à 60 % : plus de la moitié a été jouée, la phrase est entendue en entier (dans `heard` et la conversation), la
    /// question compte, et le tour suivant est une réponse à part.
    @Test func anInterruptionAfterHalfOfTheFirstSentenceHearsItAndCountsTheQuestion() async {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "t2"), fast: [question("Un. Deux."), modelReply("[CONCLURE]\nMerci.")],
            completion: .manual, events: [6: .speechStart(sample: 0), 12: .speechEnd(sample: 7000)])
        let log = await h.start()
        await h.say(0)
        await log.wait(.speakingStarted(question: 1))

        h.audio.inner.scriptedPosition = 0.006   // 60 %
        pushLoud(h, from: 0, count: 5)
        await log.wait(where: isInterrupted)
        #expect(log.items.filter(isInterrupted) == [.interrupted(heard: "Un.")])
        pushLoud(h, from: 5000, count: 2)
        await h.audio.plays.wait(atLeast: 3)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.waitForEnd()

        #expect(h.fast.requests.map(\.input) == ["t1", "t2"])
        #expect(h.fast.requests.map(\.instruction) == [InterviewPrompt.instruction(remainingQuestions: 8),
                                                       InterviewPrompt.instruction(remainingQuestions: 7)])
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Un.", "t2", "Merci.")))
    }

    /// Revue finale, m-F : la borne. Coupée à 50 % exactement de sa durée (0,005 s d'un clip de 0,01 s, égalité exacte en virgule
    /// flottante : la moitié d'un double est exacte), la phrase est entendue : la règle dit « la moitié au moins ».
    @Test func anInterruptionAtExactlyHalfOfTheFirstSentenceHearsIt() async {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "t2"), fast: [question("Un. Deux."), modelReply("[CONCLURE]\nMerci.")],
            completion: .manual, events: [6: .speechStart(sample: 0), 12: .speechEnd(sample: 7000)])
        let log = await h.start()
        await h.say(0)
        await log.wait(.speakingStarted(question: 1))

        h.audio.inner.scriptedPosition = 0.005   // 50 %
        pushLoud(h, from: 0, count: 5)
        await log.wait(where: isInterrupted)
        #expect(log.items.filter(isInterrupted) == [.interrupted(heard: "Un.")])
        pushLoud(h, from: 5000, count: 2)
        await h.audio.plays.wait(atLeast: 3)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.waitForEnd()

        #expect(h.fast.requests.map(\.instruction) == [InterviewPrompt.instruction(remainingQuestions: 8),
                                                       InterviewPrompt.instruction(remainingQuestions: 7)])
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Un.", "t2", "Merci.")))
    }

    /// Revue finale, m-A : « Un. » et « Deux. » (deux clips de 0,01 s) sont en file ; « Un. » finit à l'instant même où la position
    /// est lue (sa fin est livrée, la position rendue est celle de sa fin, 0,01 s). Cette position est celle de « Un. » : elle ne
    /// fait pas entendre « Deux. », à peine commencée.
    @Test func aClipThatEndsWhileThePositionIsReadDoesNotMakeTheNextSentenceHeard() async {
        let h = ConversationHarness(turns: firstTurn, transcripts: texts("t1"), fast: [question("Un. Deux.")], completion: .manual,
                                    events: [6: .speechStart(sample: 0)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 2)

        let inner = h.audio.inner
        inner.scriptedPosition = 0.01
        h.audio.onPositionRead {
            inner.finishPlayback(.played)
            inner.flushEnds()
        }
        pushLoud(h, from: 0, count: 5)
        await log.wait(where: isInterrupted)

        #expect(log.items.filter(isInterrupted) == [.interrupted(heard: "Un.")])
        await finish(h)
    }

    // MARK: Règle 12 : un passage né pendant la transcription du tour

    /// La personne reprend pendant que son tour est transcrit, assez fort et assez longtemps : ce passage est gardé depuis son début et
    /// fusionné au tour, et la réflexion attend qu'il soit fini.
    @Test func aPassageBornDuringTheTranscriptionThatReachesTheGateIsMergedIntoTheTurn() async throws {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: { $0 == 0 ? .hold : .text("t2") }, fast: [modelReply("[CONCLURE]\nMerci.")],
            events: [6: .speechStart(sample: 0), 12: .speechEnd(sample: 7000)])
        let log = await h.start()
        await h.say(0)
        await h.transcriber.waitForCalls(1)

        pushLoud(h, from: 0, count: 5)
        await log.wait(6 + 5, where: isLevel)
        h.transcriber.release(call: 0, text: "t1")
        await log.wait(.turnEnded("t1"))
        pushLoud(h, from: 5000, count: 2)
        await log.waitForEnd()

        let call = try #require(h.transcriber.calls.dropFirst().first)
        #expect(call.clip == AudioClip(samples: loudSamples(0..<7000), sampleRate: 16000))
        let trace = log.trace
        let first = try #require(trace.firstIndex(of: .turnEnded("t1")))
        let second = try #require(trace.firstIndex(of: .turnEnded("t2")))
        let thinking = try #require(trace.firstIndex(of: .state(.thinking)))
        #expect(first < second && second < thinking)   // aucune réflexion sur « t1 » seul
        #expect(h.fast.requests.map(\.input) == ["t1 t2"])
        #expect(log.end == .prompt("Prompt final", conversation("t1 t2", "Merci.")))
    }

    @Test func aPassageBornDuringTheTranscriptionBelowTheGateIsDropped() async {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: { $0 == 0 ? .hold : .text("jamais") }, fast: [modelReply("[CONCLURE]\nMerci.")],
            events: [6: .speechStart(sample: 0), 8: .speechEnd(sample: 3000)])
        let log = await h.start()
        await h.say(0)
        await h.transcriber.waitForCalls(1)

        pushQuiet(h, from: 0, count: 3)
        await log.wait(6 + 3, where: isLevel)
        h.transcriber.release(call: 0, text: "t1")
        await log.waitForEnd()

        #expect(h.transcriber.calls.count == 1)
        #expect(h.fast.requests.map(\.input) == ["t1"])
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Merci.")))
    }

    /// Le passage naît pendant la transcription, sous le seuil ; la réflexion commence (la ligne de temps n'est PAS remise à neuf : un
    /// passage est ouvert), puis il atteint le seuil : la requête est annulée, et le passage est transcrit depuis son début, né avant la
    /// réflexion.
    @Test func aPassageBornDuringTheTranscriptionKeepsItsStartWhenItInterruptsTheThinking() async throws {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: { $0 == 0 ? .hold : .text("t2") },
            fast: [ScriptedModel([]), modelReply("[CONCLURE]\nMerci.")],
            events: [6: .speechStart(sample: 0), 12: .speechEnd(sample: 7000)])
        let log = await h.start()
        await h.say(0)
        await h.transcriber.waitForCalls(1)

        pushLoud(h, from: 0, count: 2)
        await log.wait(6 + 2, where: isLevel)
        h.transcriber.release(call: 0, text: "t1")
        await h.fast.model(at: 0).started.wait()
        pushLoud(h, from: 2000, count: 3)
        await log.wait(where: isInterrupted)
        await h.fast.model(at: 0).terminated.wait()
        #expect(h.fast.model(at: 0).wasCancelled)
        pushLoud(h, from: 5000, count: 2)
        await log.waitForEnd()

        let call = try #require(h.transcriber.calls.dropFirst().first)
        #expect(call.clip == AudioClip(samples: loudSamples(0..<7000), sampleRate: 16000))
        #expect(h.fast.requests.map(\.input) == ["t1", "t1 t2"])
    }

    // MARK: Remise à neuf de la ligne de temps avec un reste non découpé (revue finale, I-A)

    /// Site de la fin de `hear` : le passage du premier tour se ferme alors que 500 échantillons (7 000..<7 500) ne remplissent pas
    /// encore un bloc ; la ligne de temps est remise à neuf (bloc 7) avec ce reste. La personne reprend pendant que son tour est
    /// transcrit : le détecteur annonce le passage à l'échantillon 0 de la ligne neuve, la porte passe, et le passage, fusionné au
    /// tour, est transcrit depuis ces 500 échantillons.
    @Test func audioNotYetInABlockWhenTheTimelineIsRenewedStartsTheNextTurn() async throws {
        let h = ConversationHarness(
            transcripts: { $0 == 0 ? .hold : .text("t2") }, fast: [modelReply("[CONCLURE]\nMerci.")],
            events: firstTurnInChunksOf1500.merging([7: .speechStart(sample: 0), 13: .speechEnd(sample: 7000)]) { _, added in added })
        let log = await h.start()
        await pushFirstTurnInChunksOf1500(h, log)
        await h.transcriber.waitForCalls(1)
        #expect(h.detector.resetMarks == [0, 7])   // la fin de `hear` seule, le reste en attente devant le bloc 7

        pushLoud(h, from: 0, count: 7)
        await log.wait(5 + 7, where: isLevel)
        h.transcriber.release(call: 0, text: "t1")
        await log.waitForEnd()

        #expect(h.transcriber.calls.first?.clip == AudioClip(samples: rampSamples(1000..<6000), sampleRate: 16000))
        let call = try #require(h.transcriber.calls.dropFirst().first)
        #expect(call.clip == AudioClip(samples: rampSamples(7000..<7500) + loudSamples(0..<6500), sampleRate: 16000))
        #expect(log.end == .prompt("Prompt final", conversation("t1 t2", "Merci.")))
    }

    /// Décision du contrôleur sur I-A : à la fin d'une réplique (`finishReply`), le reste n'est PAS reporté. Il a été capté pendant
    /// que l'outil parlait : il relève de la porte, et l'outil ne doit pas s'entendre lui-même. Ici 1 500 échantillons forts sont
    /// captés pendant la parole (un bloc, plus un reste de 500), puis la réplique finit. La ligne de temps, son compte et la porte
    /// repartent de zéro, alignés (porte réglée à une trame : un reste reporté la ferait passer). Le tour suivant, annoncé à
    /// l'échantillon `start` de la ligne neuve avec 1 000 échantillons de remplissage, commence par son propre premier échantillon :
    /// le reste n'est ni dans le passage (`start` 0) ni dans le remplissage (`start` 500).
    @Test(arguments: [0, 500])
    func audioCapturedWhileTheReplyIsSpokenIsNotCarriedIntoTheNextTurn(start: Int) async throws {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "t2"), fast: [question("Un."), modelReply("[CONCLURE]\nMerci.")],
            completion: .manual, config: makeConversationConfig(padding: 0.0625, interruptMinDuration: 0.02),
            events: [7: .speechStart(sample: start), 11: .speechEnd(sample: 4000)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        h.audio.inner.push(loudChunk(0..<1500))   // pendant la parole : le bloc 6, et un reste de 500
        await log.wait(6 + 1, where: isLevel)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.wait(.state(.listening), count: 2)
        #expect(h.detector.resetMarks == [0, 6, 6, 7])   // talk, fin de `hear`, `proceed`, `finishReply`
        let renewed = await h.chain.listeningLineState()
        #expect(renewed.samples == 0 && renewed.duration == 0 && !renewed.gatePassesFromZero)

        for k in 0..<5 { h.audio.inner.push(rampChunk((1_000_000 + k * 1000)..<(1_000_000 + (k + 1) * 1000))) }
        await h.audio.plays.wait(atLeast: 2)   // « Merci. »
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.waitForEnd()

        let call = try #require(h.transcriber.calls.dropFirst().first)
        #expect(call.clip == AudioClip(samples: rampSamples(1_000_000..<1_005_000), sampleRate: 16000))
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Un.", "t2", "Merci.")))
    }

    /// Revue finale, m-3 : le site de la fin de `hear` pendant une réplique. Pendant la parole, 4 500 échantillons forts (trois
    /// tranches de 1 500) : un passage `.busy` s'ouvre au bloc 6 et se ferme au bloc 9, trop court pour la porte (14 trames sur 15) ;
    /// il reste 500 échantillons (4 000..<4 500) qui ne remplissent pas un bloc. La fin de `hear` remet la ligne à neuf en les
    /// reportant, la réplique durant encore. La personne se tait, la réplique finit : aucune interruption, `finishReply` jette ce
    /// reste, et le tour suivant ne contient rien de l'audio capté pendant la réplique.
    @Test func aPassageClosedDuringTheReplyCarriesItsTailUnderTheGate() async throws {
        let h = ConversationHarness(
            turns: firstTurn, transcripts: texts("t1", "t2"), fast: [question("Un."), modelReply("[CONCLURE]\nMerci.")],
            completion: .manual, config: makeConversationConfig(padding: 0.0625),
            events: [6: .speechStart(sample: 0), 9: .speechEnd(sample: 3000), 10: .speechStart(sample: 0), 14: .speechEnd(sample: 4000)])
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)

        for k in 0..<3 { h.audio.inner.push(loudChunk((k * 1500)..<((k + 1) * 1500))) }
        await log.wait(6 + 3, where: isLevel)
        #expect(h.detector.resetMarks == [0, 6, 6, 10])   // talk, fin de `hear`, `proceed`, fin de `hear` pendant la réplique
        let carried = await h.chain.listeningLineState()
        #expect(carried.samples == 500 && !carried.gatePassesFromZero)   // le reste est reporté, sous la porte
        #expect(!log.items.contains(where: isInterrupted))

        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.wait(.state(.listening), count: 2)
        #expect(h.detector.resetMarks == [0, 6, 6, 10, 10])   // `finishReply`
        let renewed = await h.chain.listeningLineState()
        #expect(renewed.samples == 0 && renewed.duration == 0 && !renewed.gatePassesFromZero)

        for k in 0..<5 { h.audio.inner.push(rampChunk((1_000_000 + k * 1000)..<(1_000_000 + (k + 1) * 1000))) }
        await h.audio.plays.wait(atLeast: 2)   // « Merci. »
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.waitForEnd()

        #expect(h.audio.inner.stopPlaybackCount == 0)
        #expect(!log.items.contains(where: isInterrupted))
        let call = try #require(h.transcriber.calls.dropFirst().first)
        #expect(call.clip == AudioClip(samples: rampSamples(1_000_000..<1_005_000), sampleRate: 16000))
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Un.", "t2", "Merci.")))
    }

    /// La porte et la ligne de temps restent alignées après une remise à neuf qui reporte un reste de 500 échantillons : le passage
    /// s'ouvre à l'échantillon 500 de la ligne neuve pendant la parole, la porte compte les trames qui commencent à 500 ou après
    /// (trames 2 et suivantes) et coupe au 5e bloc fort (17 trames reçues, 15 au niveau), pas avant. Une porte sans le reste aurait
    /// ses indices décalés de 500 et ne couperait qu'au 6e. Puis « conclure » : le passage encore ouvert est transcrit jusqu'au
    /// dernier échantillon reçu (le compte des échantillons de la ligne neuve inclut le reste).
    @Test func afterARenewalThatCarriesAudioNotYetInABlockTheGateCutsAtTheRightBlock() async throws {
        let h = ConversationHarness(
            transcripts: texts("t1", "t2"), fast: [question("Un. Deux.")], completion: .manual,
            events: firstTurnInChunksOf1500.merging([7: .speechStart(sample: 500)]) { _, added in added })
        let log = await h.start()
        await pushFirstTurnInChunksOf1500(h, log)
        await h.audio.plays.wait(atLeast: 1)
        #expect(h.detector.resetMarks == [0, 7, 7])

        pushLoud(h, from: 0, count: 4)
        await log.wait(5 + 4, where: isLevel)
        #expect(!log.items.contains(where: isInterrupted))
        pushLoud(h, from: 4000, count: 1)
        await log.wait(5 + 5, where: isLevel)   // le niveau d'une tranche est émis après la consultation de la porte
        #expect(log.items.filter(isInterrupted) == [.interrupted(heard: "")])
        #expect(h.detector.blocks.count == 12)

        await h.chain.conclude()
        await log.waitForEnd()
        let call = try #require(h.transcriber.calls.dropFirst().first)
        #expect(call.clip == AudioClip(samples: loudSamples(0..<5000), sampleRate: 16000))
        #expect(log.end == .prompt("Prompt final", conversation("t1 t2")))
    }

    // MARK: Une phrase qui n'existe pas (revue de la tâche 6, m-1)

    /// La garde de génération écarte déjà toute entrée d'une réplique abandonnée ; si un glissement futur en laissait passer une, la
    /// fin d'un clip d'une phrase qui n'existe pas est ignorée, sans planter le processus (sans garde : indice hors limites).
    @Test func theEndOfAClipForASentenceThatDoesNotExistIsIgnoredWithoutCrashing() async {
        let h = ConversationHarness()
        let log = await h.start()
        await log.wait(.state(.listening))
        await h.chain.finishClip(3, .played)
        await finish(h)
        #expect(!log.items.contains { if case .sentencePlayed = $0 { true } else { false } })
    }

    /// Une synthèse, réussie ou en panne, pour une phrase qui n'existe pas : ignorée. Ni avis de voix, ni question comptée.
    @Test func aSynthesisForASentenceThatDoesNotExistIsIgnored() async {
        let h = ConversationHarness()
        let log = await h.start()
        await log.wait(.state(.listening))
        await h.chain.deliver(3, .failure(SpeechError.timedOut))
        await h.chain.deliver(4, .success(Speech(clip: AudioClip(samples: [0.1], sampleRate: 16000))))
        #expect(await h.chain.voiceUsable)
        #expect(await h.chain.questionsAsked == 0)
        await finish(h)
        #expect(!log.items.contains(.notice(.voiceUnavailable)) && !log.items.contains(.state(.speaking)))
    }

    /// Revue finale, m-C : une phrase enregistrée dans la file sans texte (le glissement que couvre la garde d'`advance`) est sautée,
    /// et la file reste libre : rien en synthèse, rien en attente, la réplique peut finir. Sans cela, la file restait « en synthèse »
    /// pour toujours et la réplique ne finissait jamais.
    @Test func aSentenceQueuedWithoutTextIsSkippedAndDoesNotFreezeTheQueue() async {
        let h = ConversationHarness()
        let log = await h.start()
        await log.wait(.state(.listening))

        let after = await h.chain.advanceOverASentenceWithoutText()

        #expect(after.snapshot == ReplySnapshot(queuedClips: 0, synthesizing: nil, pending: []))
        #expect(after.idle && after.outcome == .skipped)
        #expect(h.speech.texts.isEmpty)
        await finish(h)
    }

    // MARK: Ce qui attend dans le flux est abandonné (I-3)

    /// La fin du clip « Un. » est déjà dans le flux quand la personne coupe (le bloc qui décide est retenu dans le détecteur pendant
    /// qu'elle arrive) : elle ne lance pas la synthèse de « Trois. », aucune lecture ne part, et « Un. » n'est annoncée qu'une fois.
    @Test func afterAnInterruptionWhatWaitsInTheStreamStartsNoSynthesisNorPlayback() async {
        let h = ConversationHarness(turns: firstTurn, transcripts: texts("t1"), fast: [question("Un. Deux. Trois.")], completion: .manual,
                                    events: [6: .speechStart(sample: 0)])
        let deciding = h.detector.hold(block: 10)
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 2)
        pushLoud(h, from: 0, count: 5)
        await deciding.entered.wait()

        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()   // la fin de « Un. » est dans le flux, derrière le bloc retenu
        deciding.release.open()
        await log.wait(where: isInterrupted)
        h.audio.inner.push(constantChunk(0.01))   // une entrée de plus : tout ce qui précédait dans le flux a été lu
        await log.wait(6 + 6, where: isLevel)

        #expect(h.speech.texts == ["Un.", "Deux."])
        #expect(h.audio.plays.count == 2)
        #expect(log.count { $0 == .sentencePlayed("Un.") } == 1)
        #expect(log.items.filter(isInterrupted) == [.interrupted(heard: "Un.")])
        await finish(h)
    }

    @Test func afterConcludeWhatWaitsInTheStreamStartsNoSynthesisNorPlayback() async {
        let h = ConversationHarness(turns: firstTurn, transcripts: texts("t1"), fast: [question("Un. Deux. Trois.")], completion: .manual)
        let held = h.detector.hold(block: 6)
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 2)
        h.audio.inner.push(constantChunk(0.01))
        await held.entered.wait()

        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await h.chain.conclude()
        await log.waitForEnd()

        #expect(h.speech.texts == ["Un.", "Deux."])
        #expect(h.audio.plays.count == 2)
        #expect(log.count { $0 == .sentencePlayed("Un.") } == 1)
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Un.")))
    }

    @Test func afterCancelWhatWaitsInTheStreamStartsNoSynthesisNorPlayback() async {
        let h = ConversationHarness(turns: firstTurn, transcripts: texts("t1"), fast: [question("Un. Deux. Trois.")], completion: .manual)
        let held = h.detector.hold(block: 6)
        let log = await h.start()
        await h.say(0)
        await h.audio.plays.wait(atLeast: 2)
        h.audio.inner.push(constantChunk(0.01))
        await held.entered.wait()

        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await h.cancel()
        await log.waitForEnd()

        #expect(h.speech.texts == ["Un.", "Deux."])
        #expect(h.audio.plays.count == 2)
        #expect(log.end == .cancelled)
    }
}
