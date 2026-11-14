import AppKit
import Foundation
import SwiftUI
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
    let system = FakeSystemHotKeys()
    let surface = FakePanelSurface()
    let clicks = FakeClickMonitor()
    let presenter = Presenter()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervox-app-controller-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
    }

    func makeController() -> AppController {
        AppController(
            settingsStore: store, secrets: InMemorySecretStore(), hotKeyRegistrar: hotKeys,
            escapeRegistrar: escape, permissionsProbe: probe, systemHotKeys: system,
            makePanelSurface: { [surface] _ in surface }, clickMonitor: clicks,
            makeSettingsWindow: presenter.make, terminate: presenter.terminate)
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
        #expect(notice.contains("refusé par macOS"))
        #expect(controller.panelModel.hotKeyLabel == nil)
    }

    /// I2 (c) : le raccourci du fichier (ici le défaut, ⌃⌥Espace) est un raccourci de macOS activé sur ce Mac.
    /// Il est quand même enregistré (qui l'emporte n'est pas connu), et le panneau s'ouvre pour le dire.
    @Test func hotKeyThatIsAnEnabledSystemShortcutIsAnnouncedAtLaunch() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        system.hotKeys = [.standard]
        let controller = makeController()

        controller.applyHotKeyAtLaunch()
        #expect(hotKeys.registered == .standard)
        #expect(controller.panelModel.isOpen)
        let notice = try #require(controller.panelModel.notices[.hotKey])
        #expect(notice.contains("raccourci de macOS"))
        #expect(notice.contains(HotKey.standard.label))

        // Un autre raccourci accepté efface l'avis.
        #expect(HotKeyTests.failure(controller.changeHotKey(HotKeyTests.keyB)) == nil)
        #expect(controller.panelModel.notices[.hotKey] == nil)
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

    // MARK: - Réglages et Quitter

    func makeOpenPanel() -> AppController {
        _ = NSApplication.shared  // `NSApp` doit exister pour le menu principal ; rien n'est affiché.
        let controller = makeController()
        controller.applyHotKeyAtLaunch()
        hotKeys.press()
        return controller
    }

    @Test func openingSettingsClosesThePanel() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let controller = makeOpenPanel()
        #expect(escape.registered != nil)
        #expect(clicks.isWatching)

        controller.openSettings()

        #expect(!controller.panelModel.isOpen)
        #expect(!surface.isShown)
        #expect(escape.registered == nil)
        #expect(!clicks.isWatching)
        let window = try #require(presenter.windows.first)
        #expect(window.presentations == 1)
        // Fenêtre gardée : une seconde ouverture présente la même.
        controller.openSettings()
        #expect(presenter.windows.count == 1)
        #expect(window.presentations == 2)
    }

    @Test func settingsWindowInstallsTheMainMenu() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        NSApplication.shared.mainMenu = nil
        let controller = makeOpenPanel()

        controller.openSettings()

        let titles = NSApplication.shared.mainMenu?.items.map(\.title) ?? []
        #expect(titles.contains("Édition"))
        // ⌘Q du menu principal passe par `quit()` : panneau fermé, puis fin demandée.
        let quit = try #require(NSApplication.shared.mainMenu?.items.first?.submenu?.items.first { $0.keyEquivalent == "q" })
        hotKeys.press()
        #expect(controller.panelModel.isOpen)
        (quit.target as? NSObject)?.perform(quit.action!, with: quit)
        #expect(presenter.terminations == 1)
        #expect(!controller.panelModel.isOpen)
    }

    @Test func quittingClosesThePanel() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeOpenPanel()

        controller.quit()

        #expect(presenter.terminations == 1)
        #expect(!controller.panelModel.isOpen)
        #expect(escape.registered == nil)
        #expect(!clicks.isWatching)
    }

    @Test func successfulSaveClearsTheLoadNotice() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try corruptTheSettingsFile()
        let controller = makeController()
        #expect(controller.panelModel.notices[.settingsLoad] != nil)

        // Le fichier illisible a été mis de côté : la sauvegarde suivante réussit.
        controller.panelModel.select("prompt")
        #expect(controller.panelModel.notices[.settingsLoad] == nil)
        #expect(store.load().settings.lastModeID == "prompt")
    }
}

/// Fenêtres de réglages et demandes de fin, à la place de l'écran et de `NSApp.terminate`.
@MainActor final class Presenter {
    private(set) var windows: [FakeSettingsWindow] = []
    private(set) var terminations = 0

    func make(_ content: AnyView, onLeave: @escaping @MainActor () -> Void) -> any SettingsWindowSurface {
        let window = FakeSettingsWindow(onLeave: onLeave)
        windows.append(window)
        return window
    }

    func terminate() { terminations += 1 }
}

/// Fenêtre de réglages double : rien ne s'affiche ; `leave` imite une fenêtre fermée ou quittée.
@MainActor final class FakeSettingsWindow: SettingsWindowSurface {
    private let onLeave: @MainActor () -> Void
    private(set) var presentations = 0

    init(onLeave: @escaping @MainActor () -> Void) { self.onLeave = onLeave }

    func present() { presentations += 1 }
    func leave() { onLeave() }
}
