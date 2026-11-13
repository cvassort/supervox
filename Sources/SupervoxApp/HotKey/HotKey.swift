import Carbon.HIToolbox

/// Raccourci clavier global : une touche (code virtuel) et ses modificateurs.
public struct HotKey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Contrôle + option + espace.
    public static let standard = HotKey(keyCode: 49, modifiers: [.control, .option])

    /// `validate(layout:)` avec la disposition de clavier active du système.
    public func validate() -> HotKeyValidation { validate(layout: SystemKeyboardLayout()) }

    /// Dit si la combinaison peut être proposée à l'utilisateur. Règles, dans cet ordre :
    /// 1. la touche est elle-même un modificateur : `.modifierOnly` ;
    /// 2. aucun modificateur, ou un bit de modificateur inconnu (fichier de réglages écrit à la main :
    ///    on ne le transmet pas tel quel au système), ou majuscule seule, ou option seule sur une touche qui n'est pas
    ///    une touche de fonction : `.needsModifier` (ces combinaisons tapent un caractère) ;
    /// 3. combinaison que le système s'est réservée : `.reserved`. ⌘Espace, ⌘Tab et ⇧⌘Tab sont
    ///    reconnus par code de touche ; ⌘Q, ⌘W, ⌘H et ⌘M par le caractère que la touche produit
    ///    dans `layout` (le système réserve la lettre, où qu'elle soit sur le clavier).
    /// Les règles sont volontairement étroites : rien d'autre n'est déclaré réservé.
    /// Limite : dans une disposition sans lettres latines (cyrillique, par exemple), ⌘Q n'est pas
    /// déclaré réservé.
    public func validate(layout: any KeyboardLayout) -> HotKeyValidation {
        if Self.modifierKeyCodes.contains(keyCode) { return .modifierOnly }
        if modifiers.isEmpty || !Modifiers.known.contains(modifiers) { return .needsModifier }
        if modifiers == [.shift] || modifiers == [.option], !Self.functionKeyCodes.contains(keyCode) {
            return .needsModifier
        }
        if isReserved(layout: layout) { return .reserved(label(layout: layout)) }
        return .valid
    }

    private func isReserved(layout: any KeyboardLayout) -> Bool {
        if modifiers == [.command] {
            if keyCode == UInt32(kVK_Space) || keyCode == UInt32(kVK_Tab) { return true }
            return Self.reservedLetters.contains(Self.printableName(forKeyCode: keyCode, layout: layout) ?? "")
        }
        return modifiers == [.command, .shift] && keyCode == UInt32(kVK_Tab)
    }

    /// Codes des touches qui sont elles-mêmes des modificateurs : `kVK_RightCommand` (0x36) à
    /// `kVK_Function` (0x3F), soit commande, majuscule, verrouillage majuscule, option, contrôle,
    /// leurs versions de droite, et fn.
    static let modifierKeyCodes: ClosedRange<UInt32> = UInt32(kVK_RightCommand)...UInt32(kVK_Function)

    /// Touches de fonction F1 à F20 (les codes ne se suivent pas).
    private static let functionKeyCodes: Set<UInt32> = Set(
        [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
            kVK_F20,
        ].map { UInt32($0) })

    /// Lettres qui, avec commande seule, appartiennent au système : quitter, fermer la fenêtre,
    /// masquer, réduire.
    private static let reservedLetters: Set<String> = ["Q", "W", "H", "M"]

    /// `label(layout:)` avec la disposition de clavier active du système.
    public var label: String { label(layout: SystemKeyboardLayout()) }

    /// Symboles des modificateurs dans l'ordre de la convention macOS (⌃⌥⇧⌘), puis le nom de la
    /// touche, par exemple « ⌃⌥Espace ».
    ///
    /// Nom de la touche : les touches non imprimables (Espace, Retour, Tab, Échap, flèches,
    /// touches de fonction, pavé numérique…) ont un nom fixe par code. Pour les autres, c'est le
    /// caractère que `layout` produit, en majuscule ; si la disposition n'en rend aucun d'imprimable,
    /// le nom de la table ANSI (QWERTY) ; en dernier recours « Touche 123 », jamais une chaîne vide.
    ///
    /// Limite connue : le repli sur la table ANSI suppose une disposition QWERTY. Le caractère est
    /// celui de la touche sans modificateur (sur AZERTY, la touche des chiffres rend « & », « é »…).
    public func label(layout: any KeyboardLayout) -> String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + (Self.printableName(forKeyCode: keyCode, layout: layout) ?? Self.fixedKeyNames[keyCode] ?? "Touche \(keyCode)")
    }

    /// Nom d'une touche imprimable d'après la disposition (en majuscule), à défaut d'après la
    /// table ANSI ; `nil` pour une touche à nom fixe ou inconnue.
    private static func printableName(forKeyCode keyCode: UInt32, layout: any KeyboardLayout) -> String? {
        if fixedKeyNames[keyCode] != nil { return nil }
        if let character = layout.character(forKeyCode: keyCode), isPrintable(character) {
            return character.uppercased()
        }
        return ansiKeyNames[keyCode]
    }

    /// Faux pour le vide, les caractères de contrôle, de mise en forme, privés (les touches de
    /// fonction y sont codées par le système) et les espaces.
    private static func isPrintable(_ character: String) -> Bool {
        !character.isEmpty
            && character.unicodeScalars.allSatisfy {
                switch $0.properties.generalCategory {
                case .control, .format, .privateUse, .unassigned, .surrogate, .spaceSeparator,
                    .lineSeparator, .paragraphSeparator:
                    return false
                default:
                    return true
                }
            }
    }

    /// Touches imprimables : lettres, chiffres de la rangée du haut, ponctuation, nommées d'après
    /// une disposition ANSI (QWERTY). Sert de repli quand la disposition active ne rend rien.
    private static let ansiKeyNames: [UInt32: String] = table([
        (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
        (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
        (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
        (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
        (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
        (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
        (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
        (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"),
        (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"),
        (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
        (kVK_ANSI_Equal, "="), (kVK_ANSI_Minus, "-"), (kVK_ANSI_RightBracket, "]"),
        (kVK_ANSI_LeftBracket, "["), (kVK_ANSI_Quote, "'"), (kVK_ANSI_Semicolon, ";"),
        (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Slash, "/"),
        (kVK_ANSI_Period, "."), (kVK_ANSI_Grave, "`"),
    ])

    /// Touches non imprimables ou indépendantes de la disposition : leur nom ne change jamais.
    private static let fixedKeyNames: [UInt32: String] = table([
        (kVK_Space, "Espace"), (kVK_Return, "Retour"), (kVK_Tab, "Tab"),
        (kVK_Escape, "Échap"), (kVK_Delete, "Effacer"), (kVK_ForwardDelete, "Suppr"),
        (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_DownArrow, "↓"), (kVK_UpArrow, "↑"),
        (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"),
        (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"),
        (kVK_F11, "F11"), (kVK_F12, "F12"), (kVK_F13, "F13"), (kVK_F14, "F14"),
        (kVK_F15, "F15"), (kVK_F16, "F16"), (kVK_F17, "F17"), (kVK_F18, "F18"),
        (kVK_F19, "F19"), (kVK_F20, "F20"),
        (kVK_Home, "Début"), (kVK_End, "Fin"),
        (kVK_PageUp, "Page précédente"), (kVK_PageDown, "Page suivante"),
        (kVK_ANSI_Keypad0, "Pavé 0"), (kVK_ANSI_Keypad1, "Pavé 1"),
        (kVK_ANSI_Keypad2, "Pavé 2"), (kVK_ANSI_Keypad3, "Pavé 3"),
        (kVK_ANSI_Keypad4, "Pavé 4"), (kVK_ANSI_Keypad5, "Pavé 5"),
        (kVK_ANSI_Keypad6, "Pavé 6"), (kVK_ANSI_Keypad7, "Pavé 7"),
        (kVK_ANSI_Keypad8, "Pavé 8"), (kVK_ANSI_Keypad9, "Pavé 9"),
        (kVK_ANSI_KeypadEnter, "Entrée"),
    ])

    private static func table(_ named: [(Int, String)]) -> [UInt32: String] {
        Dictionary(uniqueKeysWithValues: named.map { (UInt32($0.0), $0.1) })
    }
}

/// Résultat de `HotKey.validate()`.
public enum HotKeyValidation: Equatable, Sendable {
    case valid
    /// La touche n'est accompagnée d'aucun modificateur : elle volerait la frappe normale.
    case needsModifier
    /// La touche est elle-même un modificateur (commande, majuscule, option, contrôle, fn…).
    case modifierOnly
    /// Combinaison que le système s'est réservée ; le texte est son libellé, par exemple « ⌘Q ».
    case reserved(String)
}

/// Modificateurs d'un raccourci. Les valeurs sont celles de Carbon
/// (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`) et sont écrites telles quelles
/// dans le fichier de réglages : ne pas les renuméroter.
public struct Modifiers: OptionSet, Codable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = Modifiers(rawValue: 1 << 8)
    public static let shift = Modifiers(rawValue: 1 << 9)
    public static let option = Modifiers(rawValue: 1 << 11)
    public static let control = Modifiers(rawValue: 1 << 12)

    /// Les quatre modificateurs que Carbon connaît pour un raccourci.
    static let known: Modifiers = [.command, .shift, .option, .control]
}
