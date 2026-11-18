import Foundation
import os

/// Registre des générations de lecture : tranche, parmi les rappels du lecteur, ceux qui sont des fins naturelles et ceux
/// qui suivent un arrêt demandé.
///
/// Mesuré (tâche 1) : après `AVAudioPlayerNode.stop()`, le gestionnaire d'achèvement est appelé, de façon synchrone sur le
/// fil appelant, avec le même type qu'à la fin naturelle. Son argument ne dit donc rien : c'est ce registre qui sait si un
/// arrêt a été demandé depuis que le clip a été mis en file.
struct PlaybackLedger {
    /// Numéro de la dernière génération donnée ; les numéros partent de 1.
    private var last = 0
    /// Dernière génération couverte par un `stopAll()` : tout rappel d'un numéro inférieur ou égal est un arrêt.
    private var stoppedThrough = 0

    /// Numéro d'un clip qui vient d'être mis en file.
    mutating func scheduled() -> Int {
        last += 1
        return last
    }

    /// Un arrêt a été demandé : les clips déjà en file ne se termineront plus que par `.stopped`.
    mutating func stopAll() {
        stoppedThrough = last
    }

    /// Un rappel d'une génération antérieure au dernier `stopAll()` vaut `.stopped`, sinon `.played`. Pur : « une seule
    /// fois par lecture » est l'affaire de `PlaybackTracker`, qui retire le clip en le réglant.
    func end(forGeneration generation: Int) -> PlaybackEnd {
        generation <= stoppedThrough ? .stopped : .played
    }
}

/// La file série où les `onEnd` sont livrés, avec le contrôle « pas depuis un `onEnd` ». Une file, et une clé de contrôle, **par
/// instance** : un `onEnd` d'une capture peut couper la lecture d'une autre.
final class EndDelivery: Sendable {
    private let queue: DispatchQueue
    private let key = DispatchSpecificKey<Void>()

    init(queue: DispatchQueue = DispatchQueue(label: "dev.supervox.playback-events")) {
        self.queue = queue
        queue.setSpecific(key: key, value: ())
    }

    /// Envoie `body` à la file, sans l'attendre : en ordre d'appel.
    func deliver(_ body: @escaping @Sendable () -> Void) {
        queue.async(execute: body)
    }

    /// Rend la main quand tout ce qui a été envoyé a été livré. Jamais depuis un `onEnd` (interblocage).
    func flush() { queue.sync {} }

    /// Précondition : l'appelant n'est pas dans un `onEnd` de cette file.
    func assertNotInside(calling call: String) {
        precondition(DispatchQueue.getSpecific(key: key) == nil,
                     "\(call) appelé depuis onEnd : erreur de programmation. Signaler un autre contexte qui appellera \(call).")
    }
}

/// Les clips en file d'une capture : un numéro de génération par clip, la fin rendue **une seule fois**, jamais sur le fil de
/// l'appelant, la position du clip en cours.
///
/// Verrous : `state` (verrou non récursif) protège le registre et la file ; il n'est **jamais tenu** pendant un appel au
/// lecteur (`stopPlayer`) ni pendant un `onEnd`. Le lecteur appelle ses gestionnaires de façon synchrone depuis son
/// `stop()` : un verrou tenu autour de cet appel que `settle` reprend tuerait le processus (réentrée d'un
/// `os_unfair_lock`).
///
/// **Invariant de l'appelant** : `register`, `registerSilent` et `stopAll` doivent être sérialisés par l'appelant (`lifecycle` dans
/// `AudioCapture`). Un clip mis en file *pendant* l'appel au lecteur de `stopAll`, puis coupé par ce même arrêt, serait sinon rendu
/// `.played` : le registre ne l'a pas encore compté dans l'arrêt (sondé par la revue). `settle`, lui, peut venir de n'importe quel fil.
///
/// `onEnd` est livré sur la file série `delivery`, par `async` (en ordre, envoyé sous le verrou `state` : l'ordre de livraison est
/// celui de l'ordre des réglages) : ni le fil du lecteur, ni le fil qui appelle `stopAll` (peut-être le fil principal) ne
/// l'exécutent, et un `onEnd` qui rappelle `play()` ne reprend aucun verrou tenu plus haut. Conséquence : `.stopped` peut arriver un
/// peu **après** le retour de `stopAll`, jamais avant l'appel du lecteur.
final class PlaybackTracker: Sendable {
    private struct Entry {
        /// Début du clip sur la ligne de temps du lecteur, en trames de sortie.
        var start: Int64
        var frames: Int64
        var sampleRate: Double
        /// Clip vide : rien à jouer. Il attend les clips devant lui et finit juste après le dernier.
        var silent = false
        var onEnd: @Sendable (PlaybackEnd) -> Void
    }

    private struct State {
        var ledger = PlaybackLedger()
        var pending: [Int: Entry] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let delivery: EndDelivery

    /// - Parameter events: la file série où `onEnd` est livré (une file à soi par capture ; les tests passent la leur pour la
    ///   vider avec `sync {}`).
    init(events: DispatchQueue = DispatchQueue(label: "dev.supervox.playback-events")) {
        delivery = EndDelivery(queue: events)
    }

    var hasPending: Bool { state.withLock { !$0.pending.isEmpty } }

    /// Pour les tests : rend la main quand tout ce qui a été envoyé à la file des événements a été livré. Jamais depuis un `onEnd`.
    func flushEvents() { delivery.flush() }

    /// Met un clip en file ; rend son numéro de génération.
    ///
    /// - Parameter nowSample: temps courant du lecteur (trames), `nil` si inconnu (le lecteur ne rend pas encore).
    ///   Le clip commence à la fin du précédent s'il est encore en file, sinon tout de suite.
    func register(frames: Int64, sampleRate: Double, nowSample: Int64?, onEnd: @escaping @Sendable (PlaybackEnd) -> Void) -> Int {
        state.withLock { state in
            let now = nowSample ?? 0
            let queuedEnd = state.pending.values.map { $0.start + $0.frames }.max()
            let start = queuedEnd.map { max($0, now) } ?? now
            let generation = state.ledger.scheduled()
            state.pending[generation] = Entry(start: start, frames: frames, sampleRate: sampleRate, onEnd: onEnd)
            return generation
        }
    }

    /// Met en file un clip qui n'a rien à jouer (vide, ou réduit à moins d'une trame par la conversion) : `.played`, sans toucher au
    /// lecteur. Sans clip devant lui, il finit tout de suite (livré par la file des événements, jamais en ligne) ; sinon il attend le
    /// dernier clip devant lui, pour que les fins restent dans l'ordre de la file, et partage son sort (`.stopped` si un arrêt passe).
    func registerSilent(onEnd: @escaping @Sendable (PlaybackEnd) -> Void) {
        state.withLock { state in
            let generation = state.ledger.scheduled()
            if state.pending.isEmpty {
                let end = state.ledger.end(forGeneration: generation)
                delivery.deliver { onEnd(end) }
                return
            }
            let queuedEnd = state.pending.values.map { $0.start + $0.frames }.max() ?? 0
            state.pending[generation] = Entry(start: queuedEnd, frames: 0, sampleRate: 1, silent: true, onEnd: onEnd)
        }
    }

    /// Le lecteur rappelle (fin naturelle, ou conséquence de son `stop()`) : la fin est rendue **une fois**. Un rappel pour un
    /// clip déjà réglé (second rappel, rappel tardif après un arrêt) est ignoré. À appeler depuis le gestionnaire du lecteur.
    /// Les clips vides qui n'attendaient que celui-ci finissent aussitôt après lui.
    func settle(_ generation: Int) {
        state.withLock { state in
            guard let entry = state.pending.removeValue(forKey: generation) else { return }
            let end = state.ledger.end(forGeneration: generation)
            delivery.deliver { entry.onEnd(end) }
            while let head = state.pending.min(by: { $0.key < $1.key }), head.value.silent {
                state.pending.removeValue(forKey: head.key)
                let silentEnd = state.ledger.end(forGeneration: head.key)
                delivery.deliver { head.value.onEnd(silentEnd) }
            }
        }
    }

    /// Coupe tout : marque l'arrêt, appelle `stopPlayer` (l'arrêt du lecteur, qui peut rappeler `settle` en synchrone depuis
    /// ici), puis rend `.stopped` aux clips que le lecteur n'a pas rappelés. Sans clip en file, `stopPlayer` n'est pas appelé,
    /// sauf `force` (le lecteur a joué et doit quitter son état « joue » avant l'arrêt du moteur) : un lecteur qui n'a rien joué n'est
    /// pas touché.
    func stopAll(force: Bool, stopPlayer: () -> Void) {
        let queued = state.withLock { state -> [Int] in
            guard !state.pending.isEmpty else { return [] }
            state.ledger.stopAll()
            return state.pending.keys.sorted()
        }
        guard !queued.isEmpty else {
            if force { stopPlayer() }
            return
        }
        stopPlayer()   // sans verrou : voir la note de la classe
        for generation in queued { settle(generation) }
    }

    /// `stopPlayback()` depuis `onEnd` : erreur de programmation, comme `stop()` depuis `onChunk`.
    func assertNotInEndHandler() {
        delivery.assertNotInside(calling: "stopPlayback()")
    }

    // MARK: - Position

    /// Secondes déjà jouées d'un clip, bornées à `0…durée`.
    static func position(sampleTime: Int64, start: Int64, frames: Int64, sampleRate: Double) -> Double {
        let played = Double(min(max(sampleTime - start, 0), frames))
        return played / sampleRate
    }

    /// Secondes déjà jouées du clip en tête de file (un clip vide n'est jamais « en cours ») ; `nil` sans lecture. `currentSample` donne
    /// le temps courant du lecteur (trames) ; il est appelé hors verrou. `nil` de sa part : le lecteur ne rend pas encore, le clip n'a
    /// rien joué.
    func position(currentSample: () -> Int64?) -> Double? {
        let head = state.withLock { state in state.pending.filter { !$0.value.silent }.min { $0.key < $1.key }?.value }
        guard let head else { return nil }
        guard let now = currentSample() else { return 0 }
        return Self.position(sampleTime: now, start: head.start, frames: head.frames, sampleRate: head.sampleRate)
    }
}
