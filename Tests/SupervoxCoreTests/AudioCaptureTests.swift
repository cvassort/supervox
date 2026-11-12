import Foundation
import Testing
@testable import SupervoxCore

/// Test d'intégration avec un vrai micro : à lancer à la main avec `SUPERVOX_MIC=1`.
/// Il enregistre environ une seconde de bruit ambiant, uniquement en mémoire : rien n'est écrit sur disque
/// et aucune valeur d'échantillon n'est affichée.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_MIC"] == "1"))
func captureRecordsAboutOneSecondTwiceFromTheSameInstance() async throws {
    let capture = AudioCapture()
    // Deux cycles sur la même instance : c'est ce que fait `record`, une capture par phrase.
    for cycle in 1...2 {
        try capture.start()
        try await Task.sleep(for: .seconds(1))
        let clip = capture.stop()
        #expect(clip.sampleRate > 0, "cycle \(cycle)")
        #expect(clip.duration >= 0.5 && clip.duration <= 2, "cycle \(cycle) : durée \(clip.duration) s")
        #expect(!capture.inputDescription.isEmpty)
        // Un accès refusé donne du silence parfait : on le signale sans jamais exposer le contenu.
        let silent = clip.samples.allSatisfy { $0 == 0 }
        Issue.record("cycle \(cycle) : \(clip.samples.count) échantillons à \(clip.sampleRate) Hz, silence parfait : \(silent), entrée : \(capture.inputDescription)", severity: .warning)
    }
}
