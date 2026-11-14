import CoreGraphics
import Foundation
import Testing

@testable import SupervoxApp

/// Ce que les réalisations système construisent sans toucher au système : le contenu à écrire, le masque des
/// modificateurs, les événements (construits, jamais postés). Aucun appel à `postPaste`, `modifiersHeld`, `read`,
/// `write` ou `writeText` du système.
@MainActor @Suite struct SystemInsertionPartsTests {
    @Test("le texte transitoire porte le texte en UTF-8 et les types TransientType et ConcealedType ; le texte non transitoire, le texte seul")
    func textPayloadCarriesTheTransientMarkers() throws {
        let text = "dictée privée"
        let transient = SystemPasteboard.contents(forText: text, transient: true)
        #expect(transient.items.count == 1)
        let item = try #require(transient.items.first)
        #expect(Set(item.keys) == [
            "public.utf8-plain-text", "org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType",
        ])
        #expect(item["public.utf8-plain-text"] == Data(text.utf8))

        let plain = SystemPasteboard.contents(forText: text, transient: false)
        #expect(plain.items == [["public.utf8-plain-text": Data(text.utf8)]])
    }

    nonisolated static let flagCases: [(CGEventFlags, Bool)] = [
        (.maskCommand, true), (.maskAlternate, true), (.maskControl, true), (.maskShift, true),
        ([.maskCommand, .maskShift], true), ([.maskAlphaShift, .maskControl], true),
        ([], false), (.maskAlphaShift, false), (.maskSecondaryFn, false), (.maskNumericPad, false),
        ([.maskAlphaShift, .maskSecondaryFn, .maskNumericPad], false),
    ]

    @Test("seuls ⌘, ⌥, ⌃ et ⇧ comptent comme modificateurs tenus ; majuscules verrouillées, fn et pavé numérique, non",
        arguments: flagCases)
    func onlyRealModifiersCount(flags: CGEventFlags, held: Bool) {
        #expect(SystemKeyPoster.modifiersAreHeld(in: flags) == held)
    }

    @Test("l'événement de collage : appui puis relâchement de la touche demandée, avec ⌘ seul, construits sans être postés")
    func pasteEventsAreCommandPlusTheKey() throws {
        let events = try #require(SystemKeyPoster.pasteEvents(keyCode: 47))
        #expect(events.down.type == .keyDown)
        #expect(events.up.type == .keyUp)
        #expect(events.down.getIntegerValueField(.keyboardEventKeycode) == 47)
        #expect(events.up.getIntegerValueField(.keyboardEventKeycode) == 47)
        #expect(events.down.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == .maskCommand)
        #expect(events.up.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == .maskCommand)
    }
}
