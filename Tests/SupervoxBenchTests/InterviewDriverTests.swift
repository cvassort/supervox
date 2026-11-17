import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxBench

// `InterviewDriver` : quand le banc pousse un tour, quand il conclut, ce qu'il note. Le moteur est un double qui n'émet que ce que le
// test lui fait émettre, dans l'ordre lu dans le code du moteur (`ConversationChain` et ses extensions) et dans ses doubles de test,
// non d'après le brief ; le son est le vrai `WavTurnFeed`, dont le test lit les tours poussés. Ce que le vrai moteur émet est
// vérifié à part, dans `InterviewCommandTests`.

/// Un moteur d'entretien dont les événements viennent du test, et qui compte les appels qu'on lui fait.
private final class EventScriptEngine: ConversationEngine {
    private let stream: AsyncStream<ConversationEvent>
    private let continuation: AsyncStream<ConversationEvent>.Continuation
    private let calls = Mutex((conclude: 0, cancel: 0))

    init() { (stream, continuation) = AsyncStream<ConversationEvent>.makeStream() }

    var concludeCalls: Int { calls.withLock { $0.conclude } }
    var cancelCalls: Int { calls.withLock { $0.cancel } }

    func start() async -> AsyncStream<ConversationEvent> { stream }
    func conclude() async { calls.withLock { $0.conclude += 1 } }
    func cancel() async { calls.withLock { $0.cancel += 1 } }

    func emit(_ event: ConversationEvent) { continuation.yield(event) }
    func endStream() { continuation.finish() }
}

/// Le pilote, son moteur double, son vrai `WavTurnFeed`, ses attentes et son horloge.
private final class Rig: Sendable {
    let engine = EventScriptEngine()
    let board = WaitBoard()
    let clock = InterviewClock()
    let feed: WavTurnFeed
    let chunks = ChunkRecorder()
    private let observed = Tally()
    private let task: Mutex<Task<InterviewTrace, Never>?> = Mutex(nil)
    let lines = LineLog()

    init(turns: Int = 3, interruptAfter: Double? = nil) throws {
        let board = board, clock = clock
        let feed = WavTurnFeed(turns: (0..<turns).map { _ in tone(seconds: 0.1) }, wait: { await board.wait($0) }, now: { clock.now() })
        self.feed = feed
        try feed.start(onChunk: chunks.record)
        let engine = engine, observed = observed, lines = lines
        let started = Task {
            await InterviewDriver.run(
                engine: engine, feed: feed, interruptAfter: interruptAfter, wait: { await board.wait($0) }, now: { clock.now() },
                observe: { _ in observed.increment() }, progress: { lines.add($0) })
        }
        task.withLock { $0 = started }
    }

    /// Émet les événements l'un après l'autre, en attendant à chaque fois que le pilote l'ait traité : ce que le test lit ensuite
    /// est l'état **après** cet événement, sans durée ni sondage au hasard.
    func send(_ events: ConversationEvent...) async throws {
        for event in events {
            let before = observed.value
            engine.emit(event)
            let handled = await settle { observed.value == before + 1 }
            try #require(handled, "le pilote n'a pas traité \(event)")
        }
    }

    /// La fin de l'entretien, puis la trace.
    func finish(_ end: ConversationEnd = .cancelled) async throws -> InterviewTrace {
        try await send(.finished(end))
        return await result()
    }

    func result() async -> InterviewTrace {
        let started = task.withLock { $0 }
        return await started?.value ?? InterviewTrace()
    }

    var pushed: [Int] { feed.pushedTurns }
}

/// Une réplique entière, de la réflexion à sa fin, pour une question (`question`) dite par `text`.
private func fullReply(_ rig: Rig, question: Int, text: String = "Une question ?") async throws {
    try await rig.send(
        .state(.thinking), .replyText(text), .state(.speaking), .speakingStarted(question: question), .sentencePlayed(text),
        .speakingEnded(heard: text))
}

/// Une conversation dont les tours sont `texts` (la personne puis l'intervieweur, en alternance).
private func talk(_ texts: String...) -> Conversation {
    var conversation = Conversation()
    for (index, text) in texts.enumerated() {
        if index.isMultiple(of: 2) { conversation.appendUser(text) } else { conversation.appendInterviewer(text) }
    }
    return conversation
}

@Suite(.timeLimit(.minutes(1))) struct InterviewDriverTests {
    // MARK: Ordre des tours (règle 2)

    @Test func theNextTurnIsPushedOnlyOnceTheReplyHasEndedAndTheEngineListensAgain() async throws {
        let rig = try Rig()
        try await rig.send(.state(.preparing))
        #expect(rig.pushed.isEmpty)   // rien n'est poussé avant que l'entretien écoute

        try await rig.send(.state(.listening))
        #expect(rig.pushed == [0])

        // Tout au long de la réplique au tour 1, rien n'est poussé.
        try await rig.send(.turnEnded("un"), .state(.thinking), .replyText("Une question ?"), .state(.speaking))
        #expect(rig.pushed == [0])
        try await rig.send(.speakingStarted(question: 1))
        #expect(rig.pushed == [0], "un tour poussé pendant la réplique ferait une interruption")
        try await rig.send(.sentencePlayed("Une question ?"))
        #expect(rig.pushed == [0])
        try await rig.send(.speakingEnded(heard: "Une question ?"))
        #expect(rig.pushed == [0], "la réplique est finie, mais le moteur n'écoute pas encore : une conclusion peut suivre")

        try await rig.send(.state(.listening))
        #expect(rig.pushed == [0, 1])
        #expect(rig.chunks.count == 210)   // deux tours de 0,1 s : 5 + 100 tranches chacun
        _ = try await rig.finish()
    }

    @Test(arguments: [ConversationNotice.notUnderstood, .modelFailed(.empty)])
    func aTurnThatGetsAnAvisInsteadOfAReplyDoesNotStallTheNextOne(notice: ConversationNotice) async throws {
        let rig = try Rig()
        try await rig.send(.state(.listening))
        if notice == .notUnderstood {
            try await rig.send(.notice(notice))
        } else {
            try await rig.send(.turnEnded("un"), .state(.thinking), .notice(notice))
        }
        #expect(rig.pushed == [0])
        try await rig.send(.state(.listening))
        #expect(rig.pushed == [0, 1])
        let trace = try await rig.finish()
        #expect(trace.turns.map(\.heard) == (notice == .notUnderstood ? [false, false] : [true, false]))
        #expect(trace.notices == [notice])
    }

    // MARK: Interruption (règle 2)

    @Test func withAnInterruptionTheNextTurnIsPushedAfterTheSimulatedDelayFollowingSpeakingStarted() async throws {
        let rig = try Rig(interruptAfter: 0.5)
        try await rig.send(.state(.listening))
        try #require(await settle { rig.board.requests == [InterviewDriver.reactionTimeout] })
        try await rig.send(.turnEnded("un"), .state(.thinking), .replyText("Une question ?"), .state(.speaking))
        try await rig.send(.speakingStarted(question: 1))
        // L'attente de 0,5 s démarre avec la réplique (celle du tour sans réaction a disparu : elle est seule), et le tour ne part
        // pas avant qu'elle soit rendue.
        try #require(await settle { rig.board.pendingSeconds == [0.5] })
        #expect(rig.pushed == [0])
        #expect(rig.board.release(seconds: 0.5))
        try #require(await settle { rig.pushed == [0, 1] })

        // La réplique coupée, l'écoute reprend : ni ce `.interrupted` ni ce `.listening` ne poussent un tour de plus.
        try await rig.send(.interrupted(heard: ""), .state(.listening))
        #expect(rig.pushed == [0, 1])
        // La réplique au tour interrupteur : même règle.
        try await rig.send(.turnEnded("deux"), .state(.thinking), .replyText("Autre ?"), .speakingStarted(question: 2))
        try #require(await settle { rig.board.pendingSeconds == [0.5] })
        #expect(rig.board.release(seconds: 0.5))
        try #require(await settle { rig.pushed == [0, 1, 2] })

        // Plus de tour à pousser : la prochaine réplique n'arme plus d'attente (absence vérifiée après de nombreux passages du
        // planificateur : un test qui passe à tort si l'attente tardait plus, jamais l'inverse).
        try await rig.send(.interrupted(heard: "Autre ?"), .state(.listening), .turnEnded("trois"), .speakingStarted(question: 3))
        await quiesce()
        #expect(rig.board.pendingSeconds.isEmpty)
        #expect(rig.board.requests == [InterviewDriver.reactionTimeout, 0.5, InterviewDriver.reactionTimeout, 0.5,
                                       InterviewDriver.reactionTimeout])
        let trace = try await rig.finish()
        #expect(trace.interruptions == ["", "Autre ?"])
    }

    @Test func aReplyThatEndsBeforeTheInterruptionDelayIsNotInterrupted() async throws {
        let rig = try Rig(turns: 2, interruptAfter: 0.5)
        try await rig.send(.state(.listening), .turnEnded("un"), .state(.thinking), .replyText("Courte."), .speakingStarted(question: 1))
        try #require(await settle { rig.board.pendingSeconds == [0.5] })

        try await rig.send(.speakingEnded(heard: "Courte."))
        // L'attente n'a plus d'objet : elle est annulée, et le tour part à l'écoute suivante, comme sans interruption.
        try #require(await settle { rig.board.pendingSeconds.isEmpty })
        #expect(rig.pushed == [0])
        try await rig.send(.state(.listening))
        #expect(rig.pushed == [0, 1])
        #expect(rig.board.release(seconds: 0.5) == false)
        #expect(rig.pushed == [0, 1])
        _ = try await rig.finish()
    }

    @Test func aReplyOfTheInterruptedTurnThatEndsWhileTheNextTurnIsInFlightDoesNotReleaseAnotherTurn() async throws {
        // Le tour 2 est poussé, mais l'ancienne réplique va au bout (la porte d'interruption ne l'a pas coupée) : son `.speakingEnded`
        // n'est pas celui d'une réplique au tour 2, et le `.listening` qui suit ne doit pas pousser le tour 3.
        let rig = try Rig(interruptAfter: 0.5)
        try await rig.send(.state(.listening), .turnEnded("un"), .state(.thinking), .replyText("Q"), .speakingStarted(question: 1))
        try #require(await settle { rig.board.pendingSeconds == [0.5] })
        rig.board.release(seconds: 0.5)
        try #require(await settle { rig.pushed == [0, 1] })

        try await rig.send(.speakingEnded(heard: "Q"), .state(.listening))
        #expect(rig.pushed == [0, 1])
        _ = try await rig.finish()
    }

    // MARK: Fin (règle 4)

    @Test func theConclusionIsAskedOnceAfterTheLastReplyAndNotRightAfterTheLastTurn() async throws {
        let rig = try Rig(turns: 1)
        try await rig.send(.state(.listening))
        #expect(rig.pushed == [0])
        #expect(rig.engine.concludeCalls == 0, "conclure avec les tranches encore en file perdrait le dernier tour")
        try await rig.send(.turnEnded("un"))
        try await fullReply(rig, question: 1)
        #expect(rig.engine.concludeCalls == 0, "le moteur n'écoute pas encore")

        try await rig.send(.state(.listening))
        #expect(rig.engine.concludeCalls == 1)
        #expect(rig.pushed == [0])
        try await rig.send(.state(.concluding), .state(.finished))
        let trace = try await rig.finish(.prompt("Un prompt.", talk("un", "Une question ?")))
        #expect(rig.engine.concludeCalls == 1)
        #expect(trace.concludeSent)
        #expect(trace.end == .prompt("Un prompt.", talk("un", "Une question ?")))
    }

    @Test func aConclusionAlreadyAnnouncedIsNotAskedForAgain() async throws {
        // Une réplique de conclusion : `.speakingEnded`, puis `.state(.concluding)`. Un `.state(.listening)` qui arriverait ensuite
        // (le moteur en émet un à chaque reprise d'écoute) ne doit pas faire demander une seconde conclusion.
        let rig = try Rig(turns: 1)
        try await rig.send(.state(.listening), .turnEnded("un"))
        try await fullReply(rig, question: 1)
        try await rig.send(.state(.concluding), .state(.listening))
        #expect(rig.engine.concludeCalls == 0)
        let trace = try await rig.finish()
        #expect(!trace.concludeSent)
        #expect(rig.engine.concludeCalls == 0)
    }

    @Test func noTurnIsPushedOnceTheConclusionIsAnnounced() async throws {
        // La réplique du tour 1 est finie, le moteur annonce sa conclusion : un `.state(.listening)` ne pousse rien.
        let rig = try Rig(turns: 3)
        try await rig.send(.state(.listening), .turnEnded("un"))
        try await fullReply(rig, question: 1)
        try await rig.send(.state(.concluding), .state(.listening))
        #expect(rig.pushed == [0])
        #expect(rig.engine.concludeCalls == 0)
        _ = try await rig.finish()
    }

    @Test func theTwoOrdersOfTheConclusionEventsAreHandled() async throws {
        // À la limite de questions : `.turnEnded` arrive avant `.state(.concluding)`.
        let limit = try Rig(turns: 3)
        try await limit.send(.state(.listening), .turnEnded("un"))
        try await fullReply(limit, question: 1)
        try await limit.send(.state(.listening), .turnEnded("deux"), .state(.concluding), .state(.listening))
        #expect(limit.pushed == [0, 1])
        #expect(limit.engine.concludeCalls == 0)
        let limitTrace = try await limit.finish()
        #expect(limitTrace.turns.map(\.heard) == [true, true])

        // Après notre `conclude()` : `.state(.concluding)` arrive avant les derniers événements, dont un `.listening` perdu.
        let asked = try Rig(turns: 1)
        try await asked.send(.state(.listening), .turnEnded("un"))
        try await fullReply(asked, question: 1)
        try await asked.send(.state(.listening))
        #expect(asked.engine.concludeCalls == 1)
        try await asked.send(.state(.concluding), .state(.listening))
        #expect(asked.engine.concludeCalls == 1, "un second conclude() est sans effet pour le moteur, mais il ne doit pas partir")
        #expect(asked.pushed == [0])
        _ = try await asked.finish()
    }

    @Test func theLastWordsTranscribedAfterTheConclusionIsAnnouncedBelongToTheTurnInFlight() async throws {
        // Mode interruption : le tour 2 est poussé pendant une réplique ; le moteur annonce sa conclusion, puis transcrit ces
        // derniers mots (`.state(.concluding)` avant `.turnEnded`).
        let rig = try Rig(turns: 2, interruptAfter: 0.5)
        try await rig.send(.state(.listening), .turnEnded("un"), .state(.thinking), .replyText("Q"), .speakingStarted(question: 1))
        try #require(await settle { rig.board.pendingSeconds == [0.5] })
        rig.board.release(seconds: 0.5)
        try #require(await settle { rig.pushed == [0, 1] })
        try await rig.send(.speakingEnded(heard: "Q"), .state(.concluding), .turnEnded("derniers mots"))
        let trace = try await rig.finish()
        #expect(trace.turns.map(\.heard) == [true, true])
        #expect(rig.engine.concludeCalls == 0)
    }

    @Test func aStreamThatEndsWithoutAnEndCancelsTheEngineAndHasNoEnd() async throws {
        let rig = try Rig(turns: 1)
        try await rig.send(.state(.listening))
        rig.engine.endStream()
        let trace = await rig.result()
        #expect(trace.end == nil)
        #expect(rig.engine.cancelCalls == 1)
    }

    // MARK: Un tour sans réaction

    @Test func aTurnTheEngineNeverReactsToIsNotedAndTheNextOneGoes() async throws {
        let rig = try Rig(turns: 2)
        try await rig.send(.state(.listening))
        try #require(await settle { rig.board.pendingSeconds == [InterviewDriver.reactionTimeout] })
        #expect(rig.pushed == [0])

        #expect(rig.board.release(seconds: InterviewDriver.reactionTimeout))
        try #require(await settle { rig.pushed == [0, 1] })
        // Sa propre attente est armée pour le nouveau tour ; la réponse du moteur la rend sans objet.
        try #require(await settle { rig.board.pendingSeconds == [InterviewDriver.reactionTimeout] })
        try await rig.send(.turnEnded("deux"))
        try #require(await settle { rig.board.pendingSeconds.isEmpty })
        let trace = try await rig.finish()
        #expect(trace.turns.map(\.noReaction) == [true, false])
        #expect(trace.turns.map(\.heard) == [false, true])
    }

    @Test func aTurnTheEngineNeverReactsToIsFollowedByTheConclusionWhenItWasTheLast() async throws {
        let rig = try Rig(turns: 1)
        try await rig.send(.state(.listening))
        try #require(await settle { rig.board.pendingSeconds == [InterviewDriver.reactionTimeout] })
        rig.board.release(seconds: InterviewDriver.reactionTimeout)
        let concluded = await settle { rig.engine.concludeCalls == 1 }
        #expect(concluded)
        _ = try await rig.finish()
    }

    // MARK: Durées

    @Test func theDurationsRunFromTheEndOfTheTurnToEachMomentOfTheReply() async throws {
        let rig = try Rig(turns: 1)
        try await rig.send(.state(.listening))   // le tour est poussé à la date 0 : sa voix finit à 0
        // Un texte d'une réplique ancienne, avant le texte du tour : il ne compte pas.
        rig.clock.advance(0.5)
        try await rig.send(.replyText("ancienne réplique"))
        rig.clock.advance(1)
        try await rig.send(.turnEnded("un"))
        try await rig.send(.state(.thinking))
        rig.clock.advance(0.5)
        try await rig.send(.replyText("Une"))
        rig.clock.advance(0.5)
        try await rig.send(.speakingStarted(question: 1))
        rig.clock.advance(0.25)
        try await rig.send(.sentencePlayed("Une question ?"))
        // Seul le premier de chaque sorte compte.
        rig.clock.advance(8)
        try await rig.send(.replyText("Une question ?"), .speakingStarted(question: 2), .sentencePlayed("Autre."))

        let trace = try await rig.finish()
        let turn = try #require(trace.turns.first)
        #expect(turn.toFirstText == 2)
        #expect(turn.toFirstSentence == 2.5)
        #expect(turn.toPlayed == 2.75)
    }

    // MARK: Questions et avis

    @Test func theQuestionsAreThoseTheEngineCountsAndAnUnheardOneIsGivenBack() async throws {
        let rig = try Rig(turns: 1)
        try await rig.send(.state(.listening), .turnEnded("un"))
        try await fullReply(rig, question: 1)
        // La question 2 est annoncée, puis coupée avant d'être entendue : le moteur ne la compte pas, et son numéro revient.
        try await rig.send(.state(.thinking), .speakingStarted(question: 2), .interrupted(heard: ""))
        // Une réplique de conclusion reprend le numéro de la dernière question posée : elle n'en compte pas une.
        try await rig.send(.state(.thinking), .speakingStarted(question: 1), .speakingEnded(heard: "Merci."))
        // Une réplique coupée pendant la réflexion n'avait rien annoncé.
        try await rig.send(.state(.thinking), .interrupted(heard: ""))
        let trace = try await rig.finish()
        #expect(trace.questions == 1)
        #expect(trace.interruptions == ["", ""])
    }

    @Test func theNoticesAreKeptInOrder() async throws {
        let rig = try Rig(turns: 1)
        try await rig.send(.state(.listening), .notice(.voiceFellBack), .turnEnded("un"), .notice(.proposal), .notice(.lastQuestion))
        let trace = try await rig.finish()
        #expect(trace.notices == [.voiceFellBack, .proposal, .lastQuestion])
    }

    @Test func theProgressLinesNameTheTurnsAndTheConclusion() async throws {
        let rig = try Rig(turns: 1)
        try await rig.send(.state(.listening), .turnEnded("un"))
        try await fullReply(rig, question: 1)
        try await rig.send(.state(.listening))
        _ = try await rig.finish()
        #expect(rig.lines.all == ["Tour 1 sur 1 poussé.", "Tous les tours sont poussés : conclusion demandée."])
    }
}
