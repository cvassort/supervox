import Foundation
import os

/// Les clips acceptés par l'`AudioIO` et leur fin, lus par le rangement d'une réplique : il attend que tous aient fini après
/// avoir coupé la lecture. Les fins arrivent par `onEnd`, hors de l'acteur.
final class ReplyPlayback: Sendable {
    private struct State {
        var outstanding = 0
        var ends: [Int: PlaybackEnd] = [:]
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Un clip va être donné à `play` (rendu par `release` si `play` refuse).
    func reserve() { state.withLock { $0.outstanding += 1 } }

    func release() { settle(nil) }

    func ended(_ index: Int, _ end: PlaybackEnd) { settle((index, end)) }

    var outstanding: Int { state.withLock { $0.outstanding } }
    var ends: [Int: PlaybackEnd] { state.withLock { $0.ends } }

    func waitUntilIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { state -> Bool in
                if state.outstanding == 0 { return true }
                state.waiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    private func settle(_ finished: (index: Int, end: PlaybackEnd)?) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            if let finished { state.ends[finished.index] = finished.end }
            state.outstanding = max(state.outstanding - 1, 0)
            guard state.outstanding == 0 else { return [] }
            defer { state.waiters = [] }
            return state.waiters
        }
        for continuation in ready { continuation.resume() }
    }
}
