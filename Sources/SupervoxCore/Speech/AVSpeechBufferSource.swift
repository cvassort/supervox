import AVFAudio
import Foundation

/// La mince couche qui appelle `AVSpeechSynthesizer` : `write` vers des tampons, et le délégué pour la fin. **Jamais exécutée par
/// les tests** (elle synthétise par une vraie voix du système) ; tout ce qu'elle fait de non trivial est dans `SpeechRendering`.
///
/// Confinée au fil principal (`@MainActor`) : `AVSpeechSynthesizer` n'est pas `Sendable`, et le système rend les tampons et le
/// délégué sur le fil principal, à condition que sa boucle tourne (mesuré, `docs/bench/2026-11-16-essai-voix-et-lecture.md`).
/// Elle ne le bloque donc jamais. Le synthétiseur est un champ : il vit autant que la source, que `SpeechRendering` garde
/// jusqu'à la fin (libéré avant, il ne signale plus rien).
@MainActor
final class AVSpeechBufferSource: NSObject, SpeechBufferSource, AVSpeechSynthesizerDelegate {
    private let language: String
    private let synthesizer = AVSpeechSynthesizer()
    private var onFinish: (@MainActor () -> Void)?

    init(language: String) {
        self.language = language
        super.init()
    }

    func start(text: String, voiceIdentifier: String, onBuffer: @escaping @MainActor (AVAudioBuffer) -> Void,
               onFinish: @escaping @MainActor () -> Void) throws(SpeechError) {
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) else { throw SpeechError.noVoice(language: language) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        self.onFinish = onFinish
        synthesizer.delegate = self
        synthesizer.write(utterance) { buffer in
            // Rendu sur le fil principal (mesuré) ; l'appelant copie le tampon tout de suite.
            MainActor.assumeIsolated { onBuffer(buffer) }
        }
    }

    func stop() {
        onFinish = nil
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        MainActor.assumeIsolated { onFinish?() }
    }
}
