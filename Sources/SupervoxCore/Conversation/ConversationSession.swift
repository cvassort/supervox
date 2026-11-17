import Foundation

/// La façade de l'entretien : ce que l'appelant garde, et rien d'autre. Elle possède le moteur (`ConversationChain`) et l'annule
/// quand elle est libérée sans `cancel()` : le micro est alors arrêté et le flux finit sur `.finished(.cancelled)`.
///
/// L'acteur ne peut pas le faire lui-même : ses tâches (la conversation, la fin) le retiennent tant que l'entretien tourne, un
/// `deinit` sur lui ne s'exécuterait jamais. Le filet de l'acteur reste : un lecteur qui abandonne le flux annule aussi l'entretien.
public final class ConversationSession: ConversationEngine {
    let chain: ConversationChain

    public init(_ chain: ConversationChain) {
        self.chain = chain
    }

    public func start() async -> AsyncStream<ConversationEvent> { await chain.start() }
    public func conclude() async { await chain.conclude() }
    public func cancel() async { await chain.cancel() }

    deinit {
        let chain = chain
        Task { await chain.cancel() }
    }
}
