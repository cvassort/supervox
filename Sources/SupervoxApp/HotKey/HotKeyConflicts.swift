/// À qui appartient une combinaison : au raccourci global, ou à un mode (son identifiant).
public enum HotKeyOwner: Hashable, Sendable {
    case global
    case mode(String)
}

/// Les refus d'une combinaison proposée au raccourci global ou à un mode. Une seule table de phrases : la fenêtre de réglages
/// (`HotKeySettingsModel`) et l'onglet des modes disent la même chose pour le même refus.
public enum HotKeyConflicts {
    /// La phrase qui refuse `candidate` pour `owner`, ou `nil` si elle est libre. Dans l'ordre : combinaison invalide ou réservée
    /// (Échap seul, sans modificateur, en fait partie), raccourci global, autre mode, raccourci de macOS activé.
    ///
    /// `global` et `modes` sont les raccourcis attribués dans les réglages, qu'ils soient enregistrés auprès du système ou non :
    /// un raccourci refusé au lancement garde sa combinaison. Redonner à `owner` la combinaison qu'il a déjà n'est pas un
    /// conflit. `names` donne le nom des modes (identifiant vers nom) pour nommer le détenteur.
    public static func refusal(
        for candidate: HotKey, owner: HotKeyOwner, global: HotKey?, modes: [String: HotKey], names: [String: String],
        systemEnabled: [HotKey], layout: any KeyboardLayout
    ) -> String? {
        let label = candidate.label(layout: layout)
        let validation = candidate.validate(layout: layout)
        guard validation == .valid else { return refusal(validation, label: label) }
        if owner != .global, candidate == global { return heldByGlobal(label: label) }
        let holder = modes.filter { $0.value == candidate && owner != .mode($0.key) }.keys.sorted().first
        if let holder { return heldByMode(label: label, name: names[holder]) }
        if systemEnabled.contains(candidate) { return systemShortcutRefusal(label: label) }
        return nil
    }

    /// Refus d'une combinaison invalide ou réservée.
    static func refusal(_ validation: HotKeyValidation, label: String) -> String {
        switch validation {
        case .valid: ""
        case .needsModifier: "Ajoutez ⌃ ou ⌘ : \(label) taperait du texte."
        case .modifierOnly: "Ajoutez une touche aux modificateurs."
        case .reserved(let reserved): "\(reserved) est réservé par le système."
        }
    }

    /// Refus d'une combinaison que le système n'a pas voulu enregistrer : macOS ne dit pas pourquoi, une autre application la tient
    /// sans doute.
    static func refusedBySystem(label: String) -> String {
        "\(label) a été refusé par macOS : il est sans doute déjà pris par une autre application. Choisissez-en un autre."
    }

    /// Refus d'une combinaison que macOS utilise déjà.
    static func systemShortcutRefusal(label: String) -> String {
        "\(label) est un raccourci de macOS activé sur ce Mac (Réglages Système, Clavier, Raccourcis clavier) : choisissez-en un autre."
    }

    /// Refus d'une combinaison que tient le raccourci global.
    static func heldByGlobal(label: String) -> String {
        "\(label) est déjà le raccourci global de Supervox, qui lance la dictée : choisissez-en un autre."
    }

    /// Refus d'une combinaison que tient un mode ; `name` est son nom, `nil` s'il n'est plus connu.
    static func heldByMode(label: String, name: String?) -> String {
        guard let name else { return "\(label) est déjà le raccourci d'un autre mode : choisissez-en un autre." }
        return "\(label) est déjà le raccourci du mode « \(name) » : choisissez-en un autre."
    }
}
