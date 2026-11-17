import Foundation
import os

/// Là où le rappel du micro dépose ses tranches. Il ne fait qu'un verrou bref et un `yield` (contrat de `onChunk`). Une seule
/// écoute est ouverte à la fois : une tranche qui arrive hors écoute est écartée, et à l'ouverture d'une écoute celle d'avant
/// est close, avec ce qui n'y a pas été lu.
final class ChunkIntake: Sendable {
    private struct State {
        var sink: AsyncStream<AudioChunk>.Continuation?
        var lastArrival = 0.0
        var chunks = 0
        var closed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Date de la dernière tranche arrivée du micro, écoute ou non (le chien de garde la lit), sans la compter.
    func stamp(_ time: Double) { state.withLock { $0.lastArrival = time } }

    var lastArrival: Double { state.withLock { $0.lastArrival } }
    var hasSeenAChunk: Bool { state.withLock { $0.chunks > 0 } }

    func deliver(_ chunk: AudioChunk, at time: Double) {
        let sink = state.withLock { state -> AsyncStream<AudioChunk>.Continuation? in
            state.lastArrival = time
            state.chunks += 1
            return state.sink
        }
        sink?.yield(chunk)
    }

    func open(_ sink: AsyncStream<AudioChunk>.Continuation) {
        let previous = state.withLock { state -> AsyncStream<AudioChunk>.Continuation? in
            guard !state.closed else { return sink }
            defer { state.sink = sink }
            return state.sink
        }
        previous?.finish()
    }

    func closeEpoch() {
        state.withLock { state -> AsyncStream<AudioChunk>.Continuation? in
            defer { state.sink = nil }
            return state.sink
        }?.finish()
    }

    /// Plus aucune écoute ne s'ouvrira.
    func shutdown() {
        state.withLock { state -> AsyncStream<AudioChunk>.Continuation? in
            state.closed = true
            defer { state.sink = nil }
            return state.sink
        }?.finish()
    }
}
