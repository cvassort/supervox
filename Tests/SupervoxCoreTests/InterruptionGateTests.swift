import Foundation
import Testing
@testable import SupervoxCore

// La porte d'interruption (règle 1 de la tâche 6) : pure, sans horloge. L'audio est à 16 kHz, découpé en trames de 20 ms
// (320 échantillons) ; une trame compte si son niveau atteint le seuil, et seulement si elle commence au début du passage ou après.

/// `count` trames d'un signal constant d'amplitude `amplitude` (0,1 : −20 dB ; 0,01 : −40 dB).
private func frames(_ count: Int, amplitude: Float) -> [Float] {
    [Float](repeating: amplitude, count: count * 320)
}

private let loud: Float = 0.1      // −20 dB
private let quiet: Float = 0.01    // −40 dB

@Suite(.timeLimit(.minutes(1)))
struct InterruptionGateTests {
    @Test func theTestSignalsAreAtTheStatedLevels() {
        #expect(abs(AudioLevel.decibels(of: frames(1, amplitude: loud)) - -20) < 0.001)
        #expect(abs(AudioLevel.decibels(of: frames(1, amplitude: quiet)) - -40) < 0.001)
    }

    @Test func fifteenLoudFramesFromThePassageStartInterruptFourteenDoNot() {
        var fourteen = InterruptionGate(minDuration: 0.30, level: -30)
        fourteen.append(frames(14, amplitude: loud))
        #expect(!fourteen.shouldInterrupt(passageStart: 0))   // 0,28 s

        var fifteen = InterruptionGate(minDuration: 0.30, level: -30)
        fifteen.append(frames(15, amplitude: loud))
        #expect(fifteen.shouldInterrupt(passageStart: 0))   // 0,30 s, compté en échantillons : 15 × 320 = 4 800
    }

    @Test func fortyFramesBelowTheLevelNeverInterrupt() {
        var gate = InterruptionGate(minDuration: 0.30, level: -30)
        gate.append(frames(40, amplitude: quiet))
        #expect(!gate.shouldInterrupt(passageStart: 0))
    }

    @Test func loudFramesBeforeThePassageStartAreNotCounted() {
        var gate = InterruptionGate(minDuration: 0.30, level: -30)
        gate.append(frames(20, amplitude: loud))   // avant le passage : 20 trames fortes
        gate.append(frames(14, amplitude: loud))   // dans le passage : 14
        #expect(!gate.shouldInterrupt(passageStart: 20 * 320))
        gate.append(frames(1, amplitude: loud))
        #expect(gate.shouldInterrupt(passageStart: 20 * 320))
    }

    /// Un début de passage au milieu d'une trame : cette trame commence avant le passage, elle ne compte pas.
    @Test func theFrameThatStraddlesThePassageStartIsNotCounted() {
        var gate = InterruptionGate(minDuration: 0.30, level: -30)
        gate.append(frames(15, amplitude: loud))
        #expect(gate.shouldInterrupt(passageStart: 0))
        #expect(!gate.shouldInterrupt(passageStart: 100))   // trames 1 à 14 seulement
        gate.append(frames(1, amplitude: loud))
        #expect(gate.shouldInterrupt(passageStart: 100))
        #expect(gate.shouldInterrupt(passageStart: 320))   // une trame qui commence au début du passage compte
    }

    @Test func nonConsecutiveLoudFramesAreSummed() {
        var gate = InterruptionGate(minDuration: 0.30, level: -30)
        gate.append(frames(8, amplitude: loud))
        gate.append(frames(5, amplitude: quiet))
        gate.append(frames(6, amplitude: loud))
        #expect(!gate.shouldInterrupt(passageStart: 0))   // 14 trames fortes
        gate.append(frames(3, amplitude: quiet))
        gate.append(frames(1, amplitude: loud))
        #expect(gate.shouldInterrupt(passageStart: 0))   // 15, sur 23 trames
    }

    /// Les tranches du micro ne tombent pas sur les trames : le reste d'une tranche attend la suivante, une trame incomplète ne
    /// compte pas.
    @Test func framesAreCutAcrossAppendsAndAnIncompleteFrameDoesNotCount() {
        var gate = InterruptionGate(minDuration: 0.30, level: -30)
        let signal = frames(15, amplitude: loud)
        gate.append(Array(signal[0..<1000]))
        gate.append(Array(signal[1000..<4799]))   // il manque le dernier échantillon de la quinzième trame
        #expect(!gate.shouldInterrupt(passageStart: 0))
        gate.append([loud])
        #expect(gate.shouldInterrupt(passageStart: 0))
    }

    /// Le seuil est atteint, pas dépassé : une trame exactement au niveau compte.
    @Test func aFrameExactlyAtTheLevelCounts() {
        let frame = frames(1, amplitude: 0.05)
        var gate = InterruptionGate(minDuration: 0.30, level: AudioLevel.decibels(of: frame))
        for _ in 0..<15 { gate.append(frame) }
        #expect(gate.shouldInterrupt(passageStart: 0))
    }

    /// La durée et le niveau viennent de l'appelant (les réglages), pas d'une constante : 0,1 s et −50 dB.
    @Test func theDurationAndTheLevelAreThoseGiven() {
        var gate = InterruptionGate(minDuration: 0.1, level: -50)
        gate.append(frames(4, amplitude: quiet))   // −40 dB, au-dessus de −50
        #expect(!gate.shouldInterrupt(passageStart: 0))   // 0,08 s
        gate.append(frames(1, amplitude: quiet))
        #expect(gate.shouldInterrupt(passageStart: 0))   // 0,10 s
    }

    /// Trente secondes au plus sont gardées ; les indices restent ceux de l'audio reçu depuis la dernière remise à zéro.
    @Test func atMostThirtySecondsAreKeptAndSampleIndicesStayAbsolute() {
        var gate = InterruptionGate(minDuration: 0.30, level: -30)
        gate.append(frames(15, amplitude: loud))   // de 0 à 4 800
        #expect(gate.shouldInterrupt(passageStart: 0))
        gate.append(frames(1_500, amplitude: quiet))   // 30 s de plus : les trames fortes du début sortent de la fenêtre
        #expect(!gate.shouldInterrupt(passageStart: 0))
        let later = (15 + 1_500) * 320
        gate.append(frames(15, amplitude: loud))
        #expect(gate.shouldInterrupt(passageStart: later))
        #expect(!gate.shouldInterrupt(passageStart: later + 320))
    }

    @Test func resetForgetsTheFramesAndRestartsTheIndices() {
        var gate = InterruptionGate(minDuration: 0.30, level: -30)
        gate.append(frames(15, amplitude: loud))
        gate.append([loud, loud])   // une trame commencée
        gate.reset()
        #expect(!gate.shouldInterrupt(passageStart: 0))
        gate.append(frames(15, amplitude: loud))
        #expect(gate.shouldInterrupt(passageStart: 0))   // l'échantillon 0 est le premier reçu après la remise à zéro
        #expect(!gate.shouldInterrupt(passageStart: 1))
    }

    @Test func aPassageThatStartsAfterTheAudioReceivedCountsNothing() {
        var gate = InterruptionGate(minDuration: 0.30, level: -30)
        gate.append(frames(15, amplitude: loud))
        #expect(!gate.shouldInterrupt(passageStart: 1_000_000))
    }
}
