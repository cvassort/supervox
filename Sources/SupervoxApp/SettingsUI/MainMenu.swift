import AppKit

/// Menu principal minimal. L'application, de politique `.accessory`, n'affiche pas de barre de menus,
/// mais quand elle est active (fenêtre de réglages au premier plan) c'est ce menu qui donne leur effet
/// à ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A, ⌘W et ⌘Q. Les actions d'édition et de fermeture vont au premier
/// répondeur (cible `nil`) ; Quitter appelle `quit`, le même chemin que le menu de la barre d'état.
@MainActor
enum MainMenu {
    static func make(quit: @escaping @MainActor () -> Void) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Supervox", [ClosureMenuItem.make("Quitter Supervox", key: "q", action: quit)]))
        main.addItem(submenu("Fichier", [item("Fermer", #selector(NSWindow.performClose(_:)), "w")]))
        main.addItem(submenu(
            "Édition",
            [
                item("Annuler", Selector(("undo:")), "z"),
                item("Rétablir", Selector(("redo:")), "z", [.command, .shift]),
                .separator(),
                item("Couper", #selector(NSText.cut(_:)), "x"),
                item("Copier", #selector(NSText.copy(_:)), "c"),
                item("Coller", #selector(NSText.paste(_:)), "v"),
                item("Tout sélectionner", #selector(NSText.selectAll(_:)), "a"),
            ]))
        return main
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// Élément de menu qui appelle une fermeture ; l'élément retient sa cible.
@MainActor
final class ClosureMenuItem: NSObject {
    private let action: @MainActor () -> Void

    private init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    static func make(_ title: String, key: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let target = ClosureMenuItem(action)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: key)
        item.target = target
        item.representedObject = target
        return item
    }

    @objc private func run() { action() }
}
