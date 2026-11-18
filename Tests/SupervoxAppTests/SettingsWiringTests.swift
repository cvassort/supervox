import AppKit
import Foundation
import SwiftUI
import Testing

@testable import SupervoxApp

/// Le contrôleur et la fenêtre de réglages : un seul détenteur des réglages, le raccourci réappliqué,
/// et une fenêtre construite sans lire aucune clé.
@MainActor @Suite(.timeLimit(.minutes(1))) struct SettingsWiringTests {
    let directory: URL
    let store: SettingsStore
    let secrets = RecordingSecretStore()
    let registrar = HotKeyTests.FakeRegistrar()
    let escape = HotKeyTests.FakeRegistrar()
    let modeRegistrars = ModeRegistrars()
    let surface = FakePanelSurface()
    let clicks = FakeClickMonitor()
    let presenter = Presenter()
    let monitor = FakeKeyMonitor()
    let catalog = FakeModelCatalog(models: [FakeModelCatalog.turbo])
    static let promptTokenLimit = 111

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervox-settings-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
    }

    /// Un fichier de réglages existe toujours (réglages par défaut) : `launch()` suit le chemin d'un lancement ordinaire.
    func makeController(
        settingsView: @escaping AppController.SettingsViewProvider = AppController.emptySettings,
        interview: InterviewEnvironment = .unavailable
    ) -> AppController {
        if !FileManager.default.fileExists(atPath: store.file.path) { try? store.save(.defaults) }
        return AppController(
            settingsStore: store, secrets: secrets, hotKeyRegistrar: registrar,
            escapeRegistrar: escape, makeModeHotKeyRegistrar: { [modeRegistrars] in modeRegistrars.make() },
            permissionsProbe: FakePermissionsProbe(microphone: .granted, accessibility: .granted),
            systemHotKeys: FakeSystemHotKeys(), keyboardLayout: HotKeyTests.ansi, settingsView: settingsView,
            makePanelSurface: { [surface] _ in surface }, clickMonitor: clicks,
            makeSettingsWindow: presenter.make, terminate: presenter.terminate,
            rewriter: .unavailable, inserter: InsertionRig().inserter, interview: interview, announcer: RecordingAnnouncer())
    }

    /// Attend la présentation de la fenêtre ; une annulation du test (limite de temps) l'annule aussi, au lieu de laisser le test
    /// suspendu sur `.value`.
    func finished(_ task: Task<Void, Never>?) async {
        guard let task else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Les modèles que la fenêtre de test a reçus, pour agir comme l'utilisateur.
    @MainActor final class Built {
        var hotKey: HotKeySettingsModel?
        var modes: ModesModel?
        var interview: InterviewSettingsModel?
        var content: SettingsContent?
    }

    /// La vraie composition de la fenêtre (`SettingsView.content`), avec disposition et moniteur de touches doubles.
    func testProvider(_ built: Built) -> AppController.SettingsViewProvider {
        { [monitor] controller in
            let hotKey = SettingsView.makeHotKeyModel(controller, keyMonitor: monitor)
            built.hotKey = hotKey
            let modes = SettingsView.makeModesModel(controller, keyMonitor: monitor)
            built.modes = modes
            let interview = SettingsView.makeInterviewModel(controller)
            built.interview = interview
            let content = SettingsView.content(
                providers: SettingsView.makeProvidersModel(controller), hotKey: hotKey,
                transcription: SettingsView.makeTranscriptionModel(
                    controller, catalog: catalog, promptTokenLimit: Self.promptTokenLimit),
                modes: modes,
                permissions: controller.permissions, openSystemSettings: { _ in }, interview: interview,
                navigation: controller.settingsNavigation)
            built.content = content
            return content
        }
    }

    /// Une combinaison tenue par un mode est refusée au raccourci global, avec le nom du mode, sans solliciter le système ; et la
    /// capture rend aussi les raccourcis des modes.
    @Test func theGlobalCaptureRefusesAModesCombinationAndSuspendsTheModesHotKeys() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings.defaults
        settings.modes[1].hotKey = HotKeyTests.keyB
        settings.modes[1].name = "Compte rendu"
        try store.save(settings)
        let controller = makeController()
        controller.launch()
        let hotKey = SettingsView.makeHotKeyModel(controller, keyMonitor: monitor)
        #expect(modeRegistrars.registered == [HotKeyTests.keyB])

        hotKey.startRecording()
        #expect(modeRegistrars.registered.isEmpty, "la capture rend les raccourcis des modes au système")
        let calls = registrar.registerCalls
        hotKey.record(HotKeyTests.keyB)
        #expect(hotKey.message?.contains("Compte rendu") == true)
        #expect(registrar.registerCalls == calls + 1, "seul le rétablissement de la capture : ⌃⌥B n'est pas proposé au système")
        #expect(controller.settings.hotKey == .standard)
        #expect(registrar.registered == .standard)
        #expect(modeRegistrars.registered == [HotKeyTests.keyB], "la capture finie, le raccourci du mode est rétabli")
    }

    /// N1 : fenêtre fermée, quittée ou application passée en arrière-plan pendant une capture : la capture prend fin,
    /// le moniteur de touches est retiré et le raccourci global est réenregistré.
    @Test func leavingTheSettingsWindowEndsTheCaptureAndRestoresTheHotKey() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let built = Built()
        let controller = makeController(settingsView: testProvider(built))
        controller.launch()
        controller.openSettings()
        let window = try #require(presenter.windows.first)
        let hotKey = try #require(built.hotKey)

        hotKey.startRecording()
        #expect(registrar.registered == nil)
        #expect(monitor.isActive)

        window.leave()
        #expect(!hotKey.isRecording)
        #expect(!monitor.isActive)
        #expect(registrar.registered == .standard)
        registrar.press()
        #expect(controller.panelModel.isOpen)
    }

    /// N1 : le raccourci ne peut pas être réenregistré à la fin de la capture ; le panneau le dit.
    @Test func failedRestoreAfterTheCaptureIsAnnouncedInThePanel() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let built = Built()
        let controller = makeController(settingsView: testProvider(built))
        controller.launch()
        controller.openSettings()
        let window = try #require(presenter.windows.first)
        let hotKey = try #require(built.hotKey)

        hotKey.startRecording()
        registrar.refused = [.standard]
        window.leave()

        let notice = try #require(controller.panelModel.notices[.hotKey])
        #expect(notice.contains(HotKey.standard.label(layout: HotKeyTests.ansi)))
        #expect(notice.contains("n'a pas pu être rétabli"))
        #expect(controller.panelModel.hotKeyLabel == nil)
    }

    /// L'ouverture de la fenêtre demande quelles clés existent, sans en lire aucune. Une fois l'état connu,
    /// une nouvelle ouverture ne redemande rien (`checkKeys` ne demande que les états inconnus).
    @Test func openingTheSettingsChecksWhichKeysExist() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let provider = Provider(id: UUID(), name: "Local", baseURL: "http://localhost:1", kind: .openAICompatible, models: [])
        try store.save(AppSettings(version: 1, providers: [provider], hotKey: .standard, hotKeyBehavior: .toggle, lastModeID: "prompt"))
        let controller = makeController(settingsView: testProvider(Built()))
        #expect(secrets.calls.isEmpty)

        controller.openSettings()
        await finished(controller.settingsPresentation)
        #expect(secrets.calls.map(\.name) == ["contains"])

        controller.openSettings()
        await finished(controller.settingsPresentation)
        #expect(secrets.calls.map(\.name) == ["contains"])
        #expect(secrets.readCount == 0)
    }

    /// Les réglages de transcription passent par `updateSettings`, comme le reste : une seule copie vivante.
    @Test func transcriptionChangesAreSavedThroughTheController() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        let transcription = SettingsView.makeTranscriptionModel(
            controller, catalog: catalog, promptTokenLimit: Self.promptTokenLimit)
        #expect(transcription.settings == .defaults)

        transcription.setEngine(.parakeet)
        transcription.setLanguage("en")
        controller.panelModel.select("prompt")
        await transcription.setVocabulary(text: "Docker")

        let onDisk = store.load().settings
        #expect(onDisk.transcription.engine == .parakeet)
        #expect(onDisk.transcription.language == "en")
        #expect(onDisk.transcription.vocabulary == ["Docker"])
        #expect(onDisk.lastModeID == "prompt")
        #expect(controller.settings == onDisk)
    }

    /// Les choix de l'onglet Modes passent par `updateSettings`, comme le reste : le fichier, puis les réglages en vigueur.
    @Test func reviewChoicesAreSavedThroughTheController() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        let modes = SettingsView.makeModesModel(controller, keyMonitor: monitor)
        #expect(!controller.settings.reviewsBeforePaste(ModeChip.rawID))

        modes.setReview(true, for: ModeChip.rawID)

        let onDisk = store.load().settings
        #expect(onDisk.mode(ModeChip.rawID)?.reviewBeforePaste == true)
        #expect(onDisk.reviewsBeforePaste(ModeChip.rawID))
        #expect(controller.settings == onDisk)
        #expect(controller.settings.reviewsBeforePaste(ModeChip.rawID))
        #expect(modes.rows.first { $0.id == ModeChip.rawID }?.reviews == true)
        #expect(modes.message == nil)

        // Un modèle construit plus tard part des choix enregistrés.
        let reopened = SettingsView.makeModesModel(controller, keyMonitor: monitor)
        #expect(reopened.rows.map(\.reviews) == [true, false, true, true])
    }

    /// Règle 9 : renommer un mode par l'onglet écrit `settings.json` et change la pastille du panneau.
    @Test func renamingAModeWritesTheFileAndChangesTheChipOfThePanel() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        controller.launch()
        let modes = SettingsView.makeModesModel(controller, keyMonitor: monitor)
        #expect(controller.panelModel.modes.map(\.title) == ["Dictée brute", "Dictée nettoyée", "Prompt", "Entretien"])

        var draft = modes.draft(for: ModeChip.cleanedID)
        draft.name = "Mise au propre"
        #expect(modes.save(draft))

        #expect(store.load().settings.mode(ModeChip.cleanedID)?.name == "Mise au propre")
        #expect(controller.settings == store.load().settings)
        #expect(controller.panelModel.modes.map(\.title) == ["Dictée brute", "Mise au propre", "Prompt", "Entretien"])
        #expect(modes.rows.map(\.title) == controller.panelModel.modes.map(\.title))
    }

    /// Créer, dupliquer, déplacer, supprimer : le panneau suit, et le fichier aussi.
    @Test func creatingDuplicatingMovingAndDeletingModesFollowsInThePanelAndTheFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        controller.launch()
        let modes = SettingsView.makeModesModel(controller, keyMonitor: monitor)

        let created = modes.add()
        let copy = modes.duplicate(ModeChip.promptID)
        modes.move(created, by: -2)
        // Avant le déplacement : Dictée brute, Dictée nettoyée, Prompt, la copie, Entretien, le mode créé (à la fin).
        let onDisk = store.load().settings
        #expect(onDisk.modes.map(\.id) == controller.panelModel.modes.map(\.id))
        #expect(onDisk.modes.map(\.id) == [ModeChip.rawID, ModeChip.cleanedID, ModeChip.promptID, created, copy, ModeChip.interviewID])
        #expect(onDisk.mode(copy)?.instruction == ModeDefaults.prompt)

        modes.delete(created)
        #expect(!store.load().settings.modes.contains { $0.id == created })
        #expect(!controller.panelModel.modes.contains { $0.id == created })
        #expect(modes.rows.map(\.id) == controller.panelModel.modes.map(\.id))
    }

    /// Un mode que l'onglet écrit ne défait rien de ce que le fichier porte d'autre : champs inconnus, consigne, moteur, raccourci
    /// d'un autre mode ; et une écriture faite ailleurs entre la création du modèle et le geste est gardée.
    @Test func theModesTabOnlyWritesWhatItTouchesAndKeepsWhatWasWrittenElsewhere() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(
            #"""
            {"version": 2, "lastModeID": "perso-1", "futur": {"a": 1},
             "modes": [
               {"id": "dictee-brute", "name": "Dictée brute", "futur-mode": [true]},
               {"id": "dictee-nettoyee", "name": "Dictée nettoyée", "instruction": "Ma consigne.", "engine": "parakeet"},
               {"id": "perso-1", "name": "Courriel", "instruction": "Écris.", "reviewBeforePaste": false,
                "hotKey": {"keyCode": 12, "modifiers": 6144}, "futur-mode": null},
               {"id": "entretien", "name": "Entretien"}]}
            """#.utf8
        ).write(to: store.file)
        let before = store.load().settings
        let controller = makeController()
        let modes = SettingsView.makeModesModel(controller, keyMonitor: monitor)

        // Après la création du modèle : le panneau change de mode, un autre onglet ajoute un fournisseur.
        let provider = Provider(
            id: UUID(), name: "Ajouté après", baseURL: "https://api.example.com/v1", kind: .openAICompatible, models: [])
        try controller.updateSettings {
            $0.lastModeID = ModeChip.promptID
            $0.providers = [provider]
        }

        modes.setReview(true, for: ModeChip.rawID)
        modes.setReview(true, for: ModeChip.cleanedID)

        let onDisk = store.load().settings
        #expect(controller.settings == onDisk)
        #expect(onDisk.providers == [provider])
        var expected = before
        expected.lastModeID = ModeChip.promptID
        expected.providers = [provider]
        expected.modes[0].reviewBeforePaste = true
        expected.modes[1].reviewBeforePaste = true
        #expect(onDisk == expected)
        #expect(onDisk.mode(ModeChip.cleanedID)?.instruction == "Ma consigne.")
        #expect(onDisk.mode(ModeChip.cleanedID)?.engine == .parakeet)
        #expect(onDisk.mode("perso-1")?.reviewBeforePaste == false)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: Any])
        #expect((written["futur"] as? NSDictionary)?.isEqual(to: ["a": 1]) == true)
        let writtenModes = try #require(written["modes"] as? [[String: Any]])
        #expect(writtenModes[0]["futur-mode"] != nil)
        #expect(writtenModes[2]["futur-mode"] is NSNull)

        // Un mode dupliqué garde aussi les champs inconnus de l'original, et rien d'autre ne change.
        let copy = modes.duplicate("perso-1")
        let afterCopy = store.load().settings
        #expect(afterCopy.mode(copy)?.hotKey == nil)
        #expect(afterCopy.mode("perso-1") == onDisk.mode("perso-1"))
        #expect(afterCopy.lastModeID == ModeChip.promptID)
    }

    @Test func aRefusedSaveLeavesTheReviewChoiceAsItWas() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        let modes = SettingsView.makeModesModel(controller, keyMonitor: monitor)
        try Data("pas du json".utf8).write(to: store.file)

        modes.setReview(true, for: ModeChip.rawID)

        #expect(!controller.settings.reviewsBeforePaste(ModeChip.rawID))
        #expect(modes.rows.first { $0.id == ModeChip.rawID }?.reviews == false)
        #expect(modes.message?.contains("settings.json") == true)
    }

    /// La suppression du mode choisi dans le panneau : le fichier garde Dictée brute comme dernier mode (une seule écriture, par
    /// `updateSettings`), le panneau y revient, et le raccourci du mode est rendu au système.
    @Test func deletingTheModeChosenInThePanelBringsBackTheRawModeAndFreesItsHotKey() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings.defaults
        settings.modes.insert(Mode(id: "perso-un", name: "Compte rendu", instruction: "Résume.", hotKey: HotKeyTests.keyB), at: 1)
        settings.lastModeID = "perso-un"
        try store.save(settings)
        let controller = makeController()
        controller.launch()
        #expect(controller.panelModel.selectedModeID == "perso-un")
        #expect(modeRegistrars.registered == [HotKeyTests.keyB])
        let modes = SettingsView.makeModesModel(controller, keyMonitor: monitor)

        modes.delete("perso-un")

        let onDisk = store.load().settings
        #expect(!onDisk.modes.contains { $0.id == "perso-un" })
        #expect(onDisk.lastModeID == ModeChip.rawID, "dans la même écriture, pas à une prochaine sélection")
        #expect(controller.settings == onDisk)
        #expect(controller.panelModel.selectedModeID == ModeChip.rawID)
        #expect(modeRegistrars.registered.isEmpty)
        #expect(controller.modeHotKeys.active.isEmpty)
    }

    /// Le raccourci d'un mode, de la capture à l'enregistrement : le système le prend, le fichier le garde ; un refus du système
    /// garde l'ancien.
    @Test func aModesHotKeyIsCapturedRegisteredAndSavedAndASystemRefusalKeepsTheOldOne() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings.defaults
        settings.modes.insert(Mode(id: "perso-un", name: "Compte rendu", instruction: "Résume.", hotKey: HotKeyTests.keyB), at: 1)
        try store.save(settings)
        let controller = makeController()
        controller.launch()
        let modes = SettingsView.makeModesModel(controller, keyMonitor: monitor)
        let keyC = HotKey(keyCode: 0x08, modifiers: [.control, .option])

        modes.startRecording(for: "perso-un")
        #expect(monitor.isActive)
        #expect(modeRegistrars.registered.isEmpty, "la capture rend les raccourcis des modes au système")
        monitor.send(keyCode: 0x08, flags: [.control, .option])

        #expect(store.load().settings.mode("perso-un")?.hotKey == keyC)
        #expect(modeRegistrars.registered == [keyC])
        #expect(registrar.registered == .standard, "le raccourci général revient")
        #expect(!monitor.isActive)
        #expect(modes.message == nil)

        // Le système refuse la combinaison suivante : l'ancienne reste, dans le système comme dans le fichier.
        for modeRegistrar in modeRegistrars.made { modeRegistrar.refused = [HotKeyTests.keyA] }
        modes.startRecording(for: "perso-un")
        monitor.send(keyCode: 0x00, flags: [.control, .option])
        #expect(modes.message?.contains("refusé par macOS") == true)
        #expect(store.load().settings.mode("perso-un")?.hotKey == keyC)
        #expect(modeRegistrars.registered == [keyC])

        // Une combinaison que le raccourci général tient est refusée avant le système.
        modes.startRecording(for: "perso-un")
        monitor.send(keyCode: UInt16(HotKey.standard.keyCode), flags: [.control, .option])
        #expect(modes.message?.contains("raccourci global") == true)
        #expect(store.load().settings.mode("perso-un")?.hotKey == keyC)
    }

    /// Un mode supprimé pendant que la feuille est ouverte : la capture est refusée par le contrôleur, rien n'est enregistré.
    @Test func theControllerRefusesAHotKeyForAModeThatIsNoLongerInTheSettings() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        controller.launch()
        let modes = SettingsView.makeModesModel(controller, keyMonitor: monitor)
        let id = modes.add()
        try controller.updateSettings { $0.modes.removeAll { $0.id == id } }

        modes.startRecording(for: id)
        #expect(modes.message == ModesModel.unknownModeMessage)
        #expect(!monitor.isActive)
        #expect(modeRegistrars.registered.isEmpty)
        #expect(controller.modeHotKeys.active.isEmpty)
    }

    /// Règle 9 : la fenêtre gardée d'une ouverture à l'autre relit les réglages (`reload` à la présentation).
    @Test func aKeptSettingsWindowRereadsTheSettingsOnEachPresentation() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let built = Built()
        let controller = makeController(settingsView: testProvider(built))

        controller.openSettings()
        await finished(controller.settingsPresentation)
        let modes = try #require(built.modes)
        #expect(modes.rows.map(\.title) == ["Dictée brute", "Dictée nettoyée", "Prompt", "Entretien"])

        // Fermée, la fenêtre est gardée ; pendant ce temps, un autre chemin change les réglages.
        try controller.updateSettings {
            $0.modes[1].name = "Écrit ailleurs"
            $0.modes.append(Mode(id: "perso-ailleurs", name: "Autre mode", instruction: "x"))
            $0.providers = [Provider(id: UUID(), name: "Ajouté ailleurs", baseURL: "https://example.com", kind: .anthropic, models: ["m"])]
        }
        #expect(modes.rows.map(\.title) == ["Dictée brute", "Dictée nettoyée", "Prompt", "Entretien"], "pas encore relu")

        controller.openSettings()
        await finished(controller.settingsPresentation)
        #expect(built.modes === modes, "la fenêtre et son modèle sont gardés")
        #expect(modes.rows.map(\.title) == ["Dictée brute", "Écrit ailleurs", "Prompt", "Entretien", "Autre mode"])
        #expect(modes.modelOptions.map(\.providerName) == ["Ajouté ailleurs"])
    }

    /// Fermer la fenêtre pendant une capture de raccourci de mode rend les raccourcis.
    @Test func leavingTheWindowEndsAModeHotKeyCapture() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings.defaults
        settings.modes.insert(Mode(id: "perso-un", name: "Compte rendu", instruction: "Résume.", hotKey: HotKeyTests.keyB), at: 1)
        try store.save(settings)
        let controller = makeController()
        controller.launch()
        let modes = SettingsView.makeModesModel(controller, keyMonitor: monitor)
        let content = SettingsView.content(
            providers: SettingsView.makeProvidersModel(controller),
            hotKey: SettingsView.makeHotKeyModel(controller, keyMonitor: monitor),
            transcription: SettingsView.makeTranscriptionModel(controller, catalog: catalog, promptTokenLimit: Self.promptTokenLimit),
            modes: modes, permissions: controller.permissions, openSystemSettings: { _ in })

        modes.startRecording(for: "perso-un")
        #expect(modeRegistrars.registered.isEmpty)
        content.onLeave()
        #expect(modes.recordingModeID == nil)
        #expect(!monitor.isActive)
        #expect(modeRegistrars.registered == [HotKeyTests.keyB])
        #expect(registrar.registered == .standard)
    }

    @Test func aRefusedSaveRestoresTheDisplayedTranscriptionSetting() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        let transcription = SettingsView.makeTranscriptionModel(
            controller, catalog: catalog, promptTokenLimit: Self.promptTokenLimit)
        try Data("pas du json".utf8).write(to: store.file)

        transcription.setEngine(.parakeet)

        #expect(transcription.settings.engine == .whisperKit)
        #expect(controller.settings.transcription.engine == .whisperKit)
        #expect(transcription.message?.contains("settings.json") == true)
    }

    /// L'ouverture de la fenêtre relit les modèles du disque : un téléchargement fait ailleurs ou une suppression à la main se voit.
    @Test func openingTheSettingsListsTheLocalModels() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let controller = makeController(settingsView: testProvider(Built()))
        #expect(catalog.listCount == 0)

        controller.openSettings()
        await finished(controller.settingsPresentation)
        #expect(catalog.listCount == 1)
    }

    /// Sans catalogue (l'entrée par défaut de la fenêtre), l'onglet ne liste rien et ne casse rien.
    @Test func withoutACatalogTheModelListIsEmptyButKnown() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let unavailable = UnavailableModelCatalog()
        #expect(await unavailable.models().isEmpty)
        #expect(await unavailable.promptTokenCount(["x"], whisperModel: "small") == nil)
        let controller = makeController()
        let transcription = SettingsView.makeTranscriptionModel(
            controller, catalog: unavailable, promptTokenLimit: Self.promptTokenLimit)
        await transcription.refresh()
        #expect(transcription.hasListed)
        #expect(transcription.models.isEmpty)
    }

    // MARK: - Onglet Entretien et navigation (tâche 10)

    /// Règle 6, sur la VRAIE composition de la fenêtre AVEC l'onglet Entretien (`SettingsView.content`, modèle et navigation du
    /// contrôleur) : `openSettings(tab:)` ouvre la fenêtre sur l'onglet demandé, sans la construire en double ; l'onglet est dans la
    /// liste de la vue, et la vue est liée à la navigation du contrôleur.
    @Test func openingTheSettingsOnATabSelectsItInTheRealCompositionAndPresentsTheWindow() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let built = Built()
        let controller = makeController(settingsView: testProvider(built))
        #expect(controller.settingsNavigation.tab == .providers, "premier affichage : Fournisseurs")

        controller.openSettings(tab: .interview)

        let content = try #require(built.content)
        #expect(content.tabs.contains(.interview), "l'onglet est dans la barre de la vraie fenêtre")
        let navigation = try #require(content.navigation)
        #expect(navigation === controller.settingsNavigation, "la vue suit la navigation du contrôleur")
        #expect(navigation.tab == .interview)
        #expect(content.tabs.contains(navigation.tab), "l'onglet choisi existe dans la fenêtre")
        #expect(presenter.windows.count == 1)
        #expect(presenter.windows.first?.presentations == 1)
    }

    /// Règle 6 : la fenêtre déjà ouverte sur un autre onglet est ramenée au premier plan, sur l'onglet demandé, dans la vraie
    /// composition.
    @Test func anOpenRealWindowIsBroughtBackOnTheRequestedTab() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let built = Built()
        let controller = makeController(settingsView: testProvider(built))
        controller.openSettings()
        let navigation = try #require(built.content?.navigation)
        navigation.tab = .modes  // la personne a cliqué sur Modes

        controller.openSettings(tab: .interview)

        #expect(presenter.windows.count == 1, "la même fenêtre")
        #expect(presenter.windows.first?.presentations == 2)
        #expect(navigation.tab == .interview)
        #expect(try #require(built.content).tabs.contains(navigation.tab))
    }

    /// Règle 6 : `openSettings()` sans onglet garde l'onglet courant (« Réglages… » du menu rouvre là où l'on s'était arrêté), dans
    /// la vraie composition.
    @Test func openingTheRealWindowWithoutATabKeepsTheCurrentTab() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let built = Built()
        let controller = makeController(settingsView: testProvider(built))
        controller.openSettings()
        let navigation = try #require(built.content?.navigation)
        #expect(navigation.tab == .providers)
        navigation.tab = .transcription

        controller.openSettings()

        #expect(navigation.tab == .transcription)
        #expect(presenter.windows.first?.presentations == 2)
    }

    /// Les onglets : l'onglet Entretien n'existe que si son modèle est donné (les appelants d'avant la tâche 10 rendent les mêmes
    /// cinq onglets), et vient après Modes, dont il dépend.
    @Test func theInterviewTabExistsOnlyWithItsModelAndComesAfterModes() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SettingsTab.visible(hasInterview: false) == [.providers, .hotKey, .permissions, .transcription, .modes])
        #expect(SettingsTab.visible(hasInterview: true).last == .interview)
        #expect(
            SettingsTab.visible(hasInterview: true).map(\.title)
                == ["Fournisseurs", "Raccourci", "Permissions", "Transcription", "Modes", "Entretien"])

        let controller = makeController()
        let plain = SettingsView.content(
            providers: SettingsView.makeProvidersModel(controller),
            hotKey: SettingsView.makeHotKeyModel(controller, keyMonitor: monitor),
            transcription: SettingsView.makeTranscriptionModel(
                controller, catalog: catalog, promptTokenLimit: Self.promptTokenLimit),
            modes: SettingsView.makeModesModel(controller, keyMonitor: monitor), permissions: controller.permissions,
            openSystemSettings: { _ in })
        #expect(plain.tabs == SettingsTab.visible(hasInterview: false))
    }

    /// La vraie fenêtre de l'application (`SettingsView.provider`) a l'onglet Entretien.
    @Test func theProductionWindowHasTheInterviewTab() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        let content = SettingsView.provider(catalog: catalog, promptTokenLimit: Self.promptTokenLimit)(controller)
        #expect(content.tabs == SettingsTab.visible(hasInterview: true))
        #expect(content.tabs.contains(.interview))
        #expect(content.navigation === controller.settingsNavigation, "la vraie fenêtre suit la navigation du contrôleur")
    }

    /// Règle 1, de bout en bout : le modèle de l'onglet écrit par le contrôleur (réglages en mémoire et fichier), sans écraser ce qui
    /// s'écrit ailleurs ; et le silence en pratique vient de l'environnement de l'entretien du contrôleur.
    @Test func theInterviewModelWritesThroughTheControllerAndAsksItsEnvironmentForTheEffectiveSilence() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = FakeInterviewEnvironment(journal: Journal()).environment
        environment.effectiveTurnSilence = { _ in 1.024 }
        let controller = makeController(interview: environment)
        let interview = SettingsView.makeInterviewModel(controller)

        try controller.updateSettings {
            $0.providers = [
                Provider(id: UUID(), name: "Ajouté ailleurs", baseURL: "https://example.com", kind: .anthropic, models: [])
            ]
        }
        interview.maxQuestions = 5
        interview.turnSilence = 0.6

        #expect(controller.settings.interview.maxQuestions == 5)
        #expect(controller.settings.providers.map(\.name) == ["Ajouté ailleurs"])
        let onDisk = store.load().settings
        #expect(onDisk.interview.maxQuestions == 5)
        #expect(onDisk.interview.turnSilence == 0.6)
        #expect(interview.effectiveSilenceText.hasPrefix("0,60 s demandées, 1,02 s en pratique"))
    }

    /// Un fichier de réglages illisible refuse l'enregistrement : le modèle le dit, et rien n'est écrit.
    @Test func aRefusedSaveIsSaidByTheInterviewTabAndWritesNothing() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        let interview = SettingsView.makeInterviewModel(controller)
        try Data("pas du json".utf8).write(to: store.file)

        interview.maxQuestions = 5

        #expect(interview.maxQuestions == InterviewSettings.defaults.maxQuestions)
        #expect(controller.settings.interview.maxQuestions == InterviewSettings.defaults.maxQuestions)
        #expect(interview.message?.contains("settings.json") == true)
        #expect(try Data(contentsOf: store.file) == Data("pas du json".utf8), "le fichier n'a pas été touché")
    }

    /// La présentation de la fenêtre efface le message d'un refus d'avant : la personne rouvre la fenêtre, le bandeau d'erreur ne
    /// reste pas.
    @Test func presentingTheWindowClearsAnOldRefusalOfTheInterviewTab() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let built = Built()
        let controller = makeController(settingsView: testProvider(built))
        controller.openSettings(tab: .interview)
        await finished(controller.settingsPresentation)
        let interview = try #require(built.interview)
        try Data("pas du json".utf8).write(to: store.file)
        interview.maxQuestions = 5
        #expect(interview.message != nil, "le refus est affiché")

        controller.openSettings(tab: .interview)
        await finished(controller.settingsPresentation)

        #expect(interview.message == nil, "rouverte, la fenêtre n'affiche plus le refus d'avant")
    }

    /// La présentation de la fenêtre relit l'onglet Entretien : un réglage écrit ailleurs s'y voit.
    @Test func presentingTheWindowRereadsTheInterviewTab() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let built = Built()
        let controller = makeController(settingsView: testProvider(built))
        controller.openSettings(tab: .interview)
        await finished(controller.settingsPresentation)
        let interview = try #require(built.interview)

        try controller.updateSettings { $0.interview.maxQuestions = 12 }
        #expect(interview.maxQuestions == InterviewSettings.defaults.maxQuestions, "pas encore relu")
        controller.openSettings(tab: .interview)
        await finished(controller.settingsPresentation)

        #expect(built.interview === interview, "la fenêtre et son modèle sont gardés")
        #expect(interview.maxQuestions == 12)
    }

    /// Ce que la personne a tapé dans le gabarit est enregistré quand elle quitte la fenêtre (fermée, plus au premier plan, application
    /// passée en arrière-plan) : `SettingsContent.onLeave`, ici par la fenêtre double.
    @Test func leavingTheWindowSavesTheTypedTemplate() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let built = Built()
        let controller = makeController(settingsView: testProvider(built))
        controller.openSettings(tab: .interview)
        await finished(controller.settingsPresentation)
        let interview = try #require(built.interview)
        let window = try #require(presenter.windows.first)

        interview.template = "Mon gabarit, tapé."
        #expect(store.load().settings.interview.template == nil, "rien n'est écrit pendant la frappe")
        window.leave()

        #expect(store.load().settings.interview.template == "Mon gabarit, tapé.")
        #expect(controller.settings.interview.template == "Mon gabarit, tapé.")
    }

    /// Quitter (menu, panneau) enregistre le gabarit tapé avant la fin de l'application, et la fin a bien lieu.
    @Test func quittingSavesTheTypedTemplateBeforeTerminating() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let built = Built()
        let controller = makeController(settingsView: testProvider(built))
        controller.openSettings(tab: .interview)
        await finished(controller.settingsPresentation)
        let interview = try #require(built.interview)

        interview.template = "Tapé juste avant Quitter."
        controller.quit()

        #expect(store.load().settings.interview.template == "Tapé juste avant Quitter.")
        #expect(presenter.terminations == 1)
    }

    /// Une fin demandée par le système (déconnexion, arrêt) enregistre aussi le gabarit tapé.
    @Test func aSystemTerminationRequestSavesTheTypedTemplate() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = NSApplication.shared
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        let built = Built()
        let controller = makeController(settingsView: testProvider(built))
        controller.openSettings(tab: .interview)
        await finished(controller.settingsPresentation)
        let interview = try #require(built.interview)

        interview.template = "Tapé avant l'arrêt du système."
        let decision = controller.requestTermination(reply: { _ in })

        #expect(decision == .now)
        #expect(store.load().settings.interview.template == "Tapé avant l'arrêt du système.")
    }

    /// Fenêtre jamais ouverte : quitter ne plante pas et n'écrit rien.
    @Test func quittingWithoutAnOpenSettingsWindowWritesNothing() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        let before = try Data(contentsOf: store.file)
        controller.quit()
        #expect(presenter.terminations == 1)
        #expect(try Data(contentsOf: store.file) == before)
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
        let hotKey = SettingsView.makeHotKeyModel(controller, keyMonitor: monitor)

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
        #expect(controller.panelModel.hotKeyLabel == HotKeyTests.keyB.label(layout: HotKeyTests.ansi))

        registrar.refused = [HotKeyTests.keyA]
        #expect(HotKeyTests.failure(controller.changeHotKey(HotKeyTests.keyA)) == .refused)
        #expect(registrar.registered == HotKeyTests.keyB)
        #expect(controller.panelModel.hotKeyLabel == HotKeyTests.keyB.label(layout: HotKeyTests.ansi))
    }

    @Test func settingsWindowIsBuiltWithoutReadingAnyKey() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = Provider(id: UUID(), name: "Local", baseURL: "http://localhost:1", kind: .openAICompatible, models: ["m"])
        try store.save(AppSettings(version: 1, providers: [provider], hotKey: .standard, hotKeyBehavior: .toggle, lastModeID: "prompt"))
        let controller = makeController(settingsView: SettingsView.provider)

        let view = NSHostingView(rootView: SettingsView.provider(controller).view)
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
        controller.launch()
        registrar.press()
        #expect(controller.panelModel.isOpen)
        #expect(escape.registered != nil)

        let model = SettingsView.makeHotKeyModel(controller, keyMonitor: monitor)
        model.startRecording()
        #expect(registrar.registered == nil)
        #expect(escape.registered == nil)
        #expect(!controller.panelModel.isOpen)

        model.cancelRecording()
        #expect(registrar.registered == .standard)
        registrar.press()
        #expect(controller.panelModel.isOpen)
        controller.togglePanelFromMenu()

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
