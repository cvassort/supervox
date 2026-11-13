import AppKit
import Foundation
import SwiftUI
import Testing

@testable import SupervoxApp

/// Le contrôleur et la fenêtre de réglages : un seul détenteur des réglages, le raccourci réappliqué,
/// et une fenêtre construite sans lire aucune clé.
@MainActor @Suite struct SettingsWiringTests {
    let directory: URL
    let store: SettingsStore
    let secrets = RecordingSecretStore()
    let registrar = HotKeyTests.FakeRegistrar()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervox-settings-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
    }

    func makeController(settingsView: @escaping AppController.SettingsViewProvider = AppController.emptySettings)
        -> AppController
    {
        AppController(
            settingsStore: store, secrets: secrets, hotKeyRegistrar: registrar,
            escapeRegistrar: HotKeyTests.FakeRegistrar(),
            permissionsProbe: FakePermissionsProbe(microphone: .granted, accessibility: .granted),
            settingsView: settingsView)
    }

    /// Changement de mode dans le panneau, puis ajout d'un fournisseur dans la fenêtre : les deux restent.
    @Test func modeChangeThenProviderSaveKeepsBoth() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        let providers = SettingsView.makeProvidersModel(controller)

        controller.panelModel.select("prompt")
        try await providers.add(name: "Local", baseURL: "http://localhost:1", kind: .openAICompatible, key: "")

        let onDisk = store.load().settings
        #expect(onDisk.lastModeID == "prompt")
        #expect(onDisk.providers.map(\.name) == ["Local"])
        #expect(controller.settings == onDisk)
    }

    /// L'inverse : fournisseur, raccourci et comportement enregistrés, puis changement de mode.
    @Test func providerAndHotKeySavesThenModeChangeKeepsAll() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        let providers = SettingsView.makeProvidersModel(controller)
        let hotKey = SettingsView.makeHotKeyModel(controller, layout: HotKeyTests.ansi)

        try await providers.add(name: "Local", baseURL: "http://localhost:1", kind: .openAICompatible, key: "")
        hotKey.record(HotKeyTests.keyB)
        controller.panelModel.select("entretien")

        let onDisk = store.load().settings
        #expect(onDisk.providers.map(\.name) == ["Local"])
        #expect(onDisk.hotKey == HotKeyTests.keyB)
        #expect(onDisk.lastModeID == "entretien")
        #expect(registrar.registered == HotKeyTests.keyB)
        #expect(controller.settings == onDisk)
    }

    @Test func failedSaveLeavesTheSettingsInMemoryUnchanged() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        // Fichier devenu illisible après le chargement : `save` refuse de l'écraser.
        try Data("pas du json".utf8).write(to: store.file)
        let before = controller.settings

        #expect(throws: SettingsError.unreadableFileKept(fileName: "settings.json")) {
            try controller.updateSettings { $0.lastModeID = "prompt" }
        }
        #expect(controller.settings == before)
    }

    @Test func changedHotKeyIsRegisteredAndShownInThePanel() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()

        let result = controller.changeHotKey(HotKeyTests.keyB)
        #expect(HotKeyTests.failure(result) == nil)
        #expect(registrar.registered == HotKeyTests.keyB)
        #expect(controller.panelModel.hotKeyLabel == HotKeyTests.keyB.label)

        registrar.refused = [HotKeyTests.keyA]
        #expect(HotKeyTests.failure(controller.changeHotKey(HotKeyTests.keyA)) == .taken)
        #expect(registrar.registered == HotKeyTests.keyB)
        #expect(controller.panelModel.hotKeyLabel == HotKeyTests.keyB.label)
    }

    @Test func settingsWindowIsBuiltWithoutReadingAnyKey() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = Provider(id: UUID(), name: "Local", baseURL: "http://localhost:1", kind: .openAICompatible, models: ["m"])
        try store.save(AppSettings(version: 1, providers: [provider], hotKey: .standard, hotKeyBehavior: .toggle, lastModeID: "prompt"))
        let controller = makeController(settingsView: SettingsView.provider)

        let view = NSHostingView(rootView: SettingsView.provider(controller))
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        view.layoutSubtreeIfNeeded()
        _ = view.fittingSize

        #expect(secrets.readCount == 0)
        #expect(secrets.calls.isEmpty)
    }

    @Test func mainMenuGivesTheEditingShortcutsAndQuit() throws {
        let menu = MainMenu.make()
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.keyEquivalent, $0) })
        #expect(byKey["x"]?.action == #selector(NSText.cut(_:)))
        #expect(byKey["c"]?.action == #selector(NSText.copy(_:)))
        #expect(byKey["v"]?.action == #selector(NSText.paste(_:)))
        #expect(byKey["a"]?.action == #selector(NSText.selectAll(_:)))
        #expect(byKey["q"]?.action == #selector(NSApplication.terminate(_:)))
        // Cible nil : l'action va au premier répondeur, le champ de texte qui a la frappe.
        #expect(items.allSatisfy { $0.target == nil && $0.keyEquivalentModifierMask == .command })
    }

    @Test func eachDeniedPermissionOpensItsOwnPane() {
        #expect(SystemSettingsPane.microphone.url.absoluteString.hasSuffix("?Privacy_Microphone"))
        #expect(SystemSettingsPane.accessibility.url.absoluteString.hasSuffix("?Privacy_Accessibility"))
        #expect(SystemSettingsPane.microphone.url.scheme == "x-apple.systempreferences")
    }
}
