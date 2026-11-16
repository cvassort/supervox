import AVFAudio
import Foundation

/// Ce que `SpeechRendering` demande à un synthétiseur de tampons : lancer une phrase, rendre chaque tampon et la fin du délégué,
/// et s'arrêter. La seule réalisation est `AVSpeechBufferSource` (la mince couche qui appelle `AVSpeechSynthesizer`) ; les tests
/// en mettent une double. Tout se passe sur le fil principal : c'est là que le système rend les tampons et le délégué
/// (mesuré, `docs/bench/2026-11-16-essai-voix-et-lecture.md`).
@MainActor
protocol SpeechBufferSource: AnyObject {
    /// Lance la synthèse. `onBuffer` reçoit chaque tampon (le rappel doit le copier sans attendre), `onFinish` la fin signalée par
    /// le délégué. Lève `SpeechError.noVoice` si la voix n'existe plus.
    func start(text: String, voiceIdentifier: String, onBuffer: @escaping @MainActor (AVAudioBuffer) -> Void,
               onFinish: @escaping @MainActor () -> Void) throws(SpeechError)
    /// Coupe tout de suite la synthèse ; n'appelle plus aucun rappel.
    func stop()
}

/// La machine d'état d'une synthèse en cours : pure, sans fil ni système. Le premier verdict gagne, une seule fois ; tout ce qui
/// vient après (le délégué après le tampon nul, un tampon tardif, la garde de durée après la fin) est ignoré.
struct SynthesisGate {
    enum Event {
        /// Un tampon lu.
        case chunk(AudioClip)
        /// La fin : le tampon de longueur nulle **ou** `didFinish`, le premier des deux (mesuré : ils se suivent à 0,2 ms).
        case end
        case fail(SpeechError)
        case cancelled
    }

    enum Verdict: Equatable {
        case finished([AudioClip])
        case failed(SpeechError)
        case cancelled
    }

    private var clips: [AudioClip] = []
    private(set) var verdict: Verdict?

    /// Le verdict, rendu **seulement à l'instant où il tombe** ; `nil` sinon (l'événement a été gardé ou ignoré).
    mutating func handle(_ event: Event) -> Verdict? {
        guard verdict == nil else { return nil }
        switch event {
        case .chunk(let clip):
            clips.append(clip)
            return nil
        case .end: verdict = .finished(clips)
        case .fail(let error): verdict = .failed(error)
        case .cancelled: verdict = .cancelled
        }
        return verdict
    }
}

@MainActor
private final class RenderRun {
    private var gate = SynthesisGate()
    private var continuation: CheckedContinuation<[AudioClip], any Error>?
    /// Verdict tombé avant que l'attente ne soit installée.
    private var early: SynthesisGate.Verdict?

    var isSettled: Bool { gate.verdict != nil }
    var finishedCleanly: Bool { if case .finished = gate.verdict { return true } else { return false } }

    func handle(_ event: SynthesisGate.Event) {
        guard let verdict = gate.handle(event) else { return }
        guard let continuation else { early = verdict; return }
        self.continuation = nil
        continuation.resume(with: Self.result(of: verdict))
    }

    func install(_ continuation: CheckedContinuation<[AudioClip], any Error>) {
        if let early {
            self.early = nil
            continuation.resume(with: Self.result(of: early))
        } else {
            self.continuation = continuation
        }
    }

    private static func result(of verdict: SynthesisGate.Verdict) -> Result<[AudioClip], any Error> {
        switch verdict {
        case .finished(let clips): .success(clips)
        case .failed(let error): .failure(error)
        case .cancelled: .failure(CancellationError())
        }
    }
}

enum SpeechRendering {
    /// Rend les morceaux d'une phrase, dans l'ordre. Ne bloque jamais le fil principal : il attend une continuation.
    ///
    /// - La fin est le premier de : tampon de longueur nulle, `didFinish`. Prise une seule fois.
    /// - Garde de durée : `sleep(timeout)` qui rend avant la fin donne `SpeechError.timedOut` (un synthétiseur libéré, ou une
    ///   boucle principale arrêtée, ne signalent rien du tout : mesuré). L'attente est injectée.
    /// - Un tampon qu'on ne sait pas lire fait échouer la synthèse (`.empty`) : l'ignorer tronquerait la parole en silence.
    /// - Annulation : la source est arrêtée, et `CancellationError` est levée sans attendre un signal du système.
    /// - La source reste vivante jusqu'au retour (un synthétiseur libéré avant la fin ne signale plus rien : mesuré).
    @MainActor
    static func render(text: String, voiceIdentifier: String, source: any SpeechBufferSource, timeout: Double,
                       sleep: @escaping @Sendable (Double) async throws -> Void) async throws -> [AudioClip] {
        let run = RenderRun()
        let timer = Task { @MainActor in
            do { try await sleep(timeout) } catch { return }
            run.handle(.fail(.timedOut))
        }
        defer {
            timer.cancel()
            if !run.finishedCleanly { source.stop() }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[AudioClip], any Error>) in
                run.install(continuation)
                if Task.isCancelled { run.handle(.cancelled); return }
                do throws(SpeechError) {
                    try source.start(text: text, voiceIdentifier: voiceIdentifier, onBuffer: { buffer in
                        guard !run.isSettled else { return }
                        guard let pcm = buffer as? AVAudioPCMBuffer else { return run.handle(.fail(.empty)) }
                        if pcm.frameLength == 0 { return run.handle(.end) }
                        guard let clip = SystemSpeechSynthesizer.clip(from: pcm) else { return run.handle(.fail(.empty)) }
                        run.handle(.chunk(clip))
                    }, onFinish: { run.handle(.end) })
                } catch {
                    run.handle(.fail(error))
                }
            }
        } onCancel: {
            Task { @MainActor in run.handle(.cancelled) }
        }
    }
}
