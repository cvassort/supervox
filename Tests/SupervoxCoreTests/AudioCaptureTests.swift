import AVFAudio
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
        let t0 = DispatchTime.now().uptimeNanoseconds
        let hostAtReturn = mach_absolute_time()
        try await Task.sleep(for: .seconds(1))
        let t1 = DispatchTime.now().uptimeNanoseconds
        let clip = capture.stop()
        let elapsed = Double(t1 - t0) / 1e9
        let missingTail = elapsed - clip.duration

        #expect(clip.sampleRate > 0, "cycle \(cycle)")
        #expect(clip.duration >= 0.5 && clip.duration <= 2, "cycle \(cycle) : durée \(clip.duration) s")
        #expect(!capture.inputDescription.isEmpty)
        // Contrat de `stop()` : au plus une fenêtre de tap (100 ms) manque entre le temps écoulé et le clip.
        // Tolérance 0,15 s = fenêtre de 100 ms + 50 ms de marge d'ordonnancement ; mesuré : écarts de 0,01 à 0,07 s
        // sur 14 prises. Avec des fenêtres de 400 ms, ce test échouerait.
        #expect(missingTail <= 0.15, "cycle \(cycle) : il manque \(missingTail) s en fin de prise")
        // Un accès refusé donne du silence parfait : on le signale sans jamais exposer le contenu.
        let silent = clip.samples.allSatisfy { $0 == 0 }
        // > 0 : le 1er échantillon du clip a été capté APRÈS le retour de start() (début de prise perdu) ; < 0 : avant.
        let firstOffset = capture.firstSampleHostTime.map {
            AVAudioTime.seconds(forHostTime: $0) - AVAudioTime.seconds(forHostTime: hostAtReturn)
        }
        let latency = capture.startLatency.map { String($0) } ?? "nil"
        let facts = "\(clip.samples.count) échantillons à \(clip.sampleRate) Hz, durée \(clip.duration) s, écoulé \(elapsed) s"
        let facts2 = "écart \(missingTail) s, délai 1er buffer \(latency) s, silence parfait : \(silent), 1er échantillon capté à \(firstOffset.map { String($0) } ?? "nil") s du retour de start()"
        Issue.record("cycle \(cycle) : \(facts), \(facts2), entrée : \(capture.inputDescription)", severity: .warning)
    }
}
