import Foundation
import Testing
@testable import SupervoxCore

private func tone(_ hz: Double, seconds: Double, rate: Double) -> AudioClip {
    let n = Int(seconds * rate)
    return AudioClip(samples: (0..<n).map { Float(sin(2 * .pi * hz * Double($0) / rate)) }, sampleRate: rate)
}

@Test func resamplingPreservesDurationAndTone() {
    let src = AudioClip(samples: (0..<48000).map { Float(sin(2 * .pi * 440 * Double($0) / 48000)) }, sampleRate: 48000)
    let out = Resampler.resample(src, to: 16000)
    #expect(abs(out.samples.count - 16000) <= 2)
    let crossings = zip(out.samples, out.samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
    #expect(abs(crossings - 440) <= 2)   // la fréquence de 440 Hz est conservée
}

@Test func resampledClipReportsTargetRateAndKeepsAmplitude() {
    let out = Resampler.resample(tone(440, seconds: 1, rate: 48000), to: 16000)
    #expect(out.sampleRate == 16000)
    // Un sinus d'amplitude 1 doit rester proche de 1 (hors bords où le filtre se stabilise).
    let peak = out.samples[200..<(out.samples.count - 200)].map { abs($0) }.max() ?? 0
    #expect(peak > 0.9 && peak < 1.1)
}

/// 44,1 kHz vers 16 kHz n'est pas un rapport entier : la durée doit tout de même être conservée.
@Test func resamplingNonIntegerRatioPreservesDuration() {
    let out = Resampler.resample(tone(300, seconds: 2, rate: 44100), to: 16000)
    #expect(abs(out.samples.count - 32000) <= 2)
    #expect(abs(out.duration - 2.0) < 0.001)
}

@Test func resamplingToSameRateReturnsClipUnchanged() {
    let clip = tone(440, seconds: 0.1, rate: 16000)
    #expect(Resampler.resample(clip, to: 16000) == clip)
}

@Test func resamplingEmptyClipGivesEmptyClipAtTargetRate() {
    let out = Resampler.resample(AudioClip(samples: [], sampleRate: 48000), to: 16000)
    #expect(out.samples.isEmpty && out.sampleRate == 16000)
}

/// Une fréquence au-dessus de la fréquence de Nyquist de la cible (10 kHz pour 16 kHz) ne doit pas se replier
/// dans la bande utile : c'est ce que garantit le filtre anti-repliement du convertisseur.
@Test func resamplingAttenuatesFrequenciesAboveTargetNyquist() {
    let out = Resampler.resample(tone(12000, seconds: 1, rate: 48000), to: 16000)
    let rms = (out.samples[200..<(out.samples.count - 200)].map { $0 * $0 }.reduce(0, +)
               / Float(out.samples.count - 400)).squareRoot()
    #expect(rms < 0.1)   // le signal d'entrée a un RMS de 0,707
}

@Test func audioClipDurationIsSamplesOverRate() {
    #expect(abs(AudioClip(samples: Array(repeating: 0, count: 8000), sampleRate: 16000).duration - 0.5) < 1e-9)
    #expect(AudioClip(samples: [], sampleRate: 16000).duration == 0)
}
