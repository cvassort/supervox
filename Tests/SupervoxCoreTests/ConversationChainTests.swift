import Foundation
import Testing
@testable import SupervoxCore

// Le moteur de l'entretien (règles 1 à 10 de la tâche 5). Tout tourne sur des doubles : aucun micro, aucun son, aucune voix
// du système, aucun réseau, aucune attente réelle. Les tests rendent la main à l'entretien par des portes (`Gate`,
// `CountLatch`, `EventLog.wait`) ; un test suspendu échoue à la limite de la suite, il ne reste pas en vie.

/// Met fin à un entretien que le test laisse en cours, et attend la fin du flux.
func finish(_ harness: ConversationHarness) async {
    await harness.cancel()
    await harness.log?.waitForEnd()
}

func isLevel(_ event: ConversationEvent) -> Bool {
    if case .level = event { return true }
    return false
}

func isPartial(_ event: ConversationEvent) -> Bool {
    if case .partialTranscript = event { return true }
    return false
}

func isFinished(_ event: ConversationEvent) -> Bool {
    if case .finished = event { return true }
    return false
}

func isSpeakingStarted(_ event: ConversationEvent) -> Bool {
    if case .speakingStarted = event { return true }
    return false
}

/// La réponse d'une question : le marqueur de tête, puis la phrase.
func question(_ text: String) -> ScriptedModel { modelReply("[SUITE]\n" + text) }

private let twoTurns = [TurnScript(base: 0), TurnScript(base: 1_000_000)]

/// Les textes que le moteur de transcription rend à ses appels successifs.
func texts(_ texts: String...) -> @Sendable (Int) -> ScriptedTranscriber.Reply {
    { index in .text(index < texts.count ? texts[index] : "réponse") }
}

/// Le détecteur a été remis à neuf avant le premier bloc de chaque tour scripté, et jamais pendant un passage (entre le bloc qui
/// l'ouvre et celui qui le ferme) : un passage ne perd jamais son début, et un tour ne voit rien du précédent.
func expectFreshDetectorForEachTurn(_ h: ConversationHarness, sourceLocation: SourceLocation = #_sourceLocation) {
    let marks = h.detector.resetMarks
    var offset = 0
    for turn in h.turns {
        #expect(marks.contains(offset), "aucune remise à neuf avant le bloc \(offset)", sourceLocation: sourceLocation)
        let inside = (offset + turn.start + 1)...(offset + turn.blocks - 1)
        #expect(!marks.contains(where: inside.contains), "remise à neuf pendant le passage \(inside)", sourceLocation: sourceLocation)
        offset += turn.blocks
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ConversationPreparationTests {
    // MARK: Règle 1

    @Test func preparationPreparesBothEnginesThenOpensTheMicrophoneThenListens() async {
        let h = ConversationHarness()
        let seen = CallbackBox<[Int]>()
        let (detector, transcriber) = (h.detector, h.transcriber)
        h.audio.onStart { seen.set([detector.prepares, transcriber.prepares]) }

        let log = await h.start()
        await log.wait(.state(.listening))

        #expect(log.trace == [.state(.preparing), .state(.listening)])
        #expect(seen.value == [1, 1])   // détecteur et transcripteur préparés avant l'ouverture du micro
        #expect(h.audio.inner.log == ["start"])
        await finish(h)
    }

    @Test func aMicrophoneThatCannotStartEndsTheEntretienWithNothingElseOpen() async {
        let h = ConversationHarness(startError: .noInputDevice)

        let log = await h.start()
        let events = await log.waitForEnd()

        #expect(events == [.state(.preparing), .state(.finished),
                           .finished(.failed(.microphone("noInputDevice"), Conversation()))])
        #expect(h.audio.inner.log.isEmpty && !h.audio.inner.isRunning)   // jamais ouvert, donc jamais fermé
        #expect(h.previewSleeper.started == 0 && h.watchdogSleeper.started == 0)   // aucune tâche de surveillance lancée
    }

    /// Une panne du micro ne porte qu'un code stable : jamais la phrase de `AudioCaptureError.reason`, jamais le message venu de la
    /// capture (qui peut citer un périphérique ou une erreur du système).
    @Test(arguments: [
        (AudioCaptureError.microphoneAccessDenied("Autorisez le micro dans les Réglages"), "microphoneAccessDenied"),
        (AudioCaptureError.noInputDevice, "noInputDevice"),
        (AudioCaptureError.alreadyRunning, "alreadyRunning"),
        (AudioCaptureError.engineFailed("détail du moteur audio : périphérique « Casque »"), "engineFailed"),
        (AudioCaptureError.notRunning, "notRunning"),
    ])
    func aMicrophoneThatCannotStartGivesAStableCodeAndNeverTheCaptureMessage(error: AudioCaptureError, code: String) async {
        let h = ConversationHarness(startError: error)

        let events = await h.start().waitForEnd()

        #expect(events.last == .finished(.failed(.microphone(code), Conversation())))
    }

    @Test func anEngineThatCannotBePreparedEndsTheEntretienBeforeTheMicrophoneOpens() async {
        let h = ConversationHarness(detectorPrepareError: TestFailure("modèle absent"))

        let events = await h.start().waitForEnd()

        #expect(events == [.state(.preparing), .state(.finished), .finished(.failed(.engine("detectorFailed"), Conversation()))])
        #expect(h.audio.inner.log.isEmpty)
    }

    @Test func aSecondStartDoesNotOpenAnythingAndReturnsAFinishedStream() async {
        let h = ConversationHarness()
        let log = await h.start()
        await log.wait(.state(.listening))

        let second = EventLog.reading(await h.chain.start())
        await second.waitForEnd()

        #expect(second.items.isEmpty)
        #expect(h.audio.inner.log == ["start"] && h.detector.prepares == 1)
        await finish(h)
    }

    @Test func theTurnPolicyIsOneThousandTwentyFourTokensAndThirtySeconds() {
        #expect(RewritePolicy.turn.maxTokens == 1_024 && RewritePolicy.turn.timeout == 30)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ConversationTurnTests {
    // MARK: Règle 2

    @Test func microphoneChunksAreBroughtTo16kHzAndShownAsLevels() async throws {
        let h = ConversationHarness(turns: [TurnScript(blocks: 8, start: 1, end: 4, base: 0)], fast: [modelReply("[CONCLURE]\nMerci.")])
        let log = await h.start()
        await log.wait(.state(.listening))
        // Une onde, non un signal constant : le moteur doit rendre ce que rend un `StreamingResampler` 48 kHz vers 16 kHz sur les mêmes
        // tranches, dans le même ordre (la référence est calculée ici, avec une instance neuve).
        let wave = (0..<3000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let chunk = AudioChunk(samples: wave, sampleRate: 48000)
        let reference = try #require(StreamingResampler(from: 48000, to: 16000))
        var converted: [Float] = []
        for _ in 0..<14 { converted += reference.push(wave) }
        try #require(converted.count >= 4000)

        for _ in 0..<14 { h.audio.inner.push(chunk) }   // 3 000 échantillons à 48 kHz : environ 1 000 à 16 kHz, un bloc
        await log.waitForEnd()

        let levels = log.items.compactMap { event -> Float? in
            if case .level(let level) = event { return level }
            return nil
        }
        let level = try #require(levels.first)
        #expect(levels.count >= 8 && level > 0)
        #expect(levels.allSatisfy { $0 == AudioLevel.display(of: wave) })
        // Le détecteur reçoit l'audio à 16 kHz, bloc après bloc ; le passage transcrit est découpé dans cet audio-là. (L'écoute est
        // continue : les tranches qui suivent la fermeture du passage vont aussi au détecteur, d'où « au moins » huit blocs.)
        try #require(converted.count >= 8000 && h.detector.blocks.count >= 8)
        #expect(Array(h.detector.blocks.prefix(8)) == (0..<8).map { Array(converted[($0 * 1000)..<(($0 + 1) * 1000)]) })
        let call = try #require(h.transcriber.calls.first)
        #expect(call.clip == AudioClip(samples: Array(converted[1000..<4000]), sampleRate: 16000))
    }

    @Test func aClosedPassageIsTranscribedWithPaddingAndBecomesATurn() async throws {
        let turn = TurnScript(blocks: 8, start: 3, end: 5, base: 0)
        let h = ConversationHarness(turns: [turn], fast: [modelReply("[CONCLURE]\nMerci.")],
                                    config: makeConversationConfig(padding: 0.1))
        let log = await h.start()

        await h.say(0)
        let events = await log.waitForEnd()

        // Début à 3 000, fin à 5 000, remplissage de 0,1 s (1 600 échantillons) de chaque côté, borné à l'audio reçu (8 000).
        let call = try #require(h.transcriber.calls.first)
        #expect(call.clip == AudioClip(samples: rampSamples(1400..<6600), sampleRate: 16000))
        #expect(call.language == "fr" && call.vocabulary == ["Supervox"])
        #expect(events.contains(.turnEnded("réponse")))
        #expect(log.end == .prompt("Prompt final", conversation("réponse", "Merci.")))
    }

    @Test func anOpenPassageIsPreviewedEveryIntervalOneAtATime() async throws {
        let h = ConversationHarness(turns: [TurnScript(blocks: 6, start: 1, end: 4, base: 0)],
                                    transcripts: { $0 == 0 ? .hold : .text("réponse finale") },
                                    fast: [modelReply("[CONCLURE]\nMerci.")])
        let log = await h.start()
        await log.wait(.state(.listening))
        await h.previewSleeper.waitForSleeps(1)
        #expect(h.previewSleeper.requested == [1])

        for block in 0..<3 { h.audio.inner.push(rampChunk((block * 1000)..<((block + 1) * 1000))) }   // la voix commence au bloc 1
        await log.wait(3, where: isLevel)
        h.previewSleeper.tick()
        await h.transcriber.waitForCalls(1)

        let preview = try #require(h.transcriber.calls.first)
        #expect(preview.clip == AudioClip(samples: rampSamples(1000..<3000), sampleRate: 16000))
        #expect(h.previewSleeper.started == 1)   // l'aperçu retenu : aucune seconde passe ne part
        h.transcriber.release(call: 0, text: "bon")
        await log.wait(.partialTranscript("bon"))
        await h.previewSleeper.waitForSleeps(2)   // la suivante n'attend qu'après la fin de celle-ci

        for block in 3..<6 { h.audio.inner.push(rampChunk((block * 1000)..<((block + 1) * 1000))) }
        let events = await log.waitForEnd()

        let partial = try #require(events.firstIndex(of: .partialTranscript("bon")))
        let ended = try #require(events.firstIndex(of: .turnEnded("réponse finale")))
        #expect(partial < ended)
        #expect(h.transcriber.calls.count == 2)
    }

    @Test func aPreviewStillRunningWhenThePassageClosesIsCancelledAndNeverShown() async {
        let h = ConversationHarness(turns: [TurnScript(blocks: 6, start: 1, end: 4, base: 0)],
                                    transcripts: { $0 == 0 ? .hold : .text("réponse finale") },
                                    fast: [modelReply("[CONCLURE]\nMerci.")])
        let log = await h.start()
        await log.wait(.state(.listening))
        await h.previewSleeper.waitForSleeps(1)
        for block in 0..<3 { h.audio.inner.push(rampChunk((block * 1000)..<((block + 1) * 1000))) }
        await log.wait(3, where: isLevel)
        h.previewSleeper.tick()
        await h.transcriber.waitForCalls(1)   // l'aperçu est retenu dans le moteur

        for block in 3..<6 { h.audio.inner.push(rampChunk((block * 1000)..<((block + 1) * 1000))) }
        let events = await log.waitForEnd()

        await h.transcriber.cancellation(of: 0).wait()   // le tour fermé a annulé l'aperçu avant de lancer le final
        #expect(events.contains(.turnEnded("réponse finale")))
        #expect(!events.contains(where: isPartial))
        #expect(h.previewSleeper.isSleeping == false)
    }

    // MARK: Règle 3

    @Test func withoutAnnouncedVoiceTheTranscriberIsNeverCalledHoweverLongTheAudio() async {
        let h = ConversationHarness()   // le détecteur n'annonce jamais de voix
        let log = await h.start()
        await log.wait(.state(.listening))
        await h.previewSleeper.waitForSleeps(1)

        for block in 0..<20 { h.audio.inner.push(rampChunk((block * 1000)..<((block + 1) * 1000))) }
        await log.wait(20, where: isLevel)   // les vingt tranches sont entièrement traitées
        h.previewSleeper.tick()
        await h.previewSleeper.waitForSleeps(2)   // une passe d'aperçu s'est déroulée sans rien à transcrire
        h.previewSleeper.tick()
        await h.previewSleeper.waitForSleeps(3)

        #expect(h.transcriber.calls.isEmpty)
        #expect(h.detector.blocks.count == 20)
        #expect(!log.items.contains { if case .turnEnded = $0 { true } else { false } })
        await finish(h)
    }

    @Test func aBlankTranscriptionIsNotUnderstoodAddsNothingAndConsumesNoQuestion() async {
        let h = ConversationHarness(turns: twoTurns, transcripts: { $0 == 0 ? .text("  \n") : .text("bonjour") },
                                    fast: [modelReply("[CONCLURE]\nMerci.")], config: makeConversationConfig(maxQuestions: 3))
        let log = await h.start()

        await h.say(0)
        await log.wait(.state(.listening), count: 2)   // retour à l'écoute
        #expect(log.trace == [.state(.preparing), .state(.listening), .notice(.notUnderstood), .state(.listening)])
        #expect(h.fast.calls == 0)
        await h.say(1)
        await log.waitForEnd()

        #expect(h.fast.requests == [CompletionRequest(
            model: "modele-exemple-rapide", instruction: InterviewPrompt.instruction(remainingQuestions: 3), input: "bonjour",
            maxTokens: 777)])   // le tour vide n'est pas dans la conversation, la question n'est pas comptée
        #expect(log.end == .prompt("Prompt final", conversation("bonjour", "Merci.")))
        // Le tour vide n'a laissé aucun passage ni aucun échantillon à l'écoute suivante.
        #expect(h.transcriber.calls.map(\.clip) == [h.expectedClip(turn: 0), h.expectedClip(turn: 1)])
        // Le détecteur est remis à neuf avant le premier bloc et entre les deux tours, jamais pendant un passage.
        expectFreshDetectorForEachTurn(h)
    }

    // MARK: Règle 4

    @Test func afterATurnTheFastModelReceivesTheInstructionAndTheConversationInOneRequest() async {
        let h = ConversationHarness(turns: twoTurns, transcripts: texts("t1", "t2"),
                                    fast: [question("Quelle est votre demande ?"), modelReply("[CONCLURE]\nMerci.")])
        let log = await h.start()

        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        #expect(h.fast.calls == 1)   // une seule requête pour ce tour
        await h.say(1)
        await log.waitForEnd()

        #expect(h.fast.requests == [
            CompletionRequest(model: "modele-exemple-rapide", instruction: InterviewPrompt.instruction(remainingQuestions: 8),
                              input: "t1", maxTokens: 777),
            CompletionRequest(model: "modele-exemple-rapide", instruction: InterviewPrompt.instruction(remainingQuestions: 7),
                              input: "t2", maxTokens: 777,
                              history: [CompletionTurn(role: .user, text: "t1"),
                                        CompletionTurn(role: .assistant, text: "Quelle est votre demande ?")]),
        ])
        #expect(Array(log.trace.prefix(9)) == [
            .state(.preparing), .state(.listening), .turnEnded("t1"), .state(.thinking), .state(.speaking),
            .speakingStarted(question: 1), .sentencePlayed("Quelle est votre demande ?"),
            .speakingEnded(heard: "Quelle est votre demande ?"), .state(.listening)])
    }

    // MARK: Politique du tour (règle 4)

    @Test func theTurnRequestUsesTheTurnPolicyOfTheConfiguration() async throws {
        // Les nombres de la configuration de test (777 jetons, 17 s) ne sont ni ceux de `.turn` ni ceux de `.standard`.
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [modelReply("[CONCLURE]\nMerci.")])
        let log = await h.start()

        await h.say(0)
        await log.waitForEnd()

        let request = try #require(h.fast.requests.first)
        #expect(request.maxTokens == 777)
        #expect(h.turnSleeper.requested == [17])   // le délai que la requête demande à son attente injectée
        #expect(h.conclusionSleeper.requested == [43])
    }

    // MARK: Règle 10

    @Test func eachTurnStartsFromAFreshTimelineAndAFreshDetector() async throws {
        // Pendant la réplique, le micro continue de livrer : l'écoute est continue, ces tranches vont au détecteur, mais sans voix
        // annoncée elles ne sont jamais transcrites. Le second tour (blocs globaux 9 à 14) est poussé à la main : ses événements sont
        // donnés par rang global, décalés des trois blocs de la réplique.
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1", "t2"),
                                    fast: [question("Une question ?"), modelReply("[CONCLURE]\nMerci.")], completion: .manual,
                                    events: [10: .speechStart(sample: 1000), 14: .speechEnd(sample: 4000)])
        let log = await h.start()

        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)   // l'intervieweur parle
        for block in 0..<3 { h.audio.inner.push(rampChunk((9_000_000 + block * 1000)..<(9_000_000 + (block + 1) * 1000))) }
        await log.wait(6 + 3, where: isLevel)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.wait(.state(.listening), count: 2)
        for block in 0..<6 { h.audio.inner.push(rampChunk((1_000_000 + block * 1000)..<(1_000_000 + (block + 1) * 1000))) }
        await h.audio.plays.wait(atLeast: 2)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.waitForEnd()

        #expect(h.transcriber.calls.map(\.clip) == [
            h.expectedClip(turn: 0), AudioClip(samples: rampSamples(1_001_000..<1_004_000), sampleRate: 16000)])
        #expect(h.detector.blocks.count == 15)   // les deux tours de six blocs, et les trois blocs entendus pendant la réplique
        let replyBlocks = h.detector.blocks.dropFirst(6).prefix(3).joined()
        #expect(Array(replyBlocks) == rampSamples(9_000_000..<9_003_000))
        let firstBlockOfTheSecondTurn = try #require(h.detector.blocks.dropFirst(9).first)
        #expect(firstBlockOfTheSecondTurn == rampSamples(1_000_000..<1_001_000))   // le premier bloc du second tour est le sien
        // Le détecteur est remis à neuf avant chaque tour (avant le bloc 0, avant le bloc 9), jamais pendant un passage.
        let marks = h.detector.resetMarks
        #expect(marks.contains(0) && marks.contains(9))
        #expect(!marks.contains { (2...5).contains($0) || (11...14).contains($0) })
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ConversationSpeechTests {
    // MARK: Règles 5 et 6

    @Test func theReplyIsSynthesizedSentenceBySentenceWithoutTheMarker() async throws {
        let h = ConversationHarness(
            turns: [TurnScript(base: 0)], transcripts: texts("t1"),
            fast: [modelReply("[SUI", "TE]\nBonjour. Que voulez-", "vous faire ? Dites-moi tout.")])
        let log = await h.start()

        await h.say(0)
        await log.wait(.speakingEnded(heard: "Bonjour. Que voulez-vous faire ? Dites-moi tout."))

        #expect(h.speech.texts == ["Bonjour.", "Que voulez-vous faire ?", "Dites-moi tout."])
        #expect(h.audio.inner.played.compactMap { $0.samples.first } == [1, 2, 3])   // les clips jouent dans l'ordre des phrases
        let replies = log.items.compactMap { event -> String? in
            if case .replyText(let text) = event { return text }
            return nil
        }
        #expect(replies.last == "Bonjour. Que voulez-vous faire ? Dites-moi tout.")
        #expect(zip(replies, replies.dropFirst()).allSatisfy { $1.hasPrefix($0) && $1 != $0 })   // cumulé, jamais le marqueur
        #expect(replies.allSatisfy { !$0.contains("[") })
        let trace = log.trace
        #expect(trace.filter(isSpeakingStarted) == [.speakingStarted(question: 1)])
        let start = try #require(trace.firstIndex(of: .speakingStarted(question: 1)))
        #expect(trace[start...].prefix(5) == [.speakingStarted(question: 1), .sentencePlayed("Bonjour."),
                                               .sentencePlayed("Que voulez-vous faire ?"), .sentencePlayed("Dites-moi tout."),
                                               .speakingEnded(heard: "Bonjour. Que voulez-vous faire ? Dites-moi tout.")])
        await finish(h)
    }

    @Test func theSynthesizerNeverReceivesAMarkerWhateverTheCuts() async {
        // Les réponses du jeu de la tâche 4 (règle 6), avec ce qui doit être dit et montré, écrit à la main.
        let responses: [(text: String, shown: String)] = [
            ("[SUITE]\nQuelle est la contrainte principale ?", "Quelle est la contrainte principale ?"),
            ("[PROPOSER]\nJ'ai tout ce qu'il faut. On peut conclure ?", "J'ai tout ce qu'il faut. On peut conclure ?"),
            ("[CONCLURE]\nMerci, c'est noté.", "Merci, c'est noté."),
            ("  [conclure] \n d'accord. Un autre [Suite] ici, puis [PROPOSER] là.\n", "d'accord. Un autre  ici, puis  là."),
            ("[AUTRE]\nQuestion ? [SU[SUITE]ITE] et [CONCLURE] [PROPOSE", "Question ?  et  [PROPOSE"),
        ]
        for size in [1, 3, 1000] {
            for response in responses {
                let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"),
                                            fast: [modelReply(response.text, cutEvery: size)])
                let log = await h.start()
                await h.say(0)
                await log.wait(1) { if case .speakingEnded = $0 { true } else { false } }
                let shown = log.items.compactMap { event -> String? in
                    if case .replyText(let text) = event { return text }
                    return nil
                }.last

                #expect(shown == response.shown, "\(response.text) coupée tous les \(size)")
                for sentence in h.speech.texts {
                    let lowered = sentence.lowercased()
                    #expect(!lowered.contains("[suite]") && !lowered.contains("[proposer]") && !lowered.contains("[conclure]"),
                            "\(sentence)")
                }
                await finish(h)
            }
        }
    }

    @Test func onlyThePlayedSentencesEnterTheConversation() async throws {
        let h = ConversationHarness(
            turns: twoTurns, transcripts: texts("t1", "t2"),
            fast: [question("Un. Deux. Trois."), modelReply("[CONCLURE]\nMerci.")], completion: .manual)
        let log = await h.start()

        await h.say(0)
        await h.audio.plays.wait(atLeast: 1)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await h.audio.plays.wait(atLeast: 2)
        h.audio.inner.finishPlayback(.stopped)   // la deuxième phrase est coupée avant la fin : elle n'a pas été entendue
        h.audio.inner.flushEnds()
        await h.audio.plays.wait(atLeast: 3)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.wait(.state(.listening), count: 2)

        #expect(log.trace.filter { if case .sentencePlayed = $0 { true } else { false } } == [.sentencePlayed("Un."), .sentencePlayed("Trois.")])
        #expect(log.trace.contains(.speakingEnded(heard: "Un. Trois.")))
        await h.say(1)
        await h.audio.plays.wait(atLeast: 4)
        h.audio.inner.finishPlayback(.played)
        h.audio.inner.flushEnds()
        await log.waitForEnd()

        let second = try #require(h.fast.requests.dropFirst().first)
        #expect(second.history.last == CompletionTurn(role: .assistant, text: "Un. Trois."))
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Un. Trois.", "t2", "Merci.")))
    }

    @Test func atMostOneSynthesisAndTwoQueuedClipsAtATime() async {
        let h = ConversationHarness(
            turns: [TurnScript(base: 0)], transcripts: texts("t1"),
            fast: [question("Première phrase. Deuxième phrase. Troisième phrase. Quatrième phrase.")], completion: .manual)
        let log = await h.start()

        await h.say(0)
        await h.audio.plays.wait(atLeast: 2)
        // L'acteur a fini de traiter la deuxième mise en file (`snapshot` passe derrière) : la troisième phrase attend.
        let queued = await h.chain.replySnapshot()
        #expect(queued == ReplySnapshot(queuedClips: 2, synthesizing: nil, pending: [2, 3]))
        #expect(h.speech.texts == ["Première phrase.", "Deuxième phrase."])

        for played in 1...4 {
            await h.audio.plays.wait(atLeast: played)
            h.audio.inner.finishPlayback(.played)
            h.audio.inner.flushEnds()
        }
        await log.wait(1) { if case .speakingEnded = $0 { true } else { false } }

        #expect(h.audio.peakQueuedClips == 2)
        #expect(h.speech.peakConcurrentSyntheses == 1)
        #expect(h.speech.texts.count == 4)
        await finish(h)
    }

    // MARK: Règle 7

    @Test func aProposalIsAnnouncedAndTheNextAnswerGoesBackToTheFastModelWithoutAnyKeywordSearch() async throws {
        let h = ConversationHarness(
            turns: twoTurns, transcripts: texts("t1", "oui c'est bon"),
            fast: [modelReply("[PROPOSER]\nJ'ai tout ce qu'il faut. On conclut ?"), question("Une dernière précision ?")])
        let log = await h.start()

        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        let trace = log.trace
        #expect(trace.contains(.notice(.proposal)))
        let proposal = try #require(trace.firstIndex(of: .notice(.proposal)))
        let firstQuestion = try #require(trace.firstIndex(of: .speakingStarted(question: 1)))
        #expect(proposal < firstQuestion)
        await h.say(1)
        await log.wait(.state(.listening), count: 3)   // la réponse « oui c'est bon » n'a pas conclu : l'entretien continue

        #expect(h.fast.calls == 2)
        let second = try #require(h.fast.requests.dropFirst().first)
        #expect(second.input == "oui c'est bon")
        #expect(log.trace.contains(.speakingStarted(question: 2)))   // la proposition compte, la suivante aussi
        #expect(log.count { $0 == .notice(.proposal) } == 1)
        #expect(!log.items.contains(.state(.concluding)))
        await finish(h)
    }

    @Test func aConcludeSignalSpeaksTheLastSentenceThenConcludesWithoutAnotherTurn() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"),
                                    fast: [modelReply("[CONCLURE]\nTrès bien, je rédige.")])
        let log = await h.start()

        await h.say(0)
        let events = await log.waitForEnd()

        #expect(h.speech.texts == ["Très bien, je rédige."])
        #expect(log.trace == [
            .state(.preparing), .state(.listening), .turnEnded("t1"), .state(.thinking), .state(.speaking),
            .speakingStarted(question: 0),   // la phrase de fin n'est pas une question : le numéro est celui de la dernière posée
            .sentencePlayed("Très bien, je rédige."), .speakingEnded(heard: "Très bien, je rédige."),
            .state(.concluding), .state(.finished), .finished(.prompt("Prompt final", conversation("t1", "Très bien, je rédige.")))])
        #expect(h.fast.calls == 1)
        #expect(!events.contains { if case .notice = $0 { true } else { false } })
    }

    // MARK: Règle 8

    @Test func theCeilingConcludesAfterTheLastAnswerWithoutAnotherRequestToTheFastModel() async throws {
        let h = ConversationHarness(
            turns: [TurnScript(base: 0), TurnScript(base: 1_000_000), TurnScript(base: 2_000_000)],
            transcripts: texts("t1", "t2", "t3"), fast: [question("Première ?"), question("Seconde ?")],
            config: makeConversationConfig(maxQuestions: 2))
        let log = await h.start()

        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        #expect(!log.items.contains(.notice(.lastQuestion)))   // la première de deux n'est pas la dernière
        await h.say(1)
        await log.wait(.state(.listening), count: 3)
        await h.say(2)
        await log.waitForEnd()

        #expect(h.fast.calls == 2)   // la réponse à la deuxième question ne repart pas au modèle rapide
        #expect(h.fast.requests.map(\.instruction) == [
            InterviewPrompt.instruction(remainingQuestions: 2), InterviewPrompt.instruction(remainingQuestions: 1)])
        let trace = log.trace
        #expect(log.count { $0 == .notice(.lastQuestion) } == 1)
        let lastQuestion = try #require(trace.firstIndex(of: .notice(.lastQuestion)))
        let secondQuestion = try #require(trace.firstIndex(of: .speakingStarted(question: 2)))
        let firstQuestionHeard = try #require(trace.firstIndex(of: .speakingEnded(heard: "Première ?")))
        #expect(lastQuestion < secondQuestion && lastQuestion > firstQuestionHeard)
        #expect(log.end == .prompt("Prompt final", conversation("t1", "Première ?", "t2", "Seconde ?", "t3")))
        #expect(trace.suffix(4) == [.turnEnded("t3"), .state(.concluding), .state(.finished), .finished(.prompt("Prompt final", conversation("t1", "Première ?", "t2", "Seconde ?", "t3")))])
    }

    @Test func theLastQuestionNoticeIsNotGivenWhenTheReplyIsTheClosingSentence() async {
        let h = ConversationHarness(
            turns: twoTurns, transcripts: texts("t1", "t2"), fast: [question("Seule question ?"), modelReply("[CONCLURE]\nMerci.")],
            config: makeConversationConfig(maxQuestions: 2))
        let log = await h.start()

        await h.say(0)
        await log.wait(.state(.listening), count: 2)
        await h.say(1)
        await log.waitForEnd()

        #expect(log.count { $0 == .notice(.lastQuestion) } == 0)   // la seconde réponse est un message de fin, pas une question
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ConversationConclusionTests {
    // MARK: Règle 9

    @Test func theMicrophoneIsStoppedAndHasReturnedBeforeTheStrongModelIsAsked() async throws {
        let template = "Rédige un prompt de test."
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"),
                                    fast: [modelReply("[CONCLURE]\nMerci.")],
                                    config: makeConversationConfig(template: template, vocabulary: ["Supervox", "FluidAudio"]))
        let log = await h.start()

        await h.say(0)
        await log.waitForEnd()

        // L'ordre est celui du journal commun, pris à l'instant des appels : aucune lecture après coup de deux journaux.
        let journal = h.journal.all
        let stopReturned = try #require(journal.firstIndex(of: "audio.stop.returned"))
        let strongAsked = try #require(journal.firstIndex(of: "strong.complete"))
        let concluding = try #require(journal.firstIndex(of: "event.state.concluding"))
        let finished = try #require(journal.firstIndex(of: "event.finished"))
        #expect(concluding < stopReturned && stopReturned < strongAsked && strongAsked < finished)
        #expect(journal.filter { $0 == "audio.stop" }.count == 1)
        let seen = try #require(h.audioAtStrongRequests.first)
        #expect(seen.log.last == "stop" && !seen.running)   // à l'instant de la requête, le son était arrêté
        #expect(!h.audio.inner.isRunning)

        // La requête : le modèle fort, le gabarit, la conversation (délimitée par des balises à suffixe tiré), la politique.
        let request = try #require(h.strong.requests.first)
        let expected = conversation("t1", "Merci.")
        let suffix = String(request.input.dropFirst("<entretien-".count).prefix { $0 != ">" })
        #expect(!suffix.isEmpty)
        #expect(request.model == "modele-exemple-fort")
        #expect(request.input == "<entretien-\(suffix)>\n\(expected.transcript)\n</entretien-\(suffix)>")
        #expect(request.instruction == [template, InterviewPrompt.conversationRule(suffix: suffix),
                                        RewritePrompt.vocabularyBlock(["Supervox", "FluidAudio"])].compactMap { $0 }.joined(separator: "\n\n"))
        #expect(request.history.isEmpty)
        #expect(log.end == .prompt("Prompt final", expected))
        #expect(log.items.last == log.items.last(where: isFinished))   // `.finished` est le dernier événement
        #expect(log.count(isFinished) == 1)
    }

    @Test func theConclusionRequestUsesTheConclusionPolicyOfTheConfiguration() async throws {
        // 4 321 jetons et 43 s : ni `.standard` (16 000 / 120) ni `.turn` (1 024 / 30).
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [modelReply("[CONCLURE]\nMerci.")])
        let log = await h.start()

        await h.say(0)
        await log.waitForEnd()

        let request = try #require(h.strong.requests.first)
        #expect(request.maxTokens == 4_321)
        #expect(h.conclusionSleeper.requested == [43])
        #expect(h.turnSleeper.requested == [17])   // le tour, lui, a gardé la politique de tour
    }

    @Test func aFailingConclusionKeepsTheConversation() async {
        let h = ConversationHarness(turns: [TurnScript(base: 0)], transcripts: texts("t1"), fast: [modelReply("[CONCLURE]\nMerci.")],
                                    strong: [ScriptedModel([.stop(.refused), .finish])])
        let log = await h.start()

        await h.say(0)
        await log.waitForEnd()

        #expect(log.end == .conclusionFailed(.refused, conversation("t1", "Merci.")))
        #expect(!h.audio.inner.isRunning)
    }

    @Test func aConversationWithoutAnyTurnOfThePersonIsNothingSaidAndAsksNoModel() async {
        let h = ConversationHarness()
        let log = await h.start()
        await log.wait(.state(.listening))

        await h.chain.conclude()
        await log.waitForEnd()

        #expect(log.end == .nothingSaid)
        #expect(h.strong.calls == 0 && h.fast.calls == 0)
        #expect(h.audio.inner.log == ["start", "stop"] && !h.audio.inner.isRunning)
    }
}

/// Une valeur posée par un rappel et lue par le test.
final class CallbackBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
}

// MARK: - La file de parole

@Suite struct SpeechQueueTests {
    @Test func oneSynthesisAtATimeAndAtMostTwoClipsInTheQueue() {
        var queue = SpeechQueue()
        let first = queue.register(), second = queue.register(), third = queue.register()
        #expect(first == 0 && second == 1 && third == 2)

        #expect(queue.nextToSynthesize() == 0)
        #expect(queue.nextToSynthesize() == nil)   // une synthèse est en cours : pas de seconde
        queue.synthesisFinished()
        queue.clipQueued()
        #expect(queue.nextToSynthesize() == 1)
        queue.synthesisFinished()
        queue.clipQueued()
        #expect(queue.queuedClips == 2)
        #expect(queue.nextToSynthesize() == nil)   // deux clips en file : la troisième phrase attend
        queue.clipEnded()
        #expect(queue.nextToSynthesize() == 2)
    }

    @Test func aSentenceThatMakesNoClipLeavesTheQueueFree() {
        var queue = SpeechQueue()
        _ = queue.register()
        _ = queue.register()

        #expect(queue.nextToSynthesize() == 0)
        queue.synthesisFinished()   // pas de clip (phrase sautée) : rien n'est en file
        #expect(queue.nextToSynthesize() == 1)
        queue.synthesisFinished()
        #expect(queue.isIdle)
    }

    @Test func theQueueIsIdleOnlyWhenNothingIsPendingSynthesizingOrQueued() {
        var queue = SpeechQueue()
        #expect(queue.isIdle)
        _ = queue.register()
        #expect(!queue.isIdle)
        _ = queue.nextToSynthesize()
        #expect(!queue.isIdle)
        queue.synthesisFinished()
        #expect(queue.isIdle)
        queue.clipQueued()
        #expect(!queue.isIdle)
        queue.clipEnded()
        #expect(queue.isIdle)
    }

    @Test func takingAllPendingSentencesLeavesTheOneBeingSynthesized() {
        var queue = SpeechQueue()
        for _ in 0..<3 { _ = queue.register() }
        _ = queue.nextToSynthesize()

        #expect(queue.takeAllPending() == [1, 2])
        #expect(queue.pending.isEmpty && queue.synthesizing == 0)
    }
}
