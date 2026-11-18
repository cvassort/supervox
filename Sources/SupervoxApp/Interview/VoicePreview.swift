import Foundation
import SupervoxCore

/// L'écoute d'une voix : la phrase d'essai de sa langue, dite par cette voix, puis jouée par le lecteur de sortie seule (le micro
/// n'est jamais ouvert). Une seule écoute à la fois.
///
/// Règles :
/// - Qui parle est décidé par la résolution unique `VoiceChoice.resolve(in:secrets:)` (injectée par `resolve`) et par rien d'autre ;
///   la fabrique reçoit la forme normalisée, avec le fournisseur résolu pour une voix de fournisseur, `nil` pour une voix du système.
/// - Aucun repli : une voix de fournisseur qui échoue dit sa panne ; la voix du système ne parle jamais à sa place.
/// - Une panne n'est classée qu'une fois, par l'étape où elle arrive (résolution, synthèse, lecture), selon la table de
///   `Failure` ; l'annulation n'est jamais une panne.
/// - Arrêt sûr : `stop()` annule la tâche de l'écoute (synthèse et lecture : l'annulation est le moyen sûr d'arrêter un
///   `ClipPlayer`), puis appelle `stopNow()` (l'arrêt est fait avant le retour : pour qui ouvre le micro juste après). Chaque écoute
///   a son jeton : un état tardif d'une écoute arrêtée ou remplacée est jeté, et rien n'est joué après `stop()`.
///
/// - Une voix du système désignée absente de la liste des voix installées (`systemVoices`, relue à l'écoute) : `.notInstalled`,
///   sans fabriquer de voix. Ce contrôle vit ici, et seulement ici : tout appelant y passe.
/// - Tant qu'un micro est tenu (`microphoneHeld`), l'écoute est refusée avant toute résolution (aucune lecture du trousseau) :
///   `.failed(.microphoneBusy)`. C'est la garantie ; l'onglet ne fait que la refléter.
@MainActor
public final class VoicePreview {
    public enum State: Equatable, Sendable {
        case idle, preparing, playing, failed(Failure)
    }

    /// La table des pannes (une phrase fixe par cas dans `VoicesText.failure`) :
    /// - `notInstalled` : la voix du système n'est pas sur cet ordinateur (`SpeechError.noVoice`, ou identifiant absent de la liste) ;
    /// - `unusable` : la voix de fournisseur ne peut pas parler (la résolution la rend au système avec une raison) ; rien n'est fabriqué ;
    /// - `provider` : la résolution a levé cette `RewriteFailure`, ou la synthèse du fournisseur a levé une erreur que
    ///   `RewriteFailure.from` classe (la fonction de la réécriture, réutilisée telle quelle) ;
    /// - `silent` : `SpeechError.empty`, ou un clip sans échantillon ;
    /// - `timedOut` : `SpeechError.timedOut`, ou la borne `limitSeconds` ;
    /// - `playback` : `ClipPlayerError` ;
    /// - `unavailable` : `InterviewEnvironment.Unavailable` (fabrique ou lecteur absent), et toute autre erreur de la voix du système.
    /// - `microphoneBusy` : un micro est tenu (dictée, correction, entretien) ; rien n'a été résolu ni fabriqué.
    public enum Failure: Equatable, Sendable {
        case notInstalled, unusable(SystemReason), provider(RewriteFailure), silent, timedOut, playback, unavailable
        case microphoneBusy
    }

    /// La résolution d'une voix : en production, `VoiceChoice.resolve(in:secrets:)`.
    public typealias Resolve = @MainActor (VoiceChoice, AppSettings) async throws -> ResolvedVoice

    /// Durée laissée à la synthèse de la phrase d'essai, en secondes : 15, choix non mesuré. La lecture n'est pas bornée (le clip
    /// a sa durée).
    public nonisolated static let limitSeconds: Double = 15

    private let makeVoice: @Sendable (VoiceChoice, ResolvedProvider?) -> any SpeechSynthesizer
    private let makePlayer: @Sendable () -> any ClipPlayer
    private let resolve: Resolve
    private let systemVoices: @Sendable () -> [SystemVoiceInfo]
    private let microphoneHeld: @MainActor () -> Bool
    private let sleep: @Sendable (Double) async throws -> Void

    /// Le lecteur, fabriqué à la première lecture et gardé : un `play` suivant sur le même lecteur arrête le précédent, et
    /// `stopNow()` vise la lecture en cours.
    private var player: (any ClipPlayer)?
    private var task: Task<Void, Never>?
    /// Le jeton de l'écoute en cours ; changé par chaque `start` et chaque `stop`.
    private var generation = 0
    /// Où publier l'état de l'écoute en cours ; `nil` une fois l'écoute finie, arrêtée ou remplacée.
    private var onState: (@MainActor (State) -> Void)?

    public init(
        makeVoice: @escaping @Sendable (VoiceChoice, ResolvedProvider?) -> any SpeechSynthesizer,
        makePlayer: @escaping @Sendable () -> any ClipPlayer,
        resolve: @escaping Resolve,
        systemVoices: @escaping @Sendable () -> [SystemVoiceInfo],
        microphoneHeld: @escaping @MainActor () -> Bool,
        sleep: @escaping @Sendable (Double) async throws -> Void
    ) {
        self.makeVoice = makeVoice
        self.makePlayer = makePlayer
        self.resolve = resolve
        self.systemVoices = systemVoices
        self.microphoneHeld = microphoneHeld
        self.sleep = sleep
    }

    /// Arrête l'écoute en cours (elle publie `.idle`), puis lance celle-ci : `.preparing` tout de suite, `.playing` pendant la
    /// lecture, puis `.idle` à la fin, ou `.failed`.
    ///
    /// Un micro tenu : `.failed(.microphoneBusy)` est publié une fois, ici, et rien d'autre (ni jeton, ni tâche, ni résolution).
    /// Le rappel n'est pas retenu : le `stop()` d'avant micro suivant ne publierait sinon `.idle` par-dessus la phrase.
    public func start(_ choice: VoiceChoice, settings: AppSettings, onState: @escaping @MainActor (State) -> Void) {
        stop()
        if microphoneHeld() {
            onState(.failed(.microphoneBusy))
            return
        }
        generation += 1
        let token = generation
        self.onState = onState
        onState(.preparing)
        task = Task { [weak self] in
            await self?.run(choice.normalized, settings: settings, token: token)
        }
    }

    /// Annule la synthèse et la lecture en cours, puis arrête le lecteur avant de rendre la main. L'écoute arrêtée publie `.idle`,
    /// une fois, ici ; plus rien d'elle n'arrive ensuite. Sans écoute : rien.
    public func stop() {
        task?.cancel()
        task = nil
        generation += 1
        player?.stopNow()
        let pending = onState
        onState = nil
        pending?(.idle)
    }

    // MARK: - L'écoute

    /// Une panne classée, qui finit l'écoute.
    private struct Stop: Error {
        let failure: Failure
    }

    private func run(_ choice: VoiceChoice, settings: AppSettings, token: Int) async {
        let end: State
        do {
            try await listen(choice, settings: settings, token: token)
            end = .idle
        } catch let stop as Stop {
            end = .failed(stop.failure)
        } catch {
            // L'annulation (arrêt, remplacement) n'est pas une panne.
            end = .idle
        }
        publish(end, token: token)
        if token == generation {
            onState = nil
            task = nil
        }
    }

    private func listen(_ choice: VoiceChoice, settings: AppSettings, token: Int) async throws {
        let resolved: ResolvedVoice
        do {
            resolved = try await resolve(choice, settings)
        } catch let failure as RewriteFailure {
            throw Stop(failure: .provider(failure))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Stop(failure: .unavailable)
        }
        // Arrêtée pendant la résolution (même par une résolution sourde à l'annulation) : rien n'est fabriqué.
        try checkLive(token)

        let voice: any SpeechSynthesizer
        let fromProvider: Bool
        switch resolved {
        case .system(_, _, because: let reason?):
            throw Stop(failure: .unusable(reason))
        case .system(_, let identifier, because: nil):
            // Une voix désignée absente de la liste : le synthétiseur du système prendrait la meilleure voix de la langue sans
            // rien lever, et l'on entendrait une autre voix que celle qu'on écoute.
            // Laissé : entre cette relecture et la synthèse, la voix peut disparaître ; le synthétiseur prend alors la meilleure
            // voix de la langue sans rien lever (il n'a pas de mode strict).
            if let identifier, !systemVoices().contains(where: { $0.identifier == identifier }) {
                throw Stop(failure: .notInstalled)
            }
            voice = makeVoice(choice, nil)
            fromProvider = false
        case .provider(let provider, _):
            voice = makeVoice(choice, provider)
            fromProvider = true
        }

        let phrase = VoicesText.samplePhrase(for: choice.language)
        let speech: Speech
        do {
            speech = try await Deadline.run(seconds: Self.limitSeconds, sleep: sleep) { try await voice.synthesize(phrase) }
        } catch {
            throw try Self.synthesisFailure(error, fromProvider: fromProvider)
        }
        // Une réponse arrivée après l'arrêt n'est jamais jouée. Défense en profondeur, sans test propre : l'annulation la masque
        // (`Deadline.run` rend `CancellationError` dès l'annulation).
        try checkLive(token)
        guard !speech.clip.samples.isEmpty else { throw Stop(failure: .silent) }

        let player = currentPlayer()
        publish(.playing, token: token)
        do {
            try await player.play(speech.clip)
        } catch is ClipPlayerError {
            throw Stop(failure: .playback)
        } catch is InterviewEnvironment.Unavailable {
            throw Stop(failure: .unavailable)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Stop(failure: .playback)
        }
        try checkLive(token)
    }

    /// Classe une erreur de la synthèse, une fois. L'annulation est rendue telle quelle (levée), jamais classée.
    private static func synthesisFailure(_ error: any Error, fromProvider: Bool) throws -> Stop {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        switch error {
        case is DeadlineExceeded:
            return Stop(failure: .timedOut)
        case let speech as SpeechError:
            switch speech {
            case .noVoice: return Stop(failure: .notInstalled)
            case .empty: return Stop(failure: .silent)
            case .timedOut: return Stop(failure: .timedOut)
            }
        case is InterviewEnvironment.Unavailable:
            return Stop(failure: .unavailable)
        default:
            return Stop(failure: fromProvider ? .provider(RewriteFailure.from(error)) : .unavailable)
        }
    }

    private func checkLive(_ token: Int) throws {
        if token != generation || Task.isCancelled { throw CancellationError() }
    }

    private func currentPlayer() -> any ClipPlayer {
        if let player { return player }
        let made = makePlayer()
        player = made
        return made
    }

    /// Publie l'état de l'écoute `token` seulement si elle est encore l'écoute en cours.
    private func publish(_ state: State, token: Int) {
        guard token == generation else { return }
        onState?(state)
    }
}
