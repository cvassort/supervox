import AppKit
import SwiftUI
import os

/// Assemble l'application de barre de menus : réglages sur disque, secrets, raccourci global,
/// panneau, permissions, élément de barre de menus, fenêtre de réglages.
///
/// Au lancement, rien n'est demandé à l'utilisateur : aucune invite de permission, aucune lecture
/// du trousseau. Les permissions se demandent depuis le panneau ; les secrets se lisent quand une
/// requête en a besoin.
@MainActor
public final class AppController {
    /// Fournit le contenu de la fenêtre « Réglages ». Point d'extension : la fenêtre est vide
    /// tant qu'aucune vue n'est fournie.
    public typealias SettingsViewProvider = @MainActor (AppController) -> AnyView

    /// Fenêtre de réglages vide, en attendant la vraie.
    public static let emptySettings: SettingsViewProvider = { _ in
        AnyView(Color.clear.frame(width: 520, height: 360))
    }

    public let settingsStore: SettingsStore
    /// Construit sans rien lire ; partagé par toute l'application.
    public let secrets: any SecretStore
    public let hotKeys: HotKeyCenter
    public let panelModel: PanelModel
    public let permissions: PermissionsModel
    /// Réglages en vigueur.
    public private(set) var settings: AppSettings

    private let panel: PanelController
    private let settingsView: SettingsViewProvider
    private var statusItem: NSStatusItem?
    private var statusMenuRefresher: MenuRefresher?
    private var settingsWindow: NSWindow?
    private let log = Logger(subsystem: "dev.supervox.app", category: "app")

    public init(
        settingsStore: SettingsStore,
        secrets: any SecretStore,
        hotKeyRegistrar: any HotKeyRegistrar,
        escapeRegistrar: any HotKeyRegistrar,
        permissionsProbe: any PermissionsProbe,
        settingsView: @escaping SettingsViewProvider = AppController.emptySettings,
        makePanelSurface: @MainActor (AnyView) -> any PanelSurface = { FloatingPanelSurface(content: $0) },
        clickMonitor: any OutsideClickMonitor = GlobalClickMonitor()
    ) {
        self.settingsStore = settingsStore
        self.secrets = secrets
        self.settingsView = settingsView
        hotKeys = HotKeyCenter(registrar: hotKeyRegistrar)

        let loaded = settingsStore.load()
        settings = loaded.settings

        let panelModel = PanelModel(lastModeID: loaded.settings.lastModeID)
        panelModel.setNotice(loaded.notice, for: .settingsLoad)
        self.panelModel = panelModel
        permissions = PermissionsModel(probe: permissionsProbe)

        // Le contenu du panneau appelle le contrôleur, qui n'existe pas encore : relais.
        let relay = ActionRelay()
        let content = PanelView(
            model: panelModel, permissions: permissions,
            openSettings: { relay.openSettings?() }, quit: { relay.quit?() })
        panel = PanelController(
            model: panelModel, escapeRegistrar: escapeRegistrar, clickMonitor: clickMonitor,
            surface: makePanelSurface(AnyView(content)))
        relay.openSettings = { [weak self] in self?.openSettings() }
        relay.quit = { [weak self] in self?.quit() }

        panelModel.onOpen = { [permissions] in permissions.refresh() }
        panelModel.onModeChanged = { [weak self] id in self?.saveLastMode(id) }

        if let notice = loaded.notice { log.notice("réglages : \(notice, privacy: .public)") }
    }

    /// Les réalisations du système : fichier de réglages de l'utilisateur, trousseau, Carbon,
    /// AVFoundation et Accessibilité.
    public convenience init(settingsView: @escaping SettingsViewProvider = SettingsView.provider) {
        let file = (try? SettingsStore.defaultFile())
            ?? URL.applicationSupportDirectory.appending(path: "Supervox/settings.json")
        self.init(
            settingsStore: SettingsStore(file: file),
            secrets: CachedSecretStore(KeychainSecretStore(service: "dev.supervox.app")),
            hotKeyRegistrar: CarbonHotKeyRegistrar(),
            escapeRegistrar: CarbonHotKeyRegistrar(),
            permissionsProbe: SystemPermissions(),
            settingsView: settingsView)
    }

    /// Installe l'élément de barre de menus et le raccourci global. À appeler une fois,
    /// l'application déjà en politique `.accessory`.
    public func start() {
        installStatusItem()
        applyHotKeyAtLaunch()
    }

    /// Enregistre le raccourci des réglages. S'il est refusé, le panneau s'ouvre de lui-même pour le
    /// dire : sans raccourci, l'utilisateur pourrait ne jamais trouver le panneau.
    func applyHotKeyAtLaunch() {
        if !applyHotKey() { panel.open() }
    }

    // MARK: - Raccourci

    /// Le comportement `hold` est enregistré dans les réglages mais n'a pas d'effet à cette étape :
    /// le raccourci bascule toujours.
    private func applyHotKey() -> Bool {
        let hotKey = settings.hotKey
        switch hotKeys.apply(hotKey, onPress: { [weak self] in self?.togglePanel() }) {
        case .success:
            panelModel.hotKeyLabel = hotKey.label
            panelModel.setNotice(nil, for: .hotKey)
            log.notice("raccourci enregistré : \(hotKey.label, privacy: .public)")
            return true
        case .failure(let error):
            panelModel.hotKeyLabel = hotKeys.active?.label
            let message = Self.message(for: error, label: hotKey.label)
            panelModel.setNotice(message, for: .hotKey)
            log.notice("raccourci refusé : \(message, privacy: .public)")
            return false
        }
    }

    private static func message(for error: HotKeyError, label: String) -> String {
        switch error {
        case .taken: "Le raccourci \(label) est déjà pris : ouvrez le panneau depuis la barre de menus."
        case .invalid: "Le raccourci \(label) n'est pas valide : ouvrez le panneau depuis la barre de menus."
        }
    }

    // MARK: - Réglages modifiés depuis la fenêtre

    /// Seul chemin d'écriture des réglages depuis la fenêtre : `change` s'applique aux réglages en vigueur
    /// (ceux que le panneau modifie aussi), qui ne changent en mémoire que si l'enregistrement réussit.
    public func updateSettings(_ change: (inout AppSettings) -> Void) throws {
        var updated = settings
        change(&updated)
        try settingsStore.save(updated)
        settings = updated
        panelModel.setNotice(nil, for: .save)
        // Le fichier mis de côté au lancement est remplacé par des réglages lisibles : l'avis n'a plus d'objet.
        panelModel.setNotice(nil, for: .settingsLoad)
    }

    /// Enregistre `hotKey` comme raccourci global, avec le même effet que celui du lancement, et met à
    /// jour le libellé du panneau. N'enregistre pas les réglages. En cas de refus, l'ancien reste actif.
    public func changeHotKey(_ hotKey: HotKey) -> Result<Void, HotKeyError> {
        let result = hotKeys.apply(hotKey, onPress: { [weak self] in self?.togglePanel() })
        panelModel.hotKeyLabel = hotKeys.active?.label
        if case .success = result { panelModel.setNotice(nil, for: .hotKey) }
        return result
    }

    /// Le temps d'une capture de raccourci : panneau fermé (Échap rendu) et raccourci global rendu au système.
    func suspendHotKeysForCapture() {
        panel.close()
        hotKeys.suspend()
    }

    /// Fin de capture : le raccourci suspendu est réenregistré, s'il l'est encore.
    func resumeHotKeys() {
        hotKeys.resume()
        panelModel.hotKeyLabel = hotKeys.active?.label
    }

    /// Plus aucun raccourci global.
    func clearHotKey() {
        hotKeys.clear()
        panelModel.hotKeyLabel = nil
    }

    // MARK: - Panneau

    private func togglePanel() {
        log.notice("raccourci pressé")
        panel.toggle()
    }

    /// Titre de l'entrée de barre de menus qui ouvre ou ferme le panneau.
    var panelMenuTitle: String { panelModel.isOpen ? "Fermer le panneau" : "Ouvrir le panneau" }

    func togglePanelFromMenu() {
        panel.toggle()
    }

    /// Par `updateSettings`, comme la fenêtre de réglages : une seule copie vivante des réglages.
    private func saveLastMode(_ id: String) {
        do {
            try updateSettings { $0.lastModeID = id }
        } catch {
            panelModel.setNotice(error.localizedDescription, for: .save)
            log.error("réglages non enregistrés : \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Barre de menus

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Supervox")
        let menu = NSMenu()
        let panelItem = MenuAction.item(panelMenuTitle, key: "") { [weak self] in self?.togglePanelFromMenu() }
        menu.addItem(panelItem)
        menu.addItem(MenuAction.item("Réglages…", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Quitter Supervox", key: "q") { [weak self] in self?.quit() })
        // Le titre suit l'état du panneau à chaque ouverture du menu.
        let delegate = MenuRefresher { [weak self, weak panelItem] in
            guard let self, let panelItem else { return }
            panelItem.title = self.panelMenuTitle
        }
        menu.delegate = delegate
        statusMenuRefresher = delegate
        item.menu = menu
        statusItem = item
        log.notice("élément de barre de menus installé : \(item.button != nil, privacy: .public)")
    }

    // MARK: - Actions

    /// Met la fenêtre de réglages au premier plan ; remplacé dans les tests, où rien ne doit s'afficher.
    var presentSettingsWindow: @MainActor (NSWindow) -> Void = { window in
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
    /// Fin de l'application ; remplacé dans les tests.
    var terminate: @MainActor () -> Void = { NSApp.terminate(nil) }

    func openSettings() {
        panel.close()
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        presentSettingsWindow(window)
        log.notice("réglages ouverts")
    }

    func makeSettingsWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: settingsView(self))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Réglages"
        // Sans menu principal, ⌘X, ⌘C, ⌘V et ⌘A ne font rien dans les champs de la fenêtre.
        NSApp.mainMenu = MainMenu.make(quit: { [weak self] in self?.quit() })
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    func quit() {
        panel.close()
        log.notice("quitter")
        terminate()
    }
}

/// Relais d'actions, posé avant que le contrôleur soit entièrement construit.
@MainActor
private final class ActionRelay {
    var openSettings: (@MainActor () -> Void)?
    var quit: (@MainActor () -> Void)?
}

/// Délégué de menu qui rafraîchit les titres juste avant l'affichage.
@MainActor
private final class MenuRefresher: NSObject, NSMenuDelegate {
    private let refresh: @MainActor () -> Void

    init(_ refresh: @escaping @MainActor () -> Void) {
        self.refresh = refresh
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }
}

/// Élément de menu qui appelle une fermeture.
@MainActor
private final class MenuAction: NSObject {
    private let action: @MainActor () -> Void

    private init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    static func item(_ title: String, key: String, action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let target = MenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: key)
        item.target = target
        // La cible d'un élément de menu n'est pas retenue : l'élément la garde.
        item.representedObject = target
        return item
    }

    @objc private func run() { action() }
}
