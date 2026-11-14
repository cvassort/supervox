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

    /// `seeded` : sans fichier de réglages, en écrit un (réglages par défaut) avant la construction, pour que `launch()`
    /// suive le chemin d'un lancement ordinaire. Les tests du premier lancement passent `false`.
    func makeController(layout: any KeyboardLayout = HotKeyTests.ansi, seeded: Bool = true) -> AppController {
        if seeded, !FileManager.default.fileExists(atPath: store.file.path) { try? store.save(.defaults) }
        return AppController(
            settingsStore: store, secrets: InMemorySecretStore(), hotKeyRegistrar: hotKeys,
            escapeRegistrar: escape, permissionsProbe: probe, systemHotKeys: system, keyboardLayout: layout,
            makePanelSurface: { [surface] _ in surface }, clickMonitor: clicks,
            makeSettingsWindow: presenter.make, terminate: presenter.terminate)
    }

    func corruptTheSettingsFile() throws {
        try Data("pas du json".utf8).write(to: store.file)
    }

    @Test func openingThePanelRereadsThePermissions() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        controller.launch()

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

        controller.launch()
        #expect(controller.panelModel.isOpen)
        #expect(surface.isShown)
        let notice = try #require(controller.panelModel.notices[.hotKey])
        #expect(notice.contains(HotKey.standard.label(layout: HotKeyTests.ansi)))
        #expect(notice.contains("refusé par macOS"))
        #expect(controller.panelModel.hotKeyLabel == nil)
    }

    /// I2 (c) : le raccourci du fichier (ici le défaut, ⌃⌥Espace) est un raccourci de macOS activé sur ce Mac.
    /// Il est quand même enregistré (qui l'emporte n'est pas connu), et le panneau s'ouvre pour le dire.
    @Test func hotKeyThatIsAnEnabledSystemShortcutIsAnnouncedAtLaunch() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        system.hotKeys = [.standard]
        let controller = makeController()

        controller.launch()
        #expect(hotKeys.registered == .standard)
        #expect(controller.panelModel.isOpen)
        let notice = try #require(controller.panelModel.notices[.hotKey])
        #expect(notice.contains("raccourci de macOS"))
        #expect(notice.contains(HotKey.standard.label(layout: HotKeyTests.ansi)))

        // Un autre raccourci accepté efface l'avis.
        #expect(HotKeyTests.failure(controller.changeHotKey(HotKeyTests.keyB)) == nil)
        #expect(controller.panelModel.notices[.hotKey] == nil)
    }

    // MARK: - Fichier non enregistrable pendant la session

    /// R1 : fichier valide rendu illisible au lancement, puis lisible de nouveau ; le changement de mode suivant ne
    /// l'écrase pas (les réglages en mémoire sont les défauts), et l'avis le dit.
    @Test func fileUnreadableAtLaunchIsNeverWrittenDuringTheSession() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = AppSettings(
            version: 1, providers: [Provider(id: UUID(), name: "Gardé", baseURL: "https://api.example.com", kind: .anthropic, models: [])],
            hotKey: HotKeyTests.keyA, hotKeyBehavior: .toggle, lastModeID: "entretien")
        try store.save(saved)
        let original = try Data(contentsOf: store.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.file.path)
        let controller = makeController()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.file.path)
        #expect(controller.panelModel.notices[.settingsLoad] != nil)

        controller.panelModel.select("prompt")

        #expect(try Data(contentsOf: store.file) == original)
        let notice = try #require(controller.panelModel.notices[.save])
        #expect(notice.contains("settings.json"))
        #expect(controller.panelModel.notices[.settingsLoad] != nil)
        #expect(controller.settings.lastModeID != "prompt")
    }

    // MARK: - Premier lancement, réouverture

    /// I3 : sans fichier de réglages, le panneau s'ouvre seul avec l'accueil et la ligne des permissions manquantes ;
    /// rien n'est demandé au système sans clic. Le fichier est créé à la fin du lancement : l'accueil ne revient pas.
    @Test func firstLaunchOpensThePanelWithAWelcomeAndCreatesTheFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        probe.set(microphone: .notDetermined, accessibility: .denied)
        #expect(!FileManager.default.fileExists(atPath: store.file.path))
        let controller = makeController(seeded: false)

        controller.launch()
        #expect(controller.panelModel.isOpen)
        #expect(surface.isShown)
        let welcome = try #require(controller.panelModel.welcome)
        #expect(welcome.contains(HotKey.standard.label(layout: HotKeyTests.ansi)))
        #expect(welcome.contains("Réglages"))
        #expect(controller.permissions.summary != nil)
        #expect(controller.permissions.canRequest)
        #expect(probe.microphoneRequests == 0)
        #expect(probe.accessibilityPrompts == 0)
        #expect(store.load().settings == .defaults)
        #expect(!store.load().isFirstLaunch)

        // Lancement suivant : silencieux.
        let next = AppController(
            settingsStore: store, secrets: InMemorySecretStore(), hotKeyRegistrar: HotKeyTests.FakeRegistrar(),
            escapeRegistrar: HotKeyTests.FakeRegistrar(), permissionsProbe: probe, systemHotKeys: system,
            keyboardLayout: HotKeyTests.ansi, makePanelSurface: { _ in FakePanelSurface() }, clickMonitor: FakeClickMonitor(),
            makeSettingsWindow: presenter.make, terminate: presenter.terminate)
        next.launch()
        #expect(!next.panelModel.isOpen)
        #expect(next.panelModel.welcome == nil)
    }

    /// Premier lancement sans raccourci (refusé par macOS) : l'accueil renvoie à la barre de menus.
    @Test func welcomeWithoutAHotKeyPointsToTheMenuBar() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        hotKeys.refused = [.standard]
        let controller = makeController(seeded: false)
        // La vraie surface prend sa taille à l'affichage : l'accueil doit déjà être là quand le panneau s'ouvre, même
        // quand c'est le refus du raccourci qui l'ouvre.
        var welcomeAtShow: String?
        surface.onShow = { welcomeAtShow = controller.panelModel.welcome }

        controller.launch()
        #expect(welcomeAtShow != nil)
        #expect(surface.showCount == 1)
        let welcome = try #require(controller.panelModel.welcome)
        #expect(!welcome.contains(HotKey.standard.label(layout: HotKeyTests.ansi)))
        #expect(welcome.contains("barre de menus"))
        #expect(controller.panelModel.notices[.hotKey] != nil)
    }

    /// L'accueil ne sert qu'à la première ouverture : il disparaît quand le panneau se ferme.
    @Test func welcomeGoesAwayWhenThePanelCloses() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(seeded: false)
        controller.launch()
        #expect(controller.panelModel.welcome != nil)

        hotKeys.press()
        #expect(!controller.panelModel.isOpen)
        #expect(controller.panelModel.welcome == nil)
        hotKeys.press()
        #expect(controller.panelModel.welcome == nil)
    }

    /// Un fichier présent : lancement silencieux, et le fichier n'est pas réécrit.
    @Test func launchWithExistingSettingsStaysSilentAndWritesNothing() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(.defaults)
        let before = try Data(contentsOf: store.file)
        let modified = try FileManager.default.attributesOfItem(atPath: store.file.path)[.modificationDate] as? Date
        let controller = makeController()

        controller.launch()
        #expect(!controller.panelModel.isOpen)
        #expect(controller.panelModel.welcome == nil)
        #expect(try Data(contentsOf: store.file) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: store.file.path)[.modificationDate] as? Date == modified)
    }

    /// Lancement ordinaire (fichier présent) avec un raccourci refusé : `launch()` ouvre le panneau, sans accueil.
    @Test func refusedHotKeyOnAnOrdinaryLaunchOpensThePanelWithoutWelcome() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(.defaults)
        hotKeys.refused = [.standard]
        let controller = makeController()

        controller.launch()
        #expect(controller.panelModel.isOpen)
        #expect(surface.showCount == 1)
        #expect(controller.panelModel.welcome == nil)
        #expect(controller.panelModel.notices[.hotKey] != nil)
    }

    /// I3 (b) : relancer l'application déjà ouverte ouvre le panneau, et ne le referme pas s'il l'est déjà.
    @Test func reopeningTheRunningAppOpensThePanel() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        controller.launch()
        let delegate = ApplicationDelegate(controller: controller)

        #expect(!delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        #expect(controller.panelModel.isOpen)
        #expect(surface.isShown)
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        #expect(controller.panelModel.isOpen)
    }

    /// m21 : le libellé du raccourci vient de la disposition de clavier donnée au contrôleur, jamais de celle de la
    /// machine qui exécute les tests. Le code 0x00 est A en ANSI et Q en AZERTY.
    @Test func hotKeyLabelUsesTheInjectedKeyboardLayout() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(AppSettings(version: 1, providers: [], hotKey: HotKeyTests.keyA, hotKeyBehavior: .toggle, lastModeID: "prompt"))

        let ansi = makeController(layout: HotKeyTests.ansi)
        ansi.launch()
        #expect(ansi.panelModel.hotKeyLabel == "⌃⌥A")

        let azerty = makeController(layout: HotKeyTests.azerty)
        azerty.launch()
        #expect(azerty.panelModel.hotKeyLabel == "⌃⌥Q")
        hotKeys.refused = [HotKeyTests.keyA]
        let refused = makeController(layout: HotKeyTests.azerty)
        refused.launch()
        #expect(refused.panelModel.notices[.hotKey]?.contains("⌃⌥Q") == true)
    }

    @Test func acceptedHotKeyAtLaunchLeavesThePanelClosed() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()

        controller.launch()
        #expect(!controller.panelModel.isOpen)
        #expect(!surface.isShown)
        #expect(controller.panelModel.notices.isEmpty)
        #expect(controller.panelModel.hotKeyLabel == HotKey.standard.label(layout: HotKeyTests.ansi))
    }

    @Test func acceptedHotKeyClearsOnlyTheHotKeyNotice() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // Fichier illisible au chargement : avis de chargement.
        try corruptTheSettingsFile()
        hotKeys.refused = [.standard]
        let controller = makeController()
        let loadNotice = try #require(controller.panelModel.notices[.settingsLoad])

        controller.launch()
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
        controller.launch()
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
        controller.launch()
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
