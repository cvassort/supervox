import Carbon.HIToolbox
import Foundation

/// La disposition du clavier, vue comme une table « code de touche physique -> caractère produit
/// sans modificateur ». Injectable pour que le libellé et la validation d'un raccourci ne
/// dépendent pas de la machine qui exécute les tests.
public protocol KeyboardLayout: Sendable {
    /// Le caractère que la touche de ce code produit seule, ou `nil` si la disposition n'en rend
    /// aucun. Le résultat n'est pas filtré : c'est à l'appelant de juger s'il est imprimable.
    func character(forKeyCode keyCode: UInt32) -> String?
}

/// La disposition de clavier active du système (`UCKeyTranslate` sur les données de la source
/// d'entrée de type disposition). Sans modificateur, touches mortes ignorées.
///
/// L'interface de saisie du système (TIS) doit être interrogée depuis le fil principal. Depuis le
/// fil principal, l'appel est direct (pas d'auto-interblocage). Depuis un autre fil, il est transféré
/// au fil principal avec `DispatchQueue.main.sync` : le fil appelant est bloqué jusqu'à ce que le
/// fil principal soit libre. Risque : interblocage si le fil principal attend lui-même ce fil appelant
/// (verrou, sémaphore, `sync` croisé) ; ne pas appeler `character(forKeyCode:)` depuis un contexte
/// que le fil principal attend.
public struct SystemKeyboardLayout: KeyboardLayout {
    public init() {}

    public func character(forKeyCode keyCode: UInt32) -> String? {
        if Thread.isMainThread { return Self.translate(keyCode) }
        return DispatchQueue.main.sync { Self.translate(keyCode) }
    }

    private static func translate(_ keyCode: UInt32) -> String? {
        guard keyCode <= UInt32(UInt16.max),
            // Source de type « disposition » : si l'utilisateur écrit avec une méthode de saisie
            // (japonais, par exemple), c'est la disposition sous-jacente.
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        // `bytes` pointe dans `layoutData`, que `source` possède : les deux doivent rester vivants
        // pendant toute la lecture de `UCKeyTranslate`, sans quoi rien ne les retient.
        let status = withExtendedLifetime((source, layoutData)) {
            bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                UCKeyTranslate(
                    layout, UInt16(keyCode), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count,
                    &length, &characters)
            }
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
