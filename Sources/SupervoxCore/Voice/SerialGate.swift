import Foundation

/// Une porte à une place pour les appels asynchrones : `enter()` rend la main quand personne d'autre n'est à
/// l'intérieur, `leave()` laisse entrer le suivant, dans l'ordre d'arrivée.
///
/// Un acteur n'y suffit pas : à chaque `await` à l'intérieur d'une de ses méthodes, il accepte un autre appel, qui voit
/// un état à moitié mis à jour. Un détecteur de voix en flux, dont chaque bloc lit l'état, attend le modèle, puis
/// réécrit l'état, perdrait un bloc ou décalerait les indices. La porte fait de l'ensemble « lire, attendre, écrire »
/// une section que personne ne croise.
///
/// Usage : `await gate.enter(); defer { gate.leave() }`. Une tâche annulée pendant qu'elle attend à la porte y
/// attend quand même son tour : la section qu'elle protège décide de ce qu'elle fait de l'annulation.
public final class SerialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Nombre de tâches qui attendent à la porte (pour les tests).
    var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    public func enter() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy {
                waiters.append(continuation)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    /// À appeler une fois par `enter()`. Si une tâche attend, la place lui passe directement (la porte ne s'ouvre pas
    /// entre-temps : personne ne peut doubler la file).
    public func leave() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}
