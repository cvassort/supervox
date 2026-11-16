import AppKit

/// L'application au premier plan, lue au système. Le contrôleur de dictée ne la lit jamais lui-même : il reçoit ce lecteur.
enum FrontApplication {
    /// L'identifiant du processus de l'application au premier plan, `nil` si le système n'en donne pas.
    static let system: @MainActor () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
}
