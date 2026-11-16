import AudioToolbox
import AVFAudio
import Foundation
import Testing
@testable import SupervoxCore

// Le montage d'un `write` : la petite machine d'état (`SynthesisGate`) et l'exécution qui la pilote (`SpeechRendering`), avec une
// source de tampons double. Rien ici n'appelle `AVSpeechSynthesizer`, ni ne démarre un moteur audio ; les tampons sont fabriqués
// en mémoire. La mince couche réelle (`AVSpeechBufferSource`) n'est jamais construite.

private func clip(_ range: Range<Int>, rate: Double = 22050) -> AudioClip {
    AudioClip(samples: range.map { Float($0) / 1000 }, sampleRate: rate)
}

private func pcm(_ range: Range<Int>, rate: Double = 22050) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(range.count, 1)))!
    buffer.frameLength = AVAudioFrameCount(range.count)
    for (i, v) in range.enumerated() { buffer.floatChannelData![0][i] = Float(v) / 1000 }
    return buffer
}

/// Rend vrai quand l'attente de la garde a été annulée. Sans horloge de test : au plus 20 000 passages (choix non mesuré, borne de
/// sécurité) ; l'annulation est immédiate, la borne n'est atteinte qu'en cas d'échec réel.
private func timerWasCancelled(_ sleeper: TickSleeper) async -> Bool {
    for round in 0..<20000 {
        if sleeper.cancelled == 1 { return true }
        if round % 50 == 49 { try? await Task.sleep(for: .milliseconds(1)) } else { await Task.yield() }
    }
    return sleeper.cancelled == 1
}

// MARK: - La machine d'état

@Suite struct SynthesisGateTests {
    @Test func theChunksAreKeptInOrderAndTheEndSettlesWithThem() {
        var gate = SynthesisGate()
        #expect(gate.handle(.chunk(clip(0..<10))) == nil)
        #expect(gate.handle(.chunk(clip(10..<30))) == nil)
        #expect(gate.handle(.end) == .finished([clip(0..<10), clip(10..<30)]))
    }

    /// Le tampon de longueur nulle puis `didFinish` (0,1 à 0,2 ms plus tard, mesuré) : la fin est prise une seule fois.
    @Test func theEndIsTakenOnceWhicheverSignalComesFirst() {
        var gate = SynthesisGate()
        _ = gate.handle(.chunk(clip(0..<10)))
        #expect(gate.handle(.end) == .finished([clip(0..<10)]))
        #expect(gate.handle(.end) == nil)
        #expect(gate.handle(.chunk(clip(10..<20))) == nil)
        #expect(gate.verdict == .finished([clip(0..<10)]))
    }

    @Test func nothingAfterTheVerdictChangesIt() {
        var gate = SynthesisGate()
        _ = gate.handle(.end)
        #expect(gate.handle(.fail(.timedOut)) == nil)
        #expect(gate.handle(.cancelled) == nil)
        #expect(gate.verdict == .finished([]))

        var timedOut = SynthesisGate()
        #expect(timedOut.handle(.fail(.timedOut)) == .failed(.timedOut))
        #expect(timedOut.handle(.end) == nil)
        #expect(timedOut.handle(.chunk(clip(0..<5))) == nil)
        #expect(timedOut.verdict == .failed(.timedOut))
    }

    /// `didCancel` : une interruption décidée par le système rend tout de suite, sans attendre la garde de durée, et reste prise
    /// une seule fois (ni une fin ni la garde ne la remplacent ensuite).
    @Test func aSystemInterruptionSettlesAtOnceAsAFailureAndOnlyOnce() {
        var gate = SynthesisGate()
        _ = gate.handle(.chunk(clip(0..<10)))
        #expect(gate.handle(.interrupted) == .failed(.timedOut))
        #expect(gate.handle(.end) == nil)
        #expect(gate.handle(.fail(.empty)) == nil)
        #expect(gate.verdict == .failed(.timedOut))
    }

    @Test func cancellationSettlesAsCancelled() {
        var gate = SynthesisGate()
        _ = gate.handle(.chunk(clip(0..<10)))
        #expect(gate.handle(.cancelled) == .cancelled)
        #expect(gate.handle(.end) == nil)
    }
}

// MARK: - Du tampon à l'événement (ce que fait le rappel, quel que soit le fil)

@Suite struct SynthesisEventTests {
    @Test func aBufferWithFramesBecomesAChunkCopiedWithItsOwnFormat() {
        let buffer = pcm(0..<64, rate: 24000)
        let event = SynthesisGate.Event.from(buffer)
        guard case .chunk(let copy) = event else { Issue.record("pas un morceau : \(event)"); return }
        #expect(copy == clip(0..<64, rate: 24000))
        // Le tampon appartient au système et sera réutilisé : la copie n'en dépend plus.
        buffer.floatChannelData![0][0] = 9
        #expect(copy.samples[0] == 0)
    }

    @Test func aZeroLengthBufferIsTheEnd() {
        guard case .end = SynthesisGate.Event.from(pcm(0..<0)) else { Issue.record("pas une fin"); return }
    }

    @Test func aBufferThatIsNotPCMFailsWithoutBeingIgnored() {
        var description = AudioStreamBasicDescription(
            mSampleRate: 22050, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        let compressed = AVAudioCompressedBuffer(format: AVAudioFormat(streamDescription: &description)!, packetCapacity: 1,
                                                 maximumPacketSize: 16)
        guard case .fail(.empty) = SynthesisGate.Event.from(compressed) else { Issue.record("pas un échec"); return }
    }
}

// MARK: - L'exécution, avec une source double

@MainActor
private final class FakeSource: SpeechBufferSource {
    var started: (text: String, voice: String)?
    var stopCount = 0
    var startError: SpeechError?
    let startedGate = Gate()
    /// Le rappel que `render` a confié à la source : sûr entre fils, comme celui du vrai système.
    private(set) var sender: (@Sendable (SynthesisGate.Event) -> Void)?

    func start(text: String, voiceIdentifier: String, emit: @escaping @Sendable (SynthesisGate.Event) -> Void) throws(SpeechError) {
        if let startError { throw startError }
        started = (text, voiceIdentifier)
        sender = emit
        startedGate.open()
    }

    func stop() { stopCount += 1 }

    /// Un tampon, comme le rappel de `write` le convertit (même fonction que la vraie couche).
    func emit(_ buffer: AVAudioBuffer) { sender?(.from(buffer)) }
    /// `didFinish` du délégué.
    func finish() { sender?(.end) }
    /// `didCancel` du délégué.
    func interrupt() { sender?(.interrupted) }
}

@MainActor
private func runRender(_ source: FakeSource, timeout: Double = 20, sleeper: TickSleeper = TickSleeper()) -> Task<[AudioClip], any Error> {
    Task { @MainActor in
        try await SpeechRendering.render(text: "Bonjour", voiceIdentifier: "voix-exemple", source: source, timeout: timeout,
                                         sleep: { try await sleeper.sleep($0) })
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct SpeechRenderingTests {
    @Test func buffersAreCopiedInOrderAndAZeroLengthBufferEndsTheRender() async throws {
        let source = FakeSource()
        let task = runRender(source)
        await source.startedGate.wait()
        #expect(source.started?.text == "Bonjour" && source.started?.voice == "voix-exemple")
        source.emit(pcm(0..<100))
        source.emit(pcm(100..<256))
        source.emit(pcm(0..<0))
        #expect(try await outcome(task).get() == [clip(0..<100), clip(100..<256)])
        #expect(source.stopCount == 0)   // une fin normale n'arrête rien
    }

    /// Aucune hypothèse sur le fil d'arrivée : les rappels viennent d'une file de fond (série), et l'ordre est gardé.
    @Test func eventsPushedFromABackgroundQueueKeepTheirOrder() async throws {
        let source = FakeSource()
        let task = runRender(source)
        await source.startedGate.wait()
        let send = try #require(source.sender)
        let buffers = (0..<400).map { pcm($0 * 2..<($0 + 1) * 2) }
        nonisolated(unsafe) let unsafeBuffers = buffers   // lus par la seule file série ci-dessous
        let queue = DispatchQueue(label: "essai.rappels")
        queue.async {
            for buffer in unsafeBuffers { send(.from(buffer)) }
            send(.from(pcm(0..<0)))
            send(.end)   // `didFinish`, 0,2 ms plus tard dans le vrai système : sans effet
        }
        let got = try await outcome(task).get()
        let expected = (0..<400).map { clip($0 * 2..<($0 + 1) * 2) }
        #expect(got == expected)   // 800 échantillons de 0 à 0,8 : sous l'écrêtage à 1
    }

    /// `didCancel` : le système interrompt tout seul ; le rendu échoue tout de suite, sans attendre la garde de durée.
    @Test func aSystemInterruptionFailsTheRenderAtOnceWithoutWaitingForTheGuard() async {
        let source = FakeSource(), sleeper = TickSleeper()
        let task = runRender(source, sleeper: sleeper)
        await source.startedGate.wait()
        source.emit(pcm(0..<50))
        source.interrupt()
        let result = await outcome(task)
        #expect(result.failureValue as? SpeechError == .timedOut)
        #expect(source.stopCount == 1)
        #expect(await timerWasCancelled(sleeper))   // la garde n'a pas rendu : elle a été annulée
    }

    /// `didFinish` seul (sans tampon nul) suffit ; s'il vient après le tampon nul, il est sans effet.
    @Test func theDelegateFinishEndsTheRenderAndALateOneChangesNothing() async throws {
        let source = FakeSource()
        let task = runRender(source)
        await source.startedGate.wait()
        source.emit(pcm(0..<64))
        source.finish()
        source.emit(pcm(64..<80))   // arrivé après la fin : ignoré
        source.finish()
        #expect(try await outcome(task).get() == [clip(0..<64)])
    }

    @Test func theEndIsTakenOnceWhenTheZeroBufferIsFollowedByDidFinish() async throws {
        let source = FakeSource()
        let task = runRender(source)
        await source.startedGate.wait()
        source.emit(pcm(0..<32))
        source.emit(pcm(0..<0))
        source.finish()
        source.finish()
        #expect(try await outcome(task).get() == [clip(0..<32)])
    }

    /// Aucun signal (synthétiseur libéré, ou boucle principale arrêtée) : la garde de durée rend `.timedOut` au lieu d'attendre sans fin.
    @Test func theDurationGuardThrowsTimedOutAndStopsTheSource() async {
        let source = FakeSource(), sleeper = TickSleeper()
        let task = runRender(source, timeout: 12.5, sleeper: sleeper)
        await source.startedGate.wait()
        source.emit(pcm(0..<50))
        await sleeper.waitForSleeps(1)
        #expect(sleeper.requested == [12.5])

        sleeper.tick()

        let result = await outcome(task)
        #expect(result.failureValue as? SpeechError == .timedOut)
        #expect(source.stopCount == 1)
    }

    @Test func aFinishedRenderCancelsItsTimer() async throws {
        let source = FakeSource(), sleeper = TickSleeper()
        let task = runRender(source, sleeper: sleeper)
        await source.startedGate.wait()
        await sleeper.waitForSleeps(1)
        source.emit(pcm(0..<0))
        _ = try await outcome(task).get()
        #expect(await timerWasCancelled(sleeper))
    }

    @Test func aGuardThatFiresAfterTheEndChangesNothing() async throws {
        let source = FakeSource(), sleeper = TickSleeper()
        let task = runRender(source, sleeper: sleeper)
        await source.startedGate.wait()
        source.emit(pcm(0..<10))
        source.emit(pcm(0..<0))
        #expect(try await outcome(task).get() == [clip(0..<10)])
        sleeper.tick()
        #expect(source.stopCount == 0)
    }

    @Test func cancellingTheTaskStopsTheSourceAndThrowsCancellation() async {
        let source = FakeSource(), sleeper = TickSleeper()
        let task = runRender(source, sleeper: sleeper)
        await source.startedGate.wait()
        source.emit(pcm(0..<50))

        task.cancel()

        #expect((await outcome(task)).failureValue is CancellationError)
        #expect(source.stopCount == 1)
        #expect(await timerWasCancelled(sleeper))
    }

    @Test func aTaskCancelledBeforeTheStartNeverLeavesAHangingRender() async {
        let source = FakeSource()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SpeechRendering.render(text: "Bonjour", voiceIdentifier: "voix-exemple", source: source, timeout: 20,
                                                    sleep: { _ in try await Task.sleep(for: .seconds(1_000_000)) })
        }
        #expect((await outcome(task)).failureValue is CancellationError)
        #expect(source.stopCount <= 1)
    }

    @Test func aStartErrorIsThrownAsIs() async {
        let source = FakeSource()
        source.startError = .noVoice(language: "fr-FR")
        let task = runRender(source)
        #expect((await outcome(task)).failureValue as? SpeechError == .noVoice(language: "fr-FR"))
    }

    /// Un tampon qui n'est pas du PCM, ou que l'on ne sait pas lire, n'est pas ignoré en silence : la parole serait tronquée.
    @Test func aBufferThatCannotBeReadFailsTheRender() async {
        let source = FakeSource()
        let task = runRender(source)
        await source.startedGate.wait()
        source.emit(pcm(0..<20))
        var description = AudioStreamBasicDescription(
            mSampleRate: 22050, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        let compressed = AVAudioCompressedBuffer(format: AVAudioFormat(streamDescription: &description)!, packetCapacity: 1,
                                                 maximumPacketSize: 16)
        source.emit(compressed)
        #expect((await outcome(task)).failureValue as? SpeechError == .empty)
        #expect(source.stopCount == 1)
    }
}
