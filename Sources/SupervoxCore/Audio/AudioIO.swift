import Foundation
import os

/// Comment une lecture s'est terminée.
public enum PlaybackEnd: Equatable, Sendable {
    /// Le dernier échantillon est sorti du périphérique (`.dataPlayedBack`).
    case played
    /// `stopPlayback()` ou `stop()` l'a coupée avant.
    case stopped
}

/// Le son d'un entretien : la capture du micro et la lecture de la voix de l'outil, **dans le même moteur** (l'annulation
/// d'écho du système ne connaît que la voix qui passe par lui).
///
/// Contrat de `onEnd` (en plus de celui de `onChunk`, voir `MicrophoneFeed`) :
/// - appelé **une seule fois** par clip, **hors du fil principal** : `.played` quand le dernier échantillon est sorti du
///   périphérique, `.stopped` si `stopPlayback()` ou `stop()` l'a coupé avant ;
/// - `stopPlayback()` et `stop()` **n'attendent pas** les `onEnd` : `.stopped` peut arriver juste après leur retour ;
/// - `onEnd` ne doit **jamais** appeler `stopPlayback()` (précondition, comme `stop()` depuis `onChunk`) ; il peut appeler `play()`.
public protocol AudioIO: MicrophoneFeed {
    /// Met le clip en file, après ceux déjà en file : ils se jouent l'un après l'autre. Rend la main sans attendre la fin.
    /// - Throws: `AudioCaptureError.notRunning` hors capture (avant `start`, ou après `stop`). Rien n'est joué, `onEnd` n'est pas appelé.
    func play(_ clip: AudioClip, onEnd: @escaping @Sendable (PlaybackEnd) -> Void) throws
    /// Coupe tout de suite la lecture et vide la file : chaque clip en file reçoit `.stopped`. La capture continue.
    func stopPlayback()
    /// Secondes déjà jouées du clip en cours ; `nil` sans lecture.
    var playbackPosition: Double? { get }
}

/// Le vrai son : **une seule** `AudioCapture` (traitement de la voix, sans invite d'autorisation) pour la capture et la lecture. Le
/// tampon interne de la capture n'accumule rien (`accumulate: false`) : un entretien long ne fait pas grossir la mémoire.
///
/// `Sendable` simple, sans `@unchecked` : le seul état est `device`, constant, et l'appareil est lui-même `Sendable`.
public final class LiveAudioIO: AudioIO {
    let device: any PlaybackCapture

    public convenience init() {
        self.init(device: AudioCapture(voiceProcessing: true, promptsForAccess: false))
    }

    /// Pour les tests : une capture double à la place du matériel.
    init(device: any PlaybackCapture) {
        self.device = device
    }

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws {
        try device.startStreaming(onChunk: onChunk, accumulate: false)
    }

    public func stop() {
        _ = device.stop()
    }

    public func play(_ clip: AudioClip, onEnd: @escaping @Sendable (PlaybackEnd) -> Void) throws {
        try device.play(clip, onEnd: onEnd)
    }

    public func stopPlayback() {
        device.stopPlayback()
    }

    public var playbackPosition: Double? { device.playbackPosition }
}

/// Un son scripté, pour les tests, l'outil d'images et le banc : le micro est alimenté par `push`, la lecture se termine comme le
/// dit `completion`. Aucun son n'est joué.
///
/// Différence avec le vrai son : les `onEnd` sont rendus **sur le fil de l'appelant** (`stopPlayback()`, `stop()`,
/// `finishPlayback`, et `play()` en mode `.immediate`), comme `ScriptedMicrophoneFeed` livre sur le fil qui l'appelle, pour que les
/// tests soient déterministes ; en mode `.afterDuration`, sur une tâche. Aucun `onEnd` n'est jamais rendu sous le verrou du double.
///
/// `Sendable` simple, sans `@unchecked` : tout l'état variable est dans `state`, derrière un verrou.
public final class ScriptedAudioIO: AudioIO {
    public enum Completion: Sendable {
        /// Rien ne se termine avant `finishPlayback`.
        case manual
        /// `play` rend `.played` tout de suite, dans l'ordre des appels (le clip n'est jamais en file).
        case immediate
        /// Chaque clip attend la fin du précédent, puis l'attente reçoit sa durée (secondes) ; `.played` à son retour.
        case afterDuration(@Sendable (Double) async -> Void)
    }

    private struct Queued {
        let id: Int
        let clip: AudioClip
        let onEnd: @Sendable (PlaybackEnd) -> Void
    }

    private struct State {
        var running = false
        var gate: DeliveryGate?
        var onChunk: (@Sendable (AudioChunk) -> Void)?
        var queue: [Queued] = []
        var nextID = 1
        /// La dernière attente lancée en mode `.afterDuration` : la suivante la précède.
        var tail: Task<Void, Never>?
        var log: [String] = []
        var played: [AudioClip] = []
        var stopPlaybackCount = 0
        var scriptedPosition = 0.0
    }

    private let startError: AudioCaptureError?
    private let completion: Completion
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(startError: AudioCaptureError? = nil, completion: Completion = .manual) {
        self.startError = startError
        self.completion = completion
    }

    // MARK: Observation

    /// Les clips acceptés par `play`, dans l'ordre.
    public var played: [AudioClip] { state.withLock { $0.played } }
    public var isRunning: Bool { state.withLock { $0.running } }
    public var stopPlaybackCount: Int { state.withLock { $0.stopPlaybackCount } }
    /// Les appels **acceptés**, dans l'ordre : « start », « play », « stopPlayback », « stop ». Un `start` ou un `play` refusé
    /// (erreur levée) n'y figure pas ; `stopPlayback` et `stop` n'échouent jamais et y figurent toujours.
    public var log: [String] { state.withLock { $0.log } }

    /// La position rendue par `playbackPosition` tant qu'un clip est en file (0 au départ).
    public var scriptedPosition: Double {
        get { state.withLock { $0.scriptedPosition } }
        set { state.withLock { $0.scriptedPosition = newValue } }
    }

    // MARK: Capture

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws {
        if let startError { throw startError }
        try state.withLock { state in
            guard !state.running else { throw AudioCaptureError.alreadyRunning }
            state.running = true
            state.gate = DeliveryGate()
            state.onChunk = onChunk
            state.log.append("start")
        }
    }

    /// Livre une tranche à l'`onChunk` de `start`, **sur le fil de l'appelant**, sous la porte de livraison. Rien avant `start` ni après `stop()`.
    public func push(_ chunk: AudioChunk) {
        let target = state.withLock { state in state.gate.flatMap { gate in state.onChunk.map { (gate, $0) } } }
        guard let (gate, onChunk) = target else { return }
        gate.deliver { onChunk(chunk) }
    }

    public func stop() {
        // Hors du verrou du double : `close()` attend une livraison en cours, dont `onChunk` peut prendre ce verrou.
        let gate = state.withLock { $0.gate }
        gate?.close()
        let queued = state.withLock { state -> [Queued] in
            state.log.append("stop")
            state.running = false
            state.gate = nil
            state.onChunk = nil
            state.tail = nil
            defer { state.queue = [] }
            return state.queue
        }
        for entry in queued { entry.onEnd(.stopped) }
    }

    // MARK: Lecture

    public func play(_ clip: AudioClip, onEnd: @escaping @Sendable (PlaybackEnd) -> Void) throws {
        let immediate = try state.withLock { state -> Bool in
            guard state.running else { throw AudioCaptureError.notRunning }
            state.log.append("play")
            state.played.append(clip)
            let id = state.nextID
            state.nextID += 1
            switch completion {
            case .immediate:
                return true
            case .manual:
                state.queue.append(Queued(id: id, clip: clip, onEnd: onEnd))
            case .afterDuration(let wait):
                state.queue.append(Queued(id: id, clip: clip, onEnd: onEnd))
                let previous = state.tail
                let duration = clip.duration
                state.tail = Task { [self] in
                    await previous?.value
                    await wait(duration)
                    finish(id: id, .played)
                }
            }
            return false
        }
        if immediate { onEnd(.played) }
    }

    /// Mode `.manual` (et tout mode) : termine le clip en tête de file par `end`. `false` s'il n'y en a aucun.
    @discardableResult
    public func finishPlayback(_ end: PlaybackEnd) -> Bool {
        let head = state.withLock { state in state.queue.isEmpty ? nil : state.queue.removeFirst() }
        guard let head else { return false }
        head.onEnd(end)
        return true
    }

    public func stopPlayback() {
        let queued = state.withLock { state -> [Queued] in
            state.log.append("stopPlayback")
            state.stopPlaybackCount += 1
            state.tail = nil
            defer { state.queue = [] }
            return state.queue
        }
        for entry in queued { entry.onEnd(.stopped) }
    }

    public var playbackPosition: Double? {
        state.withLock { $0.queue.isEmpty ? nil : $0.scriptedPosition }
    }

    /// Fin d'une attente : sans effet si le clip a déjà été rendu (arrêt, `finishPlayback`).
    private func finish(id: Int, _ end: PlaybackEnd) {
        let entry = state.withLock { state -> Queued? in
            guard let index = state.queue.firstIndex(where: { $0.id == id }) else { return nil }
            return state.queue.remove(at: index)
        }
        entry?.onEnd(end)
    }
}
