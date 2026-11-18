import AVFAudio
import Foundation

/// Ce que `SpeechRendering` demande à un synthétiseur de tampons : lancer une phrase et pousser les événements qu'il reçoit du
/// système, et s'arrêter. La seule réalisation est `AVSpeechBufferSource` (la mince couche qui appelle `AVSpeechSynthesizer`) ;
/// les tests en mettent une double.
///
/// **Aucune hypothèse sur le fil des rappels du système** : `emit` est `@Sendable` et sûr depuis n'importe quel fil. Le rappel
/// ne fait que copier le tampon en `AudioClip` (`SynthesisGate.Event.from`) et le pousser ; l'ordre d'un même producteur est
/// gardé. La source elle-même (le synthétiseur, sa boucle d'exécution) reste, elle, sur le fil principal : la mesure dit que le
/// système exige sa boucle (`docs/bench/2026-11-16-essai-voix-et-lecture.md`).
@MainActor
protocol SpeechBufferSource: AnyObject {
    /// Lance la synthèse. `emit` reçoit un `.chunk` par tampon, puis `.end` (tampon de longueur nulle **ou** `didFinish`, le
    /// premier des deux), ou `.interrupted` (`didCancel`). Lève `SpeechError.noVoice` si la voix n'existe plus.
    func start(text: String, voiceIdentifier: String, emit: @escaping @Sendable (SynthesisGate.Event) -> Void) throws(SpeechError)
    /// Coupe tout de suite la synthèse ; n'appelle plus `emit`.
    func stop()
}

/// La machine d'état d'une synthèse en cours : pure, sans fil ni système. Le premier verdict gagne, une seule fois ; tout ce qui
/// vient après (le délégué après le tampon nul, un tampon tardif, la garde de durée après la fin) est ignoré.
struct SynthesisGate {
    enum Event: Sendable {
        /// Un tampon lu.
        case chunk(AudioClip)
        /// La fin : le tampon de longueur nulle **ou** `didFinish`, le premier des deux (mesuré : ils se suivent à 0,2 ms).
        case end
        case fail(SpeechError)
        /// L'appelant annule.
        case cancelled
        /// `didCancel` : le système a interrompu la synthèse de lui-même. Rendue tout de suite (sans attendre la garde de durée)
        /// comme `SpeechError.timedOut` : « rien de rendu » pour l'appelant, qui traite la voix comme indisponible. Ce n'est
        /// pas `.cancelled` : l'appelant n'a rien annulé, et le repli ne doit pas le prendre pour une annulation.
        case interrupted
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
        case .interrupted: verdict = .failed(.timedOut)
        }
        return verdict
    }
}

extension SynthesisGate.Event {
    /// Ce que le rappel de `write` fait d'un tampon, **quel que soit le fil** (fonction pure, sans état) : un tampon de longueur
    /// nulle est la fin ; un tampon lisible est copié en `AudioClip` avec **son** format (le tampon appartient au système et n'est
    /// valable que pendant le rappel) ; un tampon qu'on ne sait pas lire fait échouer la synthèse (`.empty`), car l'ignorer
    /// tronquerait la parole en silence.
    static func from(_ buffer: AVAudioBuffer) -> SynthesisGate.Event {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return .fail(.empty) }
        if pcm.frameLength == 0 { return .end }
        guard let clip = SystemSpeechSynthesizer.clip(from: pcm) else { return .fail(.empty) }
        return .chunk(clip)
    }
}

enum SpeechRendering {
    /// Rend les morceaux d'une phrase, dans l'ordre. Ne bloque jamais le fil principal : il consomme un `AsyncStream` où le
    /// rappel du système, la garde de durée et l'annulation poussent leurs événements (un seul consommateur, donc l'ordre de
    /// chaque producteur est gardé).
    ///
    /// - La fin est le premier de : tampon de longueur nulle, `didFinish`. Prise une seule fois (`SynthesisGate`).
    /// - Garde de durée : `sleep(timeout)` qui rend avant la fin donne `SpeechError.timedOut` (un synthétiseur libéré, ou une
    ///   boucle principale arrêtée, ne signalent rien du tout : mesuré). L'attente est injectée.
    /// - `didCancel` (`.interrupted`) échoue tout de suite, sans attendre la garde.
    /// - Annulation de l'appelant : la source est arrêtée, `CancellationError` est levée sans attendre un signal du système. Si la
    ///   fin du système arrive dans le même tour que l'annulation, `render` peut rendre les morceaux ; l'appelant
    ///   (`SystemSpeechSynthesizer.synthesize`) revérifie l'annulation avant de livrer.
    /// - La source reste vivante jusqu'au retour (un synthétiseur libéré avant la fin ne signale plus rien : mesuré).
    @MainActor
    static func render(text: String, voiceIdentifier: String, source: any SpeechBufferSource, timeout: Double,
                       sleep: @escaping @Sendable (Double) async throws -> Void) async throws -> [AudioClip] {
        try Task.checkCancellation()
        let (stream, events) = AsyncStream.makeStream(of: SynthesisGate.Event.self)
        var gate = SynthesisGate()
        let timer = Task {
            do { try await sleep(timeout) } catch { return }
            events.yield(.fail(.timedOut))
        }
        defer {
            timer.cancel()
            events.finish()
            if case .finished = gate.verdict {} else { source.stop() }
        }
        try source.start(text: text, voiceIdentifier: voiceIdentifier, emit: { events.yield($0) })
        let verdict: SynthesisGate.Verdict? = await withTaskCancellationHandler {
            for await event in stream {
                if let verdict = gate.handle(event) { return verdict }
            }
            return nil   // le flux s'est arrêté sans verdict : la tâche est annulée
        } onCancel: {
            events.yield(.cancelled)
        }
        switch verdict {
        case .finished(let clips): return clips
        case .failed(let error): throw error
        case .cancelled, nil: throw CancellationError()
        }
    }
}
