import AppKit

/// Délégué de l'application. Relancer Supervox alors qu'il tourne déjà (Finder, Launchpad, `open`) ouvre le panneau :
/// une application de barre de menus n'a pas de fenêtre à montrer, et l'utilisateur qui la relance la cherche.
///
/// `NSApplication.delegate` est une référence faible : celui qui le pose le garde.
@MainActor
public final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let controller: AppController

    public init(controller: AppController) {
        self.controller = controller
    }

    /// Rend faux : il n'y a pas de fenêtre que le système devrait rouvrir lui-même.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.openPanelOnReopen()
        return false
    }
}
