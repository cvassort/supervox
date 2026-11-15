import Foundation
import Synchronization

/// Un seul travail à la fois : un appel qui arrive pendant qu'un travail est en cours attend le même travail et en partage
/// le résultat, au lieu d'en lancer un second.
///
/// Un acteur n'y suffit pas : à chaque `await`, il accepte un autre appel, qui voit encore « pas chargé » et relance le
/// chargement (un modèle chargé deux fois, des fichiers téléchargés deux fois dans le même dossier). Le travail tourne dans
/// une tâche à part, que l'annulation d'un appelant n'annule pas : un autre appelant peut l'attendre encore (et un
/// chargement de modèle qu'on ne sait pas interrompre va de toute façon à son terme). Un travail qui échoue libère la
/// place : l'appel suivant le retente.
public final class SingleFlight: Sendable {
    private struct State {
        var task: Task<Void, any Error>?
        var generation = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Lance `work` s'il n'y en a pas en cours, sinon attend celui qui l'est. Rend, ou lève, ce que le travail a rendu ou
    /// levé.
    public func run(_ work: @escaping @Sendable () async throws -> Void) async throws {
        let task = state.withLock { state -> Task<Void, any Error> in
            if let task = state.task { return task }
            state.generation += 1
            let generation = state.generation
            let task = Task<Void, any Error> { [self] in
                defer { finish(generation) }
                try await work()
            }
            state.task = task
            return task
        }
        try await task.value
    }

    private func finish(_ generation: Int) {
        state.withLock { if $0.generation == generation { $0.task = nil } }
    }

    /// Vrai pendant qu'un travail est en cours (pour les tests).
    var isRunning: Bool { state.withLock { $0.task != nil } }
}
