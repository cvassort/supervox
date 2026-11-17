import Foundation
import os

/// Là où le rappel du micro dépose ses tranches. Il ne fait qu'un verrou bref et un `yield` dans le flux d'entrées de l'entretien
/// (contrat de `onChunk` : jamais un appel à l'`AudioIO`). Une tranche arrivée avant `open` ou après `shutdown` est écartée.
final class ChunkIntake: Sendable {
    private struct State {
        var sink: AsyncStream<ConversationInput>.Continuation?
        var lastArrival = 0.0
        var chunks = 0
        var closed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Date de la dernière tranche arrivée du micro (le chien de garde la lit), sans la compter.
    func stamp(_ time: Double) { state.withLock { $0.lastArrival = time } }

    var lastArrival: Double { state.withLock { $0.lastArrival } }
    var hasSeenAChunk: Bool { state.withLock { $0.chunks > 0 } }

    func deliver(_ chunk: AudioChunk, at time: Double) {
        let sink = state.withLock { state -> AsyncStream<ConversationInput>.Continuation? in
            state.lastArrival = time
            state.chunks += 1
            return state.sink
        }
        sink?.yield(.chunk(chunk))
    }

    /// Les tranches vont désormais dans `sink`, jusqu'à `shutdown`.
    func open(_ sink: AsyncStream<ConversationInput>.Continuation) {
        state.withLock { state in
            guard !state.closed else { return }
            state.sink = sink
        }
    }

    /// Plus aucune tranche n'est livrée. Le flux d'entrées, partagé avec la réplique et la transcription, n'est pas terminé ici.
    func shutdown() {
        state.withLock { state in
            state.closed = true
            state.sink = nil
        }
    }
}
