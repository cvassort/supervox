import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxBench

// `WavTurnFeed` : le son de l'entretien du banc. Il ne joue rien et n'écoute rien : les tours viennent de clips en mémoire, la
// lecture est une attente injectée. Aucun matériel, aucune durée réelle.

@Suite(.timeLimit(.minutes(1))) struct WavTurnFeedTests {
    private func makeFeed(
        _ turns: [AudioClip], board: WaitBoard = WaitBoard(automatic: true), clock: InterviewClock = InterviewClock()
    ) -> WavTurnFeed {
        WavTurnFeed(turns: turns, wait: { await board.wait($0) }, now: { clock.now() })
    }

    @Test func aTurnIsPushedInSlicesOfTwentyMillisecondsThenTwoSecondsOfSilence() throws {
        let clip = AudioClip(samples: (0..<1_600).map { Float($0 + 1) / 10_000 }, sampleRate: 16_000)   // 0,1 s
        let feed = makeFeed([clip])
        let recorder = ChunkRecorder()
        try feed.start(onChunk: recorder.record)

        #expect(feed.pushTurn(0))

        let chunks = recorder.chunks
        // 0,1 s = 5 tranches de 20 ms, puis 2 s = 100 tranches : 105 en tout, toutes de 320 échantillons à 16 kHz.
        #expect(chunks.count == 105)
        #expect(chunks.allSatisfy { $0.samples.count == 320 && $0.sampleRate == 16_000 })
        // La parole arrive entière et dans l'ordre, puis rien que du silence.
        #expect(Array(chunks.prefix(5).flatMap(\.samples)) == clip.samples)
        #expect(chunks.dropFirst(5).allSatisfy { $0.samples.allSatisfy { $0 == 0 } })
        #expect(feed.pushedTurns == [0])
    }

    @Test func aLastPartialSliceKeepsItsSamples() throws {
        let clip = tone(seconds: 0.05)   // 800 échantillons : 320 + 320 + 160
        let feed = makeFeed([clip])
        let recorder = ChunkRecorder()
        try feed.start(onChunk: recorder.record)

        feed.pushTurn(0)

        let chunks = recorder.chunks
        #expect(chunks.prefix(3).map(\.samples.count) == [320, 320, 160])
        let voiced = chunks.prefix(3).flatMap(\.samples)
        #expect(voiced == clip.samples)
        #expect(chunks.dropFirst(3).flatMap(\.samples).count == 32_000)   // 2 s à 16 kHz
    }

    @Test func theEndOfTheVoiceIsDatedBeforeTheSilenceNotAfterIt() throws {
        // L'horloge compte les tranches déjà livrées : la date d'une tranche est son rang.
        let recorder = ChunkRecorder()
        let feed = WavTurnFeed(turns: [tone(seconds: 0.1)], wait: { _ in }, now: { Double(recorder.count) })
        try feed.start(onChunk: recorder.record)
        #expect(feed.voiceEnd(of: 0) == nil)

        feed.pushTurn(0)

        // 0,1 s de voix = 5 tranches : la fin de la voix est la date où la cinquième vient d'être livrée, avant les 100 du silence.
        #expect(recorder.count == 105)
        #expect(feed.voiceEnd(of: 0) == 5)
    }

    @Test func aTurnThatDoesNotExistPushesNothing() throws {
        let feed = makeFeed([tone(seconds: 0.1)])
        let recorder = ChunkRecorder()
        try feed.start(onChunk: recorder.record)

        #expect(!feed.pushTurn(1))
        #expect(!feed.pushTurn(-1))

        #expect(recorder.count == 0)
        #expect(feed.pushedTurns.isEmpty)
        #expect(feed.voiceEnd(of: 1) == nil)
        #expect(feed.turnCount == 1)
    }

    @Test func aClipEndsOnlyWhenItsSimulatedDurationHasPassed() async throws {
        let board = WaitBoard()
        let feed = makeFeed([], board: board)
        try feed.start { _ in }
        let ends = Mutex<[PlaybackEnd]>([])

        try feed.play(tone(seconds: 0.25)) { end in ends.withLock { $0.append(end) } }

        // L'attente injectée a reçu la durée du clip (0,25 s), et rien n'est fini tant qu'elle n'est pas rendue.
        try #require(await settle { board.requests == [0.25] })
        feed.flushEnds()
        #expect(ends.withLock { $0 }.isEmpty)
        #expect(board.release(seconds: 0.25))
        try #require(await settle {
            feed.flushEnds()
            return ends.withLock { $0 } == [.played]
        })
    }

    @Test func aStoppedPlaybackEndsEveryQueuedClipAsStopped() async throws {
        let board = WaitBoard()
        let feed = makeFeed([], board: board)
        try feed.start { _ in }
        let ends = Mutex<[PlaybackEnd]>([])
        try feed.play(tone(seconds: 1)) { end in ends.withLock { $0.append(end) } }
        try feed.play(tone(seconds: 1)) { end in ends.withLock { $0.append(end) } }

        feed.stopPlayback()

        try #require(await settle {
            feed.flushEnds()
            return ends.withLock { $0 } == [.stopped, .stopped]
        })
        #expect(feed.playbackPosition == nil)
        board.releaseAll()
    }

    @Test func thePlaybackPositionIsTheTimeElapsedInTheClipPlayingNow() async throws {
        let board = WaitBoard()
        let clock = InterviewClock()
        let feed = makeFeed([], board: board, clock: clock)
        try feed.start { _ in }
        #expect(feed.playbackPosition == nil)
        let ends = Mutex<[PlaybackEnd]>([])

        try feed.play(tone(seconds: 1)) { end in ends.withLock { $0.append(end) } }
        try feed.play(tone(seconds: 0.5)) { end in ends.withLock { $0.append(end) } }
        clock.advance(0.25)
        #expect(feed.playbackPosition == 0.25)
        // Au-delà de sa durée (l'attente n'est pas encore rendue), la position reste à la durée du clip.
        clock.advance(1.75)
        #expect(feed.playbackPosition == 1)

        // Le premier clip finit : le second commence à cette date, sa position repart de zéro.
        try #require(await settle { board.pendingSeconds.contains(1) })
        #expect(board.release(seconds: 1))
        try #require(await settle {
            feed.flushEnds()
            return ends.withLock { $0 } == [.played]
        })
        #expect(feed.playbackPosition == 0)
        clock.advance(0.125)
        #expect(feed.playbackPosition == 0.125)

        try #require(await settle { board.pendingSeconds.contains(0.5) })
        board.release(seconds: 0.5)
        try #require(await settle {
            feed.flushEnds()
            return ends.withLock { $0 } == [.played, .played]
        })
        #expect(feed.playbackPosition == nil)
    }

    @Test func playingBeforeTheStartIsRefused() {
        let feed = makeFeed([])
        #expect(throws: AudioCaptureError.notRunning) { try feed.play(tone(seconds: 0.1)) { _ in } }
    }
}
