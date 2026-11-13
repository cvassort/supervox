import AppKit
import Testing

@testable import SupervoxApp

@MainActor @Suite struct HotKeySettingsModelTests {
    typealias FakeRegistrar = HotKeyTests.FakeRegistrar

    let registrar = FakeRegistrar()
    let center: HotKeyCenter
    var saved: [(HotKey, HotKeyBehavior)] { saves.values }
    let saves = SaveLog()

    @MainActor final class SaveLog {
        var values: [(HotKey, HotKeyBehavior)] = []
        var failure: (any Error)?
    }

    static let keyA = HotKeyTests.keyA  // ⌃⌥ + code 0x00
    static let keyB = HotKeyTests.keyB  // ⌃⌥ + code 0x0B

    init() {
        center = HotKeyCenter(registrar: registrar, layout: HotKeyTests.ansi)
    }

    /// Modèle branché sur un vrai `HotKeyCenter` (enregistreur double), comme dans l'application.
    func makeModel(
        hotKey: HotKey = keyA, behavior: HotKeyBehavior = .toggle,
        layout: any KeyboardLayout = HotKeyTests.ansi, registerFirst: Bool = true
    ) -> HotKeySettingsModel {
        if registerFirst { _ = center.apply(hotKey, onPress: {}) }
        let center = center
        let saves = saves
        return HotKeySettingsModel(
            hotKey: hotKey, active: center.active, behavior: behavior, layout: layout,
            apply: { center.apply($0, onPress: {}) },
            save: { hotKey, behavior in
                if let failure = saves.failure { throw failure }
                saves.values.append((hotKey, behavior))
            })
    }

    @Test func recordingAValidCombinationAppliesAndSavesIt() {
        let model = makeModel()
        model.startRecording()
        model.record(Self.keyB)

        #expect(model.hotKey == Self.keyB)
        #expect(registrar.registered == Self.keyB)
        #expect(saved.map(\.0) == [Self.keyB])
        #expect(saved.map(\.1) == [.toggle])
        #expect(model.message == nil)
        #expect(!model.isRecording)
    }

    @Test func takenCombinationKeepsThePreviousOneActiveAndSaysWhy() {
        registrar.refused = [Self.keyB]
        let model = makeModel()
        model.record(Self.keyB)

        #expect(model.hotKey == Self.keyA)
        #expect(registrar.registered == Self.keyA)
        #expect(saved.isEmpty)
        #expect(model.message?.contains("déjà pris") == true)
        #expect(model.message?.contains("⌃⌥B") == true)
    }

    @Test func reservedCombinationIsRefusedWithoutTouchingTheSystem() {
        let model = makeModel()
        let callsBefore = registrar.registerCalls
        model.record(HotKey(keyCode: 0x0C, modifiers: [.command]))  // ⌘Q en ANSI

        #expect(registrar.registerCalls == callsBefore)
        #expect(registrar.registered == Self.keyA)
        #expect(model.hotKey == Self.keyA)
        #expect(saved.isEmpty)
        #expect(model.message?.contains("⌘Q") == true)
        #expect(model.message?.contains("réservé") == true)
    }

    @Test func combinationWithoutModifierIsRefusedAndSaysWhy() {
        let model = makeModel()
        model.record(HotKey(keyCode: 0x00, modifiers: []))
        #expect(model.hotKey == Self.keyA)
        #expect(registrar.registered == Self.keyA)
        #expect(saved.isEmpty)
        #expect(model.message?.contains("Ajoutez") == true)
    }

    @Test func refusalMessagesDiffer() {
        let model = makeModel()
        model.record(HotKey(keyCode: 0x00, modifiers: []))
        let needsModifier = model.message
        model.record(HotKey(keyCode: 0x0C, modifiers: [.command]))
        let reserved = model.message
        registrar.refused = [Self.keyB]
        model.record(Self.keyB)
        let taken = model.message
        #expect(Set([needsModifier, reserved, taken].compactMap { $0 }).count == 3)
    }

    @Test func labelFollowsTheKeyboardLayout() {
        // Code 0x0C : « Q » en ANSI, « A » en AZERTY.
        let hotKey = HotKey(keyCode: 0x0C, modifiers: [.control, .option])
        #expect(makeModel(hotKey: hotKey, layout: HotKeyTests.ansi).label == "⌃⌥Q")
        #expect(makeModel(hotKey: hotKey, layout: HotKeyTests.azerty).label == "⌃⌥A")
    }

    @Test func failedSaveRestoresThePreviousHotKey() {
        let model = makeModel()
        saves.failure = SettingsError.unreadableFileKept(fileName: "settings.json")
        model.record(Self.keyB)

        #expect(model.hotKey == Self.keyA)
        #expect(registrar.registered == Self.keyA)
        #expect(center.active == Self.keyA)
        #expect(model.message?.contains("settings.json") == true)
    }

    @Test func inactiveSavedHotKeyIsSignalled() {
        let model = makeModel(registerFirst: false)
        #expect(model.message?.contains("pas actif") == true)
        model.record(Self.keyB)
        #expect(model.message == nil)
    }

    @Test func holdBehaviorIsNotYetAvailable() {
        let model = makeModel()
        #expect(!HotKeySettingsModel.isAvailable(.hold))
        #expect(HotKeySettingsModel.isAvailable(.toggle))
        model.setBehavior(.hold)
        #expect(model.behavior == .toggle)
        #expect(saved.isEmpty)
    }

    @Test func switchingBackToToggleIsSaved() {
        let model = makeModel(behavior: .hold)
        model.setBehavior(.toggle)
        #expect(model.behavior == .toggle)
        #expect(saved.map(\.1) == [.toggle])
        #expect(saved.map(\.0) == [Self.keyA])
    }

    // MARK: - Capture

    @Test func escapeWithoutModifierCancelsRecording() {
        let model = makeModel()
        model.startRecording()
        model.keyDown(keyCode: 0x35, flags: [])
        #expect(!model.isRecording)
        // Annulée, pas refusée : Échap seul proposé comme raccourci donnerait « Ajoutez ⌃ ou ⌘ ».
        #expect(model.message == nil)
        #expect(model.hotKey == Self.keyA)
        #expect(saved.isEmpty)
    }

    @Test func keyDownWhileRecordingRecordsTheCombination() {
        let model = makeModel()
        model.keyDown(keyCode: 0x0B, flags: [.control, .option])
        #expect(model.hotKey == Self.keyA)  // pas en capture : ignoré

        model.startRecording()
        model.keyDown(keyCode: 0x0B, flags: [.control, .option])
        #expect(model.hotKey == Self.keyB)
    }

    @Test func eventFlagsBecomeCarbonModifiersIgnoringTheOthers() {
        let all: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .capsLock, .function, .numericPad, .help]
        let hotKey = HotKeySettingsModel.hotKey(keyCode: 0x7A, flags: all)
        #expect(hotKey == HotKey(keyCode: 0x7A, modifiers: [.command, .shift, .option, .control]))
        #expect(HotKeySettingsModel.hotKey(keyCode: 0x31, flags: [.control]).modifiers == [.control])
        #expect(HotKeySettingsModel.hotKey(keyCode: 0x31, flags: [.capsLock, .function]).modifiers == [])
    }
}
