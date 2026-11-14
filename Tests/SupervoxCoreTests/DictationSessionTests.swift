import Foundation
import os
import Testing
@testable import SupervoxCore

// MARK: - Niveau affichable

@Test func levelMapsMinusSixtyDecibelsToZeroAndZeroDecibelsToOne() {
    let tolerance: Float = 1e-5
    #expect(DictationSession.level(of: []) == 0)
    #expect(DictationSession.level(of: [Float](repeating: 0, count: 100)) == 0)
    // Signal constant d'amplitude a : RMS = a, donc 20·log10(a) dB.
    #expect(abs(DictationSession.level(of: [Float](repeating: 1, count: 100)) - 1) < tolerance)
    #expect(abs(DictationSession.level(of: [Float](repeating: 0.001, count: 100)) - 0) < tolerance)   // -60 dB
    #expect(abs(DictationSession.level(of: [Float](repeating: 0.01, count: 100)) - 1.0 / 3) < tolerance)   // -40 dB
    #expect(abs(DictationSession.level(of: [Float](repeating: 0.1, count: 100)) - 2.0 / 3) < tolerance)   // -20 dB
    // Le signe ne compte pas : c'est une puissance.
    #expect(abs(DictationSession.level(of: [0.1, -0.1, 0.1, -0.1]) - 2.0 / 3) < tolerance)
}

@Test func levelStaysWithinZeroAndOne() {
    #expect(DictationSession.level(of: [Float](repeating: 0.0001, count: 10)) == 0)   // sous -60 dB
    #expect(DictationSession.level(of: [Float](repeating: 8, count: 10)) == 1)        // au-dessus de 0 dB
    #expect(DictationSession.level(of: [.nan, 0.5]) == 0)
    #expect(DictationSession.level(of: [.infinity]) == 1)
}

// MARK: - Types

@Test func everyFailureHasACompleteFrenchSentence() {
    let messages = [
        DictationFailure.microphone("accès refusé").message,
        DictationFailure.noSpeech.message,
        DictationFailure.engine("modèle absent").message,
    ]
    for message in messages {
        #expect(message.last == ".", "\(message)")
        #expect(message.first?.isUppercase == true, "\(message)")
    }
    #expect(DictationFailure.microphone("accès refusé").message.contains("accès refusé"))
    #expect(DictationFailure.engine("modèle absent").message.contains("modèle absent"))
}

@Test func defaultConfigurationValues() {
    let config = DictationConfig(language: "fr")
    #expect(config.language == "fr")
    #expect(config.vocabulary.isEmpty)
    #expect(config.previewInterval == 0.5)
    #expect(config.previewWindow == 15)
    #expect(config.padding == 0.3)
    #expect(config.maxDuration == 300)
}
