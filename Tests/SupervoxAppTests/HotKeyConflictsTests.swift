import Carbon.HIToolbox
import Testing

@testable import SupervoxApp

/// Les refus d'une combinaison pour le raccourci global ou pour un mode : mêmes règles, mêmes phrases que la fenêtre de
/// réglages (`HotKeySettingsModel`), et une phrase qui nomme le détenteur d'une combinaison déjà prise.
@MainActor @Suite struct HotKeyConflictsTests {
    static let layout = HotKeyTests.ansi
    static let keyA = HotKeyTests.keyA
    static let keyB = HotKeyTests.keyB
    static let keyC = HotKey(keyCode: 0x08, modifiers: [.control, .option])
    static let names = ["perso-un": "Compte rendu", "perso-deux": "Courriel"]

    func refusal(
        _ candidate: HotKey, owner: HotKeyOwner, global: HotKey? = keyA,
        modes: [String: HotKey] = ["perso-un": keyB], system: [HotKey] = []
    ) -> String? {
        HotKeyConflicts.refusal(
            for: candidate, owner: owner, global: global, modes: modes, names: Self.names, systemEnabled: system,
            layout: Self.layout)
    }

    @Test func aFreeCombinationIsNotRefused() {
        #expect(refusal(Self.keyC, owner: .mode("perso-deux")) == nil)
        #expect(refusal(Self.keyC, owner: .global) == nil)
    }

    @Test func theGlobalHotKeyCombinationIsRefusedToAModeAndSaysSo() throws {
        let sentence = try #require(refusal(Self.keyA, owner: .mode("perso-deux")))
        #expect(sentence.contains("⌃⌥A"))
        #expect(sentence.contains("global"))
    }

    @Test func anotherModesCombinationIsRefusedAndNamesItsHolder() throws {
        let sentence = try #require(refusal(Self.keyB, owner: .mode("perso-deux")))
        #expect(sentence.contains("⌃⌥B"))
        #expect(sentence.contains("Compte rendu"))
        // Le global la refuse de même, avec le même détenteur.
        let forGlobal = try #require(refusal(Self.keyB, owner: .global))
        #expect(forGlobal.contains("Compte rendu"))
    }

    @Test func theSameCombinationGivenBackToTheSameOwnerIsNotAConflict() {
        #expect(refusal(Self.keyB, owner: .mode("perso-un")) == nil)
        #expect(refusal(Self.keyA, owner: .global) == nil)
    }

    @Test func aModeNeverTakesTheNameOfItself() throws {
        // Deux modes : l'autre seul est nommé.
        let sentence = try #require(
            refusal(Self.keyB, owner: .mode("perso-deux"), modes: ["perso-un": Self.keyB, "perso-deux": Self.keyC]))
        #expect(sentence.contains("Compte rendu"))
        #expect(!sentence.contains("Courriel"))
    }

    @Test func anEnabledSystemShortcutIsRefusedWithTheSettingsSentence() throws {
        let sentence = try #require(refusal(Self.keyC, owner: .mode("perso-deux"), system: [Self.keyC]))
        // Mot pour mot ce que la fenêtre de réglages dit pour la même combinaison.
        let registrar = HotKeyTests.FakeRegistrar()
        let center = HotKeyCenter(registrar: registrar, layout: Self.layout)
        _ = center.apply(Self.keyA, onPress: {})
        let model = HotKeySettingsModel(
            hotKey: Self.keyA, active: center.active, behavior: .toggle, layout: Self.layout,
            systemHotKeys: FakeSystemHotKeys([Self.keyC]), keyMonitor: FakeKeyMonitor(),
            control: GlobalHotKeyControl(
                apply: { center.apply($0, onPress: {}) }, suspend: {}, resume: { true }, clear: {}, taken: { _ in nil }),
            save: { _, _ in })
        model.record(Self.keyC)
        #expect(sentence == model.message)
        #expect(sentence.contains("raccourci de macOS"))
    }

    @Test func aMissingNameStillRefusesWithoutInventingOne() throws {
        let sentence = HotKeyConflicts.refusal(
            for: Self.keyB, owner: .global, global: Self.keyA, modes: ["inconnu": Self.keyB], names: [:],
            systemEnabled: [], layout: Self.layout)
        #expect(try #require(sentence).contains("⌃⌥B"))
    }

    // MARK: - Les mêmes phrases que la fenêtre de réglages

    /// Chaque refus d'une combinaison invalide ou réservée est mot pour mot celui de `HotKeySettingsModel`, Échap compris.
    @Test(arguments: [
        HotKey(keyCode: 0x00, modifiers: []),
        HotKey(keyCode: UInt32(kVK_Escape), modifiers: []),
        HotKey(keyCode: 0x0C, modifiers: [.command]),
        HotKey(keyCode: UInt32(kVK_Command), modifiers: [.control]),
        HotKey(keyCode: UInt32(kVK_Space), modifiers: [.command]),
    ])
    func invalidOrReservedCombinationsGetTheSettingsSentences(candidate: HotKey) throws {
        let registrar = HotKeyTests.FakeRegistrar()
        let center = HotKeyCenter(registrar: registrar, layout: Self.layout)
        _ = center.apply(Self.keyA, onPress: {})
        let model = HotKeySettingsModel(
            hotKey: Self.keyA, active: center.active, behavior: .toggle, layout: Self.layout,
            systemHotKeys: FakeSystemHotKeys(), keyMonitor: FakeKeyMonitor(),
            control: GlobalHotKeyControl(
                apply: { center.apply($0, onPress: {}) }, suspend: {}, resume: { true }, clear: {}, taken: { _ in nil }),
            save: { _, _ in })
        model.record(candidate)
        let expected = try #require(model.message)
        #expect(refusal(candidate, owner: .mode("perso-deux")) == expected)
        #expect(refusal(candidate, owner: .global) == expected)
    }

    @Test func escapeAloneIsRefusedWhoeverAsks() throws {
        let escape = HotKey(keyCode: UInt32(kVK_Escape), modifiers: [])
        let sentence = try #require(refusal(escape, owner: .mode("perso-deux")))
        #expect(sentence.contains("Échap"))
    }

    @Test func aCombinationThatIsInvalidIsRefusedBeforeAnyHolderIsLookedFor() throws {
        // ⌘Q est réservé : la phrase est celle du système, même si un mode la tenait (fichier écrit à la main).
        let reserved = HotKey(keyCode: 0x0C, modifiers: [.command])
        let sentence = try #require(refusal(reserved, owner: .mode("perso-deux"), modes: ["perso-un": reserved]))
        #expect(sentence.contains("réservé"))
        #expect(!sentence.contains("Compte rendu"))
    }

    /// Le refus du système est dit par la table, pour la fenêtre du raccourci global comme pour l'onglet des modes.
    @Test func theSystemRefusalHasOneSentenceInTheTable() {
        #expect(
            HotKeyConflicts.refusedBySystem(label: "⌃⌥B")
                == "⌃⌥B a été refusé par macOS : il est sans doute déjà pris par une autre application. Choisissez-en un autre.")
    }
}
