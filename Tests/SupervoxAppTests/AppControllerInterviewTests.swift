import AppKit
import Foundation
import SupervoxCore
import Testing

@testable import SupervoxApp

/// L'entretien dans l'application assemblée : raccourcis, Échap, menu, « Réglages… » et Quitter vers le contrôleur de l'entretien.
/// Réglages dans un dossier temporaire ; enregistreurs, surface, moniteur de clics, annonceur, environnement de l'entretien,
/// conversation et historique doubles. Aucun micro, aucun son, aucune annonce du système.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AppControllerInterviewTests {
    let directory: URL
    let store: SettingsStore
    let hotKeys = HotKeyTests.FakeRegistrar()
    let escape = HotKeyTests.FakeRegistrar()
    let modeRegistrars = ModeRegistrars()
    let surface = FakePanelSurface()
    let clicks = FakeClickMonitor()
    let presenter = Presenter()
    let engines = FakeEngines()
    let announcer = RecordingAnnouncer()
    let journal = Journal()
    let environment: FakeInterviewEnvironment
    let history = FakeInterviewHistory()
    let secrets = InMemorySecretStore()
    let holdSleeper = SleepingWait(log: CallLog())

    static let interviewKey = HotKey(keyCode: 0x02, modifiers: [.control, .option])
    static let rawKey = HotKeyTests.keyB

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervox-app-interview-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
        environment = FakeInterviewEnvironment(journal: journal)
        try secrets.write("cle-exemple", account: InterviewRig.provider.id.uuidString)
    }

    /// Des réglages qui permettent l'entretien, avec Dictée brute, un mode personnel et Entretien, chacun avec son raccourci.
    func settings(lastModeID: String = ModeChip.interviewID) -> AppSettings {
        var settings = InterviewRig.readySettings()
        settings.modes = [
            Mode(id: ModeChip.rawID, name: "Dictée brute", hotKey: Self.rawKey),
            Mode(id: "perso-un", name: "Compte rendu", instruction: "Résume.", hotKey: HotKey(keyCode: 0x08, modifiers: [.control, .option])),
            Mode(id: ModeChip.interviewID, name: "Entretien", hotKey: Self.interviewKey),
        ]
        settings.lastModeID = lastModeID
        return settings
    }

    func makeController(settings: AppSettings? = nil) throws -> AppController {
        try store.save(settings ?? self.settings())
        let fake = environment
        let access = SecretAccess(secrets, queue: DispatchQueue(label: "test.app.interview.\(UUID())"))
        let controller = AppController(
            settingsStore: store, secrets: secrets, hotKeyRegistrar: hotKeys,
            escapeRegistrar: escape, makeModeHotKeyRegistrar: { [modeRegistrars] in modeRegistrars.make() },
            permissionsProbe: FakePermissionsProbe(microphone: .granted, accessibility: .granted), systemHotKeys: FakeSystemHotKeys(),
            keyboardLayout: HotKeyTests.ansi, makePanelSurface: { [surface] _ in surface }, clickMonitor: clicks,
            makeSettingsWindow: presenter.make, terminate: presenter.terminate,
            dictation: engines.environment, rewriter: .unavailable, inserter: InsertionRig().inserter,
            holdWatch: HoldWatch(anyHeld: { _ in true }, wait: { [holdSleeper] in await holdSleeper.wait($0) }),
            reviewHandoverWait: { _ in },
            interview: fake.environment,
            resolveInterview: { settings, engine in
                try await InterviewSetup.resolve(
                    settings: settings, engine: engine, secrets: access, makeModel: { _, _ in ScriptedModel(.never) },
                    makeVoice: fake.environment.makeVoice)
            },
            interviewHistory: history, announcer: announcer)
        controller.launch()
        return controller
    }

    /// La conversation `index` démarrée, puis à l'écoute.
    func listening(_ controller: AppController, index: Int = 0) async throws -> ConversationDriver {
        let found = await until { environment.drivers.count > index && environment.drivers[index].starts > 0 }
        try #require(found, "aucune conversation démarrée")
        let driver = environment.drivers[index]
        driver.emit(.state(.listening))
        try #require(await until { controller.panelModel.interview?.phase == .listening })
        return driver
    }

    // MARK: - Lancement

    @Test("règle 1 : le raccourci global lance l'entretien du dernier mode, panneau ouvert, sans session de dictée ; l'annonce passe par le double")
    func theGlobalHotKeyLaunchesTheInterview() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController()
        hotKeys.press()
        #expect(controller.panelModel.isOpen)
        #expect(controller.panelModel.interview?.phase == .preparing)
        #expect(controller.panelModel.holdsPanel && controller.panelModel.modesLocked)
        #expect(controller.dictation.isBusy)
        _ = try await listening(controller)
        #expect(engines.sessions.isEmpty)
        #expect(announcer.spoken.contains(InterviewText.title(.listening)), "les titres sont annoncés par l'annonceur reçu")
    }

    @Test("règle 1 : le raccourci du mode Entretien le choisit, l'enregistre et lance l'entretien ; lui seul conclut")
    func theInterviewModesHotKeyLaunchesAndOnlyItConcludes() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController(settings: settings(lastModeID: ModeChip.rawID))
        modeRegistrars.press(Self.interviewKey)
        #expect(controller.panelModel.selectedModeID == ModeChip.interviewID)
        #expect(store.load().settings.lastModeID == ModeChip.interviewID)
        let driver = try await listening(controller)

        hotKeys.press()
        await settle()
        #expect(driver.concludes == 0, "le global n'est pas le propriétaire")
        modeRegistrars.press(Self.interviewKey)
        #expect(await until { driver.concludes == 1 })
        #expect(controller.panelModel.concludeRequested, "« Conclure » se grise")
    }

    @Test("règle 1 : un clic sur la pastille Entretien au repos la choisit, l'enregistre et lance l'entretien, une seule fois")
    func thePillLaunchesTheInterview() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController(settings: settings(lastModeID: ModeChip.rawID))
        controller.togglePanelFromMenu()
        #expect(controller.panelModel.isOpen)
        controller.panelModel.chipTapped(ModeChip.interviewID)
        #expect(controller.panelModel.selectedModeID == ModeChip.interviewID)
        #expect(store.load().settings.lastModeID == ModeChip.interviewID)
        #expect(controller.panelModel.interview?.phase == .preparing)
        _ = try await listening(controller)
        await settle()
        #expect(environment.prepareCount == 1, "un seul lancement : le changement de mode ne lance pas une seconde fois")
        #expect(environment.drivers.count == 1)
    }

    @Test("I-2 : un clic sur la pastille Entretien déjà choisie, au repos, lance l'entretien")
    func theAlreadyChosenInterviewPillLaunchesTheInterview() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController(settings: settings(lastModeID: ModeChip.interviewID))
        controller.togglePanelFromMenu()
        #expect(controller.panelModel.selectedModeID == ModeChip.interviewID)
        controller.panelModel.chipTapped(ModeChip.interviewID)
        #expect(controller.panelModel.interview?.phase == .preparing)
        _ = try await listening(controller)
        await settle()
        #expect(environment.prepareCount == 1)
        #expect(environment.drivers.count == 1)
    }

    @Test("I-2 : un clic sur une pastille de dictée déjà choisie ne lance rien")
    func theAlreadyChosenDictationPillLaunchesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController(settings: settings(lastModeID: ModeChip.rawID))
        controller.togglePanelFromMenu()
        controller.panelModel.chipTapped(ModeChip.rawID)
        await settle()
        #expect(controller.panelModel.selectedModeID == ModeChip.rawID)
        #expect(!controller.dictation.isBusy, "aucune dictée")
        #expect(engines.sessions.isEmpty)
        #expect(controller.panelModel.interview == nil, "aucun entretien")
        #expect(environment.prepareCount == 0 && environment.drivers.isEmpty)
    }

    @Test("I-2 : la pastille Entretien ne lance rien pendant une dictée")
    func theInterviewPillLaunchesNothingDuringADictation() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController(settings: settings(lastModeID: ModeChip.rawID))
        hotKeys.press()
        #expect(controller.dictation.isBusy, "une dictée est en cours")
        controller.panelModel.chipTapped(ModeChip.interviewID)
        await settle()
        #expect(controller.panelModel.interview == nil)
        #expect(environment.prepareCount == 0 && environment.drivers.isEmpty)
        escape.press()
    }

    @Test("I-2 : la pastille Entretien déjà choisie ne lance rien pendant la relecture d'un prompt")
    func theInterviewPillLaunchesNothingDuringAReview() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController()
        hotKeys.press()
        let driver = try await listening(controller)
        driver.finish(.prompt("Le prompt.", DictationInterviewTests.exchange))
        #expect(await until { controller.panelModel.dictation.stage == .review })
        #expect(controller.panelModel.selectedModeID == ModeChip.interviewID)
        controller.panelModel.chipTapped(ModeChip.interviewID)
        await settle()
        #expect(controller.panelModel.dictation.stage == .review, "la relecture reste")
        #expect(controller.panelModel.interview == nil)
        #expect(environment.drivers.count == 1, "aucun second entretien")
    }

    @Test("I-2 : la pastille Entretien déjà choisie ne fait rien pendant un entretien")
    func theInterviewPillDoesNothingDuringAnInterview() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController()
        hotKeys.press()
        let driver = try await listening(controller)
        controller.panelModel.chipTapped(ModeChip.interviewID)
        await settle()
        #expect(controller.panelModel.interview?.phase == .listening)
        #expect(environment.drivers.count == 1 && environment.prepareCount == 1)
        #expect(driver.concludes == 0 && driver.cancels == 0, "ni conclusion ni annulation")
    }

    @Test("T9-1 : le raccourci d'un autre mode pendant l'entretien : mode affiché, dernier mode enregistré et avis inchangés")
    func anotherModesHotKeyChangesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController()
        hotKeys.press()
        let driver = try await listening(controller)
        let dictation = controller.panelModel.dictation
        let shown = controller.panelModel.interview

        modeRegistrars.press(Self.rawKey)
        modeRegistrars.release(Self.rawKey)
        await settle()
        #expect(controller.panelModel.selectedModeID == ModeChip.interviewID)
        #expect(store.load().settings.lastModeID == ModeChip.interviewID)
        #expect(controller.panelModel.dictation == dictation)
        #expect(controller.panelModel.interview == shown)
        #expect(controller.panelModel.isOpen)
        #expect(driver.concludes == 0 && driver.cancels == 0)
        #expect(engines.sessions.isEmpty)
    }

    @Test("un clic en dehors pendant l'entretien ne ferme rien (le panneau est tenu)")
    func anOutsideClickKeepsTheInterview() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController()
        hotKeys.press()
        let driver = try await listening(controller)
        clicks.clickOutside()
        await settle()
        #expect(controller.panelModel.isOpen)
        #expect(controller.panelModel.interview?.phase == .listening)
        #expect(driver.cancels == 0)
    }

    // MARK: - T9-2 : tous les chemins de fin remettent l'entretien à zéro

    enum Ending: String, CaseIterable, Sendable {
        case prompt, failure, escape, closeFromMenu, settings, quit
    }

    @Test("T9-2 : chaque chemin de fin retire l'entretien ; à la réouverture, ni panneau tenu ni pastilles verrouillées", arguments: Ending.allCases)
    func everyEndingClearsTheInterview(ending: Ending) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController()
        hotKeys.press()
        let driver = try await listening(controller)
        // `NSApp` doit exister pour le menu principal de la fenêtre de réglages ; rien n'est affiché.
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }

        switch ending {
        case .prompt:
            driver.finish(.prompt("Le prompt.", DictationInterviewTests.exchange))
            #expect(await until { controller.panelModel.dictation.stage == .review })
            #expect(await until { history.saved.count == 1 }, "l'entretien conclu est enregistré")
            escape.press()
        case .failure:
            driver.finish(.failed(.microphone("silent"), Conversation()))
            #expect(await until { controller.panelModel.dictation.notice == InterviewText.failure(.microphone("silent")) })
            controller.togglePanelFromMenu()
        case .escape:
            escape.press()
        case .closeFromMenu:
            #expect(controller.panelMenuTitle == "Fermer le panneau")
            controller.togglePanelFromMenu()
        case .settings:
            controller.openSettings()
            #expect(presenter.windows.count == 1)
        case .quit:
            controller.quit()
            #expect(presenter.terminations == 1)
        }
        #expect(await until { controller.panelModel.interview == nil }, "\(ending)")
        #expect(!controller.panelModel.isOpen, "\(ending)")
        #expect(!controller.dictation.isBusy)
        if ending != .prompt {
            #expect(await until { driver.isFinished }, "la conversation est arrêtée")
            await settle()
            #expect(history.attempts == 0, "rien n'est enregistré")
        }
        #expect(environment.drivers.count == 1)

        controller.togglePanelFromMenu()
        #expect(controller.panelModel.isOpen)
        #expect(!controller.panelModel.holdsPanel, "\(ending)")
        #expect(!controller.panelModel.modesLocked, "\(ending)")
        #expect(controller.panelModel.interview == nil)
        #expect(controller.panelModel.select(ModeChip.rawID), "les pastilles répondent de nouveau")
    }
}
