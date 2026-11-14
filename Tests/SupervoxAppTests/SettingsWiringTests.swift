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
    let escape = HotKeyTests.FakeRegistrar()
    let surface = FakePanelSurface()
    let clicks = FakeClickMonitor()

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
            escapeRegistrar: escape,
            permissionsProbe: FakePermissionsProbe(microphone: .granted, accessibility: .granted),
            systemHotKeys: FakeSystemHotKeys(), settingsView: settingsView, makePanelSurface: { [surface] _ in surface }, clickMonitor: clicks)
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
        #expect(HotKeyTests.failure(controller.changeHotKey(HotKeyTests.keyA)) == .refused)
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

        // La présence des clés peut être demandée (sans les lire) ; aucune clé n'est lue.
        #expect(secrets.readCount == 0)
        #expect(secrets.calls.allSatisfy { $0.name == "contains" })

        // La feuille d'édition d'un fournisseur existant non plus.
        let editor = NSHostingView(
            rootView: ProviderEditor(model: SettingsView.makeProvidersModel(controller), existing: provider))
        editor.frame = NSRect(x: 0, y: 0, width: 460, height: 400)
        editor.layoutSubtreeIfNeeded()
        _ = editor.fittingSize
        #expect(secrets.readCount == 0)
        #expect(secrets.calls.allSatisfy { $0.name == "contains" })
    }

    /// Pendant la capture d'un raccourci : le raccourci global et Échap sont rendus au système, puis
    /// le raccourci est réenregistré à la fin de la capture.
    @Test func recordingAHotKeySuspendsTheGlobalHotKeyAndEscape() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        controller.applyHotKeyAtLaunch()
        registrar.press()
        #expect(controller.panelModel.isOpen)
        #expect(escape.registered != nil)

        let model = SettingsView.makeHotKeyModel(controller, layout: HotKeyTests.ansi)
        model.startRecording()
        #expect(registrar.registered == nil)
        #expect(escape.registered == nil)
        #expect(!controller.panelModel.isOpen)

        model.cancelRecording()
        #expect(registrar.registered == .standard)
        registrar.press()
        #expect(controller.panelModel.isOpen)
        registrar.press()

        model.startRecording()
        model.record(HotKeyTests.keyB)
        #expect(registrar.registered == HotKeyTests.keyB)
        #expect(store.load().settings.hotKey == HotKeyTests.keyB)
        registrar.press()
        #expect(controller.panelModel.isOpen)
    }

    @Test func mainMenuGivesTheEditingShortcutsCloseAndQuit() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var quits = 0
        let menu = MainMenu.make(quit: { quits += 1 })
        let items = menu.items.flatMap { $0.submenu?.items ?? [] }
        let byShortcut = Dictionary(
            uniqueKeysWithValues: items.filter { !$0.keyEquivalent.isEmpty }
                .map { ("\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)", $0) })
        func item(_ key: String, _ mask: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
            byShortcut["\(mask.rawValue)-\(key)"]
        }
        #expect(item("x")?.action == #selector(NSText.cut(_:)))
        #expect(item("c")?.action == #selector(NSText.copy(_:)))
        #expect(item("v")?.action == #selector(NSText.paste(_:)))
        #expect(item("a")?.action == #selector(NSText.selectAll(_:)))
        #expect(item("z")?.action == Selector(("undo:")))
        #expect(item("z", [.command, .shift])?.action == Selector(("redo:")))
        #expect(item("w")?.action == #selector(NSWindow.performClose(_:)))
        // Cible nil : l'action va au premier répondeur, le champ de texte qui a la frappe.
        #expect(["x", "c", "v", "a", "z", "w"].allSatisfy { item($0)?.target == nil })

        // ⌘Q passe par le contrôleur (qui ferme le panneau), pas directement par `terminate`.
        let quit = try #require(item("q"))
        let target = try #require(quit.target as? NSObject)
        target.perform(quit.action!, with: quit)
        #expect(quits == 1)
    }

    /// Chaque permission refusée offre son propre panneau ; une permission accordée ou pas encore
    /// demandée n'en offre aucun.
    @Test func eachDeniedPermissionOpensItsOwnPane() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = FakePermissionsProbe(microphone: .denied, accessibility: .denied)
        let permissions = PermissionsModel(probe: probe)
        var opened: [SystemSettingsPane] = []
        let open: @MainActor (SystemSettingsPane) -> Void = { opened.append($0) }

        let rows = PermissionRow.rows(for: permissions, open: open)
        try #require(rows.count == 2)
        #expect(rows.map(\.title) == ["Micro", "Accessibilité"])
        #expect(rows.map(\.state) == [.denied, .denied])
        for row in rows {
            let open = try #require(row.openSystemSettings)
            open()
        }
        #expect(opened == [.microphone, .accessibility])

        probe.set(microphone: .notDetermined, accessibility: .granted)
        permissions.refresh()
        #expect(PermissionRow.rows(for: permissions, open: open).allSatisfy { $0.openSystemSettings == nil })
        probe.set(microphone: .granted, accessibility: .denied)
        permissions.refresh()
        let mixed = PermissionRow.rows(for: permissions, open: open)
        try #require(mixed.count == 2)
        #expect(mixed[0].openSystemSettings == nil)
        let openAccessibility = try #require(mixed[1].openSystemSettings)
        openAccessibility()
        #expect(opened.last == .accessibility)
    }

    @Test func systemSettingsPanesHaveDistinctPrivacyAnchors() {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SystemSettingsPane.microphone.url.absoluteString.hasSuffix("?Privacy_Microphone"))
        #expect(SystemSettingsPane.accessibility.url.absoluteString.hasSuffix("?Privacy_Accessibility"))
        #expect(SystemSettingsPane.microphone.url.scheme == "x-apple.systempreferences")
    }
}
