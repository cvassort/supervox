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
