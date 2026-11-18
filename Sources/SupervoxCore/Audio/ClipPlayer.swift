import AVFAudio
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// Joue un clip par la sortie seule (sans ouvrir le micro), pour l'écoute d'une voix.
///
/// Contrat, commun au vrai lecteur et au double :
/// - `play` rend la main quand le clip est fini, ou arrêté : par `stop()`, par l'annulation de la tâche appelante ou par un `play`
///   suivant, qui arrête la lecture en cours. Une lecture arrêtée rend la main **normalement**, sans lever ;
/// - un clip **vide** n'a rien à jouer : il arrête la lecture en cours, puis `play` rend la main tout de suite ;
/// - `play` lève `ClipPlayerError.failed` quand la lecture ne peut pas se faire. Un `play` qui lève peut avoir arrêté, ou non, la
///   lecture en cours : une fréquence refusée lève avant tout arrêt (la lecture en cours continue) ; un lecteur du système qui refuse
///   d'ouvrir le clip lève après avoir arrêté la lecture en cours ;
/// - l'annulation de la tâche appelante n'arrête que **sa** lecture, jamais celle d'un autre appel ; c'est le moyen sûr d'arrêter.
///   Un `play` lancé par une tâche déjà annulée ne touche à rien. Fenêtre résiduelle : un `play` annulé **pendant** son démarrage
///   (après avoir arrêté la lecture précédente, avant de commencer la sienne) a pu arrêter la lecture précédente, et ne joue rien ;
/// - `stop()` s'appelle de partout, ne vaut que pour la lecture **commencée**, et peut rendre la main **avant** que l'arrêt ait eu lieu
///   (le vrai lecteur le confie au fil principal) : `play` rend la main peu après. Entre l'appel de `play` et le début réel de la
///   lecture (encodage, attente du fil principal dans le vrai lecteur), un `stop()` est perdu, et la lecture va à son terme ;
/// - `stopNow()`, sur le fil principal, arrête la lecture commencée **avant** de rendre la main : pour qui va ouvrir le micro juste
///   après. Même fenêtre perdue que `stop()` avant le début réel.
public protocol ClipPlayer: Sendable {
    func play(_ clip: AudioClip) async throws
    func stop()
    @MainActor func stopNow()
}

public enum ClipPlayerError: Error, Equatable, Sendable {
    case failed
}

/// Le vrai lecteur : le clip est encodé en WAV en mémoire (`WavFile.data(from:)`) et joué par le lecteur de fichiers audio du système,
/// qui n'utilise que la sortie. Le lecteur vit sur le fil principal. Aucun test de la suite par défaut ne l'exécute : seuls les essais
/// matériels `SUPERVOX_PLAYER=1` le font ; ses deux fonctions pures (`isPlayable`, `fallbackDelay`) se testent sans lui.
public final class SystemClipPlayer: ClipPlayer {
    private struct State {
        var nextToken = 0
        /// La lecture commencée, avec le jeton de l'appel de `play` qui l'a posée ; `nil` sans lecture.
        var current: (token: Int, playback: Playback)?
        /// Lectures finies par la fin de secours (le système n'a pas appelé le délégué de fin à temps).
        var fallbackEnds = 0
    }
    private let state = Mutex(State())

    public init() {}

    /// Nombre de lectures finies par la fin de secours. Les essais matériels exigent 0 : sinon le système n'a pas appelé le délégué
    /// de fin, et chaque écoute finirait `fallbackMargin` secondes après son clip.
    var fallbackEndCount: Int { state.withLock { $0.fallbackEnds } }

    /// Marge ajoutée à la durée du clip avant la fin de secours : 2 s (valeur du plan, choix non mesuré).
    static let fallbackMargin = 2.0

    /// Une fréquence que le reste du dépôt accepte déjà pour la réponse d'un fournisseur de voix
    /// (`ProviderSpeechSynthesizer.acceptedSampleRates`) ; NaN et infinis sont dehors. L'encodeur ne la reçoit jamais autrement.
    static func isPlayable(sampleRate: Double) -> Bool {
        ProviderSpeechSynthesizer.acceptedSampleRates.contains(sampleRate)
    }

    /// Délai de la fin de secours : la durée du clip plus `fallbackMargin`. Une durée non finie ou négative (impossible avec une
    /// fréquence acceptée, défense seulement) donne la marge seule : une borne finie, jamais une attente sans fin.
    static func fallbackDelay(clipDuration: Double) -> Double {
        guard clipDuration.isFinite, clipDuration >= 0 else { return fallbackMargin }
        return clipDuration + fallbackMargin
    }

    public func play(_ clip: AudioClip) async throws {
        let data: Data?
        if clip.samples.isEmpty {
            data = nil   // rien à jouer : `run` arrête la lecture en cours
        } else {
            guard Self.isPlayable(sampleRate: clip.sampleRate) else { throw ClipPlayerError.failed }
            data = WavFile.data(from: clip)
        }
        let token = state.withLock { s -> Int in
            s.nextToken += 1
            return s.nextToken
        }
        let delay = Self.fallbackDelay(clipDuration: clip.duration)
        try await withTaskCancellationHandler {
            try await run(data, token: token, fallbackDelay: delay)
        } onCancel: {
            stop(token: token)
        }
    }

    public func stop() {
        stop(token: nil)
    }

    /// Arrête la lecture commencée sur place, sans tâche intermédiaire : le lecteur du système est arrêté avant le retour.
    @MainActor public func stopNow() {
        state.withLock { $0.current?.playback }?.stop()
    }

    /// Demande l'arrêt au fil principal ; `play` rend la main dès que l'arrêt y est passé. Avec un jeton, seulement si la lecture
    /// commencée est celle de cet appel.
    private func stop(token: Int?) {
        let playback = state.withLock { s -> Playback? in
            guard let current = s.current, token == nil || current.token == token else { return nil }
            return current.playback
        }
        guard let playback else { return }
        Task { @MainActor in playback.stop() }
    }

    @MainActor private func run(_ data: Data?, token: Int, fallbackDelay: Double) async throws {
        // Déjà annulée : ne touche à rien, ni à la lecture en cours (comme le double).
        if Task.isCancelled { return }
        guard let data else {
            let previous = state.withLock { s -> Playback? in
                defer { s.current = nil }
                return s.current?.playback
            }
            previous?.stop()
            return
        }
        let playback = Playback(fallbackDelay: fallbackDelay, onFallbackEnd: { self.state.withLock { $0.fallbackEnds += 1 } })
        let previous = state.withLock { s -> Playback? in
            defer { s.current = (token, playback) }
            return s.current?.playback
        }
        previous?.stop()
        defer { state.withLock { s in if s.current?.token == token { s.current = nil } } }
        // Annulée entre le contrôle du début et la pose, la tâche n'a pas pu arrêter cette lecture : on n'en commence pas une (la
        // précédente est déjà arrêtée : fenêtre résiduelle écrite sur le protocole).
        if Task.isCancelled { return }
        try await playback.play(data)
    }
}

/// Une lecture : le lecteur du système, son délégué, et l'attente de sa fin. Toutes les fins (fin du clip, erreur, `stop`, fin de
/// secours) passent par `end`, qui ne rend la main à `play` qu'une fois.
///
/// Fil principal, par choix. L'en-tête du lecteur (AVAudioPlayer.h, lignes 46-47 et 56-57) dit que `play` démarre le matériel audio de
/// façon synchrone et que `stop` bloque pendant sa libération. Ces deux appels se font donc sur le fil principal, et la durée de ce
/// blocage n'est pas mesurée. Sortir le lecteur du fil principal ferait dépendre la fin de lecture d'un fil sans boucle d'événements,
/// sur un code que personne n'a encore exécuté.
///
/// Le délégué : ses deux méthodes sont `nonisolated` et repassent par le fil principal. Si le système les appelait d'un autre fil
/// (non établi ; l'en-tête annonce le fil principal), rien ne plante. Si le système ne les appelait jamais (non établi non plus), la
/// fin de secours arrête le lecteur, rend la main à `durée du clip + 2 s` et se fait compter (`SystemClipPlayer.fallbackEndCount`).
@MainActor private final class Playback: NSObject, AVAudioPlayerDelegate {
    private let fallbackDelay: Double
    private let onFallbackEnd: @Sendable () -> Void
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var fallback: Task<Void, Never>?
    private var stopped = false

    init(fallbackDelay: Double, onFallbackEnd: @escaping @Sendable () -> Void) {
        self.fallbackDelay = fallbackDelay
        self.onFallbackEnd = onFallbackEnd
    }

    func play(_ data: Data) async throws {
        guard !stopped else { return }
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data, fileTypeHint: UTType.wav.identifier)
        } catch {
            throw ClipPlayerError.failed
        }
        player.delegate = self   // référence faible : `self` est retenu par `run` jusqu'à la fin
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.player = player
            guard player.play() else {
                end(.failure(ClipPlayerError.failed))
                return
            }
            let delay = fallbackDelay
            fallback = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.continuation != nil else { return }
                self.onFallbackEnd()
                self.player?.stop()
                self.end(.success(()))
            }
        }
    }

    func stop() {
        stopped = true
        player?.stop()
        end(.success(()))
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.end(flag ? .success(()) : .failure(ClipPlayerError.failed)) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in
            self.player?.stop()
            self.end(.failure(ClipPlayerError.failed))
        }
    }

    private func end(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        player = nil
        fallback?.cancel()
        fallback = nil
        continuation.resume(with: result)
    }
}

/// Un lecteur double, pour les tests (de ce module et de l'application) : il garde les clips reçus et ne joue rien.
///
/// - `.manual` : `play` attend `finish()`, `stop()`, l'annulation de sa tâche ou un `play` suivant ;
/// - `.immediate` : `play` rend la main tout de suite ;
/// - `.failing` : `play` lève `ClipPlayerError.failed` tout de suite ;
/// - dans les trois modes, un clip vide est gardé, arrête la lecture en cours et rend la main tout de suite, sans lever.
///
/// Un test attend les lectures par `waitForPlays(_:)` (jamais par un sommeil), qui rend la main à l'annulation. Le clip reçu, la
/// lecture en cours et le réveil de `waitForPlays` sont posés sous un même verrou : un test qui a vu la lecture arriver peut l'arrêter.
///
/// `stopNow()` arrête comme `stop()` et se compte à part (`stopNowCount`).
///
/// Écarts restants avec le vrai lecteur : ici `stop()` arrête avant de rendre la main ; la lecture est posée dès l'appel (ni la
/// fenêtre où un `stop()` est perdu, ni celle où un `play` annulé pendant son démarrage a déjà arrêté la lecture précédente
/// n'existent) ; un clip reçu par une tâche déjà annulée est gardé dans `clips` ; une lecture commencée ne peut pas échouer en cours
/// de route ; `.failing` lève sans arrêter la lecture en cours (le vrai lecteur, quand l'ouverture échoue, l'a déjà arrêtée).
public final class ScriptedClipPlayer: ClipPlayer {
    public enum Completion: Sendable {
        case manual, immediate, failing
    }

    private struct State {
        var clips: [AudioClip] = []
        var stops = 0
        var stopNows = 0
        var nextToken = 0
        var playing: (token: Int, continuation: CheckedContinuation<Void, Never>)?
        var waiters: [Int: (need: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
        var nextWaiter = 0

        /// Retire et rend les attentes satisfaites par le nombre de clips reçus.
        mutating func dueWaiters() -> [CheckedContinuation<Void, Never>] {
            let due = waiters.filter { $0.value.need <= clips.count }
            for key in due.keys { waiters[key] = nil }
            return due.values.map(\.continuation)
        }
    }

    private let completion: Completion
    private let state = Mutex(State())

    public init(completion: Completion = .manual) {
        self.completion = completion
    }

    /// Les clips reçus par `play`, dans l'ordre.
    public var clips: [AudioClip] { state.withLock { $0.clips } }
    /// Nombre d'appels à `stop()`, plus le nombre de `play` annulés.
    public var stopCount: Int { state.withLock { $0.stops } }
    /// Nombre d'appels à `stopNow()`.
    public var stopNowCount: Int { state.withLock { $0.stopNows } }
    /// Une lecture `.manual` attend sa fin.
    public var isPlaying: Bool { state.withLock { $0.playing != nil } }
    /// Nombre d'attentes de `waitForPlays` inscrites et pas encore servies (pour les tests de ce module).
    var registeredWaiters: Int { state.withLock { $0.waiters.count } }

    public func play(_ clip: AudioClip) async throws {
        if clip.samples.isEmpty {
            let (ended, due) = state.withLock { s -> (CheckedContinuation<Void, Never>?, [CheckedContinuation<Void, Never>]) in
                s.clips.append(clip)
                defer { s.playing = nil }
                return (s.playing?.continuation, s.dueWaiters())
            }
            ended?.resume()
            for c in due { c.resume() }
            return
        }
        switch completion {
        case .immediate:
            record(clip)
        case .failing:
            record(clip)
            throw ClipPlayerError.failed
        case .manual:
            let token = state.withLock { s -> Int in
                s.nextToken += 1
                return s.nextToken
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let (ended, due) = state.withLock { s -> ([CheckedContinuation<Void, Never>], [CheckedContinuation<Void, Never>]) in
                        s.clips.append(clip)
                        let due = s.dueWaiters()
                        // Annulée avant d'être enregistrée : le gestionnaire est déjà passé, la lecture finit tout de suite.
                        if Task.isCancelled { return ([continuation], due) }
                        let previous = s.playing?.continuation
                        s.playing = (token, continuation)
                        return (previous.map { [$0] } ?? [], due)
                    }
                    for c in ended + due { c.resume() }
                }
            } onCancel: {
                stop(token: token)
            }
        }
    }

    public func stop() {
        stop(token: nil)
    }

    /// Arrête la lecture en cours avant de rendre la main ; compté à part de `stop()`.
    @MainActor public func stopNow() {
        state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.stopNows += 1
            defer { s.playing = nil }
            return s.playing?.continuation
        }?.resume()
    }

    /// Compte un arrêt ; avec un jeton, n'arrête la lecture que si c'est celle de cet appel.
    private func stop(token: Int?) {
        state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.stops += 1
            guard let playing = s.playing, token == nil || playing.token == token else { return nil }
            s.playing = nil
            return playing.continuation
        }?.resume()
    }

    /// Termine la lecture en cours, comme une fin de clip ; sans effet s'il n'y en a pas.
    public func finish() {
        state.withLock { s -> CheckedContinuation<Void, Never>? in
            defer { s.playing = nil }
            return s.playing?.continuation
        }?.resume()
    }

    /// Rend la main quand `play` a reçu au moins `count` clips, ou quand la tâche est annulée.
    public func waitForPlays(_ count: Int) async {
        let id = state.withLock { s -> Int in
            defer { s.nextWaiter += 1 }
            return s.nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { s -> Bool in
                    if s.clips.count >= count || Task.isCancelled { return true }
                    s.waiters[id] = (count, continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.continuation.resume()
        }
    }

    private func record(_ clip: AudioClip) {
        let due = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.clips.append(clip)
            return s.dueWaiters()
        }
        for c in due { c.resume() }
    }
}
