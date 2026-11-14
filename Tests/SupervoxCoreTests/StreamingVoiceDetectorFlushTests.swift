import Foundation
import Testing
@testable import SupervoxCore

/// Détecteur scripté : un bloc dont le pic dépasse 0,5 est de la voix. Refuse un bloc qui n'a pas `blockSize`
/// échantillons, comme le vrai.
private actor EnergyDetector: StreamingVoiceDetector {
    struct WrongBlockSize: Error { let count: Int }
    nonisolated let blockSize: Int
    private var processed = 0
    private var inSpeech = false
    private(set) var blocks: [[Float]] = []

    init(blockSize: Int) { self.blockSize = blockSize }

    func prepare() async throws {}
    func reset() async { processed = 0; inSpeech = false; blocks = [] }

    func process(_ block: [Float]) async throws -> VoiceEvent? {
        guard block.count == blockSize else { throw WrongBlockSize(count: block.count) }
        blocks.append(block)
        defer { processed += blockSize }
        let voiced = (block.map { abs($0) }.max() ?? 0) > 0.5
        if voiced && !inSpeech { inSpeech = true; return .speechStart(sample: processed) }
        if !voiced && inSpeech { inSpeech = false; return .speechEnd(sample: processed) }
        return nil
    }
}

/// `count` échantillons de silence suivis de `voiced` échantillons à 0,9.
private func take(silence count: Int, voiced: Int) -> [Float] {
    [Float](repeating: 0, count: count) + [Float](repeating: 0.9, count: voiced)
}

@Suite struct StreamingVoiceDetectorFlushTests {
    @Test func timelineFlushCompletesTheLastPartialBlockWithZeros() throws {
        var t = SpeechTimeline(blockSize: 4096)
        let samples = (0..<10_000).map { Float($0 + 1) }   // jamais nul : un zéro rendu est du remplissage
        let complete = t.append(samples)
        try #require(complete.count == 2)

        let flushed = t.flush()
        let block = try #require(flushed)
        #expect(block.count == 4096)
        #expect(Array(block[0..<1808]) == Array(samples[8192...]))
        #expect(block[1808...].allSatisfy { $0 == 0 })
        // Le reste est consommé : rien à vidanger une seconde fois, et l'audio reçu n'a pas changé.
        #expect(t.flush() == nil)
        #expect(t.duration == 10_000.0 / 16000)
    }

    @Test func timelineFlushHasNothingToDoOnACompleteBlockBoundary() {
        var t = SpeechTimeline(blockSize: 4096)
        _ = t.append([Float](repeating: 0.1, count: 8192))
        #expect(t.flush() == nil)
        var empty = SpeechTimeline(blockSize: 4096)
        #expect(empty.flush() == nil)
    }

    /// Voix qui se termine dans le bloc partiel : sans `flush`, le détecteur ne l'a jamais vue ; avec, elle est détectée
    /// et le passage ouvert va jusqu'à la fin de la prise.
    @Test func shortVoiceEndingInAPartialBlockIsDetectedAfterFlush() async throws {
        let detector = EnergyDetector(blockSize: 4096)
        var t = SpeechTimeline(blockSize: 4096)
        // 1 bloc de silence, puis 1 904 échantillons dont les 400 derniers sont de la voix : le bloc est incomplet.
        let samples = take(silence: 4096 + 1504, voiced: 400)
        for block in t.append(samples) {
            if let event = try await detector.process(block) { t.apply(event) }
        }
        #expect(!t.hasSpeech)
        #expect(t.spokenClip(padding: 0) == nil)

        let event = try await detector.flush(&t)
        #expect(event == .speechStart(sample: 4096))
        #expect(t.hasSpeech)
        #expect(t.openSegmentStart == 4096)
        // La voix elle-même est dans l'audio rendu ; le remplissage de zéros n'en fait pas partie.
        let spoken = try #require(t.spokenClip(padding: 0))
        #expect(spoken.samples.count == samples.count - 4096)
        #expect(spoken.samples.suffix(400).allSatisfy { $0 == 0.9 })
        #expect(await detector.blocks.count == 2)
        #expect(await detector.blocks[1].count == 4096)
    }

    @Test func flushWithoutPartialBlockSendsNothingToTheDetector() async throws {
        let detector = EnergyDetector(blockSize: 4096)
        var t = SpeechTimeline(blockSize: 4096)
        for block in t.append(take(silence: 4096, voiced: 4096)) {
            if let event = try await detector.process(block) { t.apply(event) }
        }
        #expect(try await detector.flush(&t) == nil)
        #expect(await detector.blocks.count == 2)
        #expect(t.openSegmentStart == 4096)
    }

    /// Voix déjà ouverte, puis un bloc partiel de silence : la fin arrive avec le `flush` et ferme le passage.
    @Test func flushCanCloseAnOpenSegment() async throws {
        let detector = EnergyDetector(blockSize: 4096)
        var t = SpeechTimeline(blockSize: 4096)
        let samples = take(silence: 0, voiced: 4096) + [Float](repeating: 0, count: 100)
        for block in t.append(samples) {
            if let event = try await detector.process(block) { t.apply(event) }
        }
        #expect(t.openSegmentStart == 0)
        #expect(try await detector.flush(&t) == .speechEnd(sample: 4096))
        #expect(t.openSegmentStart == nil)
        #expect(t.closedSegments == [0..<4096])
    }
}
