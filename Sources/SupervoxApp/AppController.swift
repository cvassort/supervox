import AppKit
import SupervoxCore
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
    /// Le raccourci propre à chaque mode (`Mode.hotKey`), un registraire par mode.
    public let modeHotKeys: ModeHotKeys
    public let panelModel: PanelModel
    public let permissions: PermissionsModel
    /// La dictée : le raccourci, Échap et la fermeture du panneau y mènent.
    public let dictation: DictationController
    /// L'entretien du mode Entretien : la dictée le lance, le conclut et l'annule ; « Conclure » du panneau y mène.
    public let interview: InterviewController
    /// L'historique local des entretiens : `nil` sans dossier donné (`historyRoot`), et alors ni onglet Historique, ni entrée
    /// « Historique… » du panneau, ni purge, et l'entretien ne garde rien (`DiscardingInterviewHistory`).
    public let history: InterviewHistory?
    /// Met un texte dans le presse-papiers par l'insertion, qui le tient (un seul accès) : la copie de l'onglet Historique.
    let copyText: @MainActor (String) -> Bool
    /// Les raccourcis de macOS activés, lus quand on en a besoin (jamais gardés : l'utilisateur peut les changer).
    public let systemHotKeys: any SystemHotKeys
    /// Nomme les touches des raccourcis (libellés, avis) et reconnaît ⌘Q, ⌘W, ⌘H et ⌘M.
    public let keyboardLayout: any KeyboardLayout
    /// Réglages en vigueur.
    public private(set) var settings: AppSettings
    /// Aucun fichier de réglages au lancement.
    private let isFirstLaunch: Bool
    /// Le chargement a laissé un avis (fichier mis de côté, illisible, d'une version plus récente).
    private let hasLoadNotice: Bool
    /// Le fichier n'a pas pu être lu au lancement (ou vient d'une version plus récente) : il n'est plus jamais écrit
    /// pendant cette session, même s'il redevient lisible (`SettingsLoad.saveRefusal`).
    private let saveRefusal: SettingsError?

    private let panel: PanelController
    private let settingsView: SettingsViewProvider
    private let makeSettingsWindow: SettingsWindowMaker
    private let terminate: @MainActor () -> Void
    private let dictationEnvironment: DictationEnvironment
    /// L'environnement de l'entretien : l'onglet Entretien lui demande le silence que le détecteur applique en pratique.
    let interviewEnvironment: InterviewEnvironment
    /// L'écoute d'une voix de l'onglet Voix : une seule pour l'application. Sa voix et son lecteur viennent de l'environnement de
    /// l'entretien ; qui parle, de la résolution unique (`VoiceChoice.resolve(in:secrets:)`).
    let voicePreview: VoicePreview
    /// L'onglet que la fenêtre de réglages montre : `openSettings(tab:)` le change, un clic dessus aussi.
    public let settingsNavigation = SettingsNavigation()
    private let terminationWait: @Sendable (Double) async -> Void
    /// La fin demandée pendant une insertion : l'attente en cours (une seule).
    private var terminationTask: Task<Void, Never>?
    /// Le préchargement des moteurs lancé au lancement (les tests l'attendent).
    private(set) var preloadTask: Task<Void, Never>?
    /// La purge de l'historique lancée au lancement (les tests l'attendent).
    private(set) var historyPurgeTask: Task<Void, Never>?
    private var statusItem: NSStatusItem?
    private var statusMenuRefresher: MenuRefresher?
    private var settingsWindow: (any SettingsWindowSurface)?
    private var settingsContent: SettingsContent?
    /// La dernière demande faite à la présentation de la fenêtre ; les tests l'attendent.
    private(set) var settingsPresentation: Task<Void, Never>?
    private let log = Logger(subsystem: "dev.supervox.app", category: "app")
    /// L'avis `.hotKey` du panneau a une seule place : la part du raccourci global et celle de chaque mode refusé s'y composent
    /// (`publishHotKeyNotice`), sans que l'une efface l'autre.
    private var globalHotKeyNotice: String?
    private var modeHotKeyNotices: [String: String] = [:]
    /// Les combinaisons des modes actives quand la capture en cours a commencé (vide hors capture).
    private var modeHotKeysBeforeCapture: [String: HotKey] = [:]

    public init(
        settingsStore: SettingsStore,
        secrets: any SecretStore,
        hotKeyRegistrar: any HotKeyRegistrar,
        escapeRegistrar: any HotKeyRegistrar,
        makeModeHotKeyRegistrar: @escaping @MainActor () -> any HotKeyRegistrar,
        permissionsProbe: any PermissionsProbe,
        systemHotKeys: any SystemHotKeys,
        keyboardLayout: any KeyboardLayout,
        settingsView: @escaping SettingsViewProvider = AppController.emptySettings,
        makePanelSurface: @MainActor (AnyView) -> any PanelSurface,
        clickMonitor: any OutsideClickMonitor,
        makeSettingsWindow: @escaping SettingsWindowMaker,
        terminate: @escaping @MainActor () -> Void,
        dictation: DictationEnvironment = .unavailable,
        rewriter: RewriteEnvironment,
        frontApplication: @escaping @MainActor () -> Int32? = { nil },
        inserter: TextInserter,
        holdWatch: HoldWatch = .system,
        terminationWait: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        reviewHandoverWait: @escaping @MainActor (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        interview interviewEnvironment: InterviewEnvironment = .unavailable,
        resolveInterview: (@MainActor (AppSettings, TranscriptionEngine?) async throws -> InterviewSetup)? = nil,
        interviewHistory: (any InterviewHistoryStoring)? = nil,
        historyRoot: URL? = nil,
        announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer()
    ) {
        self.terminationWait = terminationWait
        self.settingsStore = settingsStore
        self.secrets = secrets
        self.settingsView = settingsView
        self.makeSettingsWindow = makeSettingsWindow
        self.terminate = terminate
        dictationEnvironment = dictation
        self.interviewEnvironment = interviewEnvironment
        self.systemHotKeys = systemHotKeys
        self.keyboardLayout = keyboardLayout
        hotKeys = HotKeyCenter(registrar: hotKeyRegistrar, layout: keyboardLayout)
        modeHotKeys = ModeHotKeys(makeRegistrar: makeModeHotKeyRegistrar, layout: keyboardLayout)

        let loaded = settingsStore.load()
        settings = loaded.settings
        isFirstLaunch = loaded.isFirstLaunch
        hasLoadNotice = loaded.notice != nil
        saveRefusal = loaded.saveRefusal

        let panelModel = PanelModel(lastModeID: loaded.settings.lastModeID, modes: loaded.settings.modes.map(\.chip))
        panelModel.setNotice(loaded.notice, for: .settingsLoad)
        self.panelModel = panelModel
        permissions = PermissionsModel(probe: permissionsProbe)

        // Le contenu du panneau appelle le contrôleur, qui n'existe pas encore : relais.
        let relay = ActionRelay()
        let content = PanelView(
            model: panelModel, permissions: permissions,
            openSettings: { relay.openSettings?() }, quit: { relay.quit?() })
        let panel = PanelController(
            model: panelModel, escapeRegistrar: escapeRegistrar, clickMonitor: clickMonitor,
            surface: makePanelSurface(AnyView(content)), announcer: announcer)
        self.panel = panel
        let preview = VoicePreview(
            makeVoice: interviewEnvironment.makeVoice, makePlayer: interviewEnvironment.makePlayer,
            resolve: { [secretAccess = SecretAccess(secrets)] choice, settings in
                try await choice.resolve(in: settings, secrets: secretAccess)
            },
            systemVoices: interviewEnvironment.systemVoices,
            microphoneHeld: { false },
            sleep: { try await Task.sleep(for: .seconds($0)) })
        voicePreview = preview
        // LA fermeture d'avant micro : la même pour la dictée, la correction et l'entretien.
        let stopPreviewBeforeMicrophone: @MainActor () -> Void = { [preview] in preview.stop() }
        // L'historique réel n'existe que si une racine est donnée : `nil` veut dire « pas d'historique », jamais « le vrai dossier »
        // (seul le programme `Supervox` donne la vraie racine). La durée est relue à chaque appel dans les réglages en vigueur.
        let retention = RetentionSource()
        let realHistory = historyRoot.map { root in
            InterviewHistory(root: root, retentionDays: { await retention.days() })
        }
        history = realHistory
        copyText = { [inserter] in inserter.copy($0) }
        // Sans résolution fournie (tests de l'assemblage qui ne portent pas sur l'entretien), l'entretien ne démarre pas et le dit.
        let interviewController = InterviewController(
            environment: interviewEnvironment, settings: { relay.settings?() ?? .defaults },
            behavior: { relay.settings?()?.hotKeyBehavior ?? .toggle },
            resolve: resolveInterview ?? { _, _ in throw InterviewEnvironment.Unavailable() },
            history: interviewHistory ?? realHistory ?? DiscardingInterviewHistory(), panel: panelModel,
            beforeMicrophone: stopPreviewBeforeMicrophone)
        self.interview = interviewController
        let dictationController = DictationController(
            environment: dictation, inserter: inserter,
            settings: { relay.settings?()?.transcription ?? .defaults },
            behavior: { relay.settings?()?.hotKeyBehavior ?? .toggle },
            modeID: { [panelModel] in panelModel.selectedModeID },
            // Relu à chaque appui : une permission accordée entre-temps compte tout de suite.
            microphoneAllowed: { [permissions] in
                permissions.refresh()
                return permissions.microphone == .granted
            },
            panel: panel,
            hotKeyModifiers: { relay.settings?()?.hotKey.modifiers ?? [] },
            // Le choix du mode passe par le panneau : il l'enregistre, comme un clic sur sa pastille.
            // Le raccourci réellement enregistré, pas celui des réglages : un changement que le système a refusé laisse l'ancien
            // actif, et c'est lui que l'on tient.
            modeHotKeyModifiers: { [modeHotKeys] in modeHotKeys.active[$0]?.modifiers ?? [] },
            selectMode: { [panelModel] in _ = panelModel.select($0) },
            ownerIsBound: { [hotKeys, modeHotKeys] owner in
                switch owner {
                case .global: hotKeys.active != nil
                case .mode(let id): modeHotKeys.active[id] != nil
                }
            },
            hold: holdWatch,
            // Lu une fois, à l'appui qui commence la dictée, pour le mode choisi.
            reviewBeforePaste: { relay.settings?()?.reviewsBeforePaste($0) ?? false },
            // Lu une fois, à l'appui, avec le choix de relecture : le mode tel que les réglages l'ont à cet instant.
            modes: { ModeRun.from(relay.settings?()?.mode($0)) },
            rewriter: rewriter,
            frontApplication: frontApplication,
            // Le libellé du raccourci global réellement enregistré, celui que le reste du panneau montre.
            hotKeyLabel: { [panelModel] in panelModel.hotKeyLabel },
            wait: reviewHandoverWait,
            interview: interviewController,
            // L'appui qui conclut passe par le bouton : il se grise, et une seule conclusion part.
            concludeInterview: { [panelModel] in panelModel.concludeInterview() },
            beforeMicrophone: stopPreviewBeforeMicrophone)
        self.dictation = dictationController
        dictationController.onViewChange = { [panelModel, panel] in
            panelModel.setDictation($0)
            panel.contentChanged()
        }
        // Le presse-papiers passe par l'insertion, qui le tient : un seul accès, injecté.
        panelModel.onCopy = { [inserter] in inserter.copy($0) }
        panelModel.onDraftChange = { [dictationController] in dictationController.reviewEdited($0) }
        panelModel.onPaste = { [dictationController] in dictationController.pasteReview() }
        panelModel.onCorrect = { [dictationController] in dictationController.startCorrection() }
        panelModel.onFinishCorrection = { [dictationController] in dictationController.finishCorrection() }
        panelModel.onPreviousVersion = { [dictationController] in dictationController.previousVersion() }
        panelModel.onNextVersion = { [dictationController] in dictationController.nextVersion() }
        panelModel.onConclude = { [interviewController] in interviewController.conclude() }
        panel.onClosed = { [dictationController] in dictationController.panelClosedByUser() }
        panel.escapeHandler = { [dictationController] in dictationController.escapePressed() }
        relay.settings = { [weak self] in self?.settings }
        relay.openSettings = { [weak self] in self?.openSettings() }
        relay.quit = { [weak self] in self?.quit() }
        retention.read = { [weak self] in Self.retentionDays(of: self) }
        // « Historique… » du menu « … » n'existe que si un historique est branché.
        if realHistory != nil { panelModel.onOpenHistory = { [weak self] in self?.openSettings(tab: .history) } }

        panelModel.onOpen = { [permissions] in permissions.refresh() }
        panelModel.onModeChanged = { [weak self] id in self?.saveLastMode(id) }
        // Un clic sur la pastille Entretien au repos lance l'entretien, même déjà choisie (la dictée décide si c'est le moment).
        // Le changement de mode seul ne lance rien : un seul lancement par clic, et le raccourci d'un mode lance de son côté.
        panelModel.onChipTapped = { [weak self] id in self?.dictation.modeChosen(id) }

        if let notice = loaded.notice { log.notice("réglages : \(notice, privacy: .public)") }
    }

    /// L'assemblage de production de la mise en forme : le modèle de langage lit les réglages **en vigueur** de ce contrôleur
    /// (relais posé juste après la construction, car il n'existe pas encore) et les clés par `secrets`, sur la file commune des
    /// secrets. Le seul chemin par où l'application obtient son `RewriteEnvironment` ; `makeModel` n'est remplacé que par les
    /// tests, pour qu'aucune connexion ne s'ouvre.
    convenience init(
        settingsStore: SettingsStore,
        secrets: any SecretStore,
        hotKeyRegistrar: any HotKeyRegistrar,
        escapeRegistrar: any HotKeyRegistrar,
        makeModeHotKeyRegistrar: @escaping @MainActor () -> any HotKeyRegistrar,
        permissionsProbe: any PermissionsProbe,
        systemHotKeys: any SystemHotKeys,
        keyboardLayout: any KeyboardLayout,
        settingsView: @escaping SettingsViewProvider = AppController.emptySettings,
        makePanelSurface: @MainActor (AnyView) -> any PanelSurface,
        clickMonitor: any OutsideClickMonitor,
        makeSettingsWindow: @escaping SettingsWindowMaker,
        terminate: @escaping @MainActor () -> Void,
        dictation: DictationEnvironment = .unavailable,
        makeModel: @escaping @Sendable (ProviderKind, EndpointConfig) -> any LanguageModel,
        frontApplication: @escaping @MainActor () -> Int32? = { nil },
        inserter: TextInserter,
        holdWatch: HoldWatch = .system,
        terminationWait: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        reviewHandoverWait: @escaping @MainActor (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        interview: InterviewEnvironment = .unavailable,
        interviewHistory: (any InterviewHistoryStoring)? = nil,
        historyRoot: URL? = nil,
        announcer: any AccessibilityAnnouncing = SystemAccessibilityAnnouncer()
    ) {
        let current = ActionRelay()
        let access = SecretAccess(secrets)
        self.init(
            settingsStore: settingsStore, secrets: secrets, hotKeyRegistrar: hotKeyRegistrar,
            escapeRegistrar: escapeRegistrar, makeModeHotKeyRegistrar: makeModeHotKeyRegistrar,
            permissionsProbe: permissionsProbe, systemHotKeys: systemHotKeys, keyboardLayout: keyboardLayout,
            settingsView: settingsView, makePanelSurface: makePanelSurface, clickMonitor: clickMonitor,
            makeSettingsWindow: makeSettingsWindow, terminate: terminate, dictation: dictation,
            rewriter: LiveRewriter.environment(
                settings: { current.settings?() ?? .defaults }, secrets: access, makeModel: makeModel),
            frontApplication: frontApplication, inserter: inserter, holdWatch: holdWatch, terminationWait: terminationWait,
            reviewHandoverWait: reviewHandoverWait, interview: interview,
            // La résolution de l'entretien : les réglages en vigueur au lancement, les clés par la file commune des secrets, les
            // clients par `makeModel`, la voix par l'environnement (la cible `Supervox` y branche la vraie).
            resolveInterview: { settings, engine in
                try await InterviewSetup.resolve(
                    settings: settings, engine: engine, secrets: access, makeModel: makeModel, makeVoice: interview.makeVoice)
            },
            interviewHistory: interviewHistory, historyRoot: historyRoot, announcer: announcer)
        current.settings = { [weak self] in self?.settings }
    }

    /// Les réalisations du système : fichier de réglages de l'utilisateur, trousseau, Carbon,
    /// AVFoundation et Accessibilité. `dictation` : les moteurs de la dictée, `interview` : ceux de l'entretien (son réel, voix),
    /// que la cible `Supervox` construit (`SupervoxApp` ne dépend pas d'eux). `historyRoot` : le dossier de l'historique des
    /// entretiens, donné par la cible `Supervox` seule ; `nil` (le défaut) : pas d'historique. Tout le reste de l'assemblage (dont la mise en forme) est celui de l'init
    /// ci-dessus, que les tests exécutent.
    public convenience init(
        settingsView: @escaping SettingsViewProvider = SettingsView.provider,
        dictation: DictationEnvironment = .unavailable,
        interview: InterviewEnvironment = .unavailable,
        historyRoot: URL? = nil,
        inserter: TextInserter
    ) {
        let file = (try? SettingsStore.defaultFile())
            ?? URL.applicationSupportDirectory.appending(path: "Supervox/settings.json")
        self.init(
            settingsStore: SettingsStore(file: file),
            secrets: CachedSecretStore(KeychainSecretStore(service: "dev.supervox.app")),
            hotKeyRegistrar: CarbonHotKeyRegistrar(),
            escapeRegistrar: CarbonHotKeyRegistrar(),
            makeModeHotKeyRegistrar: { CarbonHotKeyRegistrar() },
            permissionsProbe: SystemPermissions(),
            systemHotKeys: SymbolicHotKeys(),
            keyboardLayout: SystemKeyboardLayout(),
            settingsView: settingsView,
            makePanelSurface: { FloatingPanelSurface(content: $0) },
            clickMonitor: GlobalClickMonitor(),
            makeSettingsWindow: { SettingsWindow(content: $0, onLeave: $1) },
            terminate: { NSApp.terminate(nil) },
            dictation: dictation, makeModel: LiveRewriter.client, frontApplication: FrontApplication.system,
            inserter: inserter, interview: interview, historyRoot: historyRoot,
            announcer: SystemAccessibilityAnnouncer())
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
    /// Le panneau s'ouvre aussi dès que le chargement a laissé un avis : sinon l'utilisateur pourrait ne jamais
    /// apprendre que son fichier a été mis de côté.
    ///
    /// Le panneau ne s'ouvre qu'une fois tout son contenu posé (accueil, avis) : la vraie surface prend sa taille à
    /// l'affichage.
    func launch() {
        let hotKeyNeedsPanel = applyHotKey()
        applyModeHotKeys()
        if isFirstLaunch {
            panelModel.welcome = Self.welcome(hotKeyLabel: panelModel.hotKeyLabel)
            do {
                try updateSettings { _ in }
            } catch {
                panelModel.setNotice(SettingsError.sentence(forSaveError: error), for: .save)
                log.error("réglages non créés : \(String(reflecting: type(of: error)), privacy: .public)")
            }
        }
        if hotKeyNeedsPanel || isFirstLaunch || hasLoadNotice { panel.open() }
        preloadEngines()
        purgeHistory()
    }

    /// La purge de l'historique au lancement : les entretiens plus vieux que la durée en vigueur sont supprimés, en tâche de fond.
    ///
    /// Seulement quand la durée est CELLE DE LA PERSONNE : au premier lancement (aucun réglage encore choisi) ou quand le fichier de
    /// réglages n'a pas été lu (illisible, mis de côté, d'une version plus récente), la durée en vigueur est le défaut de 30 jours,
    /// pas un choix : purger avec elle supprimerait des entretiens qu'elle voulait garder plus longtemps.
    ///
    /// Ces gardes ne regardent que CE lancement : un incident de réglages laisse, au lancement suivant, un fichier lisible qui dit 30
    /// jours sans que personne l'ait choisi. Le dossier de l'historique garde donc la durée que la personne a CONFIRMÉE dans
    /// l'onglet (`InterviewHistory.confirmedRetention`) : la purge ne part que si elle est absente (jamais réglée : la durée des
    /// réglages est le défaut annoncé) ou égale à celle des réglages. Différente ou illisible : aucune purge.
    private func purgeHistory() {
        guard let history else { return }
        guard !isFirstLaunch, !hasLoadNotice, saveRefusal == nil else {
            log.notice("historique : purge au lancement ignorée, durée de conservation non lue")
            return
        }
        let settingsDays = Self.retentionDays(of: self)
        historyPurgeTask = Task {
            // La durée des réglages n'est celle de la personne que si le dossier la reconnaît : remise à zéro, fichier mis de côté,
            // édité à la main ou illisible (lu 30 jours), elle diffère de la durée confirmée dans l'onglet, et RIEN n'est supprimé.
            switch await history.confirmedRetention() {
            case .absent: break
            case .days(let confirmed) where confirmed == settingsDays: break
            case .days, .unreadable:
                self.log.notice("historique : purge au lancement ignorée, durée de conservation différente de celle confirmée")
                return
            }
            _ = await history.purge()
        }
    }

    /// La durée de conservation en jours : celle des réglages en vigueur, bornée ; sans contrôleur (il a disparu), le défaut de 30
    /// jours. JAMAIS 0 : 0 veut dire « ne rien garder », et la purge effacerait tout.
    static func retentionDays(of controller: AppController?) -> Int {
        controller?.settings.history.normalized.retentionDays ?? HistorySettings.defaults.retentionDays
    }

    /// Prépare les moteurs des réglages courants en tâche de fond, hors du fil principal et à basse priorité : rien n'est
    /// attendu, l'affichage n'est pas retardé. L'environnement ne le fait que si tous les modèles sont déjà sur le disque,
    /// jamais en téléchargeant, et ses échecs sont silencieux.
    private func preloadEngines() {
        let environment = dictationEnvironment
        let transcription = settings.transcription
        preloadTask = Task.detached(priority: .utility) { await environment.preload(transcription) }
    }

    /// L'accueil du premier lancement ; `hotKeyLabel` est `nil` sans raccourci actif.
    public static func welcome(hotKeyLabel: String?) -> String {
        let opening =
            hotKeyLabel.map { "\($0) lance la dictée (et ouvre ce panneau), depuis n'importe quelle application." }
            ?? "Ouvrez ce panneau depuis l'icône de Supervox dans la barre de menus."
        return "Bienvenue dans Supervox. \(opening) Les réglages (fournisseurs, raccourci, permissions) s'ouvrent par « Réglages… », dans le menu « … » ci-dessous ou dans celui de l'icône de la barre de menus."
    }

    /// Relance de l'application déjà ouverte : le panneau s'ouvre, ou reste ouvert.
    func openPanelOnReopen() {
        log.notice("relance de l'application : ouverture du panneau")
        panel.open()
    }

    // MARK: - Raccourci

    /// Enregistre le raccourci des réglages et pose l'avis qui le concerne. Rend `true` si le panneau doit s'ouvrir
    /// pour le montrer : raccourci refusé, ou raccourci de macOS activé pas encore signalé. Ce dernier cas n'ouvre le
    /// panneau qu'une fois : la combinaison signalée est gardée dans les réglages (`systemConflictShown`), et l'avis
    /// reste posé aux lancements suivants sans ouvrir le panneau.
    private func applyHotKey() -> Bool {
        let hotKey = settings.hotKey
        switch hotKeys.apply(
            hotKey, onPress: { [weak self] in self?.hotKeyPressed() },
            onRelease: { [weak self] in self?.hotKeyReleased() })
        {
        case .success:
            let label = hotKey.label(layout: keyboardLayout)
            panelModel.hotKeyLabel = label
            log.notice("raccourci enregistré : \(label, privacy: .public) ; rappels d'appui et de relâchement posés")
            guard systemHotKeys.enabled().contains(hotKey) else {
                setGlobalHotKeyNotice(nil)
                return false
            }
            let message =
                "Le raccourci \(label) est aussi un raccourci de macOS activé sur ce Mac : il peut ne pas ouvrir le panneau. Choisissez-en un autre dans Réglages, ou désactivez celui de macOS (Réglages Système, Clavier, Raccourcis clavier)."
            setGlobalHotKeyNotice(message)
            log.notice("raccourci de macOS : \(label, privacy: .public)")
            guard settings.systemConflictShown != hotKey else { return false }
            recordShownSystemConflict(hotKey)
            return true
        case .failure(let error):
            panelModel.hotKeyLabel = hotKeys.active?.label(layout: keyboardLayout)
            let message = Self.message(for: error, label: hotKey.label(layout: keyboardLayout))
            setGlobalHotKeyNotice(message)
            log.notice("raccourci refusé : \(message, privacy: .public)")
            return true
        }
    }

    /// Garde la combinaison signalée sans passer par `updateSettings`, qui effacerait l'avis de chargement que le
    /// panneau doit montrer. Un fichier non enregistrable n'est pas touché ; un échec laisse le panneau s'ouvrir au
    /// prochain lancement, sans autre avis.
    private func recordShownSystemConflict(_ hotKey: HotKey) {
        guard saveRefusal == nil else { return }
        var updated = settings
        updated.systemConflictShown = hotKey
        do {
            try settingsStore.save(updated)
            settings = updated
        } catch {
            log.error("raccourci signalé non gardé : \(String(reflecting: type(of: error)), privacy: .public)")
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
        if let saveRefusal { throw saveRefusal }
        var updated = settings
        change(&updated)
        try settingsStore.save(updated)
        settings = updated
        panelModel.setNotice(nil, for: .save)
        // Le fichier mis de côté au lancement est remplacé par des réglages lisibles : l'avis n'a plus d'objet.
        panelModel.setNotice(nil, for: .settingsLoad)
        // Les pastilles et les raccourcis suivent les modes enregistrés ; le panneau ouvert est redimensionné.
        panelModel.setModes(updated.modes.map(\.chip))
        panel.contentChanged()
        applyModeHotKeys()
    }

    /// Enregistre `hotKey` comme raccourci global, avec le même effet que celui du lancement, et met à
    /// jour le libellé du panneau. N'enregistre pas les réglages. En cas de refus, l'ancien reste actif.
    public func changeHotKey(_ hotKey: HotKey) -> Result<Void, HotKeyError> {
        let result = hotKeys.apply(
            hotKey, onPress: { [weak self] in self?.hotKeyPressed() },
            onRelease: { [weak self] in self?.hotKeyReleased() })
        panelModel.hotKeyLabel = hotKeys.active?.label(layout: keyboardLayout)
        if case .success = result { setGlobalHotKeyNotice(nil) }
        return result
    }

    /// Donne ce raccourci à ce mode, ou le lui retire avec `nil`, avec le même effet que l'application des réglages : s'il est
    /// accepté, l'avis qui nommait ce mode s'efface. N'enregistre pas les réglages. En cas de refus, l'ancien reste actif.
    ///
    /// Un identifiant que les réglages ne portent pas (le mode a été supprimé pendant ce temps) est refusé : rien n'est
    /// enregistré auprès du système, aucun registraire n'est fabriqué. La réponse est `.refused` ; l'onglet Modes, qui vérifie
    /// l'existence du mode avant d'appeler, dit alors une phrase fixe.
    public func changeModeHotKey(_ hotKey: HotKey?, for modeID: String) -> Result<Void, HotKeyError> {
        guard settings.mode(modeID) != nil else { return .failure(.refused) }
        let result = modeHotKeys.set(hotKey, for: modeID)
        if case .success = result {
            modeHotKeyNotices[modeID] = nil
            publishHotKeyNotice()
        }
        return result
    }

    /// La phrase qui refuse cette combinaison pour ce détenteur, ou `nil` si elle est libre. Compare aux raccourcis attribués
    /// dans les réglages (celui d'un mode que le système a refusé au lancement garde sa combinaison), et aux raccourcis de macOS
    /// activés à cet instant.
    public func hotKeyRefusal(for candidate: HotKey, owner: HotKeyOwner) -> String? {
        var bindings: [String: HotKey] = [:]
        var names: [String: String] = [:]
        for mode in settings.modes {
            names[mode.id] = mode.name
            if let hotKey = mode.hotKey { bindings[mode.id] = hotKey }
        }
        return HotKeyConflicts.refusal(
            for: candidate, owner: owner, global: settings.hotKey, modes: bindings, names: names,
            systemEnabled: systemHotKeys.enabled(), layout: keyboardLayout)
    }

    /// Met les raccourcis des modes d'accord avec les réglages en vigueur, et dit dans le panneau lesquels ne le sont pas (une
    /// ligne par mode). Une combinaison déjà active n'est pas touchée.
    ///
    /// Une combinaison déjà utilisée n'est pas laissée au système : le raccourci global gagne toujours, puis, entre modes, le
    /// premier dans l'ordre des réglages. Le perdant n'est pas enregistré, et son avis nomme le détenteur. Un mode refusé
    /// n'ouvre pas le panneau : l'avis attend sa prochaine ouverture.
    private func applyModeHotKeys() {
        var bindings: [String: HotKey] = [:]
        var holders: [(hotKey: HotKey, name: String)] = []
        var notices: [String: String] = [:]
        for mode in settings.modes {
            guard let hotKey = mode.hotKey else { continue }
            let label = hotKey.label(layout: keyboardLayout)
            if hotKey == settings.hotKey {
                notices[mode.id] = Self.inactiveMessage(label: label, modeName: mode.name, holder: nil)
            } else if let holder = holders.first(where: { $0.hotKey == hotKey }) {
                notices[mode.id] = Self.inactiveMessage(label: label, modeName: mode.name, holder: holder.name)
            } else {
                bindings[mode.id] = hotKey
                holders.append((hotKey, mode.name))
            }
        }
        let refused = modeHotKeys.apply(
            bindings, onPress: { [weak self] in self?.dictation.modeHotKeyPressed($0) },
            onRelease: { [weak self] in self?.dictation.modeHotKeyReleased($0) })
        for mode in settings.modes {
            guard let error = refused[mode.id], let hotKey = mode.hotKey else { continue }
            notices[mode.id] = Self.message(
                for: error, label: hotKey.label(layout: keyboardLayout), modeName: mode.name)
        }
        // Un refus qui dure n'est journalisé qu'une fois : l'avis est recomposé à chaque enregistrement des réglages.
        for (id, notice) in notices where modeHotKeyNotices[id] != notice { log.notice("raccourci de mode non actif") }
        modeHotKeyNotices = notices
        publishHotKeyNotice()
    }

    private static func inactiveMessage(label: String, modeName: String, holder: String?) -> String {
        let user = holder.map { "le mode « \($0) »" } ?? "le raccourci général"
        return "Le raccourci \(label) du mode « \(modeName) » n'est pas actif : il est déjà utilisé par \(user). Changez-le dans Réglages, onglet Modes."
    }

    private func setGlobalHotKeyNotice(_ text: String?) {
        globalHotKeyNotice = text
        publishHotKeyNotice()
    }

    /// L'avis `.hotKey` : la ligne du raccourci global, puis une ligne par mode refusé, dans l'ordre des modes.
    private func publishHotKeyNotice() {
        var lines = [globalHotKeyNotice].compactMap { $0 }
        lines += settings.modes.compactMap { modeHotKeyNotices[$0.id] }
        panelModel.setNotice(lines.isEmpty ? nil : lines.joined(separator: "\n"), for: .hotKey)
    }

    private static func message(for error: HotKeyError, label: String, modeName: String) -> String {
        switch error {
        case .refused:
            "Le raccourci \(label) du mode « \(modeName) » a été refusé par macOS : choisissez-en un autre dans Réglages, onglet Modes."
        case .invalid:
            "Le raccourci \(label) du mode « \(modeName) » n'est pas valide : choisissez-en un autre dans Réglages, onglet Modes."
        }
    }

    /// Le temps d'une capture de raccourci : panneau fermé (Échap rendu) et raccourci global rendu au système.
    func suspendHotKeysForCapture() {
        panel.close()
        // Ce qui était actif avant : à la reprise, un refus ne dit « rétabli » que pour une combinaison qui l'était.
        if !modeHotKeys.isSuspended { modeHotKeysBeforeCapture = modeHotKeys.active }
        hotKeys.suspend()
        modeHotKeys.suspend()
    }

    /// Fin de capture : le raccourci global et ceux des modes, suspendus, sont réenregistrés s'ils le sont encore. Rend faux si
    /// le système refuse le raccourci global (la réponse ne parle que de lui) ; un mode refusé le dit dans le panneau.
    func resumeHotKeys() -> Bool {
        let restored = hotKeys.resume()
        panelModel.hotKeyLabel = hotKeys.active?.label(layout: keyboardLayout)
        if !restored {
            globalHotKeyNotice =
                "Le raccourci \(settings.hotKey.label(layout: keyboardLayout)) n'a pas pu être rétabli après la capture : macOS l'a refusé. Choisissez-en un autre dans Réglages."
            log.notice("raccourci non rétabli après la capture")
        }
        let activeBefore = modeHotKeysBeforeCapture
        modeHotKeysBeforeCapture = [:]
        for id in modeHotKeys.resume() {
            guard let mode = settings.mode(id), let hotKey = mode.hotKey else { continue }
            let label = hotKey.label(layout: keyboardLayout)
            // « Rétabli » est vrai seulement d'une combinaison qui était active avant la capture : celle qu'on a donnée pendant,
            // ou qu'un refus du lancement avait écartée, n'a jamais été prise ; elle n'a pas pu être enregistrée.
            if activeBefore[id] == hotKey {
                modeHotKeyNotices[id] =
                    "Le raccourci \(label) du mode « \(mode.name) » n'a pas pu être rétabli après la capture : macOS l'a refusé. Choisissez-en un autre dans Réglages, onglet Modes."
                log.notice("raccourci de mode non rétabli après la capture")
            } else {
                modeHotKeyNotices[id] =
                    "Le raccourci \(label) du mode « \(mode.name) » n'a pas pu être enregistré après la capture : macOS l'a refusé. Choisissez-en un autre dans Réglages, onglet Modes."
                log.notice("raccourci de mode non enregistré après la capture")
            }
        }
        publishHotKeyNotice()
        return restored
    }

    /// Le nom du mode qui tient déjà cette combinaison comme raccourci dans les réglages, `nil` si aucun ne la tient.
    func modeHolding(_ hotKey: HotKey) -> String? {
        settings.modes.first { $0.hotKey == hotKey }?.name
    }

    /// Plus aucun raccourci global.
    func clearHotKey() {
        hotKeys.clear()
        panelModel.hotKeyLabel = nil
    }

    // MARK: - Panneau

    /// Le raccourci mène à la dictée : bascule ou maintien, selon les réglages. Le panneau s'ouvre avec elle.
    private func hotKeyPressed() {
        log.notice("raccourci pressé")
        dictation.hotKeyPressed()
    }

    private func hotKeyReleased() {
        log.notice("raccourci relâché")
        dictation.hotKeyReleased()
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
            panelModel.setNotice(SettingsError.sentence(forSaveError: error), for: .save)
            log.error("réglages non enregistrés : \(String(reflecting: type(of: error)), privacy: .public)")
        }
    }

    // MARK: - Barre de menus

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = BrandMark.menuBarImage()
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

    /// Construit la fenêtre la première fois, puis la présente ; chaque présentation lance `onPresent`. `tab` : l'onglet à montrer ;
    /// sans lui, la fenêtre garde l'onglet courant (Fournisseurs à la première ouverture).
    func openSettings(tab: SettingsTab? = nil) {
        // Un onglet Historique n'est jamais choisi sans historique : la barre ne l'a pas.
        if let tab, tab != .history || history != nil { settingsNavigation.tab = tab }
        // L'entretien s'annule aussi quand le panneau est déjà fermé (la fermeture l'annule sinon) : rien n'est gardé.
        interview.cancel()
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
        // Ce que la personne a tapé dans la fenêtre des réglages (le gabarit de l'entretien) est enregistré avant la fin.
        settingsContent?.onLeave()
        interview.cancel()
        panel.close()
        log.notice("quitter")
        terminate()
    }

    // MARK: - Fin de l'application

    /// Ce que l'application fait quand le système demande la fin.
    public enum TerminationDecision: Equatable, Sendable {
        /// Rien n'est en cours : se terminer.
        case now
        /// Un collage est en cours : attendre sa fin (restauration du presse-papiers comprise), puis `reply(true)`.
        case afterInsertion
    }

    /// Durée maximale d'attente d'un collage en cours avant de se terminer quand même, en secondes. Un collage dure au plus la
    /// patience des modificateurs (1 s) et le délai de restauration (0,4 s), plus, pour le collage d'une relecture, l'attente
    /// de passation de la frappe (0,15 s), soit 1,55 s au plus ; 3 s laissent de la marge sans retenir l'utilisateur. Choix de
    /// conception, non mesuré.
    static let terminationTimeout = 3.0

    /// Appelé par le délégué à la demande de fin. Pendant un collage, quitter laisserait le texte dicté dans le presse-papiers et
    /// perdrait celui de l'utilisateur : la fin attend la restauration (bornée), puis appelle `reply(true)`. Une seconde demande
    /// pendant l'attente ne lance pas une seconde attente.
    public func requestTermination(reply: @escaping @MainActor (Bool) -> Void) -> TerminationDecision {
        // Fin demandée par le système (déconnexion, arrêt) : le gabarit tapé est enregistré aussi.
        settingsContent?.onLeave()
        guard dictation.isInserting else { return .now }
        if terminationTask == nil {
            let dictation = dictation
            let wait = terminationWait
            log.notice("fin différée : collage en cours")
            terminationTask = Task {
                await dictation.finishInsertion(timeout: Self.terminationTimeout, wait: wait)
                reply(true)
            }
        }
        return .afterInsertion
    }
}

/// La durée de conservation de l'historique, lue à chaque appel dans les réglages en vigueur du contrôleur. Posée avant que le
/// contrôleur soit entièrement construit (l'historique est fabriqué avant lui) : tant que `read` n'est pas posée, et si le contrôleur
/// a disparu, c'est le défaut des réglages, jamais 0.
@MainActor
final class RetentionSource {
    var read: @MainActor () -> Int = { HistorySettings.defaults.retentionDays }
    func days() -> Int { read() }
}

/// Relais d'actions, posé avant que le contrôleur soit entièrement construit.
@MainActor
private final class ActionRelay {
    var openSettings: (@MainActor () -> Void)?
    var quit: (@MainActor () -> Void)?
    var settings: (@MainActor () -> AppSettings?)?
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
