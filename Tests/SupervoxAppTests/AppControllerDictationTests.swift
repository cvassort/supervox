import AppKit
import Foundation
import Testing
import SupervoxCore

@testable import SupervoxApp

/// La dictée dans l'application assemblée : le raccourci, Échap, le panneau, le menu et les réglages vers le contrôleur de
/// dictée. Réglages dans un dossier temporaire, enregistreurs, surface et moniteur de clics doubles ; sessions, presse-papiers
/// et touches doubles : aucun micro, aucun ⌘V, aucun presse-papiers du système.
@MainActor @Suite(.timeLimit(.minutes(1))) struct AppControllerDictationTests {
    let directory: URL
    let store: SettingsStore
    let hotKeys = HotKeyTests.FakeRegistrar()
    let escape = HotKeyTests.FakeRegistrar()
    let probe = FakePermissionsProbe(microphone: .granted, accessibility: .granted)
    let surface = FakePanelSurface()
    let clicks = FakeClickMonitor()
    let presenter = Presenter()
    let engines = FakeEngines()
    let rig = InsertionRig()
    /// La surveillance du maintien : un sommeil qui dure jusqu'à `holdSleeper.release()`, et les modificateurs tenus.
    let holdSleeper = SleepingWait(log: CallLog())
    let held = HeldModifiers()

    @MainActor final class HeldModifiers {
        var value = true
        var asked: [Modifiers] = []
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervox-app-dictation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
    }

    func makeController(settings: AppSettings = .defaults) -> AppController {
        try? store.save(settings)
        let controller = AppController(
            settingsStore: store, secrets: InMemorySecretStore(), hotKeyRegistrar: hotKeys,
            escapeRegistrar: escape, permissionsProbe: probe, systemHotKeys: FakeSystemHotKeys(),
            keyboardLayout: HotKeyTests.ansi, makePanelSurface: { [surface] _ in surface }, clickMonitor: clicks,
            makeSettingsWindow: presenter.make, terminate: presenter.terminate,
            dictation: engines.environment, inserter: rig.inserter,
            holdWatch: HoldWatch(
                anyHeld: { [held] in
                    held.asked.append($0)
                    return held.value
                },
                wait: { [holdSleeper] in await holdSleeper.wait($0) }))
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
        #expect(await until { controller.panelModel.dictation.phase == .recording })
        return session
    }

    @Test func theHotKeyStartsADictationAndOpensThePanel() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController()
        #expect(!controller.panelModel.isOpen)

        hotKeys.press()
        #expect(controller.panelModel.isOpen)
        #expect(surface.isShown)
        #expect(controller.panelModel.dictation.phase == .preparing)
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
        #expect(await until { controller.panelModel.dictation.phase == .failed(.noSpeech) })

        let changed = TranscriptionSettings(
            engine: "parakeet", whisperModel: "small", language: "en", vocabulary: ["terme"])
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
        #expect(controller.panelModel.lastTranscript == "Bonjour à tous.")

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
        #expect(await until { controller.panelModel.dictation.phase == .failed(.noSpeech) })
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
        controller.panelModel.select("prompt")

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
}
