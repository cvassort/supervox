import Foundation
import Testing
@testable import SupervoxCore

/// 3 s à 48 kHz : somme de deux sinus (220 Hz et 1 800 Hz), amplitude totale 0,8.
private func twoToneSignal(seconds: Double = 3, rate: Double = 48000) -> [Float] {
    let n = Int(seconds * rate)
    return (0..<n).map { i in
        let t = Double(i) / rate
        return Float(0.4 * sin(2 * .pi * 220 * t) + 0.4 * sin(2 * .pi * 1800 * t))
    }
}

private func slices(_ samples: [Float], of size: Int) -> [[Float]] {
    stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min($0 + size, samples.count)]) }
}

/// Écart quadratique moyen entre deux sorties, sur leur partie commune à partir de `from`.
private func meanSquaredError(_ a: [Float], _ b: [Float], from start: Int) -> Double {
    let end = min(a.count, b.count)
    guard end > start else { return .infinity }
    var sum = 0.0
    for i in start..<end {
        let d = Double(a[i]) - Double(b[i])
        sum += d * d
    }
    return sum / Double(end - start)
}

private func streamed(_ signal: [Float], chunk: Int, from: Double = 48000, to: Double = 16000) throws -> [Float] {
    let resampler = try #require(StreamingResampler(from: from, to: to))
    var out: [Float] = []
    for piece in slices(signal, of: chunk) { out += resampler.push(piece) }
    out += resampler.finish()
    return out
}

/// Début ignoré dans les comparaisons : 100 ms à 16 kHz.
private let skippedHead = 1600

/// Seuil d'écart quadratique moyen (amplitude du signal : 0,8) entre le rééchantillonneur continu et le clip entier.
/// Mesuré : le continu est identique au clip entier (écart 0, sur 3 s, tranches de 4 800 ; de 480 ; de 1 024 ;
/// de 4 801), alors que des tranches indépendantes de 4 800 échantillons donnent 8,6e-7 et celles de 1 024 donnent
/// 0,36. Le seuil du plan (0,01) laissait passer 4 800 échantillons indépendants (8,6e-7) : on retient 1e-9, au-dessus
/// de l'écart mesuré (0) et 850 fois sous le meilleur cas des tranches indépendantes mesuré.
private let continuousBound = 1e-9

@Test func streamingResamplerMatchesWholeClipResampling() throws {
    let signal = twoToneSignal()
    let whole = Resampler.resample(AudioClip(samples: signal, sampleRate: 48000), to: 16000).samples
    let stream = try streamed(signal, chunk: 4800)

    #expect(abs(stream.count - whole.count) <= 64, "\(stream.count) échantillons contre \(whole.count)")
    #expect(meanSquaredError(stream, whole, from: skippedHead) < continuousBound)
}

/// Des tranches de tailles quelconques (pas un multiple du rapport 3:1) ne doivent rien changer au résultat.
@Test func streamingResamplerIgnoresHowTheSignalIsSliced() throws {
    let signal = twoToneSignal()
    let whole = Resampler.resample(AudioClip(samples: signal, sampleRate: 48000), to: 16000).samples
    let resampler = try #require(StreamingResampler(from: 48000, to: 16000))
    var out: [Float] = []
    var position = 0
    var step = 0
    let sizes = [1, 7, 1023, 4801, 2, 480]
    while position < signal.count {
        let end = min(position + sizes[step % sizes.count], signal.count)
        out += resampler.push(Array(signal[position..<end]))
        position = end
        step += 1
    }
    out += resampler.finish()

    #expect(abs(out.count - whole.count) <= 64, "\(out.count) échantillons contre \(whole.count)")
    #expect(meanSquaredError(out, whole, from: skippedHead) < continuousBound)
}

/// 44,1 kHz vers 16 kHz : rapport non entier, tranches de 100 ms (4 410 échantillons).
@Test func streamingResamplerHandlesNonIntegerRatio() throws {
    let signal = twoToneSignal(rate: 44100)
    let whole = Resampler.resample(AudioClip(samples: signal, sampleRate: 44100), to: 16000).samples
    let stream = try streamed(signal, chunk: 4410, from: 44100)

    #expect(abs(stream.count - whole.count) <= 64, "\(stream.count) échantillons contre \(whole.count)")
    #expect(meanSquaredError(stream, whole, from: skippedHead) < continuousBound)
}

/// Raison d'être du type : des tranches indépendantes (un convertisseur neuf par tranche) s'écartent du clip entier,
/// pas le convertisseur continu. Tranches de 1 024 échantillons (écart indépendant mesuré : 0,356 ; continu : 0).
/// Assertion relative plutôt qu'un seuil absolu sur l'indépendant, qui dépendrait de l'amorçage du filtre.
@Test func independentChunksDriftFarFurtherFromWholeClipThanTheStreamingResampler() throws {
    let signal = twoToneSignal()
    let whole = Resampler.resample(AudioClip(samples: signal, sampleRate: 48000), to: 16000).samples
    let continuous = try streamed(signal, chunk: 1024)
    let independent = slices(signal, of: 1024).flatMap {
        Resampler.resample(AudioClip(samples: $0, sampleRate: 48000), to: 16000).samples
    }

    let continuousError = meanSquaredError(continuous, whole, from: skippedHead)
    let independentError = meanSquaredError(independent, whole, from: skippedHead)
    #expect(continuousError < 1e-6, "continu \(continuousError)")
    #expect(continuousError * 1000 <= independentError, "continu \(continuousError), indépendantes \(independentError)")
    // Un continu à 0 satisfait `0 <= x` même si `x` vaut 0 : on exige aussi un écart strict.
    #expect(independentError > continuousError, "continu \(continuousError), indépendantes \(independentError)")
}

@Test func streamingResamplerAtSameRateReturnsSamplesUnchanged() throws {
    let resampler = try #require(StreamingResampler(from: 16000, to: 16000))
    let chunk: [Float] = [0.25, -0.5, 0.75, 0, 1]
    #expect(resampler.push(chunk) == chunk)
    #expect(resampler.finish().isEmpty)
}

@Test(arguments: [(0.0, 16000.0), (-48000.0, 16000.0), (48000.0, 0.0), (48000.0, -16000.0),
                  (Double.nan, 16000.0), (48000.0, Double.nan), (Double.infinity, 16000.0), (48000.0, Double.infinity)])
func streamingResamplerRejectsNonPositiveRates(from: Double, to: Double) {
    #expect(StreamingResampler(from: from, to: to) == nil)
}

@Test func streamingResamplerAcceptsAnEmptyChunk() throws {
    let signal = twoToneSignal(seconds: 1)
    let whole = Resampler.resample(AudioClip(samples: signal, sampleRate: 48000), to: 16000).samples
    let resampler = try #require(StreamingResampler(from: 48000, to: 16000))

    #expect(resampler.push([]) == [])
    // Une tranche vide au début, au milieu et à la fin ne change rien au résultat ni n'abîme le flux.
    var out = resampler.push(Array(signal[0..<24000]))
    #expect(resampler.push([]) == [])
    out += resampler.push(Array(signal[24000...]))
    #expect(resampler.push([]) == [])
    out += resampler.finish()

    #expect(!resampler.hasFailed)
    #expect(out.count == whole.count, "\(out.count) échantillons contre \(whole.count)")
    #expect(meanSquaredError(out, whole, from: 0) < continuousBound)
}

/// La queue du filtre (16 échantillons mesurés après 3 s) ne sort qu'à la fin du flux : sans `finish()`, la fin de la
/// dictée serait amputée. Le total doit être exactement celui du clip entier.
@Test func finishFlushesTheFilterTailAndEndsTheStream() throws {
    let signal = twoToneSignal()
    let whole = Resampler.resample(AudioClip(samples: signal, sampleRate: 48000), to: 16000).samples
    let resampler = try #require(StreamingResampler(from: 48000, to: 16000))
    var pushed: [Float] = []
    for piece in slices(signal, of: 4800) { pushed += resampler.push(piece) }
    let tail = resampler.finish()

    #expect(!resampler.hasFailed)
    #expect(!tail.isEmpty)
    #expect(pushed.count + tail.count == whole.count, "\(pushed.count) + \(tail.count) contre \(whole.count)")
    // Après `finish()`, l'instance ne produit plus rien.
    #expect(resampler.push([0.5, 0.5, 0.5]).isEmpty)
    #expect(resampler.finish().isEmpty)
}

/// Une erreur du convertisseur ne doit pas passer pour du silence : l'appelant la lit par `hasFailed`.
/// La panne est injectée (le vrai `AVAudioConverter` ne se laisse pas faire échouer simplement) à la 3e conversion.
@Test func converterFailureIsReportedAndStopsTheStream() throws {
    let signal = twoToneSignal(seconds: 1)
    let resampler = try #require(StreamingResampler(from: 48000, to: 16000))
    nonisolated(unsafe) var conversions = 0
    resampler.injectedFault = {
        conversions += 1
        return conversions == 3
    }

    let first = resampler.push(Array(signal[0..<4800]))
    let second = resampler.push(Array(signal[4800..<9600]))
    #expect(!first.isEmpty && !second.isEmpty)
    #expect(!resampler.hasFailed)

    #expect(resampler.push(Array(signal[9600..<14400])).isEmpty)
    #expect(resampler.hasFailed)
    // Définitif : plus rien ne sort ensuite, et `hasFailed` ne retombe pas.
    #expect(resampler.push(Array(signal[14400..<19200])).isEmpty)
    #expect(resampler.finish().isEmpty)
    #expect(resampler.hasFailed)
}
