import Carbon.HIToolbox
import Foundation

/// Les raccourcis de macOS activés sur ce Mac (Réglages Système, Clavier, Raccourcis clavier).
///
/// macOS ne refuse pas l'enregistrement d'une combinaison que l'un de ses propres raccourcis utilise, et ne dit pas
/// lequel des deux l'emporte : Supervox le vérifie lui-même. Rien ne permet en revanche de connaître les raccourcis
/// globaux des autres applications.
@MainActor
public protocol SystemHotKeys {
    /// Les combinaisons activées, avec les seuls modificateurs ⌃, ⌥, ⇧ et ⌘.
    func enabled() -> [HotKey]
}

/// Lecture par `CopySymbolicHotKeys` (Carbon).
///
/// Le domaine de préférences `com.apple.symbolichotkeys` ne suffit pas : il ne contient que les raccourcis que
/// l'utilisateur a modifiés au moins une fois (55 entrées sur la machine de développement), alors que
/// `CopySymbolicHotKeys` rend toute la table en vigueur, défauts compris (234 entrées, dont ⌘Tab et ⌃⌘Espace,
/// absents du domaine), en tenant compte des modifications du domaine.
public struct SymbolicHotKeys: SystemHotKeys {
    public init() {}

    public func enabled() -> [HotKey] {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr, let array else { return [] }
        let entries = array.takeRetainedValue() as? [[String: Any]] ?? []
        return Self.enabledHotKeys(in: entries)
    }

    /// Bit fn des modificateurs de Carbon (`kEventKeyModifierFnMask`).
    static let functionModifier: UInt32 = 1 << 17

    /// Touches que le système marque de lui-même avec fn : flèches, touches de fonction, début, fin, page
    /// précédente et suivante, suppression avant, aide. Une combinaison du système sur ces touches est la même
    /// pour Supervox avec ou sans fn, puisque Supervox ignore fn.
    static let keysCarryingFunction: Set<UInt32> = HotKey.functionKeyCodes.union(
        [
            kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow, kVK_Home, kVK_End, kVK_PageUp,
            kVK_PageDown, kVK_ForwardDelete, kVK_Help,
        ].map { UInt32($0) })

    /// Les entrées activées, converties en `HotKey`. Sont ignorées : les entrées incomplètes, celles sans touche
    /// (code 65535), et celles qui demandent un modificateur que Supervox ne sait pas exprimer (fn sur une touche
    /// qui ne le porte pas d'elle-même, verrouillage numérique…) : aucune combinaison de Supervox ne leur est égale.
    static func enabledHotKeys(in entries: [[String: Any]]) -> [HotKey] {
        entries.compactMap { entry -> HotKey? in
            guard let enabled = (entry["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue, enabled,
                let code = (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value, code != 0xFFFF,
                var raw = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value
            else { return nil }
            if keysCarryingFunction.contains(code) { raw &= ~functionModifier }
            let modifiers = Modifiers(rawValue: raw)
            guard Modifiers.known.contains(modifiers) else { return nil }
            return HotKey(keyCode: code, modifiers: modifiers)
        }
    }
}
