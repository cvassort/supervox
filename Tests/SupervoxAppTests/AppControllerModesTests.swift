import AppKit
import Foundation
import Testing

@testable import SupervoxApp

/// Les modes dans l'application assemblée : les pastilles suivent les réglages, chaque mode a son raccourci, les refus se disent
/// dans le panneau. Registraires, surface et sonde de permissions doubles ; aucun raccourci réel.
@MainActor @Suite struct AppControllerModesTests {
    let directory: URL
    let store: SettingsStore
    let hotKeys = HotKeyTests.FakeRegistrar()
    let escape = HotKeyTests.FakeRegistrar()
    let modeRegistrars = ModeRegistrars()
    let probe = FakePermissionsProbe(microphone: .granted, accessibility: .granted)
    let system = FakeSystemHotKeys()
    let surface = FakePanelSurface()
    let presenter = Presenter()

    static let keyA = HotKeyTests.keyA
    static let keyB = HotKeyTests.keyB
    static let keyC = HotKey(keyCode: 0x08, modifiers: [.control, .option])
    static let report = Mode(id: "perso-un", name: "Compte rendu", instruction: "Résume.", hotKey: keyB)
    static let mail = Mode(id: "perso-deux", name: "Courriel", instruction: "Rédige.", hotKey: keyC)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervox-app-modes-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
    }

    /// Les réglages par défaut, avec ces modes entre Dictée brute et Entretien (qui y restent toujours).
    static func settings(_ custom: [Mode], lastModeID: String = ModeChip.rawID) -> AppSettings {
        var settings = AppSettings.defaults
        settings.modes = [Mode.base[0]] + custom + [Mode.base[3]]
        settings.lastModeID = lastModeID
        return settings
    }

    func makeController(_ settings: AppSettings) -> AppController {
        try? store.save(settings)
        return AppController(
            settingsStore: store, secrets: InMemorySecretStore(), hotKeyRegistrar: hotKeys,
            escapeRegistrar: escape, makeModeHotKeyRegistrar: { [modeRegistrars] in modeRegistrars.make() },
            permissionsProbe: probe, systemHotKeys: system, keyboardLayout: HotKeyTests.ansi,
            makePanelSurface: { [surface] _ in surface }, clickMonitor: FakeClickMonitor(),
            makeSettingsWindow: presenter.make, terminate: presenter.terminate,
            rewriter: .unavailable, inserter: InsertionRig().inserter)
    }

    func hotKeyLines(_ controller: AppController) -> [String] {
        controller.panelModel.notices[.hotKey]?.split(separator: "\n").map(String.init) ?? []
    }

    // MARK: - Les pastilles suivent les réglages

    @Test func theChipsAreTheSettingsModesInTheirOrderFromTheLaunch() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.mail, Self.report]))
        #expect(controller.panelModel.modes.map(\.title) == ["Dictée brute", "Courriel", "Compte rendu", "Entretien"])
    }

    @Test func addingRenamingMovingAndRemovingModesChangesTheChipsWithoutRelaunching() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report]))
        controller.launch()

        try controller.updateSettings { $0.modes.insert(Self.mail, at: 1) }
        #expect(controller.panelModel.modes.map(\.title) == ["Dictée brute", "Courriel", "Compte rendu", "Entretien"])

        try controller.updateSettings { $0.modes[2].name = "Bilan" }
        #expect(controller.panelModel.modes.map(\.title) == ["Dictée brute", "Courriel", "Bilan", "Entretien"])
        #expect(controller.panelModel.modes.map(\.id) == ["dictee-brute", "perso-deux", "perso-un", "entretien"])

        try controller.updateSettings { $0.modes.swapAt(1, 2) }
        #expect(controller.panelModel.modes.map(\.title) == ["Dictée brute", "Bilan", "Courriel", "Entretien"])

        try controller.updateSettings { $0.modes.removeAll { $0.id == "perso-un" } }
        #expect(controller.panelModel.modes.map(\.title) == ["Dictée brute", "Courriel", "Entretien"])
    }

    @Test func aChosenModeThatIsRemovedFallsBackToRawDictation() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report], lastModeID: "perso-un"))
        #expect(controller.panelModel.selectedModeID == "perso-un")

        try controller.updateSettings { $0.modes.removeAll { $0.id == "perso-un" } }
        #expect(controller.panelModel.selectedModeID == ModeChip.rawID)
    }

    @Test func aStateOfTheChipsThatDidNotChangeLeavesTheChosenModeAlone() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report]))
        controller.panelModel.select("perso-un")
        try controller.updateSettings { $0.modes[1].name = "Bilan" }
        #expect(controller.panelModel.selectedModeID == "perso-un")
    }

    // MARK: - Un raccourci par mode

    @Test func eachModesHotKeyIsRegisteredAtLaunchWithItsOwnRegistrar() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report, Self.mail]))
        controller.launch()

        #expect(controller.modeHotKeys.active == ["perso-un": Self.keyB, "perso-deux": Self.keyC])
        #expect(modeRegistrars.made.count == 2)
        #expect(hotKeys.registered == .standard, "le raccourci global est à part")
        #expect(controller.panelModel.notices[.hotKey] == nil)
    }

    @Test func savingTheSettingsDoesNotRegisterTheModesHotKeysAgain() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report]))
        controller.launch()
        let registerCalls = modeRegistrars.made.map(\.registerCalls)
        let unregisterCalls = modeRegistrars.made.map(\.unregisterCalls)

        controller.panelModel.select("perso-un")
        try controller.updateSettings { $0.hotKeyBehavior = .hold }
        #expect(modeRegistrars.made.map(\.registerCalls) == registerCalls)
        #expect(modeRegistrars.made.map(\.unregisterCalls) == unregisterCalls)
    }

    @Test func givingRemovingAndDeletingAModesHotKeyFollowsTheSettings() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report, Self.mail]))
        controller.launch()

        try controller.updateSettings { $0.modes[2].hotKey = nil }
        #expect(controller.modeHotKeys.active == ["perso-un": Self.keyB])
        #expect(modeRegistrars.registered == [Self.keyB])

        try controller.updateSettings { $0.modes[2].hotKey = HotKey(keyCode: 0x02, modifiers: [.control, .option]) }
        #expect(modeRegistrars.registered.count == 2)

        // Un mode supprimé perd son raccourci : son registraire est libéré.
        try controller.updateSettings { $0.modes.removeAll { $0.id == "perso-un" } }
        #expect(controller.modeHotKeys.active.keys.sorted() == ["perso-deux"])
        #expect(!modeRegistrars.registered.contains(Self.keyB))
    }

    @Test func aModesHotKeyRunsThatModesDictationControllerPath() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report]))
        controller.launch()

        modeRegistrars.press(Self.keyB)
        // « Compte rendu » a une consigne : son raccourci lance une vraie dictée, sur ce mode, qui est enregistré.
        #expect(controller.panelModel.selectedModeID == "perso-un")
        #expect(controller.panelModel.isOpen)
        #expect(controller.panelModel.dictation.stage == .preparing)
        #expect(controller.panelModel.dictation.notice != DictationController.laterModeNotice)
        #expect(store.load().settings.lastModeID == "perso-un")
    }

    @Test func theInterviewsHotKeyStillOpensThePanelWithTheLaterModeSentence() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = Self.settings([Self.report])
        settings.modes[2].hotKey = Self.keyC
        let controller = makeController(settings)
        controller.launch()

        modeRegistrars.press(Self.keyC)
        #expect(controller.panelModel.selectedModeID == ModeChip.interviewID)
        #expect(controller.panelModel.isOpen)
        #expect(controller.panelModel.dictation.notice == DictationController.laterModeNotice)
        #expect(store.load().settings.lastModeID == ModeChip.interviewID)
    }

    // MARK: - Refus, dits dans le panneau

    @Test func aRefusedModeDoesNotStopTheOthersAndIsNamedInThePanel() {
        defer { try? FileManager.default.removeItem(at: directory) }
        // Les registraires de mode refusent ⌃⌥B ; ⌃⌥C passe.
        let refusing = AppControllerModesTests.refusingRegistrars(keyB: Self.keyB)
        let controller = makeController(Self.settings([Self.report, Self.mail]), registrars: refusing)

        controller.launch()
        #expect(controller.modeHotKeys.active == ["perso-deux": Self.keyC])
        let lines = hotKeyLines(controller)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("Compte rendu") == true)
        #expect(lines.first?.contains("⌃⌥B") == true)
        #expect(lines.first?.contains("Courriel") == false)
        #expect(!controller.panelModel.isOpen, "un mode refusé n'ouvre pas le panneau : l'avis attend la prochaine ouverture")

        controller.togglePanelFromMenu()
        #expect(controller.panelModel.isOpen)
        #expect(hotKeyLines(controller).count == 1, "l'avis est là quand le panneau s'ouvre")
    }

    @Test func aGlobalRefusalStillOpensThePanelAtLaunchEvenWithModes() {
        defer { try? FileManager.default.removeItem(at: directory) }
        hotKeys.refused = [.standard]
        let controller = makeController(Self.settings([Self.report]))
        controller.launch()
        #expect(controller.panelModel.isOpen)
    }

    @Test func eachRefusedModeGetsItsOwnLineInTheOrderOfTheModes() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let refusing = AppControllerModesTests.refusingRegistrars(keyB: Self.keyB, Self.keyC)
        let controller = makeController(Self.settings([Self.mail, Self.report]), registrars: refusing)

        controller.launch()
        let lines = hotKeyLines(controller)
        #expect(lines.count == 2)
        guard lines.count == 2 else { return }
        #expect(lines[0].contains("Courriel"))
        #expect(lines[1].contains("Compte rendu"))
    }

    @Test func theGlobalNoticeAndTheModeNoticesLiveTogetherAndOneDoesNotEraseTheOther() {
        defer { try? FileManager.default.removeItem(at: directory) }
        hotKeys.refused = [.standard]
        let refusing = AppControllerModesTests.refusingRegistrars(keyB: Self.keyB)
        let controller = makeController(Self.settings([Self.report]), registrars: refusing)

        controller.launch()
        var lines = hotKeyLines(controller)
        #expect(lines.count == 2)
        guard lines.count == 2 else { return }
        #expect(lines[0].contains("refusé par macOS"))
        #expect(lines[0].contains("Compte rendu") == false)
        #expect(lines[1].contains("Compte rendu"))

        // Le global réussit : son avis part, celui du mode reste.
        let result = controller.changeHotKey(Self.keyA)
        #expect(HotKeyTests.failure(result) == nil)
        lines = hotKeyLines(controller)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("Compte rendu") == true)
    }

    @Test func aModeRefusedAfterTheLaunchIsNamedToo() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let refusing = AppControllerModesTests.refusingRegistrars(keyB: Self.keyB)
        let controller = makeController(Self.settings([]), registrars: refusing)
        controller.launch()
        #expect(controller.panelModel.notices[.hotKey] == nil)

        try controller.updateSettings { $0.modes.insert(Self.report, at: 1) }
        #expect(hotKeyLines(controller).count == 1)
        #expect(hotKeyLines(controller).first?.contains("Compte rendu") == true)

        // Le mode perd son raccourci : la ligne s'efface.
        try controller.updateSettings { $0.modes[1].hotKey = nil }
        #expect(controller.panelModel.notices[.hotKey] == nil)
    }

    // MARK: - Doublons dans les réglages

    static let sameAsReport = Mode(id: "perso-deux", name: "Courriel", instruction: "Rédige.", hotKey: keyB)

    @Test func twoModesOnTheSameCombinationKeepTheFirstOfTheListEveryTime() {
        defer { try? FileManager.default.removeItem(at: directory) }
        // Le registraire double accepte les doublons : c'est l'application qui écarte le second, pas le « système ».
        for _ in 0..<8 {
            let registrars = ModeRegistrars()
            let controller = makeController(Self.settings([Self.report, Self.sameAsReport]), registrars: registrars)
            controller.launch()
            #expect(controller.modeHotKeys.active == ["perso-un": Self.keyB])
            #expect(registrars.createdCount == 1, "le perdant n'a même pas de registraire")
        }
        for _ in 0..<8 {
            let registrars = ModeRegistrars()
            let controller = makeController(Self.settings([Self.sameAsReport, Self.report]), registrars: registrars)
            controller.launch()
            #expect(controller.modeHotKeys.active == ["perso-deux": Self.keyB], "le premier dans l'ordre des modes gagne")
        }
    }

    @Test func theLoserOfADuplicateIsNamedWithItsHolderAndNeverBlamedOnMacOS() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report, Self.sameAsReport]))
        controller.launch()

        let lines = hotKeyLines(controller)
        #expect(lines.count == 1)
        let line = lines.first ?? ""
        #expect(line.contains("Courriel"), "le mode qui n'est pas actif est nommé")
        #expect(line.contains("« Compte rendu »"), "le détenteur est nommé")
        #expect(line.contains("n'est pas actif"))
        #expect(line.contains("⌃⌥B"))
        #expect(!line.contains("macOS"))
        #expect(!controller.panelModel.isOpen)
    }

    @Test func threeModesOnOneCombinationLeaveOneHolderAndTwoLines() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let third = Mode(id: "perso-trois", name: "Note", instruction: "Note.", hotKey: Self.keyB)
        let controller = makeController(Self.settings([Self.report, Self.sameAsReport, third]))
        controller.launch()
        #expect(controller.modeHotKeys.active == ["perso-un": Self.keyB])
        let lines = hotKeyLines(controller)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains("« Compte rendu »") }, "tous nomment le détenteur, pas un autre perdant")
    }

    @Test func aModeOnTheGlobalCombinationIsSetAsideAndNamesTheGlobalHotKey() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let onGlobal = Mode(id: "perso-un", name: "Compte rendu", instruction: "Résume.", hotKey: .standard)
        let registrars = ModeRegistrars()
        let controller = makeController(Self.settings([onGlobal]), registrars: registrars)
        controller.launch()

        #expect(hotKeys.registered == .standard, "le raccourci global gagne toujours")
        #expect(controller.modeHotKeys.active.isEmpty)
        #expect(registrars.createdCount == 0)
        let lines = hotKeyLines(controller)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("raccourci général") == true)
        #expect(lines.first?.contains("Compte rendu") == true)
        #expect(lines.first?.contains("macOS") == false)
    }

    @Test func theLoserTakesTheCombinationWhenItsHolderLetsGo() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report, Self.sameAsReport]))
        controller.launch()
        #expect(controller.modeHotKeys.active == ["perso-un": Self.keyB])

        try controller.updateSettings { $0.modes.removeAll { $0.id == "perso-un" } }
        #expect(controller.modeHotKeys.active == ["perso-deux": Self.keyB])
        #expect(controller.panelModel.notices[.hotKey] == nil)
    }

    // MARK: - changeModeHotKey

    @Test func changingAModesHotKeyRegistersItAndClearsItsNotice() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let refusing = AppControllerModesTests.refusingRegistrars(keyB: Self.keyB)
        let controller = makeController(Self.settings([Self.report]), registrars: refusing)
        controller.launch()
        #expect(hotKeyLines(controller).count == 1)

        #expect(HotKeyTests.failure(controller.changeModeHotKey(Self.keyC, for: "perso-un")) == nil)
        #expect(controller.modeHotKeys.active == ["perso-un": Self.keyC])
        #expect(controller.panelModel.notices[.hotKey] == nil)
    }

    @Test func aRefusedChangeOfAModesHotKeyKeepsTheOldOne() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report]))
        controller.launch()
        for registrar in modeRegistrars.made { registrar.refused = [Self.keyC] }

        #expect(HotKeyTests.failure(controller.changeModeHotKey(Self.keyC, for: "perso-un")) == .refused)
        #expect(controller.modeHotKeys.active == ["perso-un": Self.keyB])
        #expect(modeRegistrars.registered == [Self.keyB])
        #expect(HotKeyTests.failure(controller.changeModeHotKey(nil, for: "perso-un")) == nil)
        #expect(modeRegistrars.registered.isEmpty)
    }

    /// Un identifiant que les réglages ne portent pas (mode supprimé pendant ce temps) : rien n'est enregistré, aucun registraire
    /// n'est fabriqué, et la réponse est un échec que l'onglet Modes traduit en phrase.
    @Test func aHotKeyForAnUnknownModeIsRefusedAndRegistersNothing() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report]))
        controller.launch()
        let registrarsBefore = modeRegistrars.made.count

        #expect(HotKeyTests.failure(controller.changeModeHotKey(Self.keyC, for: "perso-absent")) == .refused)
        #expect(HotKeyTests.failure(controller.changeModeHotKey(nil, for: "perso-absent")) == .refused)

        #expect(modeRegistrars.made.count == registrarsBefore, "aucun registraire n'est fabriqué pour un mode inconnu")
        #expect(controller.modeHotKeys.active == ["perso-un": Self.keyB])
        #expect(modeRegistrars.registered == [Self.keyB])
        #expect(controller.settings == Self.settings([Self.report]))
    }

    // MARK: - Capture

    @Test func aCaptureGivesEveryHotKeyBackToTheSystemAndTheEndTakesThemAgain() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report, Self.mail]))
        controller.launch()

        controller.suspendHotKeysForCapture()
        #expect(hotKeys.registered == nil)
        #expect(modeRegistrars.registered.isEmpty)

        #expect(controller.resumeHotKeys())
        #expect(hotKeys.registered == .standard)
        #expect(Set(modeRegistrars.registered.map(\.keyCode)) == [Self.keyB.keyCode, Self.keyC.keyCode])
        #expect(controller.panelModel.notices[.hotKey] == nil)
    }

    @Test func aModeThatTheSystemRefusesAfterTheCaptureSaysSoAndTheGlobalStaysTrue() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report, Self.mail]))
        controller.launch()
        controller.suspendHotKeysForCapture()
        for registrar in modeRegistrars.made { registrar.refused = [Self.keyB] }

        #expect(controller.resumeHotKeys(), "le raccourci global est rétabli : la réponse ne parle que de lui")
        #expect(hotKeys.registered == .standard)
        #expect(controller.modeHotKeys.active == ["perso-deux": Self.keyC])
        let lines = hotKeyLines(controller)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("Compte rendu") == true)
        #expect(lines.first?.contains("rétabli") == true)
    }

    /// Un mode dont la combinaison n'a jamais été active (donnée pendant la capture, refusée à la reprise) : la phrase dit
    /// « enregistré », jamais « rétabli », puisqu'il n'y a rien à rétablir.
    @Test func aModeWhoseHotKeyWasNeverActiveSaysItCouldNotBeRegisteredNotRestored() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report]))
        controller.launch()
        controller.suspendHotKeysForCapture()
        modeRegistrars.refusing = [Self.keyC]
        try controller.updateSettings { $0.modes.insert(Self.mail, at: 2) }

        #expect(controller.resumeHotKeys())
        #expect(controller.modeHotKeys.active == ["perso-un": Self.keyB], "le mode déjà actif est rétabli, l'autre n'a rien")
        let lines = hotKeyLines(controller)
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line.contains("Courriel"))
        #expect(line.contains("n'a pas pu être enregistré après la capture"))
        #expect(!line.contains("rétabli"))
    }

    /// Un mode actif dont la combinaison change pendant la capture et est refusée à la reprise : la combinaison refusée n'a jamais
    /// été active, la phrase dit « enregistré » ; l'ancienne revient.
    @Test func aChangedHotKeyThatTheSystemRefusesSaysRegisteredNotRestoredAndTheOldOneComesBack() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = makeController(Self.settings([Self.report]))
        controller.launch()
        controller.suspendHotKeysForCapture()
        for registrar in modeRegistrars.made { registrar.refused = [Self.keyC] }
        try controller.updateSettings { $0.modes[1].hotKey = Self.keyC }

        #expect(controller.resumeHotKeys())
        #expect(controller.modeHotKeys.active == ["perso-un": Self.keyB])
        let line = try #require(hotKeyLines(controller).first)
        #expect(line.contains(Self.keyC.label(layout: HotKeyTests.ansi)))
        #expect(line.contains("n'a pas pu être enregistré après la capture"))
        #expect(!line.contains("rétabli"))
    }

    // MARK: - Conflits

    @Test func aHotKeyHeldByAModeIsRefusedToEveryoneElseWithTheHoldersName() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        system.hotKeys = [Self.keyA]
        let controller = makeController(Self.settings([Self.report, Self.mail]))
        controller.launch()

        #expect(controller.modeHolding(Self.keyB) == "Compte rendu")
        #expect(controller.modeHolding(Self.keyA) == nil)
        let forMail = try #require(controller.hotKeyRefusal(for: Self.keyB, owner: .mode("perso-deux")))
        #expect(forMail.contains("Compte rendu"))
        let forGlobal = try #require(controller.hotKeyRefusal(for: Self.keyB, owner: .global))
        #expect(forGlobal.contains("Compte rendu"))
        #expect(controller.hotKeyRefusal(for: Self.keyB, owner: .mode("perso-un")) == nil)
        // La combinaison du global et un raccourci de macOS activé sont refusés aussi.
        #expect(try #require(controller.hotKeyRefusal(for: .standard, owner: .mode("perso-un"))).contains("global"))
        #expect(controller.hotKeyRefusal(for: Self.keyA, owner: .mode("perso-un")) != nil)
    }

    @Test func aModeThatTheSystemRefusedStillHoldsItsCombinationInTheSettings() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let refusing = AppControllerModesTests.refusingRegistrars(keyB: Self.keyB)
        let controller = makeController(Self.settings([Self.report, Self.mail]), registrars: refusing)
        controller.launch()
        #expect(controller.modeHotKeys.active["perso-un"] == nil)

        let sentence = try #require(controller.hotKeyRefusal(for: Self.keyB, owner: .mode("perso-deux")))
        #expect(sentence.contains("Compte rendu"), "les raccourcis attribués comptent, pas seulement ceux qui sont actifs")
    }

    // MARK: - Doubles

    /// Des registraires de mode qui refusent ces combinaisons.
    static func refusingRegistrars(keyB first: HotKey, _ more: HotKey...) -> ModeRegistrars {
        let registrars = ModeRegistrars()
        registrars.refusing = [first] + more
        return registrars
    }

    func makeController(_ settings: AppSettings, registrars: ModeRegistrars) -> AppController {
        try? store.save(settings)
        return AppController(
            settingsStore: store, secrets: InMemorySecretStore(), hotKeyRegistrar: hotKeys,
            escapeRegistrar: escape, makeModeHotKeyRegistrar: { registrars.make() },
            permissionsProbe: probe, systemHotKeys: system, keyboardLayout: HotKeyTests.ansi,
            makePanelSurface: { [surface] _ in surface }, clickMonitor: FakeClickMonitor(),
            makeSettingsWindow: presenter.make, terminate: presenter.terminate,
            rewriter: .unavailable, inserter: InsertionRig().inserter)
    }
}
