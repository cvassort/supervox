import AppKit
import SwiftUI

/// Ce que la fenêtre de réglages montre, et ce qu'elle fait quand elle est présentée ou quittée.
public struct SettingsContent {
    public var view: AnyView
    /// À chaque présentation de la fenêtre (par exemple : demander quelles clés existent).
    public var onPresent: @MainActor () async -> Void
    /// Quand l'utilisateur quitte la fenêtre : fermée, plus au premier plan, ou application passée en arrière-plan.
    /// Peut être appelé plusieurs fois de suite.
    public var onLeave: @MainActor () -> Void

    public init(
        view: AnyView, onPresent: @escaping @MainActor () async -> Void = {},
        onLeave: @escaping @MainActor () -> Void = {}
    ) {
        self.view = view
        self.onPresent = onPresent
        self.onLeave = onLeave
    }
}

/// La fenêtre de réglages telle que le contrôleur la voit ; remplacée dans les tests, où rien ne doit s'afficher.
@MainActor
public protocol SettingsWindowSurface: AnyObject {
    /// Met la fenêtre au premier plan.
    func present()
}

/// La vraie fenêtre. `onLeave` est appelé quand la fenêtre se ferme, cesse d'être la fenêtre active, ou quand
/// l'application passe en arrière-plan : une capture de raccourci en cours prend fin, le raccourci global revient.
@MainActor
final class SettingsWindow: SettingsWindowSurface {
    let window: NSWindow
    private var observers: [NSObjectProtocol] = []

    init(content: AnyView, onLeave: @escaping @MainActor () -> Void) {
        window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = "Réglages"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()

        let center = NotificationCenter.default
        let leave: @Sendable (Notification) -> Void = { _ in MainActor.assumeIsolated { onLeave() } }
        observers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main, using: leave),
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: leave),
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: leave),
        ]
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func present() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
