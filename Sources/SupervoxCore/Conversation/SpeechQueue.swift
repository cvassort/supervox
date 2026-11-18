import Foundation

/// L'état de la réplique vue de la file : au plus une synthèse en cours, au plus `maxQueuedClips` clips mis en file de lecture et
/// pas encore finis. Pure : l'acteur la fait avancer, les tests la vérifient seule.
struct SpeechQueue: Equatable {
    /// Deux clips : celui qui joue et le suivant déjà prêt, de quoi ne pas laisser de silence entre deux phrases sans synthétiser
    /// loin devant ce qui est dit (règle de la tâche 5 ; choix non mesuré).
    static let maxQueuedClips = 2

    /// Les rangs des phrases prêtes, pas encore en cours de synthèse.
    private(set) var pending: [Int] = []
    /// Le rang de la phrase en cours de synthèse.
    private(set) var synthesizing: Int?
    private(set) var queuedClips = 0
    private var registered = 0

    /// Une phrase est prête : son rang.
    mutating func register() -> Int {
        pending.append(registered)
        defer { registered += 1 }
        return registered
    }

    /// Le rang de la phrase à synthétiser maintenant, si rien n'est en cours et si la file n'est pas pleine ; elle est alors en cours.
    mutating func nextToSynthesize() -> Int? {
        guard synthesizing == nil, queuedClips < Self.maxQueuedClips, !pending.isEmpty else { return nil }
        let index = pending.removeFirst()
        synthesizing = index
        return index
    }

    mutating func synthesisFinished() { synthesizing = nil }
    mutating func clipQueued() { queuedClips += 1 }
    mutating func clipEnded() { queuedClips = max(queuedClips - 1, 0) }

    /// Sans voix : toutes les phrases en attente d'un coup.
    mutating func takeAllPending() -> [Int] {
        defer { pending = [] }
        return pending
    }

    var isIdle: Bool { pending.isEmpty && synthesizing == nil && queuedClips == 0 }
}

/// Ce que montre `ConversationChain.replySnapshot()`.
struct ReplySnapshot: Equatable {
    var queuedClips: Int
    var synthesizing: Int?
    var pending: [Int]
}
