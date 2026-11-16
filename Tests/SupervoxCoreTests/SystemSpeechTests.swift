import AVFAudio
import Foundation
import os
import Testing
@testable import SupervoxCore

// Voix du système : tout se prouve avec un `render` double ou avec la petite machine d'état (`SynthesisGate`) et une source de
// tampons double. Aucun test n'appelle `AVSpeechSynthesizer` : la mince couche qui le fait (`AVSpeechBufferSource`) n'est
// jamais construite ici, et les tampons sont fabriqués en mémoire.

private func voice(_ id: String, _ language: String, _ quality: Int) -> SystemVoiceInfo {
    SystemVoiceInfo(identifier: id, language: language, quality: quality)
}

private func floatBuffer(_ channels: [[Float]], rate: Double = 22050, interleaved: Bool = false) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels.count),
                               interleaved: interleaved)!
    let frames = channels[0].count
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = buffer.floatChannelData!
    for frame in 0..<frames {
        for (c, samples) in channels.enumerated() {
            if interleaved { data[0][frame * channels.count + c] = samples[frame] } else { data[c][frame] = samples[frame] }
        }
    }
    return buffer
}

private func int16Buffer(_ samples: [Int16], rate: Double = 22050) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    for (i, s) in samples.enumerated() { buffer.int16ChannelData![0][i] = s }
    return buffer
}

private func ramp(_ range: Range<Int>) -> [Float] { range.map { Float($0) / 1000 } }

private let french = [voice("v-fr-fr-def", "fr-FR", 1)]

/// Un `render` double qui compte ses appels et rend ce que le test lui dit.
private final class RenderProbe: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [(text: String, voice: String)]())
    var calls: [(text: String, voice: String)] { state.withLock { $0 } }
    func record(_ text: String, _ voice: String) { state.withLock { $0.append((text, voice)) } }
}

private func synthesizer(language: String = "fr-FR", voices: [SystemVoiceInfo] = french, probe: RenderProbe = RenderProbe(),
                         render: @escaping @Sendable (String, String) async throws -> [AudioClip]) -> SystemSpeechSynthesizer {
    SystemSpeechSynthesizer(language: language, voices: { voices }, render: { text, id in
        probe.record(text, id)
        return try await render(text, id)
    })
}

// MARK: - Règle 1 : choix de la voix

@Suite struct SystemVoiceChoiceTests {
    @Test func theExactLanguageComesBeforeAnyBetterVoiceOfAnotherRegion() {
        let voices = [voice("ca-premium", "fr-CA", 3), voice("fr-default", "fr-FR", 1), voice("be-enhanced", "fr-BE", 2)]
        #expect(SystemSpeechSynthesizer.pickVoice(language: "fr-FR", among: voices)?.identifier == "fr-default")
    }

    @Test func amongTheExactLanguageTheBestQualityWins() {
        let voices = [voice("a", "fr-FR", 1), voice("b", "fr-FR", 3), voice("c", "fr-FR", 2)]
        #expect(SystemSpeechSynthesizer.pickVoice(language: "fr-FR", among: voices)?.identifier == "b")
    }

    @Test func withoutTheExactLanguageAnyFrenchVoiceIsChosenByQuality() {
        let voices = [voice("en", "en-US", 3), voice("ca", "fr-CA", 1), voice("be", "fr-BE", 2)]
        #expect(SystemSpeechSynthesizer.pickVoice(language: "fr-FR", among: voices)?.identifier == "be")
    }

    @Test func equalQualityKeepsTheFirstVoiceOfTheList() {
        let voices = [voice("premiere", "fr-FR", 1), voice("seconde", "fr-FR", 1)]
        #expect(SystemSpeechSynthesizer.pickVoice(language: "fr-FR", among: voices)?.identifier == "premiere")
    }

    @Test func noFrenchVoiceGivesNil() {
        let voices = [voice("en", "en-US", 3), voice("fra", "frr-DE", 3), voice("de", "de-DE", 2)]
        #expect(SystemSpeechSynthesizer.pickVoice(language: "fr-FR", among: voices) == nil)
        #expect(SystemSpeechSynthesizer.pickVoice(language: "fr-FR", among: []) == nil)
    }

    @Test func theLanguageTagIsComparedWithoutCaseNorUnderscoreDifference() {
        let voices = [voice("a", "fr_fr", 1), voice("b", "fr-CA", 3)]
        #expect(SystemSpeechSynthesizer.pickVoice(language: "fr-FR", among: voices)?.identifier == "a")
    }

    @Test func noFrenchVoiceThrowsNoVoiceWithoutCallingRender() async {
        let probe = RenderProbe()
        let speaker = synthesizer(voices: [voice("en", "en-US", 3)], probe: probe) { _, _ in [AudioClip(samples: [0.1], sampleRate: 8000)] }
        await #expect(throws: SpeechError.noVoice(language: "fr-FR")) { try await speaker.synthesize("Bonjour") }
        #expect(probe.calls.isEmpty)
    }

    @Test func renderReceivesTheTextAndTheChosenVoiceIdentifier() async throws {
        let probe = RenderProbe()
        let speaker = synthesizer(voices: [voice("autre", "fr-CA", 1), voice("choisie", "fr-FR", 1)], probe: probe) { _, _ in
            [AudioClip(samples: [0.1], sampleRate: 8000)]
        }
        _ = try await speaker.synthesize("Bonjour tout le monde")
        #expect(probe.calls.count == 1)
        #expect(probe.calls.first?.text == "Bonjour tout le monde" && probe.calls.first?.voice == "choisie")
    }
}

// MARK: - Règle 2 : tampons

@Suite struct SystemSpeechBufferTests {
    @Test func aFloatBufferGivesItsFirstChannelAtItsOwnRate() throws {
        let first = ramp(0..<50), second = ramp(500..<550)
        let clip = try #require(SystemSpeechSynthesizer.clip(from: floatBuffer([first, second], rate: 24000)))
        #expect(clip.samples == first)
        #expect(clip.sampleRate == 24000)
    }

    @Test func aMultiChannelInterleavedBufferGivesItsFirstChannelToo() throws {
        let first = ramp(0..<20), second = ramp(300..<320)
        let clip = try #require(SystemSpeechSynthesizer.clip(from: floatBuffer([first, second], interleaved: true)))
        #expect(clip.samples == first)
    }

    @Test func anInt16BufferIsBroughtBackToMinusOneOne() throws {
        let clip = try #require(SystemSpeechSynthesizer.clip(from: int16Buffer([0, 16384, -16384, -32768, 32767], rate: 16000)))
        #expect(clip.sampleRate == 16000)
        #expect(clip.samples == [0, 0.5, -0.5, -1, Float(32767) / 32768])
    }

    @Test func aFloatBufferOutOfRangeIsClampedAndNaNBecomesSilence() throws {
        let clip = try #require(SystemSpeechSynthesizer.clip(from: floatBuffer([[2, -3, .nan, 0.25]])))
        #expect(clip.samples == [1, -1, 0, 0.25])
    }

    @Test func aZeroLengthBufferGivesNil() {
        #expect(SystemSpeechSynthesizer.clip(from: floatBuffer([[]])) == nil)
        #expect(SystemSpeechSynthesizer.clip(from: int16Buffer([])) == nil)
    }

    @Test func severalChunksMakeOneClipInOrderAtTheRateOfTheFirst() async throws {
        let speaker = synthesizer { _, _ in [
            AudioClip(samples: ramp(0..<100), sampleRate: 22050), AudioClip(samples: ramp(100..<150), sampleRate: 22050),
            AudioClip(samples: ramp(150..<160), sampleRate: 22050),
        ] }
        let speech = try await speaker.synthesize("Bonjour")
        #expect(speech.clip == AudioClip(samples: ramp(0..<160), sampleRate: 22050))
        #expect(!speech.fellBack)
    }

    /// Un morceau d'une autre fréquence est ramené à celle du premier (durée conservée), jamais collé tel quel.
    @Test func aChunkAtAnotherRateIsResampledToTheFirstRate() async throws {
        let tone = (0..<4410).map { Float(sin(Double($0) * 2 * .pi * 440 / 44100)) * 0.5 }   // 0,1 s à 44 100 Hz
        let speaker = synthesizer { _, _ in [
            AudioClip(samples: Array(repeating: 0.1, count: 2205), sampleRate: 22050),      // 0,1 s
            AudioClip(samples: tone, sampleRate: 44100),
        ] }
        let clip = try await speaker.synthesize("Bonjour").clip
        #expect(clip.sampleRate == 22050)
        #expect(abs(clip.duration - 0.2) < 0.01)
        #expect(clip.samples.prefix(2205).allSatisfy { $0 == 0.1 })
        #expect(clip.samples.suffix(2205).contains { abs($0) > 0.3 })   // le ton est bien là, au bon niveau
    }

    @Test func noSampleAtAllThrowsEmpty() async {
        for chunks in [[AudioClip](), [AudioClip(samples: [], sampleRate: 22050), AudioClip(samples: [], sampleRate: 22050)]] {
            let speaker = synthesizer { _, _ in chunks }
            await #expect(throws: SpeechError.empty) { try await speaker.synthesize("Bonjour") }
        }
    }

    @Test func aBlankTextThrowsEmptyWithoutCallingRender() async {
        let probe = RenderProbe()
        let speaker = synthesizer(probe: probe) { _, _ in [AudioClip(samples: [0.1], sampleRate: 8000)] }
        await #expect(throws: SpeechError.empty) { try await speaker.synthesize("  \n ") }
        #expect(probe.calls.isEmpty)
    }
}

// MARK: - Règle 3 : annulation de la tâche

@Suite(.timeLimit(.minutes(1))) struct SystemSpeechCancellationTests {
    /// Un `render` qui attend son annulation et dit qu'il l'a vue.
    private final class Hanging: @unchecked Sendable {
        let started = Gate(), sawCancellation = Gate()
        func render(_ text: String, _ voice: String) async throws -> [AudioClip] {
            started.open()
            do { try await Task.sleep(for: .seconds(1_000_000)) } catch { sawCancellation.open(); throw error }
            return [AudioClip(samples: [0.1], sampleRate: 8000)]
        }
    }

    @Test func aTaskCancelledDuringRenderThrowsCancellationAndRenderSeesIt() async {
        let hanging = Hanging()
        let speaker = synthesizer { try await hanging.render($0, $1) }
        let task = Task { try await speaker.synthesize("Bonjour") }
        await hanging.started.wait()
        task.cancel()
        let result = await outcome(task)
        #expect(result.failureValue is CancellationError)
        await hanging.sawCancellation.wait()
    }

    /// Un `render` sourd, qui rend ses morceaux malgré l'annulation : le résultat n'est pas livré pour autant.
    @Test func aRenderThatIgnoresTheCancellationDoesNotDeliverASpeech() async {
        let latch = DeafLatch(), started = Gate()
        let speaker = synthesizer { _, _ in
            started.open()
            await latch.wait()
            return [AudioClip(samples: [0.1], sampleRate: 8000)]
        }
        let task = Task { try await speaker.synthesize("Bonjour") }
        await started.wait()
        task.cancel()
        latch.open()
        #expect((await outcome(task)).failureValue is CancellationError)
    }

    /// Une panne quelconque levée parce qu'on annule (le moteur répond par autre chose qu'une `CancellationError`) reste une
    /// annulation pour l'appelant.
    @Test func anyErrorRaisedWhileCancelledIsReportedAsCancellation() async {
        let latch = DeafLatch(), started = Gate()
        let speaker = synthesizer { _, _ in
            started.open()
            await latch.wait()
            throw SpeechError.timedOut
        }
        let task = Task { try await speaker.synthesize("Bonjour") }
        await started.wait()
        task.cancel()
        latch.open()
        #expect((await outcome(task)).failureValue is CancellationError)
    }

    @Test func aRenderFailureWithoutCancellationKeepsItsError() async {
        let speaker = synthesizer { _, _ in throw SpeechError.timedOut }
        await #expect(throws: SpeechError.timedOut) { try await speaker.synthesize("Bonjour") }
    }
}

/// Le résultat d'une tâche lancée par le test, **et l'annulation du test la lui transmet** : une tâche non structurée ne reçoit
/// pas l'annulation de la limite de temps, et `task.result` attendrait alors sans fin (le test resterait en vie au lieu d'échouer).
func outcome<T: Sendable>(_ task: Task<T, any Error>) async -> Result<T, any Error> {
    await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
}
