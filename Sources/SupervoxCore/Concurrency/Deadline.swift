import Foundation
import Synchronization

/// Le délai de `Deadline.run` s'est écoulé avant la fin de l'opération.
public struct DeadlineExceeded: Error, Equatable {
    public init() {}
}

/// Une opération asynchrone bornée dans le temps.
///
/// `run` lance l'opération et une minuterie (`sleep`), et rend la main dès que la première finit : le résultat (ou l'erreur)
/// de l'opération, `DeadlineExceeded` si `sleep` rend d'abord, `CancellationError` si l'appelant est annulé. Dans les deux
/// derniers cas l'opération est annulée ; dans tous, la minuterie l'est.
///
/// Les deux travaux sont des tâches non structurées, et `run` n'attend jamais celle qu'il abandonne : une opération qui
/// n'écoute pas l'annulation (un moteur de transcription peut être sourd) ne retient pas l'appelant. Son résultat tardif est
/// ignoré. Un groupe de tâches ne convient pas ici, il attendrait ses enfants avant de rendre la main.
///
/// Seule une attente qui **rend** est un délai écoulé : une attente qui lève (annulée) n'en est pas un, l'opération continue
/// alors sans limite de temps.
public enum Deadline {
    public static func run<T: Sendable>(
        seconds: Double,
        sleep: @escaping @Sendable (Double) async throws -> Void,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let race = Race<T>()
        let work = Task {
            do { race.settle(.success(try await operation())) } catch { race.settle(.failure(error)) }
        }
        let timer = Task {
            do { try await sleep(seconds) } catch { return }
            race.settle(.failure(DeadlineExceeded()))
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        return try await withTaskCancellationHandler {
            try await race.outcome()
        } onCancel: {
            // D'abord le verdict, ensuite l'annulation : une opération qui se termine « normalement » parce qu'on l'annule
            // ne doit pas passer pour un succès.
            race.settle(.failure(CancellationError()))
            work.cancel()
            timer.cancel()
        }
    }
}

/// Le premier résultat gagne ; les suivants sont ignorés. Un seul lecteur attend le verdict.
private final class Race<T: Sendable>: Sendable {
    private enum State {
        case open
        case waiting(CheckedContinuation<T, any Error>)
        case settled(Result<T, any Error>)
        case delivered
    }
    private let state = Mutex<State>(.open)

    func settle(_ result: Result<T, any Error>) {
        let waiting = state.withLock { state -> CheckedContinuation<T, any Error>? in
            switch state {
            case .open:
                state = .settled(result)
                return nil
            case .waiting(let continuation):
                state = .delivered
                return continuation
            case .settled, .delivered:
                return nil
            }
        }
        waiting?.resume(with: result)
    }

    func outcome() async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            let ready = state.withLock { state -> Result<T, any Error>? in
                switch state {
                case .open:
                    state = .waiting(continuation)
                    return nil
                case .settled(let result):
                    state = .delivered
                    return result
                case .waiting, .delivered:
                    preconditionFailure("un seul lecteur attend le verdict")
                }
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
