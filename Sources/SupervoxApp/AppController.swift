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
    public typealias SettingsViewProvider = @MainActor (AppController) -> SettingsContent
    /// Construit la fenêtre de réglages autour de son contenu ; `onLeave` est appelé quand l'utilisateur la quitte.
    public typealias SettingsWindowMaker =
        @MainActor (_ content: AnyView, _ onLeave: @escaping @MainActor () -> Void) -> any SettingsWindowSurface

    /// Fenêtre de réglages vide, en attendant la vraie.
    public static let emptySettings: SettingsViewProvider = { _ in
        SettingsContent(view: AnyView(Color.clear.frame(width: 520, height: 360)))
    }

    public let settingsStore: SettingsStore
    /// Construit sans rien lire ; partagé par toute l'application.
    public let secrets: any SecretStore
    public let hotKeys: HotKeyCenter
    public let panelModel: PanelModel
    public let permissions: PermissionsModel
    /// Les raccourcis de macOS activés, lus quand on en a besoin (jamais gardés : l'utilisateur peut les changer).
    public let systemHotKeys: any SystemHotKeys
    /// Nomme les touches des raccourcis (libellés, avis) et reconnaît ⌘Q, ⌘W, ⌘H et ⌘M.
    public let keyboardLayout: any KeyboardLayout
    /// Réglages en vigueur.
    public private(set) var settings: AppSettings
    /// Aucun fichier de réglages au lancement.
    private let isFirstLaunch: Bool

    private let panel: PanelController
    private let settingsView: SettingsViewProvider
    private let makeSettingsWindow: SettingsWindowMaker
    private let terminate: @MainActor () -> Void
    private var statusItem: NSStatusItem?
    private var statusMenuRefresher: MenuRefresher?
    private var settingsWindow: (any SettingsWindowSurface)?
    private var settingsContent: SettingsContent?
    /// La dernière demande faite à la présentation de la fenêtre ; les tests l'attendent.
    private(set) var settingsPresentation: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.supervox.app", category: "app")

    public init(
        settingsStore: SettingsStore,
        secrets: any SecretStore,
        hotKeyRegistrar: any HotKeyRegistrar,
        escapeRegistrar: any HotKeyRegistrar,
        permissionsProbe: any PermissionsProbe,
        systemHotKeys: any SystemHotKeys,
        keyboardLayout: any KeyboardLayout,
        settingsView: @escaping SettingsViewProvider = AppController.emptySettings,
        makePanelSurface: @MainActor (AnyView) -> any PanelSurface,
        clickMonitor: any OutsideClickMonitor,
        makeSettingsWindow: @escaping SettingsWindowMaker,
        terminate: @escaping @MainActor () -> Void
    ) {
        self.settingsStore = settingsStore
        self.secrets = secrets
        self.settingsView = settingsView
        self.makeSettingsWindow = makeSettingsWindow
        self.terminate = terminate
        self.systemHotKeys = systemHotKeys
        self.keyboardLayout = keyboardLayout
        hotKeys = HotKeyCenter(registrar: hotKeyRegistrar, layout: keyboardLayout)

        let loaded = settingsStore.load()
        settings = loaded.settings
        isFirstLaunch = loaded.isFirstLaunch

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
            systemHotKeys: SymbolicHotKeys(),
            keyboardLayout: SystemKeyboardLayout(),
            settingsView: settingsView,
            makePanelSurface: { FloatingPanelSurface(content: $0) },
            clickMonitor: GlobalClickMonitor(),
            makeSettingsWindow: { SettingsWindow(content: $0, onLeave: $1) },
            terminate: { NSApp.terminate(nil) })
    }

    /// Installe l'élément de barre de menus et le raccourci global. À appeler une fois,
    /// l'application déjà en politique `.accessory`.
    public func start() {
        installStatusItem()
        launch()
    }

    /// Le lancement, sans l'élément de barre de menus : raccourci, puis accueil s'il n'existe pas encore de fichier
    /// de réglages.
    ///
    /// Au premier lancement, le panneau s'ouvre seul avec l'accueil et, s'il en manque, la ligne des permissions et
    /// son bouton « Autoriser… » : rien n'est demandé au système avant ce clic. Le fichier de réglages est créé à la
    /// fin de ce lancement, avec les réglages en vigueur : l'accueil ne revient pas.
    ///
    /// Le panneau ne s'ouvre qu'une fois tout son contenu posé (accueil, avis) : la vraie surface prend sa taille à
    /// l'affichage.
    func launch() {
        let hotKeyIsFine = applyHotKey()
        if isFirstLaunch {
            panelModel.welcome = Self.welcome(hotKeyLabel: panelModel.hotKeyLabel)
            do {
                try updateSettings { _ in }
            } catch {
                panelModel.setNotice(error.localizedDescription, for: .save)
                log.error("réglages non créés : \(error.localizedDescription, privacy: .public)")
            }
        }
        if !hotKeyIsFine || isFirstLaunch { panel.open() }
    }

    /// L'accueil du premier lancement ; `hotKeyLabel` est `nil` sans raccourci actif.
    public static func welcome(hotKeyLabel: String?) -> String {
        let opening =
            hotKeyLabel.map { "\($0) ouvre et ferme ce panneau, depuis n'importe quelle application." }
            ?? "Ouvrez ce panneau depuis l'icône de Supervox dans la barre de menus."
        return "Bienvenue dans Supervox. \(opening) Les réglages (fournisseurs, raccourci, permissions) s'ouvrent par « Réglages… », dans le menu « … » ci-dessous ou dans celui de l'icône de la barre de menus."
    }

    /// Relance de l'application déjà ouverte : le panneau s'ouvre, ou reste ouvert.
    func openPanelOnReopen() {
        panel.open()
    }

    /// Enregistre le raccourci des réglages. S'il est refusé, ou s'il est aussi un raccourci de macOS activé (il peut
    /// alors ne pas ouvrir le panneau), le panneau s'ouvre de lui-même pour le dire : sans raccourci, l'utilisateur
    /// pourrait ne jamais trouver le panneau.
    func applyHotKeyAtLaunch() {
        if !applyHotKey() { panel.open() }
    }

    // MARK: - Raccourci

    /// Le comportement `hold` est enregistré dans les réglages mais n'a pas d'effet à cette étape :
    /// le raccourci bascule toujours. Rend vrai si rien n'est à signaler.
    private func applyHotKey() -> Bool {
        let hotKey = settings.hotKey
        switch hotKeys.apply(hotKey, onPress: { [weak self] in self?.togglePanel() }) {
        case .success:
            let label = hotKey.label(layout: keyboardLayout)
            panelModel.hotKeyLabel = label
            log.notice("raccourci enregistré : \(label, privacy: .public)")
            guard systemHotKeys.enabled().contains(hotKey) else {
                panelModel.setNotice(nil, for: .hotKey)
                return true
            }
            let message =
                "Le raccourci \(label) est aussi un raccourci de macOS activé sur ce Mac : il peut ne pas ouvrir le panneau. Choisissez-en un autre dans Réglages, ou désactivez celui de macOS (Réglages Système, Clavier, Raccourcis clavier)."
            panelModel.setNotice(message, for: .hotKey)
            log.notice("raccourci de macOS : \(label, privacy: .public)")
            return false
        case .failure(let error):
            panelModel.hotKeyLabel = hotKeys.active?.label(layout: keyboardLayout)
            let message = Self.message(for: error, label: hotKey.label(layout: keyboardLayout))
            panelModel.setNotice(message, for: .hotKey)
            log.notice("raccourci refusé : \(message, privacy: .public)")
            return false
        }
    }

    private static func message(for error: HotKeyError, label: String) -> String {
        switch error {
        case .refused:
            "Le raccourci \(label) a été refusé par macOS : ouvrez le panneau depuis la barre de menus, puis choisissez-en un autre dans Réglages."
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
        panelModel.hotKeyLabel = hotKeys.active?.label(layout: keyboardLayout)
        if case .success = result { panelModel.setNotice(nil, for: .hotKey) }
        return result
    }

    /// Le temps d'une capture de raccourci : panneau fermé (Échap rendu) et raccourci global rendu au système.
    func suspendHotKeysForCapture() {
        panel.close()
        hotKeys.suspend()
    }

    /// Fin de capture : le raccourci suspendu est réenregistré, s'il l'est encore. Rend faux si le système le refuse.
    func resumeHotKeys() -> Bool {
        let restored = hotKeys.resume()
        panelModel.hotKeyLabel = hotKeys.active?.label(layout: keyboardLayout)
        if !restored {
            panelModel.setNotice(
                "Le raccourci \(settings.hotKey.label(layout: keyboardLayout)) n'a pas pu être rétabli après la capture : macOS l'a refusé. Choisissez-en un autre dans Réglages.",
                for: .hotKey)
            log.notice("raccourci non rétabli après la capture")
        }
        return restored
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

    /// Construit la fenêtre la première fois, puis la présente ; chaque présentation lance `onPresent`.
    func openSettings() {
        panel.close()
        let window: any SettingsWindowSurface
        let content: SettingsContent
        if let settingsWindow, let settingsContent {
            window = settingsWindow
            content = settingsContent
        } else {
            content = settingsView(self)
            // Sans menu principal, ⌘X, ⌘C, ⌘V et ⌘A ne font rien dans les champs de la fenêtre.
            NSApp.mainMenu = MainMenu.make(quit: { [weak self] in self?.quit() })
            window = makeSettingsWindow(content.view, content.onLeave)
            settingsWindow = window
            settingsContent = content
        }
        settingsPresentation = Task { await content.onPresent() }
        window.present()
        log.notice("réglages ouverts")
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
