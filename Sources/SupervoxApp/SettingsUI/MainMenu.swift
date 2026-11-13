import AppKit

/// Menu principal minimal. L'application, de politique `.accessory`, n'affiche pas de barre de menus,
/// mais quand elle est active (fenêtre de réglages au premier plan) c'est ce menu qui donne leur effet
/// à ⌘X, ⌘C, ⌘V, ⌘A et ⌘Q. Les actions des éditions vont au premier répondeur (cible `nil`).
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(
            "Supervox",
            [NSMenuItem(title: "Quitter Supervox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")]))
        main.addItem(submenu(
            "Édition",
            [
                NSMenuItem(title: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
                NSMenuItem(title: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
                NSMenuItem(title: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
                NSMenuItem(title: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
            ]))
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
