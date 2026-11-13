import Foundation
import Testing

@testable import SupervoxApp

/// Ces valeurs sont écrites dans `settings.json` : si l'une change, les fichiers existants
/// changent de sens. Ce sont les constantes Carbon (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
@Suite struct HotKeyTests {
    @Test func modifierRawValuesAreThePersistedCarbonConstants() {
        #expect(Modifiers.command.rawValue == 1 << 8)
        #expect(Modifiers.shift.rawValue == 1 << 9)
        #expect(Modifiers.option.rawValue == 1 << 11)
        #expect(Modifiers.control.rawValue == 1 << 12)
    }

    @Test func standardHotKeyIsWrittenAsControlOptionSpace() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try String(decoding: encoder.encode(HotKey.standard), as: UTF8.self)
        // 49 = touche espace ; 6144 = contrôle (4096) + option (2048).
        #expect(json == #"{"keyCode":49,"modifiers":6144}"#)
    }
}
