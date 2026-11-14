import CoreGraphics

/// L'envoi de ⌘V au système : événements clavier posés sur `.cghidEventTap`, ce qui exige le droit d'Accessibilité.
public final class SystemKeyPoster: KeyPoster {
    /// Les seuls modificateurs qui faussent un ⌘V : les bits de majuscules verrouillées, de fn et de pavé numérique
    /// accompagnent des touches ordinaires et ne doivent pas bloquer le collage.
    static let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    public init() {}

    public func modifiersHeld() -> Bool {
        Self.modifiersAreHeld(in: CGEventSource.flagsState(.combinedSessionState))
    }

    /// Faux seulement si l'événement n'a pas pu être fabriqué : le système ne dit pas si un événement posté a été reçu.
    public func postPaste(keyCode: UInt16) -> Bool {
        guard let events = Self.pasteEvents(keyCode: keyCode) else { return false }
        events.down.post(tap: .cghidEventTap)
        events.up.post(tap: .cghidEventTap)
        return true
    }

    static func modifiersAreHeld(in flags: CGEventFlags) -> Bool {
        !flags.intersection(modifierMask).isEmpty
    }

    /// Appui puis relâchement de la touche, avec ⌘ seul. Fabrique les événements sans les poster.
    static func pasteEvents(keyCode: UInt16) -> (down: CGEvent, up: CGEvent)? {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return nil }
        down.flags = .maskCommand
        up.flags = .maskCommand
        return (down, up)
    }
}
