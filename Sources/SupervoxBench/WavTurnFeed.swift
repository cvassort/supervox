import Foundation
import Synchronization
import SupervoxCore

/// Le son de l'entretien du banc : des tours de parole lus dans des fichiers WAV à la place du micro, une lecture simulée à la
/// place du haut-parleur. **Aucun matériel n'est ouvert** : c'est le seul `AudioIO` de la commande `interview`, jamais `LiveAudioIO`.
///
/// - **Micro.** `pushTurn(i)` pousse le tour `i` par tranches de 20 ms, puis 2 s de silence (le détecteur de voix a besoin de
///   silence pour fermer le passage). Quand le tour est poussé, c'est la commande qui le décide : après la fin de la réplique
///   précédente, ou après un délai de lecture simulée pour une interruption (`InterviewDriver`).
/// - **Haut-parleur.** `play` ne joue rien : le clip « finit » après son temps réel, par une attente injectée (`wait`), comme le
///   double `ScriptedAudioIO` dont c'est la composition. La position de lecture se déduit de l'horloge injectée (`now`) : le moteur la
///   lit, à l'interruption, pour décider ce qui a été entendu.
///
/// Un bloc poussé avant `start` ou après `stop` est perdu, comme avec un micro (`ScriptedAudioIO.push`).
final class WavTurnFeed: AudioIO {
    /// Durée d'une tranche poussée : 20 ms, la trame de la porte d'interruption (320 échantillons à 16 kHz) ; valeur du brief,
    /// choix non mesuré.
    static let chunkSeconds = 0.02
    /// Silence poussé après chaque tour, au moins : 2 s, valeur du brief, choix non mesuré.
    static let minimumTrailingSilence = 2.0

    /// Marge ajoutée aux blocs silencieux nécessaires : 1 s, choix non mesuré (couvre le bloc où la voix s'arrête et l'alignement des
    /// blocs).
    static let trailingMargin = 1.0

    /// Le silence à pousser pour que le détecteur ferme le passage, pour un silence de fin de tour `detectorSilence` et des blocs de
    /// `blockSeconds`. Code lu (`FluidStreamingVoiceDetector`) : le passage se ferme après 1 + ⌈silence / bloc⌉ blocs silencieux
    /// entiers (bloc de 0,256 s avec le vrai détecteur) ; on pousse ces blocs et la marge, jamais moins que `minimumTrailingSilence`.
    /// Formule du code lu, non confirmée sur le vrai détecteur.
    static func trailingSilence(detectorSilence: Double, blockSeconds: Double) -> Double {
        guard blockSeconds > 0, detectorSilence.isFinite else { return minimumTrailingSilence }
        let blocks = 1 + (detectorSilence / blockSeconds).rounded(.up)
        return max(minimumTrailingSilence, blocks * blockSeconds + trailingMargin)
    }

    private struct State {
        var pushed: [Int] = []
        var voiceEnds: [Int: Double] = [:]
        /// Les durées des clips en file (celui qui joue en tête).
        var clips: [Double] = []
        /// La date où le clip en tête a commencé.
        var currentStart: Double?
    }

    private let turns: [AudioClip]
    private let inner: ScriptedAudioIO
    private let trailingSilence: Double
    private let now: @Sendable () -> Double
    private let state = Mutex(State())

    /// - Parameters:
    ///   - turns: un clip par tour de la personne, dans l'ordre (à la fréquence où ils seront poussés).
    ///   - wait: l'attente de la durée d'un clip ; elle rend la main quand le clip est « fini ».
    ///   - trailingSilence: secondes de silence poussées après chaque tour.
    ///   - now: l'horloge, en secondes.
    init(
        turns: [AudioClip], trailingSilence: Double = WavTurnFeed.minimumTrailingSilence,
        wait: @escaping @Sendable (Double) async -> Void, now: @escaping @Sendable () -> Double
    ) {
        self.turns = turns
        self.trailingSilence = trailingSilence
        self.now = now
        inner = ScriptedAudioIO(completion: .afterDuration(wait))
    }

    var turnCount: Int { turns.count }

    /// Les tours poussés, dans l'ordre.
    var pushedTurns: [Int] { state.withLock { $0.pushed } }

    /// La date où la voix du tour `index` a fini d'être poussée (avant le silence qui la suit) ; `nil` si le tour n'a pas été poussé.
    func voiceEnd(of index: Int) -> Double? { state.withLock { $0.voiceEnds[index] } }

    /// Pousse le tour `index` (la voix, puis le silence). `false`, sans rien pousser, si ce tour n'existe pas. À ne pas appeler depuis
    /// le rappel du micro (contrat de `MicrophoneFeed`).
    @discardableResult
    func pushTurn(_ index: Int) -> Bool {
        guard turns.indices.contains(index) else { return false }
        let clip = turns[index]
        state.withLock { $0.pushed.append(index) }
        send(clip.samples, rate: clip.sampleRate)
        let voiceEnd = now()
        state.withLock { $0.voiceEnds[index] = voiceEnd }
        send([Float](repeating: 0, count: Int((trailingSilence * clip.sampleRate).rounded())), rate: clip.sampleRate)
        return true
    }

    private func send(_ samples: [Float], rate: Double) {
        let size = max(1, Int((Self.chunkSeconds * rate).rounded()))
        for start in stride(from: 0, to: samples.count, by: size) {
            inner.push(AudioChunk(samples: Array(samples[start..<min(start + size, samples.count)]), sampleRate: rate))
        }
    }

    // MARK: AudioIO

    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws { try inner.start(onChunk: onChunk) }

    func stop() { inner.stop() }

    func play(_ clip: AudioClip, onEnd: @escaping @Sendable (PlaybackEnd) -> Void) throws {
        // La file est tenue avant l'appel : un clip vide finit tout de suite, sa fin ne doit pas arriver avant son inscription.
        state.withLock { state in
            if state.clips.isEmpty { state.currentStart = now() }
            state.clips.append(clip.duration)
        }
        do {
            try inner.play(clip) { [self] end in
                state.withLock { state in
                    if !state.clips.isEmpty { state.clips.removeFirst() }
                    state.currentStart = state.clips.isEmpty ? nil : now()
                }
                onEnd(end)
            }
        } catch {
            state.withLock { state in
                if !state.clips.isEmpty { state.clips.removeLast() }
                if state.clips.isEmpty { state.currentStart = nil }
            }
            throw error
        }
    }

    func stopPlayback() { inner.stopPlayback() }

    /// Le temps écoulé dans le clip qui joue, borné par sa durée ; `nil` sans clip à jouer.
    var playbackPosition: Double? {
        guard inner.playbackPosition != nil else { return nil }
        return state.withLock { state in
            guard let start = state.currentStart, let duration = state.clips.first else { return nil }
            return min(max(now() - start, 0), duration)
        }
    }

    /// Rend la main quand toutes les fins de clip dues à cet instant ont été livrées. Jamais depuis un `onEnd`.
    func flushEnds() { inner.flushEnds() }
}
