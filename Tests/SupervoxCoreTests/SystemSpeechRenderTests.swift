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

/// Rend vrai quand l'attente de la garde a été annulée (sans horloge de test : quelques milliers de passages au plus).
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

    @Test func cancellationSettlesAsCancelled() {
        var gate = SynthesisGate()
        _ = gate.handle(.chunk(clip(0..<10)))
        #expect(gate.handle(.cancelled) == .cancelled)
        #expect(gate.handle(.end) == nil)
    }
}

// MARK: - L'exécution, avec une source double

@MainActor
private final class FakeSource: SpeechBufferSource {
    var started: (text: String, voice: String)?
    var stopCount = 0
    var startError: SpeechError?
    let startedGate = Gate()
    private var onBuffer: (@MainActor (AVAudioBuffer) -> Void)?
    private var onFinish: (@MainActor () -> Void)?

    func start(text: String, voiceIdentifier: String, onBuffer: @escaping @MainActor (AVAudioBuffer) -> Void,
               onFinish: @escaping @MainActor () -> Void) throws(SpeechError) {
        if let startError { throw startError }
        started = (text, voiceIdentifier)
        self.onBuffer = onBuffer
        self.onFinish = onFinish
        startedGate.open()
    }

    func stop() { stopCount += 1 }

    func emit(_ buffer: AVAudioBuffer) { onBuffer?(buffer) }
    func finish() { onFinish?() }
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
