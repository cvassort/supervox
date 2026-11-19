import AppKit
import Foundation
import SupervoxCore
import SwiftUI
import Testing

@testable import SupervoxApp

/// L'historique des entretiens dans l'application assemblée : la racine donnée (et JAMAIS un dossier réel quand elle ne l'est pas),
/// la purge au lancement et ses gardes, la durée relue à chaque appel, la navigation « Historique… » et le relais de copie.
/// Réglages et historique dans des dossiers temporaires ; enregistreurs, surface, fenêtre et insertion doubles.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AppControllerHistoryTests {
    let directory: URL
    let store: SettingsStore
    let secrets = RecordingSecretStore()
    let registrar = HotKeyTests.FakeRegistrar()
    let escape = HotKeyTests.FakeRegistrar()
    let modeRegistrars = ModeRegistrars()
    let surface = FakePanelSurface()
    let clicks = FakeClickMonitor()
    let presenter = Presenter()
    let insertion = InsertionRig()
    let catalog = FakeModelCatalog(models: [FakeModelCatalog.turbo])

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervox-app-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
    }

    var root: URL { directory.appendingPathComponent("entretiens-temporaires", isDirectory: true) }

    /// Réglages avec cette durée de conservation, enregistrés (un fichier lisible : ce n'est pas un premier lancement).
    func saveSettings(retention: Int) throws {
        var settings = AppSettings.defaults
        settings.history.retentionDays = retention
        try store.save(settings)
    }

    func makeController(historyRoot: URL?) -> AppController {
        AppController(
            settingsStore: store, secrets: secrets, hotKeyRegistrar: registrar,
            escapeRegistrar: escape, makeModeHotKeyRegistrar: { [modeRegistrars] in modeRegistrars.make() },
            permissionsProbe: FakePermissionsProbe(microphone: .granted, accessibility: .granted),
            systemHotKeys: FakeSystemHotKeys(), keyboardLayout: HotKeyTests.ansi,
            settingsView: SettingsView.provider(catalog: catalog, promptTokenLimit: 111),
            makePanelSurface: { [surface] _ in surface }, clickMonitor: clicks,
            makeSettingsWindow: presenter.make, terminate: presenter.terminate,
            rewriter: .unavailable, inserter: insertion.inserter, historyRoot: historyRoot,
            announcer: RecordingAnnouncer())
    }

    /// Un entretien daté d'il y a `daysAgo` jours (par rapport à maintenant : le contrôleur lit l'horloge réelle).
    static func record(_ n: Int, daysAgo: Double) -> InterviewRecord {
        InterviewRecord(
            id: InterviewHistoryTests.id(n), date: Date().addingTimeInterval(-daysAgo * 86_400),
            prompt: "Un prompt d'exemple.", conversation: InterviewRecordTests.shortConversation())
    }

    /// Dépose des entretiens dans `root` sans passer par le contrôleur : un autre magasin, qui garde tout.
    func seed(_ records: [InterviewRecord]) async throws {
        let seeder = InterviewHistory(root: root, retentionDays: { 3650 })
        for record in records { try await seeder.save(record) }
    }

    func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    /// Le menu principal de l'application est remplacé à l'ouverture de la fenêtre de réglages : rétabli à la fin du test.
    func preservingTheMainMenu(_ body: () throws -> Void) rethrows {
        _ = NSApplication.shared
        let previous = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previous }
        try body()
    }

    // MARK: - Sans racine : aucun historique, nulle part

    @Test("amendement : sans racine (nil), pas d'historique : ni dossier, ni onglet, ni entrée du menu, ni purge ; nil n'est jamais « le vrai dossier »")
    func withoutARootThereIsNoHistoryAnywhere() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try saveSettings(retention: 30)
        let controller = makeController(historyRoot: nil)

        controller.launch()

        #expect(controller.history == nil)
        #expect(controller.historyPurgeTask == nil, "aucune purge")
        #expect(!controller.panelModel.canOpenHistory, "pas d'entrée « Historique… »")
        #expect(SettingsView.makeHistoryModel(controller) == nil)
        let content = SettingsView.provider(catalog: catalog, promptTokenLimit: 111)(controller)
        #expect(content.tabs == SettingsTab.visible(hasInterview: true, hasVoices: true, hasHistory: false))
        #expect(!content.tabs.contains(.history))
        preservingTheMainMenu {
            controller.openSettings(tab: .history)
            #expect(controller.settingsNavigation.tab != .history, "un onglet absent n'est jamais choisi")
        }
        #expect(!FileManager.default.fileExists(atPath: root.path), "rien n'est créé à côté")
    }

    // MARK: - Avec racine

    @Test("avec une racine : l'historique existe, l'onglet ferme la barre, l'entrée du menu existe, le modèle est construit")
    func aRootGivesTheTabTheMenuEntryAndTheModel() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try saveSettings(retention: 30)
        let controller = makeController(historyRoot: root)

        #expect(controller.history != nil)
        #expect(controller.panelModel.canOpenHistory)
        #expect(SettingsView.makeHistoryModel(controller) != nil)
        let content = SettingsView.provider(catalog: catalog, promptTokenLimit: 111)(controller)
        #expect(content.tabs == SettingsTab.visible(hasInterview: true, hasVoices: true, hasHistory: true))
        #expect(content.tabs.last == .history)
        #expect(content.tabs.suffix(2) == [.voices, .history], "Voix juste avant Historique")
    }

    @Test("règle 8 : « Historique… » du menu « … » ouvre la fenêtre sur Historique, ou y ramène la fenêtre déjà ouverte sur un autre onglet")
    func theMenuEntryOpensTheSettingsOnTheHistoryTab() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try saveSettings(retention: 30)
        let controller = makeController(historyRoot: root)
        controller.launch()
        preservingTheMainMenu {
            #expect(controller.settingsNavigation.tab == .providers)

            controller.panelModel.openHistory()

            #expect(controller.settingsNavigation.tab == .history)
            #expect(presenter.windows.count == 1)
            #expect(presenter.windows.first?.presentations == 1)

            controller.settingsNavigation.tab = .modes  // la personne a cliqué sur Modes
            controller.panelModel.openHistory()

            #expect(controller.settingsNavigation.tab == .history)
            #expect(presenter.windows.count == 1, "la même fenêtre")
            #expect(presenter.windows.first?.presentations == 2)
        }
    }

    // MARK: - Purge au lancement

    @Test("règle 3 : au lancement, la purge supprime les entretiens plus vieux que la durée des réglages, pas les autres")
    func launchPurgesWhatIsOlderThanTheRetention() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try saveSettings(retention: 30)
        try await seed([Self.record(1, daysAgo: 10), Self.record(2, daysAgo: 40)])
        let controller = makeController(historyRoot: root)

        controller.launch()
        let task = try #require(controller.historyPurgeTask, "le lancement lance la purge")
        #expect(await bounded(task) != nil)

        let remaining = await controller.history?.list() ?? []
        #expect(remaining.map(\.id) == [InterviewHistoryTests.id(1)])
    }

    @Test("au premier lancement (aucun réglage choisi encore), la purge n'a pas lieu : le défaut de 30 jours n'est pas un choix")
    func theFirstLaunchDoesNotPurge() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // Aucun fichier de réglages.
        try await seed([Self.record(1, daysAgo: 400)])
        let controller = makeController(historyRoot: root)

        controller.launch()
        await settle()

        #expect(controller.historyPurgeTask == nil)
        #expect(names().count == 1)
    }

    @Test("un fichier de réglages illisible : la durée par défaut n'est pas celle de la personne, la purge n'a pas lieu")
    func anUnreadableSettingsFileDoesNotPurge() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("pas du json".utf8).write(to: store.file)
        try await seed([Self.record(1, daysAgo: 400)])
        let controller = makeController(historyRoot: root)

        controller.launch()
        await settle()

        #expect(controller.historyPurgeTask == nil)
        #expect(names().count == 1, "l'entretien de 400 jours reste")
    }

    // MARK: - C-1 : la durée confirmée du dossier garde le lancement d'une durée non choisie

    /// Écrit la durée confirmée du dossier sans passer par le contrôleur (ce que l'onglet a fait lors d'un choix passé).
    func confirm(_ days: Int) async throws {
        try await InterviewHistory(root: root, retentionDays: { 3650 }).confirmRetention(days)
    }

    func launched(_ controller: AppController) async {
        controller.launch()
        if let task = controller.historyPurgeTask { #expect(await bounded(task) != nil) }
    }

    func entretiens() -> [String] { names().filter { $0.hasSuffix(".json") } }

    @Test("C-1 : après un incident de réglages (fichier mis de côté), le lancement SUIVANT ne purge pas avec le défaut quand le dossier a confirmé 365 jours")
    func aLaunchAfterTheSettingsWereSetAsideDoesNotPurgeWithTheDefault() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("pas du json".utf8).write(to: store.file)
        try await seed([Self.record(1, daysAgo: 400)])
        try await confirm(365)
        await launched(makeController(historyRoot: root))  // lancement N : mis de côté, pas de purge

        let next = makeController(historyRoot: root)  // lancement N+1 : fichier absent, copie mise de côté, aucun avis
        await launched(next)

        #expect(entretiens().count == 1, "l'entretien de 400 jours reste : 30 jours n'est pas ce que la personne a choisi")
    }

    @Test("C-1 : après un premier lancement qui a écrit le défaut de 30 jours, le lancement suivant ne purge pas quand le dossier a confirmé 365 jours")
    func theLaunchAfterAFirstLaunchDoesNotPurgeWithAnUnchosenDefault() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try await seed([Self.record(1, daysAgo: 400)])
        try await confirm(365)
        await launched(makeController(historyRoot: root))  // premier lancement : pas de purge, écrit 30 jours
        #expect(store.load().settings.history.retentionDays == 30)

        await launched(makeController(historyRoot: root))

        #expect(entretiens().count == 1)
    }

    @Test("C-1 (décision 4) : sans durée confirmée, la purge à la durée des réglages A lieu au lancement suivant (le défaut annoncé)")
    func withoutAConfirmedRetentionTheDefaultStillPurges() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try await seed([Self.record(1, daysAgo: 400), Self.record(2, daysAgo: 5)])
        await launched(makeController(historyRoot: root))  // premier lancement
        #expect(entretiens().count == 2)

        await launched(makeController(historyRoot: root))

        #expect(entretiens().count == 1, "400 jours > 30 jours : supprimé ; 5 jours : gardé")
    }

    @Test("C-1 : un fichier de réglages édité à la main (\"retentionDays\": \"365\", lu 30) avec 365 confirmés : pas de purge")
    func aHandEditedRetentionReadAsTheDefaultDoesNotPurge() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try saveSettings(retention: 30)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: Any])
        object["history"] = ["retentionDays": "365"]
        try JSONSerialization.data(withJSONObject: object).write(to: store.file)
        #expect(store.load().settings.history.retentionDays == 30, "la valeur de la mauvaise forme se lit 30 sans avis")
        #expect(store.load().notice == nil)
        try await seed([Self.record(1, daysAgo: 400)])
        try await confirm(365)

        await launched(makeController(historyRoot: root))

        #expect(entretiens().count == 1)
    }

    @Test("C-1 : une durée confirmée illisible : pas de purge")
    func anUnreadableConfirmedRetentionDoesNotPurge() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try saveSettings(retention: 30)
        try await seed([Self.record(1, daysAgo: 400)])
        try Data("pas du json".utf8).write(to: root.appendingPathComponent("conservation"))

        await launched(makeController(historyRoot: root))

        #expect(entretiens().count == 1)
    }

    @Test("C-1 : la durée confirmée d'accord avec les réglages : la purge a lieu")
    func anAgreeingConfirmedRetentionPurges() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try saveSettings(retention: 90)
        try await seed([Self.record(1, daysAgo: 400), Self.record(2, daysAgo: 60)])
        try await confirm(90)

        await launched(makeController(historyRoot: root))

        #expect(entretiens().count == 1, "400 jours supprimé, 60 jours gardé")
        #expect(names().contains("conservation"), "la durée confirmée reste")
    }

    @Test("C-1 : choisir la durée dans l'onglet réécrit la durée confirmée et la ligne de l'onglet disparaît")
    func choosingTheDurationAgainRestoresThePurge() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try saveSettings(retention: 30)
        try await seed([Self.record(1, daysAgo: 100)])
        try await confirm(365)
        let controller = makeController(historyRoot: root)
        let model = try #require(SettingsView.makeHistoryModel(controller))
        await model.reload()
        #expect(model.retentionNote != nil, "la ligne dit que la durée a changé hors de l'onglet")

        let task = await model.requestRetention(365)  // la personne choisit 1 an : plus long, rien à supprimer
        #expect(await bounded(try #require(task)) != nil)
        await model.reload()

        #expect(controller.settings.history.retentionDays == 365)
        #expect(model.retentionNote == nil)
        #expect(await controller.history?.confirmedRetention() == .days(365))
    }

    // MARK: - I-R1 : la durée confirmée s'écrit AVANT les réglages

    func settingsRetentionOnDisk() -> Int { store.load().settings.history.retentionDays }

    @Test("I-R1 (scénario A) : la durée confirmée ne peut pas être écrite (un dossier occupe son nom) : les réglages restent à l'ancienne durée et AUCUNE purge n'a lieu")
    func aFailedConfirmationLeavesTheSettingsAtTheirOldDuration() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try saveSettings(retention: 30)
        try await seed([Self.record(1, daysAgo: 100)])
        // Un dossier au nom du fichier de durée : le renommage échoue, MAIS la racine reste inscriptible : une purge lancée à tort à 30
        // jours supprimerait l'entretien de 100 jours (l'assertion « aucune purge » a donc du pouvoir ; avec une racine immuable aucune
        // suppression n'aboutirait, purge ou non).
        try FileManager.default.createDirectory(at: root.appendingPathComponent("conservation"), withIntermediateDirectories: false)
        let controller = makeController(historyRoot: root)
        let model = try #require(SettingsView.makeHistoryModel(controller))
        await model.reload()

        let task = await model.requestRetention(365)
        #expect(await bounded(try #require(task)) != nil)

        #expect(model.message == HistoryModel.writeFailure)
        #expect(settingsRetentionOnDisk() == 30, "sans la durée confirmée, les réglages ne disent pas 365")
        #expect(controller.settings.history.retentionDays == 30)
        #expect(await controller.history?.confirmedRetention() == .unreadable, "le dossier au nom du fichier est toujours là")
        #expect(entretiens().count == 1, "aucune purge : à 30 jours elle aurait supprimé l'entretien de 100 jours")
    }

    @Test("I-R1 (scénario B) : ancien fichier confirmé à 30 jours, 365 choisi et l'écriture refusée : le fichier ET les réglages restent à 30")
    func aFailedConfirmationOverAnOldFileLeavesBothAtThirty() async throws {
        defer {
            chflags(root.path, 0)
            try? FileManager.default.removeItem(at: directory)
        }
        try saveSettings(retention: 30)
        try await seed([Self.record(1, daysAgo: 20)])
        try await confirm(30)
        let controller = makeController(historyRoot: root)
        let model = try #require(SettingsView.makeHistoryModel(controller))
        await model.reload()
        #expect(chflags(root.path, UInt32(UF_IMMUTABLE)) == 0)

        let task = await model.requestRetention(365)
        #expect(await bounded(try #require(task)) != nil)
        #expect(chflags(root.path, 0) == 0)

        #expect(model.message == HistoryModel.writeFailure)
        #expect(settingsRetentionOnDisk() == 30)
        #expect(await controller.history?.confirmedRetention() == .days(30))
    }

    @Test("I-R1 (scénario C) : réglages refusés APRÈS la durée confirmée : au lancement suivant, aucune purge, et la ligne de l'onglet est là")
    func aSettingsRefusalAfterTheConfirmationDoesNotPurgeAtTheNextLaunch() async throws {
        defer {
            chmod(directory.path, 0o700)
            try? FileManager.default.removeItem(at: directory)
        }
        try saveSettings(retention: 30)
        try await seed([Self.record(1, daysAgo: 100)])
        let controller = makeController(historyRoot: root)
        let model = try #require(SettingsView.makeHistoryModel(controller))
        await model.reload()
        // Le dossier des réglages refuse toute écriture ; le dossier de l'historique (un sous-dossier déjà créé) l'accepte.
        #expect(chmod(directory.path, 0o500) == 0)

        let task = await model.requestRetention(365)
        #expect(await bounded(try #require(task)) != nil)
        #expect(chmod(directory.path, 0o700) == 0)

        #expect(model.message != nil && model.messageIsFailure, "l'échec des réglages est dit")
        #expect(await controller.history?.confirmedRetention() == .days(365), "le dossier est en avance")
        #expect(settingsRetentionOnDisk() == 30)

        let next = makeController(historyRoot: root)
        await launched(next)
        #expect(entretiens().count == 1, "30 jours ne s'applique pas : le dossier a confirmé 365")
        let nextModel = try #require(SettingsView.makeHistoryModel(next))
        await nextModel.reload()
        #expect(nextModel.retentionNote == HistoryModel.retentionChangedNote)
    }

    // MARK: - Durée relue

    @Test("règle 3 : la durée est relue dans les réglages en vigueur à chaque purge : la changer s'applique sans relancer")
    func theRetentionFollowsTheLiveSettings() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try saveSettings(retention: 30)
        try await seed([Self.record(1, daysAgo: 40)])
        let controller = makeController(historyRoot: root)
        let history = try #require(controller.history)

        try controller.updateSettings { $0.history.retentionDays = 90 }
        #expect(await history.purge() == 0, "90 jours : l'entretien de 40 jours reste")

        try controller.updateSettings { $0.history.retentionDays = 7 }
        #expect(await history.purge() == 1, "7 jours : il part")
    }

    @Test("la durée de repli n'est jamais 0 : sans contrôleur, ou avant que la lecture soit posée, c'est le défaut des réglages")
    func theFallbackRetentionIsNeverZero() async throws {
        #expect(AppController.retentionDays(of: nil) == HistorySettings.defaults.retentionDays)
        #expect(AppController.retentionDays(of: nil) != 0)
        #expect(RetentionSource().days() == HistorySettings.defaults.retentionDays)

        defer { try? FileManager.default.removeItem(at: directory) }
        try saveSettings(retention: 0)
        let controller = makeController(historyRoot: root)
        #expect(AppController.retentionDays(of: controller) == 0, "un choix de la personne (Ne rien garder) est lu tel quel")
    }

    // MARK: - Relais de copie et écriture de la durée

    @Test("règle 4 : Copier passe par l'insertion du contrôleur (presse-papiers double), jamais le presse-papiers général")
    func copyingGoesThroughTheControllersInsertion() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try saveSettings(retention: 30)
        try await seed([Self.record(1, daysAgo: 1)])
        let controller = makeController(historyRoot: root)
        let model = try #require(SettingsView.makeHistoryModel(controller))
        await model.reload()

        model.copyPrompt()

        #expect(insertion.board.contents == FakePasteboard.textContents("Un prompt d'exemple."))
        #expect(model.message == "Copié.")
    }

    @Test("l'onglet écrit la durée par AppController.updateSettings : réglages en mémoire et fichier, sans écraser le reste")
    func theTabWritesTheRetentionThroughTheController() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try saveSettings(retention: 30)
        let controller = makeController(historyRoot: root)
        try controller.updateSettings { $0.interview.maxQuestions = 5 }
        let model = try #require(SettingsView.makeHistoryModel(controller))
        await model.reload()

        let task = await model.requestRetention(90)
        #expect(await bounded(try #require(task)) != nil)

        #expect(controller.settings.history.retentionDays == 90)
        let onDisk = store.load().settings
        #expect(onDisk.history.retentionDays == 90)
        #expect(onDisk.interview.maxQuestions == 5, "le reste n'est pas écrasé")
    }
}
