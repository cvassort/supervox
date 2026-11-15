import AppKit
import Foundation
import Synchronization
import Testing
import SupervoxCore

@testable import SupervoxApp

/// La dictée dans l'application assemblée : le raccourci, Échap, le panneau, le menu et les réglages vers le contrôleur de
/// dictée. Réglages dans un dossier temporaire, enregistreurs, surface et moniteur de clics doubles ; sessions, presse-papiers
/// et touches doubles : aucun micro, aucun ⌘V, aucun presse-papiers du système.
/// Les durées d'attente demandées par la fin de l'application (sans attendre).
final class TimeoutLog: Sendable {
    private let state = Mutex<[Double]>([])
    func record(_ seconds: Double) { state.withLock { $0.append(seconds) } }
    var values: [Double] { state.withLock { $0 } }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct AppControllerDictationTests {
    let directory: URL
    let store: SettingsStore
    let hotKeys = HotKeyTests.FakeRegistrar()
    let escape = HotKeyTests.FakeRegistrar()
    let modeRegistrars = ModeRegistrars()
    let probe = FakePermissionsProbe(microphone: .granted, accessibility: .granted)
    let surface = FakePanelSurface()
    let clicks = FakeClickMonitor()
    let presenter = Presenter()
    let engines = FakeEngines()
    let rig: InsertionRig
    /// L'attente du collage (entre ⌘V et la restauration) : instantanée, sauf quand `blocksInsertion` est vrai, où elle dure
    /// jusqu'à `insertionSleeper.release()`.
    let insertionSleeper = SleepingWait(log: CallLog())
    let blocksInsertion = Flag()
    /// La surveillance du maintien : un sommeil qui dure jusqu'à `holdSleeper.release()`, et les modificateurs tenus.
    let holdSleeper = SleepingWait(log: CallLog())
    let held = HeldModifiers()
    /// L'attente de la relecture avant l'insertion : instantanée, elle journalise sa durée dans le journal de l'insertion.
    let handover: HandoverWait

    @MainActor final class Flag { var on = false }

    @MainActor final class HeldModifiers {
        var value = true
        var asked: [Modifiers] = []
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervox-app-dictation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
        let sleeper = insertionSleeper
        let blocks = blocksInsertion
        rig = InsertionRig(wait: { seconds in if blocks.on { await sleeper.wait(seconds) } })
        handover = HandoverWait(log: rig.log)
        // La surface du panneau écrit ses demandes de clavier dans le même journal que l'insertion : l'ordre se compare.
        surface.log = rig.log
    }

    func makeController(
        settings: AppSettings = .defaults, terminationWait: (@Sendable (Double) async -> Void)? = nil
    ) -> AppController {
        try? store.save(settings)
        let controller = AppController(
            settingsStore: store, secrets: InMemorySecretStore(), hotKeyRegistrar: hotKeys,
            escapeRegistrar: escape, makeModeHotKeyRegistrar: { [modeRegistrars] in modeRegistrars.make() },
            permissionsProbe: probe, systemHotKeys: FakeSystemHotKeys(),
            keyboardLayout: HotKeyTests.ansi, makePanelSurface: { [surface] _ in surface }, clickMonitor: clicks,
            makeSettingsWindow: presenter.make, terminate: presenter.terminate,
            dictation: engines.environment, inserter: rig.inserter,
            holdWatch: HoldWatch(
                anyHeld: { [held] in
                    held.asked.append($0)
                    return held.value
                },
                wait: { [holdSleeper] in await holdSleeper.wait($0) }),
            terminationWait: terminationWait ?? { try? await Task.sleep(for: .seconds($0)) },
            reviewHandoverWait: { [handover] in await handover.wait($0) })
        controller.launch()
        return controller
    }

    func holdSettings() -> AppSettings {
        var settings = AppSettings.defaults
        settings.hotKeyBehavior = .hold
        return settings
    }

    /// Mène la session de la dictée en cours jusqu'à `recording`.
    func record(_ controller: AppController, index: Int = 0) async -> FakeSession {
        let found = await until { engines.sessions.count > index }
        #expect(found)
        let session = found ? engines.sessions[index] : FakeSession()
        #expect(await until { session.calls.contains("start") })
        session.emit(.preparing)
        session.emit(.recording)
        #expect(await until { controller.panelModel.dictation.stage == .recording })
        return session
    }

    // MARK: - Les modes et leurs raccourcis

    static let keyB = HotKeyTests.keyB
    /// Des modificateurs qui ne sont pas ceux du raccourci global (⌃⌥) : la surveillance du maintien les distingue.
    static let holdKey = HotKey(keyCode: 0x08, modifiers: [.command, .shift])

    /// Dictée brute avec son propre raccourci, Entretien avec le sien, et un mode personnel.
    func modesSettings(rawKey: HotKey? = keyB, lastModeID: String = ModeChip.interviewID, hold: Bool = false) -> AppSettings {
        var settings = AppSettings.defaults
        settings.modes = [
            Mode(id: ModeChip.rawID, name: "Dictée brute", hotKey: rawKey),
            Mode(id: "perso-un", name: "Compte rendu", instruction: "Résume.", hotKey: HotKey(keyCode: 0x08, modifiers: [.control, .option])),
            Mode(id: ModeChip.interviewID, name: "Entretien", hotKey: HotKey(keyCode: 0x02, modifiers: [.control, .option])),
        ]
        settings.lastModeID = lastModeID
        if hold { settings.hotKeyBehavior = .hold }
        return settings
    }

    @Test func aModesHotKeySelectsItSavesItAndStartsTheDictation() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(settings: modesSettings())
        #expect(controller.panelModel.selectedModeID == ModeChip.interviewID)

        modeRegistrars.press(Self.keyB)
        #expect(controller.panelModel.selectedModeID == ModeChip.rawID)
        #expect(controller.settings.lastModeID == ModeChip.rawID)
        #expect(store.load().settings.lastModeID == ModeChip.rawID, "le choix est enregistré sur disque")
        _ = await record(controller)
        #expect(controller.panelModel.isOpen)
    }

    @Test func theInterviewHotKeyOpensThePanelOnInterviewWithTheLaterModeSentence() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(settings: modesSettings(lastModeID: ModeChip.rawID))
        modeRegistrars.press(HotKey(keyCode: 0x02, modifiers: [.control, .option]))

        #expect(controller.panelModel.isOpen)
        #expect(controller.panelModel.selectedModeID == ModeChip.interviewID)
        #expect(controller.panelModel.dictation.notice == DictationController.laterModeNotice)
        #expect(store.load().settings.lastModeID == ModeChip.interviewID)
        await settle()
        #expect(engines.sessions.isEmpty)
    }

    @Test func aModesHotKeyEndsTheDictationItStartedAndTheGlobalOneDoesNot() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(settings: modesSettings())
        modeRegistrars.press(Self.keyB)
        let session = await record(controller)

        hotKeys.press()
        await settle()
        #expect(session.count(of: "finish") == 0, "le global ne termine pas la dictée d'un mode")
        modeRegistrars.press(HotKey(keyCode: 0x08, modifiers: [.control, .option]))
        await settle()
        #expect(session.count(of: "finish") == 0, "ni le raccourci d'un autre mode")
        #expect(controller.panelModel.selectedModeID == ModeChip.rawID, "le mode ne change pas")

        modeRegistrars.press(Self.keyB)
        #expect(await until { session.count(of: "finish") == 1 })
    }

    @Test func inHoldAModesHotKeyWatchesItsOwnModifiersAndItsReleaseEndsTheDictation() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(settings: modesSettings(rawKey: Self.holdKey, hold: true))
        modeRegistrars.press(Self.holdKey)
        let session = await record(controller)
        #expect(await until { holdSleeper.isSleeping })
        holdSleeper.release()
        #expect(await until { !held.asked.isEmpty })
        #expect(held.asked.allSatisfy { $0 == [.command, .shift] }, "les modificateurs du mode, pas ceux du global (⌃⌥)")

        hotKeys.release()
        await settle()
        #expect(session.count(of: "finish") == 0)
        modeRegistrars.release(Self.holdKey)
        #expect(await until { session.count(of: "finish") == 1 })
    }

    /// Une dictée de mode en bascule en cours : `change` retire ou change le raccourci du mode pendant qu'elle dure.
    private func toggleDictationOfRaw(
        _ controller: AppController, change: (inout AppSettings) -> Void
    ) async throws -> FakeSession {
        modeRegistrars.press(Self.keyB)
        let session = await record(controller)
        try controller.updateSettings(change)
        return session
    }

    @Test func removingTheModesHotKeyDuringAToggleDictationLetsTheGlobalHotKeyEndItWithoutLosingTheText() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(settings: modesSettings())
        let session = try await toggleDictationOfRaw(controller) { $0.modes[0].hotKey = nil }

        hotKeys.press()
        #expect(await until { session.count(of: "finish") == 1 })
        session.emit(.finalizing)
        session.emit(.finished("Texte dicté."))
        #expect(await until { controller.dictation.lastTranscript == "Texte dicté." })
    }

    @Test func deletingTheModeDuringAToggleDictationLetsTheGlobalHotKeyEndIt() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(settings: modesSettings())
        let session = try await toggleDictationOfRaw(controller) { $0.modes.removeAll { $0.id == ModeChip.rawID } }

        hotKeys.press()
        #expect(await until { session.count(of: "finish") == 1 })
    }

    @Test func changingTheModesHotKeyDuringAToggleDictationMakesTheNewOneTheOwner() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(settings: modesSettings())
        let newKey = HotKey(keyCode: 0x0D, modifiers: [.control, .option])
        let session = try await toggleDictationOfRaw(controller) { $0.modes[0].hotKey = newKey }

        hotKeys.press()
        await settle()
        #expect(session.count(of: "finish") == 0, "le raccourci du mode existe toujours : le global reste ignoré")
        modeRegistrars.press(newKey)
        #expect(await until { session.count(of: "finish") == 1 })
    }

    @Test func aRefusedChangeKeepsTheOldHotKeyAndTheHoldWatchReadsItsModifiers() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(settings: modesSettings(rawKey: Self.keyB, hold: true))
        // Les réglages passent à ⌘⇧D, que le système refuse : ⌃⌥B reste le raccourci actif du mode.
        let refused = Self.holdKey
        for registrar in modeRegistrars.made { registrar.refused = [refused] }
        try controller.updateSettings { $0.modes[0].hotKey = refused }
        #expect(controller.modeHotKeys.active[ModeChip.rawID] == Self.keyB)
        #expect(modeRegistrars.registered.contains(Self.keyB))

        modeRegistrars.press(Self.keyB)
        _ = await record(controller)
        #expect(await until { holdSleeper.isSleeping })
        holdSleeper.release()
        #expect(await until { !held.asked.isEmpty })
        #expect(
            held.asked.allSatisfy { $0 == Self.keyB.modifiers },
            "les modificateurs du raccourci actif (⌃⌥), pas ceux des réglages (⌘⇧) : la prise n'est pas coupée")
    }

    @Test func removingTheChosenModeMakesTheNextDictationFollowRawDictation() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = modesSettings(lastModeID: "perso-un")
        settings.modes[1].hotKey = nil
        let controller = makeController(settings: settings)
        #expect(controller.panelModel.selectedModeID == "perso-un")

        try controller.updateSettings { $0.modes.removeAll { $0.id == "perso-un" } }
        #expect(controller.panelModel.selectedModeID == ModeChip.rawID)
        hotKeys.press()
        _ = await record(controller)
        #expect(controller.panelModel.dictation.notice != DictationController.laterModeNotice)
    }

    // MARK: - Quitter pendant un collage (m2)

    /// Mène une dictée jusqu'au collage, retenu après ⌘V (le presse-papiers de l'utilisateur n'est pas encore rendu).
    private func startPastingDictation(_ controller: AppController) async {
        blocksInsertion.on = true
        hotKeys.press()
        let session = await record(controller)
        session.emit(.finished("Texte dicté."))
        #expect(await until { insertionSleeper.isSleeping })
        #expect(rig.board.text == "Texte dicté.")
    }

    @Test func quittingWithNothingInProgressTerminatesNow() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        var replies: [Bool] = []
        #expect(controller.requestTermination(reply: { replies.append($0) }) == .now)
        await settle()
        #expect(replies.isEmpty)
    }

    /// Quitter pendant le collage : la fin est différée, et ne répond qu'une fois le presse-papiers de l'utilisateur rendu.
    @Test func quittingDuringAPasteWaitsForTheClipboardToBeRestored() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        await startPastingDictation(controller)

        controller.quit()
        #expect(presenter.terminations == 1)
        var replies: [Bool] = []
        var restoredWhenReplying: [Bool] = []
        let decision = controller.requestTermination(reply: { [rig] in
            replies.append($0)
            restoredWhenReplying.append(rig.board.contents == FakeInsertion.original)
        })
        #expect(decision == .afterInsertion)
        await settle()
        // Le collage n'est pas fini : pas de réponse, le texte dicté est encore dans le presse-papiers.
        #expect(replies.isEmpty)
        #expect(rig.board.text == "Texte dicté.")

        insertionSleeper.release()
        #expect(await until { replies == [true] })
        #expect(restoredWhenReplying == [true])
        #expect(rig.board.contents == FakeInsertion.original)
        // Plus rien en cours : une nouvelle demande se termine tout de suite.
        #expect(controller.requestTermination(reply: { _ in }) == .now)
    }

    /// Le délégué traduit la décision : rien en cours, le système peut terminer l'application. (Le cas « plus tard » répondrait à
    /// `NSApp` : il n'est pas exercé ici, la décision l'est ci-dessus.)
    @Test func theDelegateLetsTheSystemTerminateWhenNothingIsInProgress() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        let delegate = ApplicationDelegate(controller: controller)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    /// Un collage qui ne finit jamais ne retient pas l'application : l'attente est bornée.
    @Test func theWaitForAPasteIsBounded() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let waited = TimeoutLog()
        let controller = makeController(terminationWait: { waited.record($0) })
        await startPastingDictation(controller)
        defer { insertionSleeper.release() }

        var replies: [Bool] = []
        #expect(controller.requestTermination(reply: { replies.append($0) }) == .afterInsertion)
        // Le collage est toujours retenu, et pourtant la réponse vient (la borne est écoulée).
        #expect(await until { replies == [true] })
        #expect(insertionSleeper.isSleeping)
        #expect(waited.values == [AppController.terminationTimeout])
    }

    /// Deux demandes de fin pendant le même collage : une seule attente, une seule réponse.
    @Test func twoTerminationRequestsDuringTheSamePasteAnswerOnce() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        await startPastingDictation(controller)

        var replies: [Bool] = []
        #expect(controller.requestTermination(reply: { replies.append($0) }) == .afterInsertion)
        #expect(controller.requestTermination(reply: { replies.append($0) }) == .afterInsertion)
        insertionSleeper.release()
        #expect(await until { !replies.isEmpty })
        await settle()
        #expect(replies == [true])
    }

    // MARK: - Préchargement au lancement (I4)

    /// Au lancement, les moteurs des réglages courants sont préparés en tâche de fond (l'environnement décide s'il y a de quoi :
    /// il ne télécharge jamais).
    @Test func theLaunchPreloadsTheEnginesOfTheCurrentSettings() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings.defaults
        settings.transcription = TranscriptionSettings(
            engine: .parakeet, whisperModel: "small", language: "fr", vocabulary: ["terme"])
        let controller = makeController(settings: settings)
        #expect(await until { engines.preloadedFor == [settings.transcription] })
        await controller.preloadTask?.value
        #expect(engines.preloadedFor.count == 1)
    }

    /// Le préchargement ne retarde rien : retenu, il laisse le lancement finir, le raccourci marcher et le panneau s'ouvrir.
    @Test func aSlowPreloadDelaysNeitherTheLaunchNorTheFirstDictation() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = TestGate()
        defer { gate.open() }
        engines.configure { $0.preloadGate = gate }
        let controller = makeController()
        #expect(await until { engines.preloadedFor.count == 1 })
        // Le lancement est fini (`makeController` l'a attendu) et le préchargement est encore en cours.
        #expect(hotKeys.onPress != nil)

        hotKeys.press()
        #expect(controller.panelModel.isOpen)
        #expect(controller.panelModel.dictation.stage == .preparing)
        _ = await record(controller)
    }

    @Test func theHotKeyStartsADictationAndOpensThePanel() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        #expect(!controller.panelModel.isOpen)

        hotKeys.press()
        #expect(controller.panelModel.isOpen)
        #expect(surface.isShown)
        #expect(controller.panelModel.dictation.stage == .preparing)
        let session = await record(controller)

        // Le second appui termine.
        hotKeys.press()
        #expect(await until { session.count(of: "finish") == 1 })
    }

    @Test func theHotKeyIsRegisteredWithItsPressAndItsReleaseCallbacks() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(settings: holdSettings())
        #expect(hotKeys.onPress != nil)
        #expect(hotKeys.onRelease != nil)

        hotKeys.press()
        let session = await record(controller)
        #expect(session.count(of: "finish") == 0)
        hotKeys.release()
        #expect(await until { session.count(of: "finish") == 1 })
    }

    /// Maintien : la surveillance reçoit les modificateurs du raccourci des réglages, et attrape un relâchement perdu.
    @Test func aLostReleaseInHoldModeIsCaughtWithTheHotKeysModifiers() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(settings: holdSettings())
        hotKeys.press()
        let session = await record(controller)
        #expect(await until { holdSleeper.isSleeping })

        held.value = false
        holdSleeper.release()
        #expect(await until { session.count(of: "finish") == 1 })
        #expect(held.asked == [HotKey.standard.modifiers])
    }

    @Test func aChangedHotKeyKeepsBothCallbacksAfterSuspendAndResume() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(settings: holdSettings())
        #expect(HotKeyTests.failure(controller.changeHotKey(HotKeyTests.keyB)) == nil)
        #expect(hotKeys.onRelease != nil)

        controller.suspendHotKeysForCapture()
        #expect(hotKeys.onRelease == nil)
        #expect(controller.resumeHotKeys())
        #expect(hotKeys.onRelease != nil)

        hotKeys.press()
        let session = await record(controller)
        hotKeys.release()
        #expect(await until { session.count(of: "finish") == 1 })
    }

    @Test func transcriptionSettingsChangedInTheWindowApplyToTheNextDictation() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        hotKeys.press()
        let first = await record(controller)
        first.emit(.failed(.noSpeech))
        #expect(await until { controller.panelModel.dictation.stage == .failed(.noSpeech) })

        let changed = TranscriptionSettings(
            engine: .parakeet, whisperModel: "small", language: "en", vocabulary: ["terme"])
        try controller.updateSettings { $0.transcription = changed }
        hotKeys.press()
        #expect(await until { engines.sessions.count == 2 })
        #expect(engines.settingsSeen == [.defaults, changed])
    }

    /// Le texte de la dernière dictée est dans le panneau (même collé : « collé » ne prouve pas que l'application cible l'a reçu),
    /// et « Copier » passe par le presse-papiers de l'insertion, jamais par le presse-papiers général.
    @Test func thePanelKeepsTheLastTranscriptAndCopyingGoesThroughTheInsertionPasteboard() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        hotKeys.press()
        let session = await record(controller)
        session.emit(.finished("Bonjour à tous."))
        #expect(await until { !controller.panelModel.isOpen })
        #expect(controller.panelModel.dictation.lastTranscript == "Bonjour à tous.")

        // Le collage a restitué le presse-papiers d'origine ; « Copier » y remet le texte.
        #expect(rig.board.text == "brouillon de l'utilisateur")
        let before = rig.log.entries.count
        controller.panelModel.copyTranscript()
        #expect(rig.board.text == "Bonjour à tous.")
        #expect(Array(rig.log.entries.dropFirst(before)) == ["writeText(transient: false)"])
        #expect(controller.panelModel.transcriptCopied)
    }

    /// Un presse-papiers qui refuse l'écriture : le panneau dit « Copie impossible » et n'affiche jamais « Copié ».
    @Test func aCopyThePasteboardRefusesIsNeverShownAsCopied() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        hotKeys.press()
        let session = await record(controller)
        session.emit(.finished("Bonjour à tous."))
        #expect(await until { !controller.panelModel.isOpen })

        // Le panneau est ouvert (menu) : seule la dictée suivante, pas l'ouverture, doit remettre l'état à neuf.
        controller.openPanelOnReopen()
        rig.board.acceptsWrites = false
        controller.panelModel.copyTranscript()
        #expect(controller.panelModel.copyState == .failed)
        #expect(!controller.panelModel.transcriptCopied)
        #expect(rig.board.text == "brouillon de l'utilisateur")

        // Une nouvelle dictée remet l'état à neuf.
        rig.board.acceptsWrites = true
        hotKeys.press()
        #expect(controller.panelModel.isOpen)
        _ = await record(controller, index: 1)
        #expect(controller.panelModel.copyState == .idle)
    }

    /// Le panneau suit son contenu : quand l'état de la dictée change la hauteur du contenu, la surface est redimensionnée.
    @Test func thePanelIsResizedWhenTheDictationChangesTheHeightOfItsContent() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        hotKeys.press()
        let session = await record(controller)
        #expect(surface.resizes.isEmpty)

        // « Enregistrement » demande plus de place : la surface le mesure à chaque changement.
        surface.height = 220
        session.emit(DictationSnapshot(phase: .recording, liveText: "bonjour à tous", level: 0.4, elapsed: 2))
        #expect(await until { surface.resizes == [220] })

        // Le même état qui avance (durée, niveau) ne change pas la hauteur : rien n'est demandé.
        session.emit(DictationSnapshot(phase: .recording, liveText: "bonjour à tous", level: 0.5, elapsed: 3))
        #expect(await until { controller.panelModel.dictation.elapsed == 3 })
        #expect(surface.resizes == [220])
    }

    @Test func escapeDuringADictationCancelsItAndClosesThePanel() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        hotKeys.press()
        let session = await record(controller)

        escape.press()
        #expect(!controller.panelModel.isOpen)
        #expect(!surface.isShown)
        #expect(await until { session.count(of: "cancel") == 1 })
        session.emit(.finished("tardif"))
        await settle()
        #expect(rig.log.entries.filter { $0.hasPrefix("writeText") }.isEmpty)
        #expect(controller.panelModel.dictation == DictationViewState())
    }

    @Test func escapeOutsideADictationClosesThePanelAsBefore() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        controller.openPanelOnReopen()
        #expect(controller.panelModel.isOpen)

        escape.press()
        #expect(!controller.panelModel.isOpen)
        #expect(engines.sessions.isEmpty)
    }

    @Test(arguments: ["menu", "settings", "quit"])
    func closingThePanelByAnotherPathDuringADictationCancelsIt(_ path: String) async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        hotKeys.press()
        let session = await record(controller)

        // `NSApp` doit exister pour le menu principal de la fenêtre de réglages ; rien n'est affiché.
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        switch path {
        case "menu": controller.togglePanelFromMenu()
        case "settings": controller.openSettings()
        default: controller.quit()
        }
        #expect(!controller.panelModel.isOpen)
        #expect(await until { session.count(of: "cancel") == 1 })
        #expect(controller.panelModel.dictation == DictationViewState())
    }

    @Test func aClickOutsideIsIgnoredDuringADictationAndClosesThePanelOtherwise() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        hotKeys.press()
        let session = await record(controller)

        clicks.clickOutside()
        #expect(controller.panelModel.isOpen)
        #expect(session.count(of: "cancel") == 0)

        session.emit(.failed(.noSpeech))
        #expect(await until { controller.panelModel.dictation.stage == .failed(.noSpeech) })
        clicks.clickOutside()
        #expect(!controller.panelModel.isOpen)
    }

    @Test func thePanelModelMirrorsTheDictation() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        hotKeys.press()
        let session = await record(controller)

        session.emit(.recording, liveText: "bonjour", level: 0.5, elapsed: 1.5)
        #expect(await until { controller.panelModel.dictation.liveText == "bonjour" })
        #expect(controller.panelModel.dictation == controller.dictation.view)
        #expect(controller.panelModel.dictation.elapsed == 1.5)
    }

    @Test func aModeOtherThanRawDictationOpensThePanelWithoutADictation() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        controller.panelModel.select(ModeChip.interviewID)

        hotKeys.press()
        #expect(controller.panelModel.isOpen)
        #expect(controller.panelModel.dictation.notice == "Ce mode arrive à une étape suivante.")
        await settle()
        #expect(engines.sessions.isEmpty)

        // Les pastilles restent cliquables : revenir à la dictée brute permet de dicter.
        controller.panelModel.select("dictee-brute")
        hotKeys.press()
        #expect(await until { engines.sessions.count == 1 })
    }

    @Test func withoutMicrophonePermissionThePanelOpensOnThePermissionsLineAndNothingStarts() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        probe.set(microphone: .denied)
        let controller = makeController()

        hotKeys.press()
        #expect(controller.panelModel.isOpen)
        #expect(controller.permissions.summary?.contains("Micro") == true)
        await settle()
        #expect(engines.sessions.isEmpty)

        // La permission est relue à l'appui : accordée entre-temps, la dictée démarre.
        probe.set(microphone: .granted)
        hotKeys.press()
        #expect(await until { engines.sessions.count == 1 })
        #expect(controller.permissions.microphone == .granted)
    }

    @Test func theWelcomeSaysWhatTheHotKeyDoesNow() {
        let welcome = AppController.welcome(hotKeyLabel: "⌃⌥Espace")
        #expect(welcome.contains("⌃⌥Espace lance la dictée"))
        #expect(!welcome.contains("ouvre et ferme"))
    }

    // MARK: - Relecture

    /// Active « Relire avant de coller » pour la dictée brute, par l'onglet Modes, comme le fait l'utilisateur.
    func enableReview(_ controller: AppController) {
        let modes = SettingsView.makeModesModel(controller)
        modes.setReview(true, for: ModeChip.rawID)
        #expect(modes.message == nil)
        #expect(controller.settings.reviewsBeforePaste(ModeChip.rawID))
    }

    /// Une dictée menée jusqu'à la relecture de `text`.
    @discardableResult
    func reviewedDictation(_ controller: AppController, _ text: String = "Texte dicté.", index: Int = 0) async
        -> FakeSession
    {
        hotKeys.press()
        let session = await record(controller, index: index)
        session.emit(.finished(text))
        #expect(await until { controller.panelModel.dictation.stage == .review })
        return session
    }

    /// Règle 18, de bout en bout : la bascule de Dictée brute par l'onglet Modes, une dictée, la relecture, « Coller ».
    @Test func theModesSwitchLeadsToTheReviewAndPasteInsertsInTheOrderOfTheJournal() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        // Sans la bascule, la dictée brute se colle toute seule (comportement de l'étape 3).
        enableReview(controller)

        hotKeys.press()
        let session = await record(controller)
        session.emit(.finished("Texte dicté."))
        #expect(await until { controller.panelModel.dictation.stage == .review })
        #expect(controller.panelModel.dictation.draft == "Texte dicté.")
        #expect(controller.panelModel.canPaste)
        #expect(controller.panelModel.isOpen)
        await settle()
        #expect(rig.log.entries == ["keyboard(focused)"], "rien n'est inséré tant que « Coller » n'est pas choisi")

        // Le texte est corrigé dans le panneau, puis collé par le geste.
        controller.panelModel.editDraft("Texte dicté, corrigé.")
        controller.panelModel.paste()
        #expect(await until { controller.panelModel.dictation.stage == .idle && !controller.panelModel.isOpen })
        #expect(rig.log.entries == [
            "keyboard(focused)",
            "keyboard(none)", "wait(0.15)",
            "read", "writeText(transient: true)", "modifiersHeld", "postPaste(9)", "writeText(transient: false)",
            // Plus de « keyboard(none) » à la fermeture : `hide()` retire lui-même la frappe, en un seul retrait.
        ])
        #expect(rig.board.text == "Texte dicté, corrigé.")
        #expect(handover.durations == [DictationController.focusHandoverDelay])
        #expect(controller.dictation.lastTranscript == "Texte dicté, corrigé.")
        #expect(controller.panelModel.dictation.lastTranscript == "Texte dicté, corrigé.")
        #expect(!controller.dictation.isBusy)
    }

    @Test func withTheSwitchOffTheRawDictationPastesByItselfAsBefore() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        hotKeys.press()
        let session = await record(controller)
        session.emit(.finished("Texte dicté."))
        #expect(await until { !controller.panelModel.isOpen })
        #expect(rig.board.contents == FakeInsertion.original, "le presse-papiers d'origine est rendu")
        #expect(!rig.log.entries.contains("keyboard(focused)"), "aucune relecture : la frappe n'est jamais prise")
        #expect(handover.durations.isEmpty)
    }

    /// Règle 10 : par chaque chemin de fermeture, la relecture finit sans collage ni copie, et le brouillon est gardé.
    @Test(arguments: ["escape", "menu", "settings", "quit"])
    func closingThePanelDuringTheReviewKeepsTheDraftAndInsertsNothing(_ path: String) async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        enableReview(controller)
        await reviewedDictation(controller)
        controller.panelModel.editDraft("Le brouillon relu.")
        rig.log.entries.removeAll()

        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        switch path {
        case "escape": escape.press()
        case "menu": controller.togglePanelFromMenu()
        case "settings": controller.openSettings()
        default: controller.quit()
        }
        #expect(!controller.panelModel.isOpen)
        await settle()
        #expect(controller.dictation.lastTranscript == "Le brouillon relu.")
        #expect(controller.panelModel.dictation == DictationViewState(lastTranscript: "Le brouillon relu."))
        #expect(rig.log.entries.filter { !$0.hasPrefix("keyboard") }.isEmpty, "aucun collage, aucune copie")
        #expect(rig.board.contents == FakeInsertion.original)
    }

    /// Règles 10, 11 et 17 : la fermeture du panneau par chaque chemin, pendant le collage, en finit avec lui sans rien insérer
    /// de plus. « passation » : l'attente de `focusHandoverDelay`, retenue par le test ; « sondage » : l'insertion attend le
    /// relâchement des modificateurs, avant le ⌘V.
    @Test(arguments: ["escape", "menu", "settings", "quit"], ["passation", "sondage"])
    func closingThePanelWhilePastingInsertsNothingMore(path: String, phase: String) async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        enableReview(controller)
        await reviewedDictation(controller)
        controller.panelModel.editDraft("Le brouillon à ne pas coller.")
        rig.log.entries.removeAll()
        if phase == "passation" {
            handover.holds = true
        } else {
            rig.keys.held = [true]
            blocksInsertion.on = true
        }
        controller.panelModel.paste()
        #expect(controller.panelModel.dictation.stage == .pasting)
        if phase == "passation" {
            #expect(await until { handover.sleeper.isSleeping })
            #expect(!rig.log.entries.contains("read"), "rien n'est encore inséré")
        } else {
            #expect(await until { insertionSleeper.isSleeping })
            #expect(rig.board.text == "Le brouillon à ne pas coller.", "l'insertion est en route, avant le ⌘V")
        }

        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        switch path {
        case "escape": escape.press()
        case "menu": controller.togglePanelFromMenu()
        case "settings": controller.openSettings()
        default: controller.quit()
        }
        #expect(!controller.panelModel.isOpen)
        #expect(await until { !controller.dictation.isInserting })
        await settle()
        #expect(controller.dictation.lastTranscript == "Le brouillon à ne pas coller.")
        #expect(
            controller.panelModel.dictation == DictationViewState(lastTranscript: "Le brouillon à ne pas coller."))
        #expect(!rig.log.entries.contains { $0.hasPrefix("postPaste") }, "aucun ⌘V")
        #expect(rig.board.contents == FakeInsertion.original, "le presse-papiers d'origine est intact ou rendu")
        if phase == "passation" {
            #expect(rig.log.entries.filter { !$0.hasPrefix("keyboard") && !$0.hasPrefix("wait") }.isEmpty, "ni lecture ni écriture")
        }
    }

    /// Règle 14 : changer de pastille pendant la relecture ne touche ni le texte ni l'étape ; la dictée suivante suit le mode.
    @Test func changingTheModeDuringTheReviewKeepsItAndTheNextDictationFollowsTheNewMode() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        enableReview(controller)
        await reviewedDictation(controller)
        controller.panelModel.editDraft("Texte à garder.")
        let before = controller.panelModel.dictation

        controller.panelModel.select(ModeChip.interviewID)
        #expect(controller.panelModel.dictation == before)
        #expect(controller.panelModel.dictation.stage == .review)
        #expect(controller.settings.lastModeID == ModeChip.interviewID, "le mode choisi est enregistré")

        // Le raccourci est ignoré : le panneau reste ouvert, la relecture intacte.
        hotKeys.press()
        await settle()
        #expect(controller.panelModel.isOpen)
        #expect(controller.panelModel.dictation == before)
        #expect(engines.sessions.count == 1)

        // Fermée, la relecture laisse la place : la dictée suivante suit le nouveau mode (ici, pas encore de dictée).
        escape.press()
        hotKeys.press()
        #expect(controller.panelModel.dictation.notice == DictationController.laterModeNotice)
        #expect(engines.sessions.count == 1)
        controller.panelModel.select(ModeChip.rawID)
        #expect(controller.settings.lastModeID == ModeChip.rawID)
        hotKeys.press()
        #expect(await until { engines.sessions.count == 2 })
    }

    /// Règle 15 : « Copier » en relecture copie le brouillon entier par l'insertion, sans quitter la relecture.
    @Test func copyingDuringTheReviewCopiesTheDraftAndStaysInTheReview() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        enableReview(controller)
        await reviewedDictation(controller)
        controller.panelModel.editDraft("Le brouillon entier, corrigé.")
        rig.log.entries.removeAll()

        controller.panelModel.copyTranscript()
        #expect(rig.board.text == "Le brouillon entier, corrigé.")
        #expect(rig.log.entries == ["writeText(transient: false)"])
        #expect(controller.panelModel.copyState == .copied)
        #expect(controller.panelModel.isOpen)
        #expect(controller.panelModel.dictation.stage == .review)

        controller.panelModel.editDraft("Le brouillon entier, corrigé encore.")
        #expect(controller.panelModel.copyState == .idle)
        rig.board.acceptsWrites = false
        controller.panelModel.copyTranscript()
        #expect(controller.panelModel.copyState == .failed)
        #expect(controller.panelModel.isOpen)
        #expect(controller.panelModel.dictation.stage == .review)
    }

    /// Règle 13 : un clic en dehors ne ferme pas la relecture (le clic sert à aller dans la fenêtre cible).
    @Test func aClickOutsideDoesNotCloseTheReview() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        enableReview(controller)
        await reviewedDictation(controller)

        clicks.clickOutside()
        #expect(controller.panelModel.isOpen)
        #expect(controller.panelModel.dictation.stage == .review)
        #expect(controller.panelModel.dictation.draft == "Texte dicté.")
    }
}
