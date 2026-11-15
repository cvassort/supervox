import AppKit

/// Ce que le panneau flottant fait de la frappe.
public enum PanelKeyboard: Equatable, Sendable {
    /// Le panneau ne peut pas devenir clé : l'application de dessous garde la frappe (état de la dictée).
    case none
    /// Le panneau peut devenir clé sur un clic, sans l'être tout de suite ; s'il l'est déjà, il rend la frappe à l'application
    /// de dessous.
    case available
    /// Le panneau devient clé, sans activer l'application, et le champ de relecture prend la frappe.
    case focused
}

/// Une commande du menu Édition que le panneau sait exécuter lui-même.
public enum EditingCommand: Equatable, Sendable {
    case undo, redo, cut, copy, paste, selectAll
}

/// La traduction d'une touche en commande d'édition. Supervox est un agent de barre de menus : sans menu Édition, ⌘Z, ⌘C…
/// n'atteindraient jamais le champ de relecture ; le panneau les traduit donc lui-même.
public enum PanelEditingKeys {
    /// La commande que ces caractères, lus **sans** modificateur (`NSEvent.charactersIgnoringModifiers`, qui suit la
    /// disposition du clavier : ⌘Z reste ⌘Z en AZERTY), et ces modificateurs désignent ; `nil` sinon. Il faut ⌘ ; ⌥ ou ⌃ en
    /// plus l'annulent ; ⇧ ne compte que pour Z (rétablir).
    public static func command(characters: String, modifiers: NSEvent.ModifierFlags) -> EditingCommand? {
        let held = modifiers.intersection([.command, .shift, .option, .control])
        guard held.contains(.command), held.isDisjoint(with: [.option, .control]) else { return nil }
        let shift = held.contains(.shift)
        switch (characters.lowercased(), shift) {
        case ("z", false): return .undo
        case ("z", true): return .redo
        case ("x", false): return .cut
        case ("c", false): return .copy
        case ("v", false): return .paste
        case ("a", false): return .selectAll
        default: return nil
        }
    }

    /// L'action de la chaîne des répondeurs qui exécute la commande.
    public static func selector(for command: EditingCommand) -> Selector {
        switch command {
        case .undo: NSSelectorFromString("undo:")
        case .redo: NSSelectorFromString("redo:")
        case .cut: #selector(NSText.cut(_:))
        case .copy: #selector(NSText.copy(_:))
        case .paste: #selector(NSText.paste(_:))
        case .selectAll: #selector(NSText.selectAll(_:))
        }
    }
}
