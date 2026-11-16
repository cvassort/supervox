import AVFAudio
import Foundation
import Synchronization

/// La mince couche qui appelle `AVSpeechSynthesizer` : `write` vers des tampons, et le délégué pour la fin. **Jamais exécutée par
/// les tests** (elle synthétise par une vraie voix du système) ; tout ce qu'elle fait de non trivial est dans `SpeechRendering`
/// et `SynthesisGate.Event.from`, testés.
///
/// Le synthétiseur est créé, utilisé et arrêté sur le fil principal (`@MainActor`) : il n'est pas `Sendable`, et le système exige sa
/// boucle (mesuré, `docs/bench/2026-11-16-essai-voix-et-lecture.md`). Il est un champ de la source, que `SpeechRendering` garde
/// jusqu'à la fin (libéré avant, il ne signale plus rien). En revanche, **les rappels du système ne sont pas supposés arriver
/// sur le fil principal** : ils passent par `SpeechRelay`, sans isolation, qui ne fait que convertir et pousser.
@MainActor
final class AVSpeechBufferSource: SpeechBufferSource {
    private let language: String
    private let synthesizer = AVSpeechSynthesizer()
    private let relay = SpeechRelay()

    init(language: String) {
        self.language = language
    }

    func start(text: String, voiceIdentifier: String, emit: @escaping @Sendable (SynthesisGate.Event) -> Void) throws(SpeechError) {
        guard let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) else { throw SpeechError.noVoice(language: language) }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        relay.arm(emit)
        synthesizer.delegate = relay
        synthesizer.write(utterance, toBufferCallback: relay.bufferCallback())
    }

    func stop() {
        relay.disarm()
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
    }
}

/// Le délégué et le rappel de `write`, **sans isolation** : ils tournent sur le fil que le système choisit. Seul état : le rappel
/// `emit`, derrière un verrou. `disarm` est appelé avant `stopSpeaking`, donc l'arrêt que l'application demande ne revient pas.
final class SpeechRelay: NSObject, AVSpeechSynthesizerDelegate, Sendable {
    private let emit = Mutex<(@Sendable (SynthesisGate.Event) -> Void)?>(nil)

    func arm(_ emit: @escaping @Sendable (SynthesisGate.Event) -> Void) {
        self.emit.withLock { $0 = emit }
    }

    func disarm() {
        emit.withLock { $0 = nil }
    }

    private func send(_ event: SynthesisGate.Event) {
        let emit = emit.withLock { $0 }
        emit?(event)
    }

    /// Le rappel de `write` : formé ici, hors de tout acteur (une fermeture écrite dans la source `@MainActor` serait isolée au
    /// fil principal, avec un contrôle à l'exécution qui planterait ailleurs).
    func bufferCallback() -> AVSpeechSynthesizer.BufferCallback {
        { [self] buffer in send(.from(buffer)) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        send(.end)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        send(.interrupted)
    }
}
