import CoreGraphics
import SupervoxCore
import Testing

@testable import SupervoxApp

/// Surface de panneau double : rien n'est affiché à l'écran.
@MainActor final class FakePanelSurface: PanelSurface, ContentSizeObserving, KeyStateObserving {
    private(set) var isShown = false
    private(set) var showCount = 0
    /// Appelé à chaque affichage : le test y lit ce que le panneau contient à ce moment-là (la vraie surface prend
    /// sa taille à l'affichage).
    var onShow: (@MainActor () -> Void)?

    /// Ce que la surface a reçu, dans l'ordre : la fermeture est un seul `hide`, sans `setKeyboard` ni `show`.
    enum Call: Equatable {
        case show
        case hide
        case keyboard(PanelKeyboard)
    }
    private(set) var calls: [Call] = []
    /// Les seules valeurs de clavier reçues, dans l'ordre.
    var keyboards: [PanelKeyboard] {
        calls.compactMap { if case .keyboard(let keyboard) = $0 { keyboard } else { nil } }
    }

    func show() {
        isShown = true
        showCount += 1
        calls.append(.show)
        onShow?()
    }

    func hide() {
        isShown = false
        calls.append(.hide)
    }

    /// Le journal de l'insertion, partagé pour comparer l'ordre des appels.
    var log: CallLog?

    func setKeyboard(_ keyboard: PanelKeyboard) {
        calls.append(.keyboard(keyboard))
        log?.entries.append("keyboard(\(keyboard))")
    }

    /// La hauteur que le contenu demande : le test la change comme le ferait un contenu qui grandit ou rétrécit.
    var height: CGFloat = 120
    private(set) var resizes: [CGFloat] = []

    func contentHeight() -> CGFloat? { height }
    func resize(toHeight height: CGFloat) { resizes.append(height) }

    /// Comme la vraie surface : le contrôleur y pose sa fermeture, que la vue d'hébergement appelle quand son contenu change de
    /// taille ; le test l'appelle par `signalContentSizeChange()`.
    var onContentSizeChange: (@MainActor () -> Void)?
    func signalContentSizeChange() { onContentSizeChange?() }

    /// Comme la vraie surface : le contrôleur y pose sa fermeture, que la surface appelle quand le panneau prend ou perd la clé.
    var onKeyChange: (@MainActor (Bool) -> Void)?
    func signalKeyChange(_ isKey: Bool) { onKeyChange?(isKey) }
}

/// Moniteur de clics double : le test déclenche lui-même un clic hors de l'application.
@MainActor final class FakeClickMonitor: OutsideClickMonitor {
    private var handler: (@MainActor () -> Void)?
    private(set) var starts = 0
    private(set) var stops = 0

    var isWatching: Bool { handler != nil }

    func start(_ onClick: @escaping @MainActor () -> Void) {
        starts += 1
        handler = onClick
    }

    func stop() {
        stops += 1
        handler = nil
    }

    /// Clic hors de l'application, s'il est surveillé.
    func clickOutside() { handler?() }
}

@MainActor @Suite struct PanelControllerTests {
    let model = PanelModel(lastModeID: "dictee-brute")
    let escape = HotKeyTests.FakeRegistrar()
    let clicks = FakeClickMonitor()
    let surface = FakePanelSurface()

    func makeController() -> PanelController {
        PanelController(model: model, escapeRegistrar: escape, clickMonitor: clicks, surface: surface)
    }

    // MARK: - Hauteur du panneau

    @Test func aChangeThatChangesTheContentHeightAsksForAResize() async {
        let controller = makeController()
        controller.open()
        #expect(surface.resizes.isEmpty, "à l'ouverture, la surface prend sa taille elle-même")

        surface.height = 180
        controller.contentChanged()
        #expect(surface.resizes == [180])

        surface.height = 90
        controller.contentChanged()
        #expect(surface.resizes == [180, 90])
    }

    @Test func aChangeThatKeepsTheHeightAsksForNothing() async {
        let controller = makeController()
        controller.open()
        controller.contentChanged()
        controller.contentChanged()
        // Moins d'un demi-point : le même contenu, mesuré à l'arrondi près.
        surface.height = 120.3
        controller.contentChanged()
        #expect(surface.resizes.isEmpty)

        surface.height = 150
        controller.contentChanged()
        controller.contentChanged()
        #expect(surface.resizes == [150])
        // La mesure du tour suivant (le contenu se met en page après le changement) ne redemande rien non plus.
        for _ in 0..<5 { await Task.yield() }
        #expect(surface.resizes == [150])
    }

    @Test func theHeightIsRememberedAtOpeningSoThatTheFirstChangeIsComparedWithIt() {
        let controller = makeController()
        surface.height = 200
        controller.open()
        controller.contentChanged()
        #expect(surface.resizes.isEmpty, "200 était déjà la hauteur à l'ouverture")
        surface.height = 100
        controller.contentChanged()
        #expect(surface.resizes == [100])
    }

    /// N3 : le lien « la vue signale un changement de hauteur → le contrôleur redimensionne ». C'est le seul déclencheur des
    /// changements qui ne passent pas par l'état de la dictée (ligne de permission, avis du pied, « Copie impossible »,
    /// accueil) : sans lui, le panneau garde sa hauteur.
    @Test func aContentSizeChangeSignalledByTheViewResizesTheOpenPanel() {
        let controller = makeController()
        controller.open()
        #expect(surface.onContentSizeChange != nil)
        surface.height = 140
        surface.signalContentSizeChange()
        #expect(surface.resizes == [140])
    }

    @Test func aContentSizeChangeSignalledWhileClosedResizesNothing() {
        _ = makeController()
        surface.height = 140
        surface.signalContentSizeChange()
        #expect(surface.resizes.isEmpty)
    }

    @Test func aClosedPanelIsNeverResizedAndReopensFresh() {
        let controller = makeController()
        surface.height = 150
        controller.contentChanged()
        #expect(surface.resizes.isEmpty)

        controller.open()
        surface.height = 170
        controller.contentChanged()
        controller.close()
        surface.height = 90
        controller.contentChanged()
        #expect(surface.resizes == [170])

        // Rouvert : la surface reprend sa taille à l'affichage ; la mémoire de la hauteur est celle de ce moment.
        controller.open()
        controller.contentChanged()
        #expect(surface.resizes == [170])
    }

    @Test func aContentChangeNotedLaterByTheLayoutIsStillCaught() async {
        let controller = makeController()
        controller.open()
        // Au moment du changement le contenu n'est pas encore remis en page : il garde l'ancienne hauteur.
        controller.contentChanged()
        #expect(surface.resizes.isEmpty)
        surface.height = 160
        for _ in 0..<5 { await Task.yield() }
        #expect(surface.resizes == [160])
    }

    // MARK: - Clavier

    @Test func keyboardRequestedWhileClosedNeverReachesTheSurface() {
        let controller = makeController()
        controller.setKeyboard(.focused)
        controller.setKeyboard(.available)
        #expect(surface.calls.isEmpty)
    }

    @Test(arguments: [PanelKeyboard.none, .available, .focused])
    func anOpenPanelPassesTheKeyboardToItsSurface(_ keyboard: PanelKeyboard) {
        let controller = makeController()
        controller.open()
        controller.setKeyboard(keyboard)
        #expect(surface.calls == [.show, .keyboard(keyboard)])
    }

    /// La fermeture ne passe plus par `setKeyboard(.none)` : `hide()` retire lui-même la frappe au panneau, en un seul retrait
    /// de l'écran (la manœuvre « retirer puis remettre » de `setKeyboard` n'a de sens que panneau ouvert).
    @Test func closingHidesOnceWithoutAKeyboardRequestOrAReshow() {
        let controller = makeController()
        controller.open()
        controller.setKeyboard(.focused)
        controller.close()
        #expect(surface.calls == [.show, .keyboard(.focused), .hide])
    }

    @Test func everyWayOfClosingHidesOnceWithoutAKeyboardRequestOrAReshow() {
        let controller = makeController()
        // La bascule du menu.
        controller.open()
        controller.setKeyboard(.focused)
        controller.toggle()
        #expect(Array(surface.calls.suffix(2)) == [.keyboard(.focused), .hide])
        // Échap sans gestionnaire.
        controller.open()
        controller.setKeyboard(.available)
        escape.press()
        #expect(Array(surface.calls.suffix(2)) == [.keyboard(.available), .hide])
        // Le clic en dehors.
        controller.open()
        controller.setKeyboard(.focused)
        clicks.clickOutside()
        #expect(Array(surface.calls.suffix(2)) == [.keyboard(.focused), .hide])
        #expect(surface.calls.filter { $0 == .hide }.count == 3)
        #expect(surface.calls.filter { $0 == .show }.count == 3)
    }

    @Test func reopeningCarriesNoKeyboardOverFromTheLastTime() {
        let controller = makeController()
        controller.open()
        controller.setKeyboard(.focused)
        controller.close()
        controller.open()
        #expect(Array(surface.calls.suffix(1)) == [.show])
        // Rien n'a été remis sur la surface depuis la fermeture.
        #expect(surface.keyboards == [.focused])
        controller.setKeyboard(.available)
        #expect(surface.keyboards == [.focused, .available])
    }

    // MARK: - Cadre redimensionné

    private let visible = CGRect(x: 0, y: 40, width: 1_000, height: 800)

    @Test func theFrameKeepsItsTopWhenItGrowsAndShrinks() {
        let frame = CGRect(x: 240, y: 500, width: 520, height: 200)   // haut à 700
        #expect(PanelController.resizedFrame(frame, height: 300, in: visible) == CGRect(x: 240, y: 400, width: 520, height: 300))
        #expect(PanelController.resizedFrame(frame, height: 120, in: visible) == CGRect(x: 240, y: 580, width: 520, height: 120))
    }

    @Test func theFrameIsPushedUpRatherThanLeavingTheScreenAtTheBottom() {
        let frame = CGRect(x: 240, y: 60, width: 520, height: 100)   // haut à 160, bas de la zone utile à 40
        let next = PanelController.resizedFrame(frame, height: 300, in: visible)
        #expect(next.minY == 40 && next.height == 300 && next.width == 520 && next.minX == 240)
    }

    @Test func aFrameTallerThanTheScreenIsCapped() {
        let next = PanelController.resizedFrame(CGRect(x: 0, y: 100, width: 520, height: 100), height: 5_000, in: visible)
        #expect(next.height == 800 && next.minY == 40)
    }

    @Test func withoutAScreenTheTopStaysWhereItIs() {
        let next = PanelController.resizedFrame(CGRect(x: 10, y: 500, width: 520, height: 200), height: 100, in: nil)
        #expect(next == CGRect(x: 10, y: 600, width: 520, height: 100))
    }

    @Test func outsideClickClosesThePanel() {
        let controller = makeController()
        controller.open()
        #expect(surface.isShown)
        #expect(clicks.isWatching)

        clicks.clickOutside()
        #expect(!model.isOpen)
        #expect(!surface.isShown)
        // Fermé par le clic comme par tout autre chemin : Échap est rendu, le moniteur retiré.
        #expect(escape.registered == nil)
        #expect(!clicks.isWatching)
    }

    @Test func clicksAreWatchedOnlyWhileThePanelIsOpen() {
        let controller = makeController()
        #expect(!clicks.isWatching)

        controller.toggle()
        #expect(clicks.isWatching)
        controller.toggle()
        #expect(!clicks.isWatching)

        // Fermé par Échap : le moniteur est retiré aussi.
        controller.open()
        escape.press()
        #expect(!model.isOpen)
        #expect(!clicks.isWatching)
        #expect(clicks.starts == clicks.stops)
    }

    @Test func escapeIsHeldOnlyWhileThePanelIsOpen() {
        let controller = makeController()
        controller.open()
        #expect(escape.registered == HotKey(keyCode: 53, modifiers: []))

        escape.press()
        #expect(!model.isOpen)
        #expect(escape.registered == nil)
    }

    @Test func refusedEscapeIsAnnouncedAndClearedOnceHeld() throws {
        model.hotKeyLabel = "⌃⌥Espace"
        escape.refused = [HotKey(keyCode: 53, modifiers: [])]
        let controller = makeController()

        controller.open()
        let notice = try #require(model.notices[.escape])
        #expect(notice.contains("Échap"))
        // L'avis dit comment fermer quand même : le raccourci lance une dictée (il ne ferme plus le panneau) et le clic en
        // dehors est ignoré pendant une dictée ; le menu de la barre de menus ferme toujours.
        #expect(notice.contains("menu"))
        #expect(notice.contains("barre de menus"))
        #expect(notice.contains("clic en dehors"))
        #expect(notice.contains("aucune dictée"))
        #expect(!notice.contains("⌃⌥Espace"))

        controller.close()
        escape.refused = []
        controller.open()
        #expect(model.notices[.escape] == nil)
    }

    // MARK: - La frappe du panneau

    @Test func theModelFollowsTheKeyStateTheSurfaceReports() {
        let controller = makeController()
        controller.open()
        #expect(!model.panelHasKeyboard)

        surface.signalKeyChange(true)
        #expect(model.panelHasKeyboard)
        surface.signalKeyChange(false)
        #expect(!model.panelHasKeyboard)
        surface.signalKeyChange(true)
        #expect(model.panelHasKeyboard)

        controller.close()
        #expect(!model.panelHasKeyboard, "un panneau fermé n'a pas la frappe")
    }

    // MARK: - Dictée

    @Test(arguments: [DictationStage.preparing, .recording, .finalizing])
    func outsideClickIsIgnoredWhileADictationRuns(_ stage: DictationStage) {
        let controller = makeController()
        controller.open()
        model.dictation = DictationViewState(stage: stage)

        clicks.clickOutside()
        #expect(model.isOpen)
        #expect(surface.isShown)
        #expect(clicks.isWatching)
    }

    /// Le clic qui sert à passer à la fenêtre où le texte doit aller ne doit pas fermer la relecture : le panneau est tenu tant que
    /// le texte attend d'être relu ou se colle (`holdsPanel`), pas seulement pendant l'enregistrement (`isActive`).
    @Test("règle 13 : le clic en dehors est ignoré en relecture et pendant le collage", arguments: [DictationStage.review, .pasting])
    func outsideClickIsIgnoredWhileTheTextIsReviewedOrPasted(_ stage: DictationStage) {
        let controller = makeController()
        controller.open()
        model.dictation = DictationViewState(stage: stage, lastTranscript: "Un texte.", draft: "Un texte.")

        clicks.clickOutside()
        #expect(model.isOpen)
        #expect(surface.isShown)
        #expect(clicks.isWatching)
        #expect(!surface.calls.contains(.hide))
    }

    @Test("règle 13 : le clic en dehors ferme comme avant en copie, au repos, après un échec, une interruption", arguments: [
        DictationStage.copied, .idle, .cancelled, .failed(.clipboard),
    ])
    func outsideClickClosesAfterTheReviewToo(_ stage: DictationStage) {
        let controller = makeController()
        controller.open()
        model.dictation = DictationViewState(stage: stage, lastTranscript: "Un texte.")
        clicks.clickOutside()
        #expect(!model.isOpen)
        #expect(surface.calls.last == .hide)
    }

    @Test(arguments: [
        DictationStage.idle, .copied, .cancelled, .failed(.noSpeech),
    ])
    func outsideClickStillClosesThePanelWhenNoDictationRuns(_ stage: DictationStage) {
        let controller = makeController()
        controller.open()
        model.dictation = DictationViewState(stage: stage)

        clicks.clickOutside()
        #expect(!model.isOpen)
    }

    @Test func closedPanelReportsItsClosingOnlyWhenItWasOpen() {
        let controller = makeController()
        var closings = 0
        controller.onClosed = { closings += 1 }

        controller.close()
        #expect(closings == 0)

        controller.open()
        controller.close()
        #expect(closings == 1)

        // Fermé par la bascule du menu : même signal.
        controller.toggle()
        controller.toggle()
        #expect(closings == 2)

        // Fermé par un clic en dehors, ou par Échap sans gestionnaire : même signal.
        controller.open()
        clicks.clickOutside()
        controller.open()
        escape.press()
        #expect(closings == 4)
    }

    @Test func escapeGoesToItsHandlerWhenThereIsOne() {
        let controller = makeController()
        var escapes = 0
        controller.escapeHandler = { escapes += 1 }
        controller.open()

        escape.press()
        #expect(escapes == 1)
        // Le gestionnaire décide : le panneau n'est pas fermé par le contrôleur de panneau lui-même.
        #expect(model.isOpen)
    }

    @Test func theControllerAnswersTheDictationControllersQuestion() {
        let controller = makeController()
        #expect(!controller.isOpen)
        controller.open()
        #expect(controller.isOpen)
    }
}
