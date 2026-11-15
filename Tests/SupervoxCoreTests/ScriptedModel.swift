import Foundation
import os
@testable import SupervoxCore

// Doubles de la réécriture : un modèle de langage qui rejoue une liste d'événements puis, sur ordre du test, une fin
// ou une erreur. Aucun ne dort : le test décide de chaque étape.

/// Rend la main quand `condition` est vraie (au plus quelques milliers de passages, sans horloge de test) : pour une
/// condition qui ne dépend que d'un effet de bord sans porte à attendre (une attente annulée qui se compte).
func eventually(_ condition: () -> Bool) async -> Bool {
    for round in 0..<20000 {
        if condition() { return true }
        if round % 50 == 49 { try? await Task.sleep(for: .milliseconds(1)) } else { await Task.yield() }
    }
    return condition()
}

/// Attente qui ignore l'annulation de la tâche (un moteur sourd, comme peut l'être un vrai moteur) : `wait()` ne rend la
/// main qu'à `open()`.
final class DeafLatch: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (isOpen: false, waiters: [CheckedContinuation<Void, Never>]()))

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = state.withLock { s -> Bool in
                if s.isOpen { return true }
                s.waiters.append(continuation)
                return false
            }
            if passes { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isOpen = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

final class ScriptedModel: LanguageModel, @unchecked Sendable {
    enum Step: Sendable {
        case event(CompletionEvent)
        /// Fin normale du flux.
        case finish
        case fail(any Error)

        static func text(_ text: String) -> Step { .event(.text(text)) }
        static func reasoning(_ text: String) -> Step { .event(.reasoning(text)) }
        static func stop(_ stop: CompletionStop) -> Step { .event(.stop(stop)) }
    }

    private struct State {
        var requests: [CompletionRequest] = []
        var continuation: AsyncThrowingStream<CompletionEvent, Error>.Continuation?
        var cancelled = false
    }

    private let script: [Step]
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Ouverte quand `complete` a été appelé.
    let started = Gate()
    /// Ouverte quand le flux est terminé, par une fin, une erreur ou l'arrêt de la lecture.
    let terminated = Gate()

    /// `script` est rejoué dès l'appel de `complete` ; sans `.finish` ni `.fail`, le flux reste ouvert et le test le
    /// poursuit avec `send`, `finish` et `fail`.
    init(_ script: [Step] = []) { self.script = script }

    var requests: [CompletionRequest] { state.withLock { $0.requests } }
    /// Le flux a été terminé par la lecture (boucle quittée, tâche annulée), non par le modèle.
    var wasCancelled: Bool { state.withLock { $0.cancelled } }

    func complete(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<CompletionEvent, Error>.makeStream()
        continuation.onTermination = { [self] termination in
            state.withLock { s in
                if case .cancelled = termination { s.cancelled = true }
                s.continuation = nil
            }
            terminated.open()
        }
        state.withLock { s in
            s.requests.append(request)
            s.continuation = continuation
        }
        for step in script { apply(step) }
        started.open()
        return stream
    }

    private func apply(_ step: Step) {
        let continuation = state.withLock { $0.continuation }
        switch step {
        case .event(let event): continuation?.yield(event)
        case .finish: continuation?.finish()
        case .fail(let error): continuation?.finish(throwing: error)
        }
    }

    func send(_ step: Step) { apply(step) }
}
