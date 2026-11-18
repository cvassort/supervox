import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxApp

// L'écoute d'une voix (réglage des voix, tâche 3). Aucun son, aucune vraie voix, aucune vraie liste des voix : le lecteur est
// `ScriptedClipPlayer`, les voix sont des doubles, la liste des voix installées est inventée, le trousseau est en mémoire.

/// Ce que l'environnement donne quand personne ne branche l'écoute : aucune voix listée, un lecteur qui refuse de jouer.
@MainActor @Suite(.timeLimit(.minutes(1))) struct VoiceEnvironmentDefaultsTests {
    static let clip = AudioClip(samples: [0.1, 0.2], sampleRate: 24_000)

    @Test func theUnavailableEnvironmentListsNoVoiceAndItsPlayerRefusesToPlay() async {
        let environment = InterviewEnvironment.unavailable
        #expect(environment.systemVoices().isEmpty)
        let player = environment.makePlayer()
        await #expect(throws: InterviewEnvironment.Unavailable.self) { try await player.play(Self.clip) }
    }

    @Test func anEnvironmentBuiltWithoutThemListsNoVoiceAndItsPlayerRefusesToPlay() async {
        let environment = InterviewEnvironment(
            prepare: { _ in throw InterviewEnvironment.Unavailable() },
            makeConversation: { _ in throw InterviewEnvironment.Unavailable() }, makeVoice: { _, _ in SilentTestVoice() })
        #expect(environment.systemVoices().isEmpty)
        let player = environment.makePlayer()
        await #expect(throws: InterviewEnvironment.Unavailable.self) { try await player.play(Self.clip) }
    }

    @Test func theEnvironmentGivesTheListAndThePlayerItWasBuiltWith() {
        let voice = SystemVoiceInfo(identifier: "voix.exemple.a", language: "fr-FR", quality: 2, name: "Voix d'exemple A")
        let player = ScriptedClipPlayer()
        let environment = InterviewEnvironment(
            prepare: { _ in throw InterviewEnvironment.Unavailable() },
            makeConversation: { _ in throw InterviewEnvironment.Unavailable() }, makeVoice: { _, _ in SilentTestVoice() },
            systemVoices: { [voice] }, makePlayer: { player })
        #expect(environment.systemVoices() == [voice])
        #expect((environment.makePlayer() as? ScriptedClipPlayer) === player)
    }
}
