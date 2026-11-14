import AppKit
import Testing

@testable import SupervoxApp

@MainActor @Suite struct HotKeySettingsModelTests {
    typealias FakeRegistrar = HotKeyTests.FakeRegistrar

    let registrar = FakeRegistrar()
    let system = FakeSystemHotKeys()
    let monitor = FakeKeyMonitor()
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
            hotKey: hotKey, active: center.active, behavior: behavior, layout: layout, systemHotKeys: system,
            keyMonitor: monitor,
            control: GlobalHotKeyControl(
                apply: { center.apply($0, onPress: {}) }, suspend: { center.suspend() },
                resume: { center.resume() }, clear: { center.clear() }),
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
        #expect(model.message?.contains("refusé par macOS") == true)
        #expect(model.message?.contains("⌃⌥B") == true)
    }

    // MARK: - Raccourcis du système

    /// I2 : macOS ne refuse pas une combinaison qu'un de ses propres raccourcis utilise ; la fenêtre la refuse avant
    /// de la proposer, et dit pourquoi.
    @Test func enabledSystemShortcutIsRefusedAndNamed() {
        system.hotKeys = [Self.keyB]
        let model = makeModel()
        model.startRecording()
        let callsBefore = registrar.registerCalls
        model.record(Self.keyB)

        #expect(registrar.registerCalls == callsBefore + 1)  // seulement le retour de l'ancien, à la fin de la capture
        #expect(registrar.registered == Self.keyA)
        #expect(model.hotKey == Self.keyA)
        #expect(saved.isEmpty)
        #expect(model.message?.contains("⌃⌥B") == true)
        #expect(model.message?.contains("raccourci de macOS") == true)
    }

    @Test func onlyTheExactSystemCombinationIsRefused() {
        system.hotKeys = [HotKey(keyCode: 0x0B, modifiers: [.control, .command])]
        let model = makeModel()
        model.record(Self.keyB)
        #expect(model.hotKey == Self.keyB)
        #expect(model.message == nil)
    }

    /// I2 (c) : le raccourci enregistré (le défaut, par exemple) est un raccourci de macOS activé sur ce Mac.
    @Test func savedHotKeyThatIsAnEnabledSystemShortcutIsSignalled() {
        system.hotKeys = [Self.keyA]
        let model = makeModel()
        #expect(model.message?.contains("raccourci de macOS") == true)
        #expect(model.message?.contains("⌃⌥A") == true)

        system.hotKeys = []
        #expect(makeModel().message == nil)
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

    // MARK: - Capture : raccourci global suspendu

    @Test func recordingSuspendsTheGlobalHotKeyAndCancellingRestoresIt() {
        let model = makeModel()
        model.startRecording()
        #expect(registrar.registered == nil)
        #expect(center.active == Self.keyA)

        model.cancelRecording()
        #expect(registrar.registered == Self.keyA)
        #expect(!model.isRecording)
    }

    @Test func refusedCombinationDuringRecordingRestoresThePreviousHotKey() {
        let model = makeModel()
        model.startRecording()
        model.record(HotKey(keyCode: 0x00, modifiers: []))  // sans modificateur : refusé avant le système
        #expect(registrar.registered == Self.keyA)

        model.startRecording()
        registrar.refused = [Self.keyB]
        model.record(Self.keyB)  // déjà pris
        #expect(registrar.registered == Self.keyA)
    }

    /// N1 : le moniteur de touches n'est posé que pendant la capture, et retiré quelle que soit la fin.
    @Test func keyMonitorIsPosedOnlyDuringTheCapture() {
        let model = makeModel()
        #expect(!monitor.isActive)

        model.startRecording()
        #expect(monitor.isActive)
        monitor.send(keyCode: 0x0B, flags: [.control, .option])  // fin par une combinaison acceptée
        #expect(model.hotKey == Self.keyB)
        #expect(!monitor.isActive)

        model.startRecording()
        monitor.send(keyCode: 0x35, flags: [])  // fin par Échap
        #expect(!model.isRecording)
        #expect(!monitor.isActive)

        model.startRecording()
        monitor.send(keyCode: 0x00, flags: [])  // fin par une combinaison refusée
        #expect(model.message != nil)
        #expect(!monitor.isActive)

        model.startRecording()
        model.cancelRecording()  // fin par la fenêtre (onglet changé, fenêtre quittée)
        #expect(!monitor.isActive)
        #expect(monitor.starts == 4)
    }

    /// N1 : le raccourci suspendu pendant la capture ne peut pas être réenregistré ; l'onglet le dit.
    @Test func failedRestoreAfterTheCaptureIsSaid() {
        let model = makeModel()
        model.startRecording()
        registrar.refused = [Self.keyA]

        model.cancelRecording()
        #expect(registrar.registered == nil)
        #expect(model.message?.contains("⌃⌥A") == true)
        #expect(model.message?.contains("n'a pas pu être rétabli") == true)
    }

    @Test func escapeWhileRecordingRestoresThePreviousHotKey() {
        let model = makeModel()
        model.startRecording()
        model.keyDown(keyCode: 0x35, flags: [])
        #expect(registrar.registered == Self.keyA)
    }

    /// Le raccourci du fichier n'était pas actif (refusé au lancement), puis l'enregistrement du nouveau échoue :
    /// aucun raccourci actif plutôt qu'un raccourci absent du fichier.
    @Test func failedSaveNeverLeavesAHotKeyThatIsNotInTheFile() {
        registrar.refused = [Self.keyA]
        let model = makeModel()
        #expect(center.active == nil)
        saves.failure = SettingsError.unreadableFileKept(fileName: "settings.json")

        model.record(Self.keyB)

        #expect(model.hotKey == Self.keyA)
        #expect(center.active == nil)
        #expect(registrar.registered == nil)
        #expect(model.message?.contains("Aucun raccourci") == true)
    }

    // MARK: - Options du comportement

    @Test func holdIsListedDisabledAndAnnouncedAsComing() throws {
        let options = HotKeySettingsModel.behaviorOptions
        #expect(options.map(\.behavior) == [.toggle, .hold])
        let hold = try #require(options.first { $0.behavior == .hold })
        #expect(!hold.isEnabled)
        #expect(hold.label.contains("à venir"))
        #expect(options.first { $0.behavior == .toggle }?.isEnabled == true)
    }
}

/// Moniteur de touches double : `send` imite une touche pressée dans l'application pendant que le moniteur est posé.
@MainActor final class FakeKeyMonitor: KeyEventMonitor {
    private var handler: (@MainActor (UInt16, NSEvent.ModifierFlags) -> Void)?
    private(set) var starts = 0
    var isActive: Bool { handler != nil }

    func start(_ handler: @escaping @MainActor (UInt16, NSEvent.ModifierFlags) -> Void) {
        starts += 1
        self.handler = handler
    }

    func stop() { handler = nil }

    func send(keyCode: UInt16, flags: NSEvent.ModifierFlags) { handler?(keyCode, flags) }
}
