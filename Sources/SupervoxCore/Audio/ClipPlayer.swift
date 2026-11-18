import AVFAudio
import Foundation
import Synchronization

/// Joue un clip par la sortie seule (sans ouvrir le micro), pour l'écoute d'une voix.
///
/// Contrat, commun au vrai lecteur et au double :
/// - `play` rend la main quand le clip est fini, ou arrêté : par `stop()`, par l'annulation de la tâche appelante (qui appelle `stop()`)
///   ou par un `play` suivant, qui arrête la lecture en cours. Une lecture arrêtée rend la main **normalement**, sans lever ;
/// - `play` lève `ClipPlayerError.failed` quand la lecture ne peut pas se faire ;
/// - `stop()` ne vaut que pour la lecture en cours : sans lecture en cours il ne fait rien, et ne retient pas la suivante.
public protocol ClipPlayer: Sendable {
    func play(_ clip: AudioClip) async throws
    func stop()
}

public enum ClipPlayerError: Error, Equatable, Sendable {
    case failed
}

/// Le vrai lecteur : le clip est encodé en WAV en mémoire (`WavFile.data(from:)`) et joué par le lecteur de fichiers audio du système,
/// qui n'utilise que la sortie. Le lecteur et son délégué vivent sur le fil principal (le protocole du délégué y est confiné par le
/// SDK). Aucun test de la suite par défaut ne l'exécute : seul l'essai matériel `SUPERVOX_PLAYER=1` le fait.
public final class SystemClipPlayer: ClipPlayer {
    /// La lecture en cours ; `nil` sans lecture.
    private let current = Mutex<Playback?>(nil)

    public init() {}

    public func play(_ clip: AudioClip) async throws {
        guard !clip.samples.isEmpty else { return }   // rien à jouer
        let data = WavFile.data(from: clip)
        try await withTaskCancellationHandler {
            try await run(data)
        } onCancel: {
            stop()
        }
    }

    /// Demande l'arrêt au fil principal ; `play` rend la main dès que l'arrêt y est passé.
    public func stop() {
        guard let playback = current.withLock({ $0 }) else { return }
        Task { @MainActor in playback.stop() }
    }

    @MainActor private func run(_ data: Data) async throws {
        let playback = Playback()
        let previous = current.withLock { slot in
            defer { slot = playback }
            return slot
        }
        previous?.stop()
        defer { current.withLock { if $0 === playback { $0 = nil } } }
        // Annulée avant d'être enregistrée, la tâche n'a pas pu arrêter cette lecture : on n'en commence pas une.
        if Task.isCancelled { return }
        try await playback.play(data)
    }
}

/// Une lecture : le lecteur du système, son délégué, et l'attente de sa fin. Toutes les fins passent par `end`, qui ne rend la main
/// à `play` qu'une fois.
@MainActor private final class Playback: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var stopped = false

    func play(_ data: Data) async throws {
        guard !stopped else { return }
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: data)
        } catch {
            throw ClipPlayerError.failed
        }
        player.delegate = self   // référence faible : `self` est retenu par `run` jusqu'à la fin
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.player = player
            if !player.play() { end(.failure(ClipPlayerError.failed)) }
        }
    }

    func stop() {
        stopped = true
        player?.stop()
        end(.success(()))
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        end(flag ? .success(()) : .failure(ClipPlayerError.failed))
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        player.stop()
        end(.failure(ClipPlayerError.failed))
    }

    private func end(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        player = nil
        continuation.resume(with: result)
    }
}

/// Un lecteur double, pour les tests (de ce module et de l'application) : il garde les clips reçus et ne joue rien.
///
/// - `.manual` : `play` attend `finish()`, `stop()`, l'annulation de sa tâche (qui appelle `stop()`) ou un `play` suivant ;
/// - `.immediate` : `play` rend la main tout de suite ;
/// - `.failing` : `play` lève `ClipPlayerError.failed` tout de suite.
///
/// Un test attend les lectures par `waitForPlays(_:)` (jamais par un sommeil), qui rend la main à l'annulation. Le clip reçu, la
/// lecture en cours et le réveil de `waitForPlays` sont posés sous un même verrou : un test qui a vu la lecture arriver peut l'arrêter.
public final class ScriptedClipPlayer: ClipPlayer {
    public enum Completion: Sendable {
        case manual, immediate, failing
    }

    private struct State {
        var clips: [AudioClip] = []
        var stops = 0
        var playing: CheckedContinuation<Void, Never>?
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
    /// Nombre d'appels à `stop()`, directs ou par l'annulation.
    public var stopCount: Int { state.withLock { $0.stops } }
    /// Une lecture `.manual` attend sa fin.
    public var isPlaying: Bool { state.withLock { $0.playing != nil } }

    public func play(_ clip: AudioClip) async throws {
        switch completion {
        case .immediate:
            record(clip)
        case .failing:
            record(clip)
            throw ClipPlayerError.failed
        case .manual:
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let (ended, due) = state.withLock { s -> ([CheckedContinuation<Void, Never>], [CheckedContinuation<Void, Never>]) in
                        s.clips.append(clip)
                        let due = s.dueWaiters()
                        // Annulée avant d'être enregistrée : `stop()` est déjà passé, la lecture finit tout de suite.
                        if Task.isCancelled { return ([continuation], due) }
                        let previous = s.playing
                        s.playing = continuation
                        return (previous.map { [$0] } ?? [], due)
                    }
                    for c in ended + due { c.resume() }
                }
            } onCancel: {
                stop()
            }
        }
    }

    public func stop() {
        state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.stops += 1
            defer { s.playing = nil }
            return s.playing
        }?.resume()
    }

    /// Termine la lecture en cours, comme une fin de clip ; sans effet s'il n'y en a pas.
    public func finish() {
        state.withLock { s -> CheckedContinuation<Void, Never>? in
            defer { s.playing = nil }
            return s.playing
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
