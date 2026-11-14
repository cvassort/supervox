import Foundation
import Testing

@testable import SupervoxApp

/// Interroge la vraie disposition de clavier active : désactivé sauf `SUPERVOX_KEYBOARD=1`.
/// Ne vérifie qu'une chose : la réalisation système rend un caractère non vide pour le code 0x00
/// (la touche A en ANSI, Q en AZERTY). Le caractère obtenu est affiché dans la sortie du test.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_KEYBOARD"] == "1"))
struct KeyboardLayoutIntegrationTests {
    @Test func systemLayoutNamesTheKeyAtCodeZero() {
        let character = SystemKeyboardLayout().character(forKeyCode: 0x00)
        print("SUPERVOX_KEYBOARD: code 0x00 -> \(character.map { "\"\($0)\"" } ?? "nil")")
        #expect(character?.isEmpty == false)
        #expect(HotKey(keyCode: 0x00, modifiers: [.control]).label(layout: SystemKeyboardLayout()).hasPrefix("⌃"))
        #expect(HotKey(keyCode: 0x00, modifiers: [.control]).label(layout: SystemKeyboardLayout()).count >= 2)
    }
}
