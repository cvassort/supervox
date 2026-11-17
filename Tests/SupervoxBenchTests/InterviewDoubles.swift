import Foundation
import Synchronization
import SupervoxCore

// Doubles de la commande `interview` du banc. Aucun ne dort, n'ouvre le micro, ne joue un son, ne touche au réseau ni ne charge un
// modèle : le temps vient d'une horloge que le test fait avancer, et chaque attente est une porte que le test ouvre (ou qui rend la
// main à l'annulation de la tâche : la limite de temps d'une suite échoue un test suspendu, elle ne le laisse pas en vie).

/// Rend la main quand `condition` est vraie, en cédant le fil entre deux lectures (aucune durée : un compte de passages, borné).
/// `false` si la borne est atteinte ou si la tâche est annulée : l'appelant l'exige par `#require`.
func settle(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<2_000_000 {
        if condition() { return true }
        if Task.isCancelled { return false }
        await Task.yield()
    }
    return condition()
}

/// Cède le fil un grand nombre de fois, pour qu'une tâche lancée plus tôt ait eu l'occasion de s'enregistrer : sert à vérifier
/// qu'une attente n'a **pas** été armée. Une vérification qui passe à tort si cette tâche tardait davantage, jamais l'inverse.
func quiesce() async {
    for _ in 0..<5_000 { await Task.yield() }
}

/// L'horloge du test : ne bouge que quand le test (ou un double) la fait avancer.
final class InterviewClock: Sendable {
    private let value = Mutex(0.0)
    func now() -> Double { value.withLock { $0 } }
    func advance(_ seconds: Double) { value.withLock { $0 += seconds } }
}

/// Les attentes de la commande (durée simulée d'un clip, délai avant d'interrompre, délai d'un tour sans réaction) : chacune est
/// enregistrée avec sa durée et attend que le test la libère, ou que sa tâche soit annulée. En mode `automatic`, elle rend la main
/// tout de suite (après avoir fait avancer l'horloge de sa durée, si une horloge est donnée).
final class WaitBoard: Sendable {
    private struct Pending {
        let id: Int
        let seconds: Double
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var requests: [Double] = []
        var pending: [Pending] = []
        var nextID = 0
    }

    private let state = Mutex(State())
    private let automatic: Bool
    private let clock: InterviewClock?

    init(automatic: Bool = false, clock: InterviewClock? = nil) {
        self.automatic = automatic
        self.clock = clock
    }

    /// Les durées demandées, dans l'ordre.
    var requests: [Double] { state.withLock { $0.requests } }
    /// Les durées des attentes encore suspendues.
    var pendingSeconds: [Double] { state.withLock { $0.pending.map(\.seconds) } }

    func wait(_ seconds: Double) async {
        let id = state.withLock { state -> Int in
            state.requests.append(seconds)
            defer { state.nextID += 1 }
            return state.nextID
        }
        if automatic {
            clock?.advance(seconds)
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    state.pending.append(Pending(id: id, seconds: seconds, continuation: continuation))
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { state in state.pending.firstIndex { $0.id == id }.map { state.pending.remove(at: $0) } }?
                .continuation.resume()
        }
    }

    /// Libère l'attente suspendue la plus ancienne de cette durée ; `false` s'il n'y en a pas.
    @discardableResult
    func release(seconds: Double) -> Bool {
        let found = state.withLock { state in
            state.pending.firstIndex { $0.seconds == seconds }.map { state.pending.remove(at: $0) }
        }
        found?.continuation.resume()
        return found != nil
    }

    func releaseAll() {
        let all = state.withLock { state in
            defer { state.pending = [] }
            return state.pending
        }
        for entry in all { entry.continuation.resume() }
    }
}

/// Un compteur de blocs de micro reçus, avec leurs échantillons.
final class ChunkRecorder: Sendable {
    private let items = Mutex<[AudioChunk]>([])
    func record(_ chunk: AudioChunk) { items.withLock { $0.append(chunk) } }
    var chunks: [AudioChunk] { items.withLock { $0 } }
    var count: Int { items.withLock { $0.count } }
}

/// Un compteur partagé.
final class Tally: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

/// Des lignes de texte reçues, dans l'ordre.
final class LineLog: Sendable {
    private let items = Mutex<[String]>([])
    func add(_ line: String) { items.withLock { $0.append(line) } }
    var all: [String] { items.withLock { $0 } }
}

/// Un clip d'amplitude constante.
func tone(seconds: Double, amplitude: Float = 0.3, rate: Double = 16_000) -> AudioClip {
    AudioClip(samples: [Float](repeating: amplitude, count: Int((seconds * rate).rounded())), sampleRate: rate)
}
