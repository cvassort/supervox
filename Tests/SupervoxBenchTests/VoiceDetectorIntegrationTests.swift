import Foundation
import SupervoxCore
import SupervoxEngines
import Testing
@testable import SupervoxBench

// Vrai détecteur, vrai modèle (téléchargé au premier passage). Activé seulement avec SUPERVOX_INTEGRATION=1.

/// `text` lu par la voix française `Thomas` de `say`, en WAV 16 kHz mono.
private func spoken(_ text: String) throws -> AudioClip {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sv-vad-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Thomas", "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
    try say.run()
    say.waitUntilExit()
    try #require(say.terminationStatus == 0, "say a échoué")
    let clip = try WavFile.read(url)
    return clip.sampleRate == transcriberSampleRate ? clip : Resampler.resample(clip, to: transcriberSampleRate)
}

/// Seuil de la fin de voix de référence : −60 dBFS. Mesuré sur une phrase de `say` : les seuils de −60 à −40 dBFS
/// placent la fin à 8 ms près (−70 dBFS : 16 ms plus tard) ; `say` ajoute ensuite ~0,2 s de souffle à −88 dBFS,
/// retiré ici.
private let referenceFloor: Float = 0.001

/// Clip de test : `lead` secondes de silence, la phrase coupée à son dernier échantillon d'au moins −60 dBFS, puis
/// 1 s de silence. Rend le clip et l'instant de fin de voix de référence.
private func clipWithTrailingSilence(_ speech: AudioClip, lead: Double) -> (clip: AudioClip, speechEnd: Double) {
    let last = speech.samples.lastIndex { abs($0) >= referenceFloor } ?? 0
    let rate = speech.sampleRate
    let leading = [Float](repeating: 0, count: Int(lead * rate))
    let trailing = [Float](repeating: 0, count: Int(rate))
    let samples = leading + speech.samples[...last] + trailing
    return (AudioClip(samples: samples, sampleRate: rate), Double(leading.count + last + 1) / rate)
}

private let sentences = [
    "Bonjour, ceci est un test de transcription.",
    "Je voudrais ajouter un cache devant la base de données.",
    "Peux-tu relire la fonction qui calcule les factures ?",
]
/// Décalages du début de la voix sur la grille de 256 ms du détecteur.
private let leads = [0.0, 0.064, 0.128, 0.192]

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_INTEGRATION"] == "1"))
struct VoiceDetectorIntegrationTests {
    @Test func silenceYieldsNoSpeech() async throws {
        let silence = AudioClip(samples: [Float](repeating: 0, count: 32000), sampleRate: 16000)
        #expect(try await FluidVoiceDetector().segments(in: silence).isEmpty)
    }

    /// Chaque phrase, à chaque décalage du début de la voix sur la grille de 256 ms : l'écart entre la fin du dernier
    /// passage détecté et la fin de référence est affiché.
    ///
    /// Borne retenue par le contrôleur (elle remplace les ±0,2 s du plan, que la grille de 256 ms ne permet pas de
    /// tenir à toutes les phases) : la fin détectée n'est jamais en avance sur la vraie fin, ce qui couperait des
    /// mots, et elle est en retard de moins de deux tranches du détecteur (0,512 s), ce qui exclut un passage fermé à
    /// la fin du clip faute de silence suffisant. Mesuré (FluidAudio 0.18.3, 3 phrases × 4 décalages) : retard de
    /// +0,045 à +0,314 s. La fin tombe aussi sur la grille du détecteur, ce qui exclut une marge ajoutée.
    ///
    /// « Jamais en avance » tolère 10 ms : la fin de référence est elle-même placée à 8 ms près (seuils de −60 à
    /// −40 dBFS), un écart de quelques millisecondes vers l'avant viendrait de la référence, pas du détecteur.
    @Test func speechEndIsNeverEarlyAndLessThanTwoHopsLate() async throws {
        let detector = FluidVoiceDetector()
        let hop = FluidVoiceDetector.hopSeconds
        for text in sentences {
            let speech = try spoken(text)
            for lead in leads {
                let (clipWithTrailingSilence, speechDuration) = clipWithTrailingSilence(speech, lead: lead)
                let segs = try await detector.segments(in: clipWithTrailingSilence)
                let end = try #require(segs.last?.end, "aucune voix détectée : « \(text) »")
                let error = end - speechDuration
                let label = String(format: "« %@ », décalage %.3f s", text, lead)
                print(String(format: "[intégration] fin de voix %@ : référence %.3f s, détectée %.3f s, écart %+.3f s, %d passage(s)",
                             label, speechDuration, end, error, segs.count))
                #expect(error >= -0.01, "fin détectée avant la vraie fin : \(label), écart \(error) s")
                #expect(error < 2 * hop, "fin détectée plus de deux tranches après la vraie fin : \(label), écart \(error) s")
                #expect(abs(end / hop - (end / hop).rounded()) < 1e-6, "fin hors de la grille du détecteur : \(label), \(end) s")
            }
        }
    }

    /// `latency` signale un enregistrement dont la voix court jusqu'à la fin du clip (passage fermé par la bibliothèque
    /// à la fin du clip, clip non coupé) ; la même phrase suivie d'une seconde de silence ne l'est pas.
    @Test func speechRunningToTheEndOfTheClipIsFlagged() async throws {
        let speech = try spoken(sentences[1])
        let last = speech.samples.lastIndex { abs($0) >= referenceFloor } ?? 0
        let cut = AudioClip(samples: Array(speech.samples[...last]), sampleRate: speech.sampleRate)
        let (padded, _) = clipWithTrailingSilence(speech, lead: 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sv-vad-fin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try WavFile.write(cut, to: folder.appendingPathComponent("1-coupee.wav"))
        try WavFile.write(padded, to: folder.appendingPathComponent("2-silence.wav"))
        let detector = FluidVoiceDetector()
        let loaded = try await LatencyAudio.load(folder, segments: { try await detector.segments(in: $0) }, warn: { _ in })
        for recording in loaded.recordings {
            print(String(format: "[intégration] %@ : durée %.3f s, fin de voix %.3f s, ouverte en fin de clip : %@",
                         recording.id, recording.duration, recording.speechEnd, recording.openAtClipEnd ? "oui" : "non"))
        }
        #expect(loaded.recordings.map(\.id) == ["1-coupee", "2-silence"])
        #expect(loaded.recordings.first?.openAtClipEnd == true)
        #expect(loaded.recordings.last?.openAtClipEnd == false)
    }
}
