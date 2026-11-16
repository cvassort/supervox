import AVFAudio
import Foundation
import os
import Testing
@testable import SupervoxCore

// MARK: - Conversion d'un clip vers le format du lecteur (règle 2), sans matériel

private func format(rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
    // Au-delà de deux canaux, le format exige une disposition des canaux.
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
    return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: layout)
}

/// Un ton de 440 Hz à 22 050 Hz, d'amplitude 0,5 : 22 050 échantillons, soit une seconde.
private func tone(seconds: Double = 1, rate: Double = 22_050, amplitude: Float = 0.5) -> AudioClip {
    AudioClip(samples: (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * Double.pi * 440 * Double($0) / rate)) }, sampleRate: rate)
}

private func channel(_ buffer: AVAudioPCMBuffer, _ index: Int) -> [Float] {
    Array(UnsafeBufferPointer(start: buffer.floatChannelData![index], count: Int(buffer.frameLength)))
}

/// 22 050 échantillons à 22 050 Hz vers 48 kHz stéréo : environ 48 000 trames. La marge (±1 % soit ±480 trames) borne
/// la latence du convertisseur ; elle n'a pas été mesurée avant ce test, c'est un choix non mesuré.
@Test func aMonoClipBecomesAboutOneSecondOfIdenticalStereoChannelsAt48Kilohertz() throws {
    let buffer = try #require(AudioCapture.playbackBuffer(tone(), format: format(rate: 48_000, channels: 2)))
    #expect(buffer.format.sampleRate == 48_000)
    #expect(buffer.format.channelCount == 2)
    #expect(abs(Int(buffer.frameLength) - 48_000) <= 480, "\(buffer.frameLength) trames")
    let left = channel(buffer, 0)
    #expect(left == channel(buffer, 1))
    #expect(left.contains { abs($0) > 0.4 }, "le ton doit être là, d'amplitude voisine de 0,5")
}

@Test func aMonoClipToA44100HertzMonoFormatKeepsOneChannel() throws {
    let buffer = try #require(AudioCapture.playbackBuffer(tone(), format: format(rate: 44_100, channels: 1)))
    #expect(buffer.format.channelCount == 1)
    #expect(abs(Int(buffer.frameLength) - 44_100) <= 441, "\(buffer.frameLength) trames")
}

/// Le format du nœud n'est pas supposé : quatre canaux reçoivent le même signal.
@Test func everyChannelOfTheNodeFormatReceivesTheSameSignal() throws {
    let buffer = try #require(AudioCapture.playbackBuffer(tone(), format: format(rate: 44_100, channels: 4)))
    let first = channel(buffer, 0)
    for index in 1..<4 { #expect(channel(buffer, index) == first, "canal \(index)") }
}

@Test func aClipAtTheNodeRateIsCopiedWithoutResampling() throws {
    let clip = tone(rate: 44_100)
    let buffer = try #require(AudioCapture.playbackBuffer(clip, format: format(rate: 44_100, channels: 2)))
    #expect(Int(buffer.frameLength) == clip.samples.count)
    #expect(channel(buffer, 0) == clip.samples)
}

@Test func anEmptyClipHasNoBuffer() {
    #expect(AudioCapture.playbackBuffer(AudioClip(samples: [], sampleRate: 22_050), format: format(rate: 48_000, channels: 2)) == nil)
}

/// NaN devient 0 (et l'infini aussi : un échantillon non fini ferait claquer le haut-parleur) ; sans cela le NaN
/// contaminerait les voisins par le filtre du convertisseur.
@Test func nonFiniteSamplesBecomeZeroAndDoNotSpreadThroughTheResampler() throws {
    var samples = [Float](repeating: 0.25, count: 2_000)
    samples[1_000] = .nan
    samples[1_500] = .infinity
    let buffer = try #require(AudioCapture.playbackBuffer(AudioClip(samples: samples, sampleRate: 22_050), format: format(rate: 44_100, channels: 1)))
    let converted = channel(buffer, 0)
    #expect(converted.allSatisfy { $0.isFinite })
    #expect(converted.contains { $0 > 0.2 })
    // Même fréquence : la copie est exacte, le NaN est devenu 0 à sa place.
    let same = try #require(AudioCapture.playbackBuffer(AudioClip(samples: samples, sampleRate: 44_100), format: format(rate: 44_100, channels: 1)))
    #expect(channel(same, 0)[1_000] == 0 && channel(same, 0)[1_500] == 0 && channel(same, 0)[999] == 0.25)
}

/// Un format entrelacé ou entier n'a pas de `floatChannelData` : pas de tampon plutôt qu'un déréférencement.
@Test func aFormatTheBufferCannotBeFilledWithIsRefused() {
    let interleaved = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: true)!
    let integer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 2, interleaved: false)!
    #expect(AudioCapture.playbackBuffer(tone(), format: interleaved) == nil)
    #expect(AudioCapture.playbackBuffer(tone(), format: integer) == nil)
}

// MARK: - AudioCapture, sans moteur démarré

@Test func playingBeforeStartThrowsNotRunningAndCallsNothing() throws {
    let capture = AudioCapture()
    let called = OSAllocatedUnfairLock(initialState: 0)
    #expect(throws: AudioCaptureError.notRunning) {
        try capture.play(tone(seconds: 0.1)) { _ in called.withLock { $0 += 1 } }
    }
    capture.playback.flushEvents()
    #expect(called.withLock { $0 } == 0)
    #expect(!capture.playback.hasPending)
}

@Test func withoutPlaybackThePositionIsNilAndStoppingTouchesNothing() {
    let capture = AudioCapture()
    #expect(capture.playbackPosition == nil)
    capture.stopPlayback()   // ne fait rien, et ne touche pas un lecteur qui n'est pas monté
    #expect(capture.stop().samples.isEmpty)
    #expect(capture.playbackPosition == nil)
}

// MARK: - LiveAudioIO : un seul moteur pour la capture et la lecture (règle 4), avec une capture double

/// Capture double : note les appels dans l'ordre, rend à `stopPlayback()` et à `stop()` le comportement du vrai lecteur mesuré à la
/// tâche 1, c'est-à-dire des rappels `.stopped` **synchrones, sur le fil appelant**, pendant l'appel.
private final class FakeDevice: PlaybackCapture {
    private struct State {
        var log: [String] = []
        var running = false
        var handler: (@Sendable (AudioChunk) -> Void)?
        var queued: [@Sendable (PlaybackEnd) -> Void] = []
        var position: Double?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var log: [String] { state.withLock { $0.log } }
    var isRunning: Bool { state.withLock { $0.running } }
    var queuedCount: Int { state.withLock { $0.queued.count } }
    func setPosition(_ value: Double?) { state.withLock { $0.position = value } }
    /// Livre une tranche comme le ferait le tap.
    func tap(_ chunk: AudioChunk) { state.withLock { $0.handler }?(chunk) }

    func startStreaming(onChunk: @escaping @Sendable (AudioChunk) -> Void, accumulate: Bool) throws {
        state.withLock {
            $0.log.append("start(accumulate: \(accumulate))")
            $0.running = true
            $0.handler = onChunk
        }
    }

    func stop() -> AudioClip {
        let queued = state.withLock { state -> [@Sendable (PlaybackEnd) -> Void] in
            state.log.append("stop")
            state.running = false
            defer { state.queued = [] }
            return state.queued
        }
        for end in queued { end(.stopped) }   // synchrone, hors du verrou : comme `player.stop()`
        return AudioClip(samples: [], sampleRate: 16_000)
    }

    func play(_ clip: AudioClip, onEnd: @escaping @Sendable (PlaybackEnd) -> Void) throws {
        try state.withLock { state in
            guard state.running else { throw AudioCaptureError.notRunning }
            state.log.append("play")
            state.queued.append(onEnd)
        }
    }

    func stopPlayback() {
        let queued = state.withLock { state -> [@Sendable (PlaybackEnd) -> Void] in
            state.log.append("stopPlayback")
            defer { state.queued = [] }
            return state.queued
        }
        for end in queued { end(.stopped) }
    }

    var playbackPosition: Double? { state.withLock { $0.position } }
}

private final class Received: Sendable {
    private let store = OSAllocatedUnfairLock(initialState: [PlaybackEnd]())
    var ends: [PlaybackEnd] { store.withLock { $0 } }
    var onEnd: @Sendable (PlaybackEnd) -> Void { { end in self.store.withLock { $0.append(end) } } }
}

private let someClip = AudioClip(samples: [0.1, 0.2, 0.3], sampleRate: 22_050)

@Test func startAndPlayGoToTheSameDeviceAndTheTapKeepsNoBuffer() throws {
    let device = FakeDevice()
    let io = LiveAudioIO(device: device)
    try io.start { _ in }
    try io.play(someClip) { _ in }
    // Un seul objet a vu les deux appels, dans l'ordre ; le tampon interne n'accumule rien (la dictée longue ne grossit pas).
    #expect(device.log == ["start(accumulate: false)", "play"])
}

@Test func playBeforeStartThrowsNotRunning() {
    let device = FakeDevice()
    let io = LiveAudioIO(device: device)
    #expect(throws: AudioCaptureError.notRunning) { try io.play(someClip) { _ in } }
    #expect(device.log.isEmpty)
}

@Test func stopGivesStoppedToEveryQueuedClipAndStopsTheCapture() throws {
    let device = FakeDevice()
    let io = LiveAudioIO(device: device)
    let received = Received()
    try io.start { _ in }
    try io.play(someClip, onEnd: received.onEnd)
    try io.play(someClip, onEnd: received.onEnd)
    io.stop()
    #expect(received.ends == [.stopped, .stopped])
    #expect(device.log.last == "stop")
    #expect(!device.isRunning)
}

@Test func stopPlaybackStopsTheClipsAndLeavesTheCaptureRunning() throws {
    let device = FakeDevice()
    let io = LiveAudioIO(device: device)
    let received = Received()
    let chunks = OSAllocatedUnfairLock(initialState: 0)
    try io.start { _ in chunks.withLock { $0 += 1 } }
    try io.play(someClip, onEnd: received.onEnd)
    io.stopPlayback()
    #expect(received.ends == [.stopped])
    #expect(device.log == ["start(accumulate: false)", "play", "stopPlayback"])   // pas de « stop »
    #expect(device.isRunning)
    device.tap(AudioChunk(samples: [0.1], sampleRate: 16_000))
    #expect(chunks.withLock { $0 } == 1, "le micro continue de livrer après stopPlayback")
}

/// L'appareil rappelle ses gestionnaires de façon synchrone depuis son `stopPlayback()` (comme le vrai lecteur). `LiveAudioIO` n'a aucun
/// verrou : ce test ne prouve que le transit, une fois, sur un autre fil, sans attente. La protection contre l'interblocage vit dans
/// `PlaybackTracker` (`stopAllHoldsNoLockWhileThePlayerCallsItsHandlersSynchronously`, processus fils), là où le verrou existe.
@Test func aSynchronousCallbackFromTheDevicesStopPlaybackReachesOnEndExactlyOnce() throws {
    let device = FakeDevice()
    let io = LiveAudioIO(device: device)
    let received = Received()
    let gate = NSLock()   // un verrou que l'`onEnd` de l'appelant prend aussi, sans que `LiveAudioIO` le tienne
    try io.start { _ in }
    try io.play(someClip) { end in
        gate.lock()
        defer { gate.unlock() }
        received.onEnd(end)
    }
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        io.stopPlayback()
        finished.signal()
    }
    #expect(finished.wait(timeout: .now() + 10) == .success, "stopPlayback() ne revient pas : interblocage")
    #expect(received.ends == [.stopped])
}

@Test func theTapChunksReachTheCallerAndThePositionIsTheDevices() throws {
    let device = FakeDevice()
    let io = LiveAudioIO(device: device)
    let got = OSAllocatedUnfairLock(initialState: [AudioChunk]())
    try io.start { chunk in got.withLock { $0.append(chunk) } }
    let chunk = AudioChunk(samples: [0.5, 0.25], sampleRate: 48_000)
    device.tap(chunk)
    #expect(got.withLock { $0 } == [chunk])
    #expect(io.playbackPosition == nil)
    device.setPosition(1.5)
    #expect(io.playbackPosition == 1.5)
}

/// Le vrai appareil : une seule `AudioCapture`, avec traitement de la voix, qui ne déclenche jamais l'invite système.
@Test func theLiveDeviceIsOneVoiceProcessingCaptureThatNeverPromptsForAccess() throws {
    let io = LiveAudioIO()
    let capture = try #require(io.device as? AudioCapture)
    #expect(capture.voiceProcessing)
    #expect(!capture.promptsForAccess)
}

// MARK: - ScriptedAudioIO (règle 5)

/// Les fins reçues, avec le clip auquel elles se rapportent ; peut être attendue (continuation) pour le mode asynchrone.
private final class Sink: Sendable {
    private let store = OSAllocatedUnfairLock(initialState: [String]())
    var all: [String] { store.withLock { $0 } }
    func onEnd(_ name: String) -> @Sendable (PlaybackEnd) -> Void {
        { end in self.store.withLock { $0.append("\(name):\(end)") } }
    }
}

private func clip(seconds: Double, rate: Double = 10) -> AudioClip {
    AudioClip(samples: [Float](repeating: 0.1, count: Int(seconds * rate)), sampleRate: rate)
}

@Test func manualModeRendersNothingBeforeFinishPlayback() throws {
    let io = ScriptedAudioIO()
    let sink = Sink()
    try io.start { _ in }
    try io.play(clip(seconds: 1), onEnd: sink.onEnd("a"))
    try io.play(clip(seconds: 2), onEnd: sink.onEnd("b"))
    #expect(sink.all.isEmpty)
    #expect(io.finishPlayback(.played))
    #expect(sink.all == ["a:played"])   // le clip en tête de file
    #expect(io.finishPlayback(.stopped))
    #expect(sink.all == ["a:played", "b:stopped"])
    #expect(!io.finishPlayback(.played), "plus aucun clip en file")
}

@Test func immediateModeRendersPlayedInOrderOfTheCalls() throws {
    let io = ScriptedAudioIO(completion: .immediate)
    let sink = Sink()
    try io.start { _ in }
    try io.play(clip(seconds: 1), onEnd: sink.onEnd("a"))
    try io.play(clip(seconds: 1), onEnd: sink.onEnd("b"))
    #expect(sink.all == ["a:played", "b:played"])
    #expect(io.played.count == 2)
}

/// L'attente reçoit la durée du clip ; `.played` n'arrive qu'à son retour, et chaque clip attend la fin du précédent.
@Test func afterDurationModeCallsTheWaitWithTheClipDurationThenRendersPlayed() async throws {
    let waited = OSAllocatedUnfairLock(initialState: [Double]())
    let io = ScriptedAudioIO(completion: .afterDuration { seconds in waited.withLock { $0.append(seconds) } })
    let sink = Sink()
    try io.start { _ in }
    await withCheckedContinuation { (all: CheckedContinuation<Void, Never>) in
        do {
            try io.play(clip(seconds: 1.5)) { end in sink.onEnd("a")(end) }
            try io.play(clip(seconds: 0.5)) { end in sink.onEnd("b")(end); all.resume() }
        } catch { all.resume() }
    }
    #expect(waited.withLock { $0 } == [1.5, 0.5])
    #expect(sink.all == ["a:played", "b:played"])
}

/// Arrêt pendant l'attente : `.stopped` tout de suite, et la fin naturelle qui suit (l'attente se débloque) n'appelle plus rien.
@Test func stopPlaybackDuringTheWaitRendersStoppedAndTheLateEndCallsNothing() async throws {
    let release = AsyncStream<Void>.makeStream()
    let entered = AsyncStream<Void>.makeStream()
    let io = ScriptedAudioIO(completion: .afterDuration { _ in
        entered.continuation.yield()
        for await _ in release.stream { break }
    })
    let sink = Sink()
    try io.start { _ in }
    try io.play(clip(seconds: 1), onEnd: sink.onEnd("a"))
    for await _ in entered.stream { break }   // l'attente est en cours
    io.stopPlayback()
    #expect(sink.all == ["a:stopped"])
    release.continuation.yield()
    try await Task.sleep(for: .milliseconds(50))   // attente d'un événement qui ne doit PAS arriver : ne peut produire qu'un faux succès
    #expect(sink.all == ["a:stopped"])
}

@Test func stopPlaybackRendersStoppedToTheQueuedClipsAndIsCounted() throws {
    let io = ScriptedAudioIO()
    let sink = Sink()
    try io.start { _ in }
    try io.play(clip(seconds: 1), onEnd: sink.onEnd("a"))
    try io.play(clip(seconds: 1), onEnd: sink.onEnd("b"))
    io.stopPlayback()
    #expect(sink.all == ["a:stopped", "b:stopped"])
    #expect(io.stopPlaybackCount == 1)
    #expect(io.isRunning, "stopPlayback ne touche pas la capture")
    io.stopPlayback()
    #expect(io.stopPlaybackCount == 2)
}

@Test func stopRendersStoppedToTheQueuedClipsAndStopsTheCapture() throws {
    let io = ScriptedAudioIO()
    let sink = Sink()
    try io.start { _ in }
    try io.play(clip(seconds: 1), onEnd: sink.onEnd("a"))
    io.stop()
    #expect(sink.all == ["a:stopped"])
    #expect(!io.isRunning)
}

@Test func pushDeliversOnTheCallersThreadAndNothingAfterStopOrBeforeStart() throws {
    let io = ScriptedAudioIO()
    let got = OSAllocatedUnfairLock(initialState: [AudioChunk]())
    let deliveredOn = OSAllocatedUnfairLock(initialState: 0 as UInt32)
    io.push(AudioChunk(samples: [9], sampleRate: 1))   // avant start : rien
    try io.start { chunk in
        got.withLock { $0.append(chunk) }
        deliveredOn.withLock { $0 = pthread_mach_thread_np(pthread_self()) }
    }
    let first = AudioChunk(samples: [1], sampleRate: 16_000)
    io.push(first)
    #expect(got.withLock { $0 } == [first])
    #expect(deliveredOn.withLock { $0 } == pthread_mach_thread_np(pthread_self()), "`onChunk` tourne sur le fil de l'appelant")
    io.stop()
    io.push(AudioChunk(samples: [2], sampleRate: 16_000))
    #expect(got.withLock { $0 } == [first], "push après stop() ne livre rien")
}

/// Un `push` d'un autre fil, arrêté dans `onChunk`, est attendu par `stop()` : le même contrat que le vrai micro.
@Test func stopWaitsForAPushInProgress() throws {
    let io = ScriptedAudioIO()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    try io.start { _ in
        entered.signal()
        release.wait()
    }
    DispatchQueue.global().async { io.push(AudioChunk(samples: [1], sampleRate: 1)) }
    #expect(entered.wait(timeout: .now() + 10) == .success)
    let stopReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        io.stop()
        stopReturned.signal()
    }
    #expect(stopReturned.wait(timeout: .now() + 0.2) == .timedOut, "stop() est revenu pendant une livraison")
    release.signal()
    #expect(stopReturned.wait(timeout: .now() + 10) == .success)
}

@Test func theLogHoldsTheAcceptedCallsInOrder() throws {
    let io = ScriptedAudioIO(completion: .immediate)
    #expect(throws: AudioCaptureError.notRunning) { try io.play(clip(seconds: 1)) { _ in } }   // refusé : pas dans le journal
    try io.start { _ in }
    #expect(throws: AudioCaptureError.alreadyRunning) { try io.start { _ in } }                   // refusé
    try io.play(clip(seconds: 1)) { _ in }
    io.stopPlayback()
    try io.play(clip(seconds: 1)) { _ in }
    io.stop()
    #expect(io.log == ["start", "play", "stopPlayback", "play", "stop"])
    #expect(io.played.count == 2, "le clip refusé n'est pas compté")
}

@Test func aStartErrorIsThrownAndNothingIsRecorded() {
    let io = ScriptedAudioIO(startError: .microphoneAccessDenied("accès refusé"))
    #expect(throws: AudioCaptureError.microphoneAccessDenied("accès refusé")) { try io.start { _ in } }
    #expect(io.log.isEmpty)
    #expect(!io.isRunning)
}

@Test func theScriptedPositionIsNilWithoutAClipAndWhatTheTestSetsWhileOneIsQueued() throws {
    let io = ScriptedAudioIO()
    try io.start { _ in }
    #expect(io.playbackPosition == nil)
    try io.play(clip(seconds: 2)) { _ in }
    #expect(io.playbackPosition == 0)
    io.scriptedPosition = 1.25
    #expect(io.playbackPosition == 1.25)
    io.finishPlayback(.played)
    #expect(io.playbackPosition == nil)
}

/// `onEnd` d'un double rappelant `play()` (le suivant de la file) ne prend aucun verrou du double : pas d'interblocage.
@Test func anOnEndThatPlaysTheNextClipDoesNotDeadlockTheDouble() throws {
    let io = ScriptedAudioIO()
    let sink = Sink()
    try io.start { _ in }
    try io.play(clip(seconds: 1)) { end in
        sink.onEnd("a")(end)
        try? io.play(clip(seconds: 1), onEnd: sink.onEnd("b"))
    }
    io.finishPlayback(.played)
    #expect(io.finishPlayback(.played))
    #expect(sink.all == ["a:played", "b:played"])
}

// MARK: - `onChunk` ne rappelle jamais l'`AudioIO` : précondition, dans le vrai comme dans le double (processus fils)

/// Sans cette précondition, `stopPlayback()` ou `play()` appelé depuis `onChunk` prend `lifecycle` pendant qu'un `stop()` d'un autre
/// fil tient `lifecycle` et attend la fin de `onChunk` : les deux fils restent bloqués pour toujours (sondé par la revue).
private func syntheticTapWindow() -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    let window = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
    window.frameLength = 480
    return window
}

private func expectProgrammingError(_ stderr: [UInt8], mentioning call: String) {
    let text = String(decoding: stderr, as: UTF8.self)
    #expect(text.contains("erreur de programmation"), "\(text)")
    #expect(text.contains(call), "\(text)")
}

@Test func captureStopPlaybackFromOnChunkIsAProgrammingError() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
        let capture = AudioCapture()
        let tap = capture.makeTap(sampleRate: 48_000, accumulate: false) { _ in capture.stopPlayback() }
        tap(syntheticTapWindow(), AVAudioTime(hostTime: 0))
    }
    expectProgrammingError(result.standardErrorContent, mentioning: "stopPlayback()")
}

@Test func capturePlayFromOnChunkIsAProgrammingError() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
        let capture = AudioCapture()
        let tap = capture.makeTap(sampleRate: 48_000, accumulate: false) { _ in
            try? capture.play(AudioClip(samples: [0.1], sampleRate: 22_050)) { _ in }
        }
        tap(syntheticTapWindow(), AVAudioTime(hostTime: 0))
    }
    expectProgrammingError(result.standardErrorContent, mentioning: "play()")
}

@Test func scriptedStopPlaybackFromOnChunkIsAProgrammingError() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
        let io = ScriptedAudioIO()
        try io.start { _ in io.stopPlayback() }
        io.push(AudioChunk(samples: [0.1], sampleRate: 16_000))
    }
    expectProgrammingError(result.standardErrorContent, mentioning: "stopPlayback()")
}

@Test func scriptedPlayFromOnChunkIsAProgrammingError() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
        let io = ScriptedAudioIO()
        try io.start { _ in try? io.play(AudioClip(samples: [0.1], sampleRate: 16_000)) { _ in } }
        io.push(AudioChunk(samples: [0.1], sampleRate: 16_000))
    }
    expectProgrammingError(result.standardErrorContent, mentioning: "play()")
}

@Test func scriptedStopFromOnChunkIsAProgrammingError() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
        let io = ScriptedAudioIO()
        try io.start { _ in io.stop() }
        io.push(AudioChunk(samples: [0.1], sampleRate: 16_000))
    }
    expectProgrammingError(result.standardErrorContent, mentioning: "stop()")
}

/// La précondition ne vise que l'appel depuis `onChunk` : depuis un autre fil, pendant une livraison en cours, ces appels restent permis
/// (ils attendent la porte ou passent) ; ici hors de toute livraison, sur le double comme sur le vrai.
@Test func playAndStopPlaybackOutsideOnChunkAreNotRefused() throws {
    let io = ScriptedAudioIO()
    try io.start { _ in }
    try io.play(someClip) { _ in }
    io.stopPlayback()
    io.stop()
    let capture = AudioCapture()
    capture.stopPlayback()
}
