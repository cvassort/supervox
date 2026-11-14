import AppKit

/// Reçoit les touches pressées dans l'application pendant la capture d'un raccourci.
@MainActor
public protocol KeyEventMonitor: AnyObject {
    /// Donne chaque touche pressée à `handler`, qui la consomme : elle n'atteint pas la fenêtre. Remplace un moniteur
    /// déjà posé.
    func start(_ handler: @escaping @MainActor (_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> Void)
    /// Retire le moniteur ; sans effet s'il n'y en a pas.
    func stop()
}

/// Moniteur local d'AppKit (`NSEvent.addLocalMonitorForEvents`).
@MainActor
final class LocalKeyDownMonitor: KeyEventMonitor {
    private var token: Any?

    func start(_ handler: @escaping @MainActor (UInt16, NSEvent.ModifierFlags) -> Void) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handler(event.keyCode, event.modifierFlags) }
            return nil
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
