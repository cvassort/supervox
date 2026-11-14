import Foundation
import Testing
@testable import SupervoxCore

/// Rampe 0, 1, 2… : chaque échantillon porte son propre indice, donc un décalage d'un seul échantillon se voit.
private func ramp(_ count: Int, from start: Int = 0) -> [Float] {
    (start..<(start + count)).map { Float($0) }
}

private func timeline(receiving count: Int, blockSize: Int = 4096) -> SpeechTimeline {
    var t = SpeechTimeline(blockSize: blockSize)
    _ = t.append(ramp(count))
    return t
}

@Suite struct SpeechTimelineTests {
    @Test func appendHandsOutCompleteBlocksInOrder() {
        var t = SpeechTimeline(blockSize: 4096)
        let first = t.append(ramp(10_000))
        #expect(first.count == 2)
        #expect(first[0] == ramp(4096))
        #expect(first[1] == ramp(4096, from: 4096))

        // 3 × 4096 = 12 288 : il manque 2 288 échantillons. Avec un de moins, le troisième bloc n'est pas encore là.
        #expect(t.append(ramp(2_287, from: 10_000)).isEmpty)
        let second = t.append(ramp(1, from: 12_287))
        #expect(second.count == 1)
        #expect(second[0] == ramp(4096, from: 8192))

        // Rien de plus tant qu'un bloc entier n'est pas complet, et un bloc n'est jamais rendu deux fois.
        #expect(t.append(ramp(100, from: 12_288)).isEmpty)
        #expect(t.duration == 12_388.0 / 16000)
    }

    @Test func appendedAudioIsSplitIdenticallyWhateverTheChunking() {
        var whole = SpeechTimeline(blockSize: 1000)
        let expected = whole.append(ramp(5300))
        var pieces = SpeechTimeline(blockSize: 1000)
        var got: [[Float]] = []
        for start in stride(from: 0, to: 5300, by: 333) {
            got += pieces.append(ramp(min(333, 5300 - start), from: start))
        }
        #expect(got == expected)
        #expect(got.count == 5)
    }

    @Test func withoutEventThereIsNoSpeech() {
        let t = timeline(receiving: 32_000)
        #expect(!t.hasSpeech)
        #expect(t.closedSegments.isEmpty)
        #expect(t.openSegmentStart == nil)
        #expect(t.spokenClip(padding: 0.2) == nil)
        #expect(t.openClip(maxSeconds: 1) == nil)
    }

    @Test func aClosedSegmentIsRecordedAndPadded() {
        var t = timeline(receiving: 32_000)
        t.apply(.speechStart(sample: 8000))
        t.apply(.speechEnd(sample: 24000))
        #expect(t.closedSegments == [8000..<24000])
        #expect(t.openSegmentStart == nil)
        #expect(t.hasSpeech)
        #expect(t.openClip(maxSeconds: 1) == nil)
        #expect(t.clip(of: 8000..<24000).samples == ramp(16000, from: 8000))
        #expect(t.clip(of: 8000..<24000).sampleRate == 16000)

        let spoken = t.spokenClip(padding: 0.2)
        #expect(spoken?.samples == ramp(27200 - 4800, from: 4800))
        #expect(spoken?.sampleRate == 16000)
    }

    @Test func paddingIsBoundedByTheTake() {
        var early = timeline(receiving: 32_000)
        early.apply(.speechStart(sample: 1000))
        early.apply(.speechEnd(sample: 24000))
        #expect(early.spokenClip(padding: 0.2)?.samples == ramp(27200))

        var late = timeline(receiving: 25_000)
        late.apply(.speechStart(sample: 8000))
        late.apply(.speechEnd(sample: 24000))
        #expect(late.spokenClip(padding: 0.2)?.samples == ramp(25_000 - 4800, from: 4800))
    }

    @Test func spokenClipKeepsInnerSilences() {
        var t = timeline(receiving: 48_000)
        t.apply(.speechStart(sample: 4000))
        t.apply(.speechEnd(sample: 10_000))
        t.apply(.speechStart(sample: 30_000))
        t.apply(.speechEnd(sample: 40_000))
        #expect(t.closedSegments == [4000..<10_000, 30_000..<40_000])
        #expect(t.spokenClip(padding: 0)?.samples == ramp(36_000, from: 4000))
    }

    @Test func anOpenSegmentRunsToTheEndOfTheTake() {
        var t = timeline(receiving: 40_000)
        t.apply(.speechStart(sample: 8000))
        #expect(t.openSegmentStart == 8000)
        #expect(t.closedSegments.isEmpty)
        #expect(t.hasSpeech)
        #expect(t.spokenClip(padding: 0.2)?.samples == ramp(40_000 - 4800, from: 4800))
        #expect(t.openClip(maxSeconds: 1)?.samples == ramp(16_000, from: 24_000))
        // Le passage est plus court que la limite : on le rend entier.
        #expect(t.openClip(maxSeconds: 10)?.samples == ramp(32_000, from: 8000))

        // L'audio qui arrive ensuite prolonge le passage ouvert.
        _ = t.append(ramp(2000, from: 40_000))
        #expect(t.spokenClip(padding: 0)?.samples == ramp(34_000, from: 8000))
        #expect(t.openClip(maxSeconds: 1)?.samples == ramp(16_000, from: 26_000))
    }

    @Test func anOpenSegmentAfterAClosedOneSpansBoth() {
        var t = timeline(receiving: 40_000)
        t.apply(.speechStart(sample: 2000))
        t.apply(.speechEnd(sample: 6000))
        t.apply(.speechStart(sample: 20_000))
        #expect(t.closedSegments == [2000..<6000])
        #expect(t.openSegmentStart == 20_000)
        #expect(t.spokenClip(padding: 0)?.samples == ramp(38_000, from: 2000))
    }

    @Test func closingASegmentEndsTheOpenOne() {
        var t = timeline(receiving: 40_000)
        t.apply(.speechStart(sample: 8000))
        t.apply(.speechEnd(sample: 16_000))
        #expect(t.openSegmentStart == nil)
        #expect(t.closedSegments == [8000..<16_000])
    }

    @Test func inconsistentEventsAreIgnored() {
        var twoStarts = timeline(receiving: 40_000)
        twoStarts.apply(.speechStart(sample: 8000))
        twoStarts.apply(.speechStart(sample: 12_000))
        #expect(twoStarts.openSegmentStart == 8000)
        #expect(twoStarts.closedSegments.isEmpty)

        var endWithoutStart = timeline(receiving: 40_000)
        endWithoutStart.apply(.speechEnd(sample: 12_000))
        #expect(!endWithoutStart.hasSpeech)
        #expect(endWithoutStart.closedSegments.isEmpty)
        #expect(endWithoutStart.openSegmentStart == nil)

        var endBeforeStart = timeline(receiving: 40_000)
        endBeforeStart.apply(.speechStart(sample: 20_000))
        endBeforeStart.apply(.speechEnd(sample: 12_000))
        #expect(endBeforeStart.openSegmentStart == 20_000)
        #expect(endBeforeStart.closedSegments.isEmpty)

        // Une fin au même échantillon que le début ne fait pas un passage vide.
        var emptySegment = timeline(receiving: 40_000)
        emptySegment.apply(.speechStart(sample: 20_000))
        emptySegment.apply(.speechEnd(sample: 20_000))
        #expect(emptySegment.openSegmentStart == 20_000)
        #expect(emptySegment.closedSegments.isEmpty)

        // Un début qui chevauche le passage déjà clos garde les passages sans chevauchement.
        var overlapping = timeline(receiving: 40_000)
        overlapping.apply(.speechStart(sample: 8000))
        overlapping.apply(.speechEnd(sample: 16_000))
        overlapping.apply(.speechStart(sample: 12_000))
        #expect(overlapping.openSegmentStart == nil)
        #expect(overlapping.closedSegments == [8000..<16_000])
    }

    @Test func anEndBeyondTheReceivedAudioIsBroughtBackToItsLength() {
        var t = timeline(receiving: 20_000)
        t.apply(.speechStart(sample: 8000))
        t.apply(.speechEnd(sample: 30_000))
        #expect(t.closedSegments == [8000..<20_000])
        #expect(t.spokenClip(padding: 0)?.samples == ramp(12_000, from: 8000))
        #expect(t.clip(of: 8000..<30_000).samples == ramp(12_000, from: 8000))
    }

    @Test func aStartBeyondTheReceivedAudioIsBroughtBackToItsLength() {
        var t = timeline(receiving: 20_000)
        t.apply(.speechStart(sample: 30_000))
        #expect(t.openSegmentStart == 20_000)
        t.apply(.speechStart(sample: -5))   // déjà ouvert : ignoré
        #expect(t.openSegmentStart == 20_000)

        var negative = timeline(receiving: 20_000)
        negative.apply(.speechStart(sample: -5))
        #expect(negative.openSegmentStart == 0)
    }
}
