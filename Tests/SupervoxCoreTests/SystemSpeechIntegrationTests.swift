import Foundation
import Testing
@testable import SupervoxCore

/// Règle 7 : la vraie voix française du système. À lancer à la main avec `SUPERVOX_SPEECH=1` (elle joue la synthèse du moteur du
/// système, sans rien envoyer à la sortie audio) ; désactivée par défaut, jamais lancée par la suite ordinaire.
@Suite(.serialized)
struct SystemSpeechIntegrationTests {
    private static let enabled = ProcessInfo.processInfo.environment["SUPERVOX_SPEECH"] == "1"

    @Test(.enabled(if: SystemSpeechIntegrationTests.enabled), .timeLimit(.minutes(1)))
    func aFrenchSentenceGivesANonEmptyClipOfPlausibleDuration() async throws {
        let speech = try await SystemSpeechSynthesizer(language: "fr-FR").synthesize("Bonjour, ceci est un essai de la voix du système.")
        #expect(!speech.clip.samples.isEmpty)
        #expect(speech.clip.sampleRate > 0)
        #expect(speech.clip.duration >= 0.3 && speech.clip.duration <= 10)
        #expect(!speech.fellBack)
    }
}
