import Testing

@testable import SupervoxApp

/// Surface de panneau double : rien n'est affiché à l'écran.
@MainActor final class FakePanelSurface: PanelSurface {
    private(set) var isShown = false
    private(set) var showCount = 0

    func show() {
        isShown = true
        showCount += 1
    }

    func hide() { isShown = false }
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
        // L'avis dit comment fermer quand même.
        #expect(notice.contains("⌃⌥Espace"))
        #expect(notice.contains("clic en dehors"))

        controller.close()
        escape.refused = []
        controller.open()
        #expect(model.notices[.escape] == nil)
    }
}
