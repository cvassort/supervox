import CoreGraphics
import Testing

@testable import SupervoxApp

/// La lecture des touches de modification : quels drapeaux du système correspondent aux modificateurs d'un raccourci.
/// Aucune lecture de l'état réel du clavier : les drapeaux sont donnés.
@Suite struct HoldWatchTests {
    @Test func eachModifierMapsToItsOwnFlag() {
        #expect(HoldWatch.flags(for: [.command]) == .maskCommand)
        #expect(HoldWatch.flags(for: [.shift]) == .maskShift)
        #expect(HoldWatch.flags(for: [.option]) == .maskAlternate)
        #expect(HoldWatch.flags(for: [.control]) == .maskControl)
        #expect(HoldWatch.flags(for: [.control, .option]) == [.maskControl, .maskAlternate])
        #expect(HoldWatch.flags(for: []) == [])
    }

    @Test func oneHeldModifierOfTheHotKeyIsEnough() {
        let hotKey: Modifiers = [.control, .option]
        #expect(HoldWatch.anyHeld(in: [.maskControl, .maskAlternate], of: hotKey))
        #expect(HoldWatch.anyHeld(in: [.maskControl], of: hotKey))
        #expect(HoldWatch.anyHeld(in: [.maskAlternate, .maskShift], of: hotKey))
    }

    @Test func otherKeysAndBitsDoNotCount() {
        let hotKey: Modifiers = [.control, .option]
        #expect(!HoldWatch.anyHeld(in: [], of: hotKey))
        #expect(!HoldWatch.anyHeld(in: [.maskShift, .maskCommand], of: hotKey))
        // Majuscules verrouillées, fn et pavé numérique accompagnent des touches ordinaires.
        #expect(!HoldWatch.anyHeld(in: [.maskAlphaShift, .maskSecondaryFn, .maskNumericPad], of: hotKey))
    }

    @Test func aHotKeyWithoutModifiersIsNeverHeld() {
        #expect(!HoldWatch.anyHeld(in: [.maskControl], of: []))
    }
}
