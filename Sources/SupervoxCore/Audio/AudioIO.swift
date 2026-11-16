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
/// - appelé **une seule fois** par clip, **hors du fil principal**, **après** le retour de l'appel qui le provoque (`play()` compris,
///   jamais à l'intérieur) : `.played` quand le dernier échantillon est sorti du périphérique, `.stopped` si `stopPlayback()` ou
///   `stop()` l'a coupé avant. Les fins arrivent dans l'ordre de la file ;
/// - un clip **vide**, ou réduit à moins d'une trame par la conversion, n'a rien à jouer : `.played` après les clips devant lui (ou tout
///   de suite s'il n'y en a pas), sans que `play()` lève ;
/// - `stopPlayback()` et `stop()` **n'attendent pas** les `onEnd` : `.stopped` peut arriver juste après leur retour ;
/// - `onEnd` ne doit **jamais** appeler `stopPlayback()` (précondition, comme `stop()` depuis `onChunk`) ; il peut appeler `play()` ;
/// - `onChunk` ne rappelle **jamais** l'`AudioIO` : ni `play()`, ni `stopPlayback()`, ni `stop()` (précondition, dans le vrai comme dans le
///   double). Ces appels prennent un verrou interne que `stop()` tient en attendant la fin de `onChunk` : un `stop()` d'un autre fil et un
///   `onChunk` qui coupe la lecture resteraient bloqués ensemble. Pour réagir à une tranche, la transmettre sans attente à un autre
///   contexte (file, acteur) qui appellera `stopPlayback()`.
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
/// Comme le vrai son, les `onEnd` sont livrés **en différé**, sur une file série dédiée : jamais à l'intérieur de `play()`,
/// `stopPlayback()`, `stop()` ni `finishPlayback()`, toujours dans l'ordre. Un test attend la livraison avec `flushEnds()` (jamais
/// par un sommeil). Un clip vide rend `.played` sans rien jouer, comme le vrai. Seule la tranche du micro est livrée en ligne : `push`
/// livre `onChunk` sur le fil de l'appelant (comme `ScriptedMicrophoneFeed`), sous la porte de livraison.
///
/// `Sendable` simple, sans `@unchecked` : tout l'état variable est dans `state`, derrière un verrou ; aucun `onEnd` n'est appelé sous ce verrou.
public final class ScriptedAudioIO: AudioIO {
    public enum Completion: Sendable {
        /// Rien ne se termine avant `finishPlayback`.
        case manual
        /// `play` rend `.played` tout de suite (en différé, après son retour), dans l'ordre des appels : le clip n'est jamais en file.
        case immediate
        /// Chaque clip attend la fin du précédent, puis l'attente reçoit sa durée (secondes) ; `.played` à son retour.
        case afterDuration(@Sendable (Double) async -> Void)
    }

    private struct Queued {
        let id: Int
        let clip: AudioClip
        /// Clip vide : jamais en tête de file, il finit juste après le clip devant lui et partage son sort.
        let silent: Bool
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
    private let delivery: EndDelivery

    public convenience init(startError: AudioCaptureError? = nil, completion: Completion = .manual) {
        self.init(startError: startError, completion: completion, events: DispatchQueue(label: "dev.supervox.scripted-events"))
    }

    /// Pour les tests : la file des événements est celle du test, qu'il peut suspendre pour voir ce qui n'est pas livré en ligne.
    init(startError: AudioCaptureError? = nil, completion: Completion = .manual, events: DispatchQueue) {
        self.startError = startError
        self.completion = completion
        delivery = EndDelivery(queue: events)
    }

    /// Rend la main quand tous les `onEnd` dus à cet instant ont été livrés. Jamais depuis un `onEnd`.
    public func flushEnds() { delivery.flush() }

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
        state.withLock { state in
            state.log.append("stop")
            state.running = false
            state.gate = nil
            state.onChunk = nil
            state.tail = nil
            emitAll(&state, .stopped)
        }
    }

    // MARK: Lecture

    public func play(_ clip: AudioClip, onEnd: @escaping @Sendable (PlaybackEnd) -> Void) throws {
        state.withLock { $0.gate }?.assertNotDelivering(calling: "play()")
        try state.withLock { state in
            guard state.running else { throw AudioCaptureError.notRunning }
            state.log.append("play")
            state.played.append(clip)
            let id = state.nextID
            state.nextID += 1
            if clip.samples.isEmpty {
                // Rien à jouer, dans tous les modes : `.played` après les clips devant lui, sans attente ni durée.
                if state.queue.isEmpty {
                    delivery.deliver { onEnd(.played) }
                } else {
                    state.queue.append(Queued(id: id, clip: clip, silent: true, onEnd: onEnd))
                }
                return
            }
            switch completion {
            case .immediate:
                delivery.deliver { onEnd(.played) }
            case .manual:
                state.queue.append(Queued(id: id, clip: clip, silent: false, onEnd: onEnd))
            case .afterDuration(let wait):
                state.queue.append(Queued(id: id, clip: clip, silent: false, onEnd: onEnd))
                let previous = state.tail
                let duration = clip.duration
                state.tail = Task { [self] in
                    await previous?.value
                    await wait(duration)
                    finish(id: id, .played)
                }
            }
        }
    }

    /// Mode `.manual` (et tout mode) : termine le clip en tête de file par `end` (les clips vides qui le suivent finissent avec lui).
    /// `false` s'il n'y en a aucun.
    @discardableResult
    public func finishPlayback(_ end: PlaybackEnd) -> Bool {
        state.withLock { state in
            guard !state.queue.isEmpty else { return false }
            emitHead(&state, end)
            return true
        }
    }

    public func stopPlayback() {
        state.withLock { $0.gate }?.assertNotDelivering(calling: "stopPlayback()")
        delivery.assertNotInside(calling: "stopPlayback()")
        state.withLock { state in
            state.log.append("stopPlayback")
            state.stopPlaybackCount += 1
            state.tail = nil
            emitAll(&state, .stopped)
        }
    }

    public var playbackPosition: Double? {
        state.withLock { state in state.queue.contains { !$0.silent } ? state.scriptedPosition : nil }
    }

    /// Fin d'une attente : sans effet si le clip a déjà été rendu (arrêt, `finishPlayback`).
    private func finish(id: Int, _ end: PlaybackEnd) {
        state.withLock { state in
            guard let index = state.queue.firstIndex(where: { $0.id == id }) else { return }
            let entry = state.queue.remove(at: index)
            delivery.deliver { entry.onEnd(end) }
            flushSilentHead(&state, end)
        }
    }

    // Les trois aides ci-dessous s'appellent sous le verrou `state` ; elles ne font qu'envoyer à la file des événements.

    private func emitHead(_ state: inout State, _ end: PlaybackEnd) {
        let head = state.queue.removeFirst()
        delivery.deliver { head.onEnd(end) }
        flushSilentHead(&state, end)
    }

    /// Les clips vides qui n'attendaient que le clip qui vient de finir finissent avec lui.
    private func flushSilentHead(_ state: inout State, _ end: PlaybackEnd) {
        while let head = state.queue.first, head.silent {
            state.queue.removeFirst()
            delivery.deliver { head.onEnd(end) }
        }
    }

    private func emitAll(_ state: inout State, _ end: PlaybackEnd) {
        let queued = state.queue
        state.queue = []
        for entry in queued { delivery.deliver { entry.onEnd(end) } }
    }
}
