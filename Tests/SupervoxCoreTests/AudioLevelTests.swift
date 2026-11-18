import Foundation
import Testing
@testable import SupervoxCore

// MARK: - Niveau en décibels (règle 1)

/// Un sinus d'amplitude 1 sur un nombre entier de périodes : puissance moyenne 1/2, soit 10·log10(0,5) = −3,0103 dB.
@Test func aFullScaleSineIsMinusThreeDecibels() {
    let samples = (0..<48_000).map { Float(sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
    let decibels = AudioLevel.decibels(of: samples)
    #expect(abs(decibels - (-3.01)) < 0.01, "\(decibels) dB")
}

/// Signal constant de valeur efficace 0,01 : 20·log10(0,01) = −40 dB.
@Test func aSignalOfRms0Point01IsMinusFortyDecibels() {
    let decibels = AudioLevel.decibels(of: [Float](repeating: 0.01, count: 480))
    #expect(abs(decibels - (-40)) < 0.01, "\(decibels) dB")
    // Le signe ne compte pas : c'est une puissance.
    #expect(abs(AudioLevel.decibels(of: [0.01, -0.01, 0.01, -0.01]) - (-40)) < 0.01)
}

@Test func anEmptyZeroOrNonNumericSignalIsTheFloorOfMinus120Decibels() {
    #expect(AudioLevel.decibels(of: []) == -120)
    #expect(AudioLevel.decibels(of: [Float](repeating: 0, count: 100)) == -120)
    #expect(AudioLevel.decibels(of: [.nan]) == -120)
    #expect(AudioLevel.decibels(of: [0.5, .nan, 0.5]) == -120)
}

/// Un signal plus bas que le plancher ne descend pas sous −120 : la valeur est un plancher, pas une mesure.
@Test func aSignalBelowTheFloorIsClampedToIt() {
    #expect(AudioLevel.decibels(of: [Float](repeating: 1e-9, count: 100)) == -120)   // −180 dB
}

// MARK: - Niveau affichable

@Test func displayMapsMinusSixtyDecibelsToZeroAndZeroDecibelsToOne() {
    let tolerance: Float = 1e-5
    #expect(AudioLevel.display(of: []) == 0)
    #expect(abs(AudioLevel.display(of: [Float](repeating: 1, count: 100)) - 1) < tolerance)
    #expect(abs(AudioLevel.display(of: [Float](repeating: 0.001, count: 100)) - 0) < tolerance)
    #expect(abs(AudioLevel.display(of: [Float](repeating: 0.1, count: 100)) - 2.0 / 3) < tolerance)
    #expect(AudioLevel.display(of: [.nan, 0.5]) == 0)
    #expect(AudioLevel.display(of: [.infinity]) == 1)
    #expect(AudioLevel.display(of: [Float](repeating: 8, count: 10)) == 1)
}

/// `DictationSession.level(of:)` ne calcule plus rien : il rend exactement l'affichage d'`AudioLevel`.
@Test(arguments: [
    [Float](), [0, 0, 0], [0.001, 0.001], [0.01, -0.02, 0.03], [0.1, -0.1], [1, 1], [8, 8], [.nan, 0.5], [.infinity], [1e-9],
])
func theDictationLevelIsExactlyTheAudioLevelDisplay(samples: [Float]) {
    #expect(DictationSession.level(of: samples) == AudioLevel.display(of: samples))
}
