import Foundation
import Testing

@testable import SupervoxApp

/// Le câblage d'`AppController`, par son `init` injectable : réglages dans un dossier temporaire,
/// enregistreurs doubles, sonde de permissions double, surface et moniteur de clics doubles.
/// Aucun élément de barre de menus, aucune fenêtre à l'écran (`start()` n'est jamais appelé).
@MainActor @Suite struct AppControllerTests {
    let directory: URL
    let store: SettingsStore
    let hotKeys = HotKeyTests.FakeRegistrar()
    let escape = HotKeyTests.FakeRegistrar()
    let probe = FakePermissionsProbe(microphone: .granted, accessibility: .granted)
    let surface = FakePanelSurface()
    let clicks = FakeClickMonitor()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervox-app-controller-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
    }

    func makeController() -> AppController {
        AppController(
            settingsStore: store, secrets: InMemorySecretStore(), hotKeyRegistrar: hotKeys,
            escapeRegistrar: escape, permissionsProbe: probe,
            makePanelSurface: { [surface] _ in surface }, clickMonitor: clicks)
    }

    func corruptTheSettingsFile() throws {
        try Data("pas du json".utf8).write(to: store.file)
    }

    @Test func openingThePanelRereadsThePermissions() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        controller.applyHotKeyAtLaunch()

        hotKeys.press()
        #expect(controller.panelModel.isOpen)
        #expect(controller.permissions.accessibility == .granted)
        hotKeys.press()

        // Retirée pendant que le panneau est fermé : la prochaine ouverture la voit.
        probe.set(accessibility: .denied)
        hotKeys.press()
        #expect(controller.permissions.accessibility == .denied)
        hotKeys.press()

        probe.set(accessibility: .granted)
        hotKeys.press()
        #expect(controller.permissions.accessibility == .granted)
    }

    @Test func choosingAModeSavesIt() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()

        controller.panelModel.select("entretien")
        #expect(store.load().settings.lastModeID == "entretien")
        #expect(controller.settings.lastModeID == "entretien")
    }

    @Test func failedSaveIsAnnouncedAndASuccessfulOneClearsIt() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        // Devenu illisible après le chargement : `save` refuse de l'écraser.
        try corruptTheSettingsFile()

        controller.panelModel.select("prompt")
        let notice = try #require(controller.panelModel.notices[.save])
        #expect(notice.contains("settings.json"))

        // La cause disparaît : la sauvegarde suivante réussit et efface l'avis.
        try FileManager.default.removeItem(at: store.file)
        controller.panelModel.select("entretien")
        #expect(controller.panelModel.notices[.save] == nil)
        #expect(store.load().settings.lastModeID == "entretien")
    }

    @Test func refusedHotKeyAtLaunchOpensThePanelWithANotice() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        hotKeys.refused = [.standard]
        let controller = makeController()

        controller.applyHotKeyAtLaunch()
        #expect(controller.panelModel.isOpen)
        #expect(surface.isShown)
        let notice = try #require(controller.panelModel.notices[.hotKey])
        #expect(notice.contains(HotKey.standard.label))
        #expect(controller.panelModel.hotKeyLabel == nil)
    }

    @Test func acceptedHotKeyAtLaunchLeavesThePanelClosed() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()

        controller.applyHotKeyAtLaunch()
        #expect(!controller.panelModel.isOpen)
        #expect(!surface.isShown)
        #expect(controller.panelModel.notices.isEmpty)
        #expect(controller.panelModel.hotKeyLabel == HotKey.standard.label)
    }

    @Test func acceptedHotKeyClearsOnlyTheHotKeyNotice() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // Fichier illisible au chargement : avis de chargement.
        try corruptTheSettingsFile()
        hotKeys.refused = [.standard]
        let controller = makeController()
        let loadNotice = try #require(controller.panelModel.notices[.settingsLoad])

        controller.applyHotKeyAtLaunch()
        #expect(controller.panelModel.notices[.hotKey] != nil)
        // Le second avis n'écrase pas le premier.
        #expect(controller.panelModel.notices[.settingsLoad] == loadNotice)

        #expect(HotKeyTests.failure(controller.changeHotKey(HotKeyTests.keyB)) == nil)
        #expect(controller.panelModel.notices[.hotKey] == nil)
        #expect(controller.panelModel.notices[.settingsLoad] == loadNotice)
    }

    @Test func saveNoticeAndHotKeyNoticeDoNotOverwriteEachOther() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        hotKeys.refused = [.standard]
        let controller = makeController()
        controller.applyHotKeyAtLaunch()
        let hotKeyNotice = try #require(controller.panelModel.notices[.hotKey])

        try corruptTheSettingsFile()
        controller.panelModel.select("prompt")
        #expect(controller.panelModel.notices[.save] != nil)
        #expect(controller.panelModel.notices[.hotKey] == hotKeyNotice)

        try FileManager.default.removeItem(at: store.file)
        controller.panelModel.select("entretien")
        #expect(controller.panelModel.notices[.save] == nil)
        #expect(controller.panelModel.notices[.hotKey] == hotKeyNotice)
    }

    @Test func statusMenuEntryTogglesThePanel() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        #expect(controller.panelMenuTitle == "Ouvrir le panneau")

        controller.togglePanelFromMenu()
        #expect(controller.panelModel.isOpen)
        #expect(controller.panelMenuTitle == "Fermer le panneau")

        controller.togglePanelFromMenu()
        #expect(!controller.panelModel.isOpen)
        #expect(!surface.isShown)
        #expect(controller.panelMenuTitle == "Ouvrir le panneau")
    }
}
