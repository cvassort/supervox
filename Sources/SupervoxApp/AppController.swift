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
    private var settingsWindow: NSWindow?
    private let log = Logger(subsystem: "dev.supervox.app", category: "app")

    public init(
        settingsStore: SettingsStore,
        secrets: any SecretStore,
        hotKeyRegistrar: any HotKeyRegistrar,
        escapeRegistrar: any HotKeyRegistrar,
        permissionsProbe: any PermissionsProbe,
        settingsView: @escaping SettingsViewProvider = AppController.emptySettings
    ) {
        self.settingsStore = settingsStore
        self.secrets = secrets
        self.settingsView = settingsView
        hotKeys = HotKeyCenter(registrar: hotKeyRegistrar)

        let loaded = settingsStore.load()
        settings = loaded.settings

        let panelModel = PanelModel(lastModeID: loaded.settings.lastModeID)
        panelModel.notice = loaded.notice
        self.panelModel = panelModel
        permissions = PermissionsModel(probe: permissionsProbe)

        // Le contenu du panneau appelle le contrôleur, qui n'existe pas encore : relais.
        let relay = ActionRelay()
        panel = PanelController(
            model: panelModel, escapeRegistrar: escapeRegistrar,
            content: PanelView(
                model: panelModel, permissions: permissions,
                openSettings: { relay.openSettings?() }, quit: { relay.quit?() }))
        relay.openSettings = { [weak self] in self?.openSettings() }
        relay.quit = { [weak self] in self?.quit() }

        panelModel.onOpen = { [permissions] in permissions.refresh() }
        panelModel.onModeChanged = { [weak self] id in self?.saveLastMode(id) }

        if let notice = loaded.notice { log.notice("réglages : \(notice, privacy: .public)") }
    }

    /// Les réalisations du système : fichier de réglages de l'utilisateur, trousseau, Carbon,
    /// AVFoundation et Accessibilité.
    public convenience init(settingsView: @escaping SettingsViewProvider = AppController.emptySettings) {
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
        applyHotKey()
    }

    // MARK: - Raccourci

    /// Le comportement `hold` est enregistré dans les réglages mais n'a pas d'effet à cette étape :
    /// le raccourci bascule toujours.
    private func applyHotKey() {
        let hotKey = settings.hotKey
        switch hotKeys.apply(hotKey, onPress: { [weak self] in self?.togglePanel() }) {
        case .success:
            panelModel.hotKeyLabel = hotKey.label
            log.notice("raccourci enregistré : \(hotKey.label, privacy: .public)")
        case .failure(let error):
            panelModel.hotKeyLabel = hotKeys.active?.label
            let message = Self.message(for: error, label: hotKey.label)
            panelModel.notice = [panelModel.notice, message].compactMap { $0 }.joined(separator: " ")
            log.notice("raccourci refusé : \(message, privacy: .public)")
        }
    }

    private static func message(for error: HotKeyError, label: String) -> String {
        switch error {
        case .taken: "Le raccourci \(label) est déjà pris : ouvrez le panneau depuis la barre de menus."
        case .invalid: "Le raccourci \(label) n'est pas valide : ouvrez le panneau depuis la barre de menus."
        }
    }

    // MARK: - Panneau

    private func togglePanel() {
        log.notice("raccourci pressé")
        panel.toggle()
    }

    private func saveLastMode(_ id: String) {
        settings.lastModeID = id
        do {
            try settingsStore.save(settings)
        } catch {
            panelModel.notice = error.localizedDescription
            log.error("réglages non enregistrés : \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Barre de menus

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Supervox")
        let menu = NSMenu()
        menu.addItem(MenuAction.item("Ouvrir le panneau", key: "") { [weak self] in self?.panel.open() })
        menu.addItem(MenuAction.item("Réglages…", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item("Quitter Supervox", key: "q") { [weak self] in self?.quit() })
        item.menu = menu
        statusItem = item
        log.notice("élément de barre de menus installé : \(item.button != nil, privacy: .public)")
    }

    // MARK: - Actions

    private func openSettings() {
        panel.close()
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        log.notice("réglages ouverts")
    }

    private func makeSettingsWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: settingsView(self))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Réglages"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func quit() {
        panel.close()
        log.notice("quitter")
        NSApp.terminate(nil)
    }
}

/// Relais d'actions, posé avant que le contrôleur soit entièrement construit.
@MainActor
private final class ActionRelay {
    var openSettings: (@MainActor () -> Void)?
    var quit: (@MainActor () -> Void)?
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
