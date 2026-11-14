import Foundation
import Testing

@testable import SupervoxApp

/// Raccourcis du système, double : la liste des combinaisons activées. Les tests n'interrogent jamais le système.
@MainActor final class FakeSystemHotKeys: SystemHotKeys {
    var hotKeys: [HotKey]
    private(set) var reads = 0
    init(_ hotKeys: [HotKey] = []) { self.hotKeys = hotKeys }
    func enabled() -> [HotKey] {
        reads += 1
        return hotKeys
    }
}

/// Lecture des entrées rendues par `CopySymbolicHotKeys`. Les formes viennent d'une lecture réelle sur la machine de
/// développement (macOS 27.2) : clés `kHISymbolicHotKeyCode`, `kHISymbolicHotKeyModifiers` (valeurs de Carbon,
/// les mêmes que `Modifiers`) et `kHISymbolicHotKeyEnabled`.
@MainActor @Suite struct SystemHotKeysTests {
    static func entry(_ code: Int, _ modifiers: Int, enabled: Any) -> [String: Any] {
        ["kHISymbolicHotKeyCode": code, "kHISymbolicHotKeyModifiers": modifiers, "kHISymbolicHotKeyEnabled": enabled]
    }

    @Test func enabledEntriesBecomeHotKeys() {
        let parsed = SymbolicHotKeys.enabledHotKeys(in: [
            Self.entry(49, 6144, enabled: true),  // ⌃⌥Espace, activé
            Self.entry(53, 2304, enabled: NSNumber(value: 1)),  // ⌥⌘Échap, activé (nombre et non booléen)
            Self.entry(49, 256, enabled: false),  // ⌘Espace, désactivé
            Self.entry(49, 4096, enabled: NSNumber(value: 0)),  // ⌃Espace, désactivé
        ])
        #expect(parsed == [
            HotKey(keyCode: 49, modifiers: [.control, .option]),
            HotKey(keyCode: 53, modifiers: [.command, .option]),
        ])
    }

    @Test func entriesWithoutAKeyOrIncompleteAreIgnored() {
        let parsed = SymbolicHotKeys.enabledHotKeys(in: [
            Self.entry(65535, 0, enabled: true),  // aucune touche
            Self.entry(65535, 512, enabled: true),
            ["kHISymbolicHotKeyCode": 12, "kHISymbolicHotKeyEnabled": true],  // sans modificateurs
            ["kHISymbolicHotKeyModifiers": 256, "kHISymbolicHotKeyEnabled": true],  // sans touche
            ["kHISymbolicHotKeyCode": 12, "kHISymbolicHotKeyModifiers": 256],  // sans état
        ])
        #expect(parsed.isEmpty)
    }

    /// Le bit fn (1 << 17) accompagne de lui-même les flèches et les touches de fonction : ⌃← du système est
    /// enregistré « fn ⌃← », et c'est la même combinaison que ⌃← pour Supervox. Sur une lettre, fn est un vrai
    /// modificateur que Supervox ne peut pas exprimer : « fn ⌃F » n'est pas ⌃F.
    @Test func functionBitIsDroppedOnlyWhereTheKeyCarriesIt() {
        let parsed = SymbolicHotKeys.enabledHotKeys(in: [
            Self.entry(123, 135168, enabled: true),  // fn ⌃←
            Self.entry(103, 131584, enabled: true),  // fn ⇧F11
            Self.entry(3, 135168, enabled: true),  // fn ⌃F
            Self.entry(0, 131072, enabled: true),  // fn A
        ])
        #expect(parsed == [
            HotKey(keyCode: 123, modifiers: [.control]),
            HotKey(keyCode: 103, modifiers: [.shift]),
        ])
    }
}
