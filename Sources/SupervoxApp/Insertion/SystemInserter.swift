import Foundation

extension TextInserter {
    /// L'insertion réelle : presse-papiers général, ⌘V posté sur le système, droit d'Accessibilité lu à chaque insertion.
    /// Construire ne lit ni n'écrit rien ; seul `insert` touche au système.
    public static func system() -> TextInserter {
        let permissions = SystemPermissions()
        return TextInserter(
            pasteboard: SystemPasteboard(), keys: SystemKeyPoster(), layout: SystemKeyboardLayout(),
            isTrusted: { permissions.accessibility() == .granted },
            wait: { try? await Task.sleep(for: .seconds($0)) })
    }
}
