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

    // MARK: - Validation et libellé

    @Test func standardHotKeyIsValidAndLabelled() {
        #expect(HotKey.standard.validate(layout: Self.ansi) == .valid)
        #expect(HotKey.standard.label == "⌃⌥Espace")
    }

    @Test func keyWithoutModifierIsRejected() {
        #expect(HotKey(keyCode: 49, modifiers: []).validate(layout: Self.ansi) == .needsModifier)
        #expect(HotKey(keyCode: 0x00, modifiers: []).validate(layout: Self.ansi) == .needsModifier)
        #expect(HotKey(keyCode: 0x7A, modifiers: []).validate(layout: Self.ansi) == .needsModifier)
    }

    /// Codes de touches qui sont elles-mêmes des modificateurs (`kVK_Command` 0x37, `kVK_Shift` 0x38,
    /// `kVK_CapsLock` 0x39, `kVK_Option` 0x3A, `kVK_Control` 0x3B, `kVK_RightCommand` 0x36,
    /// `kVK_RightShift` 0x3C, `kVK_RightOption` 0x3D, `kVK_RightControl` 0x3E, `kVK_Function` 0x3F).
    @Test(arguments: [UInt32(0x36), 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F])
    func modifierKeyAloneIsRejected(keyCode: UInt32) {
        #expect(HotKey(keyCode: keyCode, modifiers: [.command]).validate(layout: Self.ansi) == .modifierOnly)
        // Sans modificateur non plus : la touche seule est d'abord un modificateur.
        #expect(HotKey(keyCode: keyCode, modifiers: []).validate(layout: Self.ansi) == .modifierOnly)
    }

    @Test func keysNextToTheModifierKeysAreNotMistakenForModifiers() {
        // 0x35 = Échap, 0x40 = F17 : de part et d'autre de la plage 0x36...0x3F.
        #expect(HotKey(keyCode: 0x35, modifiers: [.control]).validate(layout: Self.ansi) == .valid)
        #expect(HotKey(keyCode: 0x40, modifiers: [.control]).validate(layout: Self.ansi) == .valid)
    }

    @Test func reservedCombinationsAreRejected() {
        #expect(HotKey(keyCode: 0x31, modifiers: [.command]).validate(layout: Self.ansi) == .reserved("⌘Espace"))
        #expect(HotKey(keyCode: 0x30, modifiers: [.command]).validate(layout: Self.ansi) == .reserved("⌘Tab"))
        #expect(HotKey(keyCode: 0x0C, modifiers: [.command]).validate(layout: Self.ansi) == .reserved("⌘Q"))
    }

    @Test func combinationsCloseToReservedOnesAreAccepted() {
        // Même touche avec un autre modificateur, ou autre touche avec commande : pas réservés.
        #expect(HotKey(keyCode: 0x31, modifiers: [.command, .option]).validate(layout: Self.ansi) == .valid)
        #expect(HotKey(keyCode: 0x31, modifiers: [.control]).validate(layout: Self.ansi) == .valid)
        #expect(HotKey(keyCode: 0x30, modifiers: [.command, .option]).validate(layout: Self.ansi) == .valid)
        #expect(HotKey(keyCode: 0x0C, modifiers: [.command, .control]).validate(layout: Self.ansi) == .valid)
        #expect(HotKey(keyCode: 0x00, modifiers: [.command]).validate(layout: Self.ansi) == .valid)  // ⌘A
    }

    @Test func labelListsModifiersInControlOptionShiftCommandOrder() {
        let all: Modifiers = [.command, .shift, .option, .control]
        #expect(HotKey(keyCode: 0x00, modifiers: all).label(layout: Self.ansi) == "⌃⌥⇧⌘A")
        #expect(HotKey(keyCode: 0x7A, modifiers: [.shift, .command]).label(layout: Self.ansi) == "⇧⌘F1")
        #expect(HotKey(keyCode: 0x24, modifiers: [.option]).label(layout: Self.ansi) == "⌥Retour")
        #expect(HotKey(keyCode: 0x00, modifiers: []).label(layout: Self.ansi) == "A")
    }

    /// Valeurs relevées à la main dans `HIToolbox/Events.h` du SDK (`kVK_*`), pas dans le code testé.
    /// Ce sont les noms de touches d'une disposition ANSI/QWERTY, ceux de la table de repli du code.
    static let expectedKeyNames: [(UInt32, String)] = [
        (0x00, "A"), (0x0B, "B"), (0x08, "C"), (0x02, "D"), (0x0E, "E"), (0x03, "F"), (0x05, "G"),
        (0x04, "H"), (0x22, "I"), (0x26, "J"), (0x28, "K"), (0x25, "L"), (0x2E, "M"), (0x2D, "N"),
        (0x1F, "O"), (0x23, "P"), (0x0C, "Q"), (0x0F, "R"), (0x01, "S"), (0x11, "T"), (0x20, "U"),
        (0x09, "V"), (0x0D, "W"), (0x07, "X"), (0x10, "Y"), (0x06, "Z"),
        (0x1D, "0"), (0x12, "1"), (0x13, "2"), (0x14, "3"), (0x15, "4"), (0x17, "5"), (0x16, "6"),
        (0x1A, "7"), (0x1C, "8"), (0x19, "9"),
        (0x31, "Espace"), (0x24, "Retour"), (0x30, "Tab"), (0x35, "Échap"),
        (0x33, "Effacer"), (0x75, "Suppr"),
        (0x7B, "←"), (0x7C, "→"), (0x7D, "↓"), (0x7E, "↑"),
        (0x7A, "F1"), (0x78, "F2"), (0x63, "F3"), (0x76, "F4"), (0x60, "F5"), (0x61, "F6"),
        (0x62, "F7"), (0x64, "F8"), (0x65, "F9"), (0x6D, "F10"), (0x67, "F11"), (0x6F, "F12"),
        (0x69, "F13"), (0x6B, "F14"), (0x71, "F15"), (0x6A, "F16"), (0x40, "F17"), (0x4F, "F18"),
        (0x50, "F19"), (0x5A, "F20"),
        (0x73, "Début"), (0x77, "Fin"), (0x74, "Page précédente"), (0x79, "Page suivante"),
        (0x18, "="), (0x1B, "-"), (0x1E, "]"), (0x21, "["), (0x27, "'"), (0x29, ";"),
        (0x2A, "\\"), (0x2B, ","), (0x2C, "/"), (0x2F, "."), (0x32, "`"),
        (0x52, "Pavé 0"), (0x53, "Pavé 1"), (0x54, "Pavé 2"), (0x55, "Pavé 3"), (0x56, "Pavé 4"),
        (0x57, "Pavé 5"), (0x58, "Pavé 6"), (0x59, "Pavé 7"), (0x5B, "Pavé 8"), (0x5C, "Pavé 9"),
        (0x4C, "Entrée"),
    ]

    /// Disposition à partir d'une table « code -> caractère » (minuscules, comme le rend le système).
    struct StubLayout: KeyboardLayout {
        var characters: [UInt32: String]
        func character(forKeyCode keyCode: UInt32) -> String? { characters[keyCode] }
    }

    /// Ce que rend une disposition ANSI : les caractères d'un seul signe ASCII de `expectedKeyNames`.
    static let ansi = StubLayout(
        characters: Dictionary(
            uniqueKeysWithValues: expectedKeyNames
                .filter { $0.1.count == 1 && $0.1.unicodeScalars.allSatisfy(\.isASCII) }
                .map { ($0.0, $0.1.lowercased()) }))

    /// AZERTY français : A/Q, Z/W et M/; échangés, « ² » sur le code ISO 0x0A, « & » sur le 1.
    static let azerty = StubLayout(
        characters: ansi.characters.merging([
            0x00: "q", 0x0C: "a", 0x0D: "z", 0x06: "w", 0x29: "m", 0x2E: ",", 0x0A: "²", 0x12: "&",
        ]) { _, new in new })

    /// Disposition muette : chaque nom vient de la table de repli du code, vérifiée ici contre les
    /// valeurs relevées dans l'en-tête (et non contre une disposition dérivée de ces valeurs).
    @Test(arguments: expectedKeyNames)
    func keyLabelMatchesTheCarbonVirtualKeyCode(keyCode: UInt32, name: String) {
        let silent = StubLayout(characters: [:])
        #expect(HotKey(keyCode: keyCode, modifiers: [.control]).label(layout: silent) == "⌃" + name)
    }

    /// Avec une disposition ANSI qui répond, le libellé est le même (lettres en majuscule).
    @Test(arguments: expectedKeyNames)
    func keyLabelFromAnAnsiLayoutIsTheSame(keyCode: UInt32, name: String) {
        #expect(HotKey(keyCode: keyCode, modifiers: [.control]).label(layout: Self.ansi) == "⌃" + name)
    }

    @Test func unknownKeyCodeGetsAReadableFallbackLabel() {
        #expect(HotKey(keyCode: 123 + 1000, modifiers: [.control]).label(layout: Self.ansi) == "⌃Touche 1123")
        #expect(HotKey(keyCode: 0x0A, modifiers: []).label(layout: Self.ansi) == "Touche 10")  // kVK_ISO_Section, non nommé
    }

    @Test func everyKeyCodeHasANonEmptyLabelAndLabelsAreDistinct() {
        var seen: [String: UInt32] = [:]
        for code in UInt32(0)...255 {
            let label = HotKey(keyCode: code, modifiers: []).label(layout: Self.ansi)
            #expect(!label.isEmpty, "code \(code) : libellé vide")
            if let other = seen[label] {
                Issue.record("codes \(other) et \(code) ont le même libellé « \(label) »")
            }
            seen[label] = code
        }
    }

    // MARK: - Disposition du clavier

    @Test func labelFollowsTheActiveLayout() {
        // Même code physique, caractères différents selon la disposition.
        #expect(HotKey(keyCode: 0x00, modifiers: [.control]).label(layout: Self.ansi) == "⌃A")
        #expect(HotKey(keyCode: 0x00, modifiers: [.control]).label(layout: Self.azerty) == "⌃Q")
        #expect(HotKey(keyCode: 0x0C, modifiers: [.control]).label(layout: Self.ansi) == "⌃Q")
        #expect(HotKey(keyCode: 0x0C, modifiers: [.control]).label(layout: Self.azerty) == "⌃A")
        #expect(HotKey(keyCode: 0x29, modifiers: []).label(layout: Self.azerty) == "M")
        #expect(HotKey(keyCode: 0x12, modifiers: []).label(layout: Self.azerty) == "&")
    }

    @Test func layoutCharactersAreShownInUppercase() {
        let layout = StubLayout(characters: [0x00: "é", 0x0B: "b"])
        #expect(HotKey(keyCode: 0x00, modifiers: []).label(layout: layout) == "É")
        #expect(HotKey(keyCode: 0x0B, modifiers: []).label(layout: layout) == "B")
    }

    @Test func nonPrintableKeysKeepTheirNamesWhateverTheLayoutSays() {
        let everythingIsX = StubLayout(
            characters: Dictionary(uniqueKeysWithValues: (UInt32(0)...255).map { ($0, "x") }))
        let named: [(UInt32, String)] = [
            (0x31, "Espace"), (0x24, "Retour"), (0x30, "Tab"), (0x35, "Échap"), (0x33, "Effacer"),
            (0x75, "Suppr"), (0x7B, "←"), (0x7C, "→"), (0x7D, "↓"), (0x7E, "↑"), (0x7A, "F1"),
            (0x6F, "F12"), (0x73, "Début"), (0x77, "Fin"), (0x74, "Page précédente"),
            (0x79, "Page suivante"), (0x52, "Pavé 0"), (0x4C, "Entrée"),
        ]
        for (code, name) in named {
            #expect(HotKey(keyCode: code, modifiers: []).label(layout: everythingIsX) == name)
        }
    }

    @Test func layoutThatSaysNothingFallsBackToTheAnsiTableThenToTouche() {
        let silent = StubLayout(characters: [:])
        #expect(HotKey(keyCode: 0x00, modifiers: []).label(layout: silent) == "A")
        #expect(HotKey(keyCode: 0x0A, modifiers: []).label(layout: silent) == "Touche 10")
        // Un résultat vide ou de contrôle n'est pas un caractère imprimable : même repli.
        let junk = StubLayout(characters: [0x00: "", 0x0B: "\u{7F}", 0x08: "\u{F704}", 0x0D: " "])
        #expect(HotKey(keyCode: 0x00, modifiers: []).label(layout: junk) == "A")
        #expect(HotKey(keyCode: 0x0B, modifiers: []).label(layout: junk) == "B")
        #expect(HotKey(keyCode: 0x08, modifiers: []).label(layout: junk) == "C")
        #expect(HotKey(keyCode: 0x0D, modifiers: []).label(layout: junk) == "W")
    }

    @Test func layoutCanNameKeysTheAnsiTableDoesNotKnow() {
        #expect(HotKey(keyCode: 0x0A, modifiers: [.control]).label(layout: Self.azerty) == "⌃²")
    }

    @Test func reservedQuitFollowsTheCharacterNotTheKeyCode() {
        let commandOn = { (code: UInt32, layout: StubLayout) in
            HotKey(keyCode: code, modifiers: [.command]).validate(layout: layout)
        }
        // ANSI : « q » est au code 0x0C.
        #expect(commandOn(0x0C, Self.ansi) == .reserved("⌘Q"))
        #expect(commandOn(0x00, Self.ansi) == .valid)
        // AZERTY : « q » est au code 0x00, et 0x0C porte « a ».
        #expect(commandOn(0x00, Self.azerty) == .reserved("⌘Q"))
        #expect(commandOn(0x0C, Self.azerty) == .valid)
    }

    @Test func closeWindowHideAndMinimizeAreReservedByCharacter() {
        // ANSI : W 0x0D, H 0x04, M 0x2E.
        #expect(HotKey(keyCode: 0x0D, modifiers: [.command]).validate(layout: Self.ansi) == .reserved("⌘W"))
        #expect(HotKey(keyCode: 0x04, modifiers: [.command]).validate(layout: Self.ansi) == .reserved("⌘H"))
        #expect(HotKey(keyCode: 0x2E, modifiers: [.command]).validate(layout: Self.ansi) == .reserved("⌘M"))
        // AZERTY : « w » est au code 0x06, « m » au 0x29 ; 0x0D porte « z », 0x2E la virgule.
        #expect(HotKey(keyCode: 0x06, modifiers: [.command]).validate(layout: Self.azerty) == .reserved("⌘W"))
        #expect(HotKey(keyCode: 0x29, modifiers: [.command]).validate(layout: Self.azerty) == .reserved("⌘M"))
        #expect(HotKey(keyCode: 0x0D, modifiers: [.command]).validate(layout: Self.azerty) == .valid)
        #expect(HotKey(keyCode: 0x2E, modifiers: [.command]).validate(layout: Self.azerty) == .valid)
        // Avec un autre modificateur en plus : pas réservé.
        #expect(HotKey(keyCode: 0x0D, modifiers: [.command, .option]).validate(layout: Self.ansi) == .valid)
        #expect(HotKey(keyCode: 0x0C, modifiers: [.command, .shift]).validate(layout: Self.ansi) == .valid)
    }

    @Test func commandShiftTabIsReservedByKeyCode() {
        #expect(
            HotKey(keyCode: 0x30, modifiers: [.command, .shift]).validate(layout: Self.ansi)
                == .reserved("⇧⌘Tab"))
        // Le code, pas le caractère : même résultat quelle que soit la disposition.
        #expect(
            HotKey(keyCode: 0x30, modifiers: [.command, .shift]).validate(layout: Self.azerty)
                == .reserved("⇧⌘Tab"))
        #expect(HotKey(keyCode: 0x30, modifiers: [.command, .option]).validate(layout: Self.ansi) == .valid)
    }

    @Test func shiftAloneOrOptionAloneOnATypingKeyNeedsAModifier() {
        // Ces combinaisons tapent un caractère : les prendre casserait la saisie.
        for code: UInt32 in [0x00, 0x12, 0x31, 0x24, 0x7B, 0x18] {
            #expect(HotKey(keyCode: code, modifiers: [.shift]).validate(layout: Self.ansi) == .needsModifier)
            #expect(HotKey(keyCode: code, modifiers: [.option]).validate(layout: Self.ansi) == .needsModifier)
        }
    }

    @Test func shiftAloneOrOptionAloneIsFineOnAFunctionKey() {
        // F1 à F12, puis F13 à F20 (0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A).
        let codes: [UInt32] = [
            0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
            0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
        ]
        for code in codes {
            #expect(HotKey(keyCode: code, modifiers: [.shift]).validate(layout: Self.ansi) == .valid)
            #expect(HotKey(keyCode: code, modifiers: [.option]).validate(layout: Self.ansi) == .valid)
        }
    }

    @Test func strongOrCombinedModifiersOnATypingKeyStayValid() {
        #expect(HotKey(keyCode: 0x00, modifiers: [.control]).validate(layout: Self.ansi) == .valid)
        #expect(HotKey(keyCode: 0x00, modifiers: [.command]).validate(layout: Self.ansi) == .valid)
        #expect(HotKey(keyCode: 0x00, modifiers: [.shift, .option]).validate(layout: Self.ansi) == .valid)
        #expect(HotKey(keyCode: 0x00, modifiers: [.shift, .control]).validate(layout: Self.ansi) == .valid)
    }

    @Test func unknownModifierBitsAreRejected() {
        // Un fichier de réglages écrit à la main peut porter un bit que Carbon ne connaît pas.
        let unknown = Modifiers(rawValue: 1 << 10)
        #expect(
            HotKey(keyCode: 0x00, modifiers: [.control, unknown]).validate(layout: Self.ansi)
                == .needsModifier)
        #expect(HotKey(keyCode: 0x00, modifiers: unknown).validate(layout: Self.ansi) == .needsModifier)
        #expect(
            HotKey(keyCode: 0x7A, modifiers: [.command, Modifiers(rawValue: 1)])
                .validate(layout: Self.ansi) == .needsModifier)
        // Les quatre bits connus, ensemble, restent acceptables.
        #expect(
            HotKey(keyCode: 0x00, modifiers: [.control, .option, .shift, .command])
                .validate(layout: Self.ansi) == .valid)
    }

    @MainActor @Test func centerValidatesWithItsOwnLayout() {
        let command0 = HotKey(keyCode: 0x00, modifiers: [.command])
        let ansiCenter = HotKeyCenter(registrar: FakeRegistrar(), layout: Self.ansi)
        #expect(Self.failure(ansiCenter.apply(command0) {}) == nil)
        let registrar = FakeRegistrar()
        let azertyCenter = HotKeyCenter(registrar: registrar, layout: Self.azerty)
        #expect(Self.failure(azertyCenter.apply(command0) {}) == .invalid(.reserved("⌘Q")))
        #expect(registrar.registerCalls == 0)
    }

    @Test func hotKeyRoundTripsThroughJSON() throws {
        let samples = [
            HotKey.standard,
            HotKey(keyCode: 0x7A, modifiers: [.command, .shift, .option, .control]),
            HotKey(keyCode: 0x00, modifiers: [.command]),
        ]
        for original in samples {
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(HotKey.self, from: data) == original)
        }
        // Et un fichier écrit à la main dans le format figé se relit tel quel.
        let fromFile = try JSONDecoder().decode(
            HotKey.self, from: Data(#"{"keyCode":49,"modifiers":6144}"#.utf8))
        #expect(fromFile == .standard)
    }

    // MARK: - Centre de raccourci

    @MainActor
    final class FakeRegistrar: HotKeyRegistrar {
        /// Contrat : un seul emplacement ; `register` remplace ce qui s'y trouve ; un refus
        /// ne laisse rien d'enregistré.
        var registered: HotKey?
        var onPress: (@MainActor () -> Void)?
        var refused: [HotKey] = []
        /// Imite un système qui refuse une combinaison tant que l'emplacement est occupé.
        var refusesWhileOccupied = false
        var registerCalls = 0
        var unregisterCalls = 0

        func register(_ hotKey: HotKey, onPress: @escaping @MainActor () -> Void) -> Bool {
            registerCalls += 1
            if refusesWhileOccupied, registered != nil { return false }
            registered = nil
            self.onPress = nil
            if refused.contains(hotKey) { return false }
            registered = hotKey
            self.onPress = onPress
            return true
        }

        func unregister() {
            unregisterCalls += 1
            registered = nil
            onPress = nil
        }

        /// Appui simulé sur la combinaison enregistrée, s'il y en a une.
        func press() { onPress?() }
    }

    /// `Result<Void, _>` n'est pas `Equatable` : on compare l'erreur, `nil` voulant dire succès.
    static func failure(_ result: Result<Void, HotKeyError>) -> HotKeyError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    static let keyA = HotKey(keyCode: 0x00, modifiers: [.control, .option])
    static let keyB = HotKey(keyCode: 0x0B, modifiers: [.control, .option])

    @MainActor @Test func applyRegistersAndRemembers() {
        let registrar = FakeRegistrar()
        let center = HotKeyCenter(registrar: registrar, layout: Self.ansi)
        #expect(center.active == nil)
        var presses = 0
        let result = center.apply(Self.keyA) { presses += 1 }
        #expect(Self.failure(result) == nil)
        #expect(center.active == Self.keyA)
        #expect(registrar.registered == Self.keyA)
        registrar.press()
        #expect(presses == 1)
    }

    @MainActor @Test func failedRegistrationKeepsThePreviousHotKey() {
        let registrar = FakeRegistrar()
        registrar.refused = [Self.keyB]
        let center = HotKeyCenter(registrar: registrar, layout: Self.ansi)
        var pressesA = 0
        var pressesB = 0
        #expect(Self.failure(center.apply(Self.keyA) { pressesA += 1 }) == nil)
        #expect(Self.failure(center.apply(Self.keyB) { pressesB += 1 }) == .taken)
        #expect(center.active == Self.keyA)
        // L'ancien raccourci est de nouveau enregistré, et fonctionne avec son propre rappel.
        #expect(registrar.registered == Self.keyA)
        registrar.press()
        #expect(pressesA == 1)
        #expect(pressesB == 0)
    }

    @MainActor @Test func failedRegistrationWithNothingBeforeLeavesNothingActive() {
        let registrar = FakeRegistrar()
        registrar.refused = [Self.keyB]
        let center = HotKeyCenter(registrar: registrar, layout: Self.ansi)
        #expect(Self.failure(center.apply(Self.keyB) {}) == .taken)
        #expect(center.active == nil)
        #expect(registrar.registered == nil)
    }

    @MainActor @Test func activeNeverNamesAHotKeyThatCouldNotBeRestored() {
        let registrar = FakeRegistrar()
        let center = HotKeyCenter(registrar: registrar, layout: Self.ansi)
        #expect(Self.failure(center.apply(Self.keyA) {}) == nil)
        // Le système refuse désormais tout, y compris de reprendre l'ancien raccourci.
        registrar.refused = [Self.keyA, Self.keyB]
        #expect(Self.failure(center.apply(Self.keyB) {}) == .taken)
        #expect(registrar.registered == nil)
        #expect(center.active == nil)
    }

    @MainActor @Test func applyingAgainReplacesTheCallback() {
        let registrar = FakeRegistrar()
        let center = HotKeyCenter(registrar: registrar, layout: Self.ansi)
        var first = 0
        var second = 0
        #expect(Self.failure(center.apply(Self.keyA) { first += 1 }) == nil)
        #expect(Self.failure(center.apply(Self.keyA) { second += 1 }) == nil)
        #expect(center.active == Self.keyA)
        registrar.press()
        #expect(first == 0)
        #expect(second == 1)
    }

    @MainActor @Test func successfulChangeMovesToTheNewHotKeyWithItsCallback() {
        let registrar = FakeRegistrar()
        let center = HotKeyCenter(registrar: registrar, layout: Self.ansi)
        var pressesA = 0
        var pressesB = 0
        #expect(Self.failure(center.apply(Self.keyA) { pressesA += 1 }) == nil)
        #expect(Self.failure(center.apply(Self.keyB) { pressesB += 1 }) == nil)
        #expect(center.active == Self.keyB)
        #expect(registrar.registered == Self.keyB)
        registrar.press()
        #expect(pressesA == 0)
        #expect(pressesB == 1)
    }

    @MainActor @Test func theOldHotKeyIsReleasedBeforeTheNewOneIsTried() {
        let registrar = FakeRegistrar()
        registrar.refusesWhileOccupied = true
        registrar.refused = [Self.keyB]
        let center = HotKeyCenter(registrar: registrar, layout: Self.ansi)
        var presses = 0
        #expect(Self.failure(center.apply(Self.keyA) { presses += 1 }) == nil)
        // Même combinaison redemandée : acceptée seulement si l'ancienne a été libérée d'abord.
        #expect(Self.failure(center.apply(Self.keyA) { presses += 10 }) == nil)
        // Refus du nouveau : l'ancien est repris, ce qui exige aussi un emplacement libre.
        #expect(Self.failure(center.apply(Self.keyB) {}) == .taken)
        #expect(center.active == Self.keyA)
        #expect(registrar.registered == Self.keyA)
        registrar.press()
        #expect(presses == 10)
    }

    @MainActor @Test func invalidHotKeyNeverReachesTheRegistrar() {
        let registrar = FakeRegistrar()
        let center = HotKeyCenter(registrar: registrar, layout: Self.ansi)
        let invalid = HotKey(keyCode: 0x00, modifiers: [])
        #expect(Self.failure(center.apply(invalid) {}) == .invalid(.needsModifier))
        let reserved = HotKey(keyCode: 0x0C, modifiers: [.command])
        #expect(Self.failure(center.apply(reserved) {}) == .invalid(.reserved("⌘Q")))
        #expect(registrar.registerCalls == 0)
        #expect(registrar.unregisterCalls == 0)
        #expect(center.active == nil)

        // Un raccourci déjà actif n'est pas touché par une demande invalide.
        var presses = 0
        #expect(Self.failure(center.apply(Self.keyA) { presses += 1 }) == nil)
        let callsBefore = (registrar.registerCalls, registrar.unregisterCalls)
        #expect(Self.failure(center.apply(invalid) {}) == .invalid(.needsModifier))
        #expect(registrar.registerCalls == callsBefore.0)
        #expect(registrar.unregisterCalls == callsBefore.1)
        #expect(center.active == Self.keyA)
        registrar.press()
        #expect(presses == 1)
    }

    // MARK: - Suspension

    @MainActor @Test func suspendUnregistersAndResumeRegistersTheSameHotKeyWithItsCallback() {
        let registrar = FakeRegistrar()
        let center = HotKeyCenter(registrar: registrar, layout: Self.ansi)
        var presses = 0
        _ = center.apply(Self.keyA, onPress: { presses += 1 })

        center.suspend()
        #expect(registrar.registered == nil)
        #expect(center.active == Self.keyA)
        #expect(center.isSuspended)

        center.resume()
        #expect(registrar.registered == Self.keyA)
        #expect(!center.isSuspended)
        registrar.press()
        #expect(presses == 1)

        // Hors suspension, `resume` ne touche à rien.
        let calls = registrar.registerCalls
        center.resume()
        #expect(registrar.registerCalls == calls)
    }

    @MainActor @Test func applyWhileSuspendedEndsTheSuspension() {
        let registrar = FakeRegistrar()
        let center = HotKeyCenter(registrar: registrar, layout: Self.ansi)
        _ = center.apply(Self.keyA, onPress: {})
        center.suspend()

        registrar.refused = [Self.keyB]
        #expect(Self.failure(center.apply(Self.keyB, onPress: {})) == .taken)
        #expect(registrar.registered == Self.keyA)
        #expect(!center.isSuspended)
    }

    @MainActor @Test func resumeThatTheSystemRefusesLeavesNoActiveHotKey() {
        let registrar = FakeRegistrar()
        let center = HotKeyCenter(registrar: registrar, layout: Self.ansi)
        _ = center.apply(Self.keyA, onPress: {})
        center.suspend()
        registrar.refused = [Self.keyA]

        #expect(!center.resume())
        #expect(center.active == nil)
    }

    @MainActor @Test func clearLeavesNothingRegistered() {
        let registrar = FakeRegistrar()
        let center = HotKeyCenter(registrar: registrar, layout: Self.ansi)
        _ = center.apply(Self.keyA, onPress: {})
        center.clear()
        #expect(registrar.registered == nil)
        #expect(center.active == nil)
        center.resume()
        #expect(registrar.registered == nil)
    }
}
