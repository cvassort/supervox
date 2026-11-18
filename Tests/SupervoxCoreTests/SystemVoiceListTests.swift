import AVFAudio
import Foundation
import os
import Testing
@testable import SupervoxCore

// Voix du système désignées par leur identifiant. Tout se prouve sur des listes écrites ici et un `render` double : aucun test
// n'appelle `SystemVoices.installed` (la vraie liste des voix de la machine) ni ne construit une vraie voix.

/// Les identifiants reçus par le `render` double, dans l'ordre.
private final class ChosenVoices: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    var all: [String] { state.withLock { $0 } }
    func record(_ identifier: String) { state.withLock { $0.append(identifier) } }
}

/// La meilleure voix française est `voix.exemple.fr`, qualité 3 ; la voix désignée, `voix.exemple.a`, est d'une autre langue et de
/// moindre qualité : seul l'identifiant peut la faire choisir.
private let voices = [
    SystemVoiceInfo(identifier: "voix.exemple.fr-moyenne", language: "fr-FR", quality: 2),
    SystemVoiceInfo(identifier: "voix.exemple.fr", language: "fr-FR", quality: 3),
    SystemVoiceInfo(identifier: "voix.exemple.a", language: "en-US", quality: 1, name: "Voix d'exemple A", gender: .female),
]

@Suite(.timeLimit(.minutes(1))) struct SystemVoiceListTests {
    // MARK: Règle 1

    @Test func anInstalledIdentifierWins() {
        #expect(SystemSpeechSynthesizer.pickVoice(language: "fr-FR", identifier: "voix.exemple.a", among: voices)?.identifier == "voix.exemple.a")
        // Quelle que soit la langue demandée : même sans aucune voix de cette langue, la voix désignée est prise.
        #expect(SystemSpeechSynthesizer.pickVoice(language: "de-DE", identifier: "voix.exemple.a", among: voices)?.identifier == "voix.exemple.a")
        // Elle est rendue telle quelle, nom et genre compris.
        #expect(SystemSpeechSynthesizer.pickVoice(language: "fr-FR", identifier: "voix.exemple.a", among: voices) == voices[2])
    }

    @Test func aMissingIdentifierFallsBackToTheBestVoiceOfTheLanguage() {
        #expect(SystemSpeechSynthesizer.pickVoice(language: "fr-FR", identifier: "voix.exemple.absente", among: voices)?.identifier == "voix.exemple.fr")
        #expect(SystemSpeechSynthesizer.pickVoice(language: "fr-FR", identifier: nil, among: voices)?.identifier == "voix.exemple.fr")
        // Absente, et aucune voix de la langue : rien.
        #expect(SystemSpeechSynthesizer.pickVoice(language: "de-DE", identifier: "voix.exemple.absente", among: voices) == nil)
        #expect(SystemSpeechSynthesizer.pickVoice(language: "de-DE", identifier: nil, among: voices) == nil)
    }

    // MARK: Règle 2

    @Test func theChosenIdentifierReachesTheRenderer() async throws {
        let chosen = ChosenVoices()
        func speaker(_ identifier: String?) -> SystemSpeechSynthesizer {
            SystemSpeechSynthesizer(language: "fr-FR", identifier: identifier, voices: { voices }, render: { _, id in
                chosen.record(id)
                return [AudioClip(samples: [0.1], sampleRate: 8000)]
            })
        }
        _ = try await speaker("voix.exemple.a").synthesize("Bonjour")
        _ = try await speaker("voix.exemple.absente").synthesize("Bonjour")
        _ = try await speaker(nil).synthesize("Bonjour")
        #expect(chosen.all == ["voix.exemple.a", "voix.exemple.fr", "voix.exemple.fr"])
    }

    /// Une voix désignée et installée suffit, même quand la langue n'a aucune voix : pas de `noVoice`.
    @Test func anInstalledIdentifierSpeaksEvenWithoutAVoiceOfTheLanguage() async throws {
        let chosen = ChosenVoices()
        let speaker = SystemSpeechSynthesizer(language: "de-DE", identifier: "voix.exemple.a", voices: { voices }, render: { _, id in
            chosen.record(id)
            return [AudioClip(samples: [0.1], sampleRate: 8000)]
        })
        _ = try await speaker.synthesize("Bonjour")
        #expect(chosen.all == ["voix.exemple.a"])
    }

    // MARK: Genre (code lu : `AVSpeechSynthesisVoiceGender`, AVSpeechSynthesis.h, lignes 28 à 31)

    @Test func theSystemGenderMapsCaseByCaseAndUnspecifiedIsNil() throws {
        #expect(SystemVoices.gender(.female) == .female)
        #expect(SystemVoices.gender(.male) == .male)
        #expect(SystemVoices.gender(.unspecified) == nil)
        // Un cas inconnu d'une version future du système : non précisé.
        #expect(SystemVoices.gender(try #require(AVSpeechSynthesisVoiceGender(rawValue: 99))) == nil)
    }

    /// Les appels existants compilent sans changement : nom vide et genre absent par défaut.
    @Test func aVoiceBuiltWithoutNameNorGenderHasEmptyNameAndNoGender() {
        let voice = SystemVoiceInfo(identifier: "voix.exemple.a", language: "fr-FR", quality: 1)
        #expect(voice.name == "" && voice.gender == nil)
    }
}
