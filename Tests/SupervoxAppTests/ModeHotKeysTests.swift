import Testing

@testable import SupervoxApp

/// Fabrique de registraires doubles pour les raccourcis de mode : garde chacun de ceux qu'elle a fabriqués. Aucun test de la
/// suite par défaut n'enregistre un vrai raccourci Carbon.
@MainActor final class ModeRegistrars {
    /// Ceux qui ont été fabriqués et sont gardés (`retains`). Un test qui veut voir un registraire libéré met `retains` à faux
    /// avant de fabriquer : la fabrique ne garde alors qu'une référence faible, et `releasedCount` compte ceux qui ont disparu.
    var made: [HotKeyTests.FakeRegistrar] = []
    var retains = true
    /// Les combinaisons que chaque registraire fabriqué refuse (le système les a données à une autre application).
    var refusing: [HotKey] = []
    private var boxes: [WeakRegistrar] = []

    private final class WeakRegistrar {
        weak var value: HotKeyTests.FakeRegistrar?
        init(_ value: HotKeyTests.FakeRegistrar) { self.value = value }
    }

    func make() -> any HotKeyRegistrar {
        let registrar = HotKeyTests.FakeRegistrar()
        registrar.refused = refusing
        boxes.append(WeakRegistrar(registrar))
        if retains { made.append(registrar) }
        return registrar
    }

    /// Les registraires encore vivants : tous ceux qui sont gardés, ou ceux que le code testé tient encore.
    var live: [HotKeyTests.FakeRegistrar] { boxes.compactMap(\.value) }
    var createdCount: Int { boxes.count }
    /// Ceux que le code testé a lâchés (désalloués) : la preuve d'une libération, pas seulement d'un retrait du système.
    var releasedCount: Int { boxes.filter { $0.value == nil }.count }

    /// Le registraire qui tient cette combinaison en ce moment.
    func holding(_ hotKey: HotKey) -> HotKeyTests.FakeRegistrar? { live.first { $0.registered == hotKey } }
    func press(_ hotKey: HotKey) { holding(hotKey)?.press() }
    func release(_ hotKey: HotKey) { holding(hotKey)?.release() }
    var registered: [HotKey] { live.compactMap(\.registered) }
}

/// Un « système » partagé par plusieurs registraires : une combinaison déjà tenue par l'un est refusée à l'autre (ce que fait
/// le vrai système pour une combinaison déjà prise).
@MainActor final class SystemTable {
    var held: [HotKey] = []
}

@MainActor final class OccupyingRegistrar: HotKeyRegistrar {
    private let table: SystemTable
    private var mine: HotKey?
    init(_ table: SystemTable) { self.table = table }

    func register(
        _ hotKey: HotKey, onPress: @escaping @MainActor () -> Void, onRelease: (@MainActor () -> Void)?
    ) -> Bool {
        unregister()
        guard !table.held.contains(hotKey) else { return false }
        table.held.append(hotKey)
        mine = hotKey
        return true
    }

    func unregister() {
        guard let mine else { return }
        table.held.removeAll { $0 == mine }
        self.mine = nil
    }
}

/// Ce que `ModeHotKeys` fait des raccourcis de mode : un registraire par mode, réutilisé tant que le mode existe.
@MainActor @Suite struct ModeHotKeysTests {
    static let keyA = HotKeyTests.keyA
    static let keyB = HotKeyTests.keyB
    static let keyC = HotKey(keyCode: 0x08, modifiers: [.control, .option])
    static let keyD = HotKey(keyCode: 0x02, modifiers: [.control, .option])

    let registrars = ModeRegistrars()
    let hotKeys: ModeHotKeys
    let pressed = Presses()

    @MainActor final class Presses {
        var presses: [String] = []
        var releases: [String] = []
    }

    init() {
        let registrars = registrars
        hotKeys = ModeHotKeys(makeRegistrar: { registrars.make() }, layout: HotKeyTests.ansi)
    }

    @discardableResult
    func apply(_ bindings: [String: HotKey]) -> [String: HotKeyError] {
        let pressed = pressed
        return hotKeys.apply(
            bindings, onPress: { pressed.presses.append($0) }, onRelease: { pressed.releases.append($0) })
    }

    @Test func eachModeGetsItsOwnRegistrarAndCombination() {
        #expect(apply(["un": Self.keyA, "deux": Self.keyB]).isEmpty)
        #expect(registrars.made.count == 2)
        #expect(Set(registrars.registered.map(\.keyCode)) == [Self.keyA.keyCode, Self.keyB.keyCode])
        #expect(hotKeys.active == ["un": Self.keyA, "deux": Self.keyB])
    }

    @Test func aPressAndAReleaseAreToldWithTheModeThatOwnsTheCombination() {
        apply(["un": Self.keyA, "deux": Self.keyB])
        registrars.press(Self.keyB)
        registrars.release(Self.keyB)
        registrars.press(Self.keyA)
        #expect(pressed.presses == ["deux", "un"])
        #expect(pressed.releases == ["deux"])
    }

    @Test func anUnchangedCombinationIsLeftAloneNotRegisteredAgain() {
        apply(["un": Self.keyA, "deux": Self.keyB])
        let registerCalls = registrars.made.map(\.registerCalls)
        let unregisterCalls = registrars.made.map(\.unregisterCalls)

        apply(["un": Self.keyA, "deux": Self.keyB])
        #expect(registrars.made.map(\.registerCalls) == registerCalls)
        #expect(registrars.made.map(\.unregisterCalls) == unregisterCalls)
        #expect(registrars.made.count == 2)
    }

    @Test func aChangedCombinationReusesTheRegistrarOfItsMode() {
        apply(["un": Self.keyA])
        apply(["un": Self.keyB])
        #expect(registrars.made.count == 1)
        #expect(registrars.made[0].registered == Self.keyB)
        #expect(hotKeys.active == ["un": Self.keyB])
    }

    @Test func aModeThatLosesItsHotKeyOrDisappearsReleasesItsRegistrar() {
        apply(["un": Self.keyA, "deux": Self.keyB, "trois": Self.keyC])
        apply(["un": Self.keyA])
        #expect(registrars.registered == [Self.keyA])
        #expect(hotKeys.active == ["un": Self.keyA])
        // Le mode revient : une combinaison à lui, enregistrée de nouveau.
        apply(["un": Self.keyA, "deux": Self.keyB])
        #expect(Set(registrars.registered.map(\.keyCode)) == [Self.keyA.keyCode, Self.keyB.keyCode])
    }

    @Test func aRefusedModeDoesNotStopTheOthers() {
        // Le double refuse sur ordre : la combinaison B est refusée où qu'elle soit enregistrée.
        let registrars = registrars
        let refusing = ModeHotKeys(
            makeRegistrar: {
                let registrar = HotKeyTests.FakeRegistrar()
                registrar.refused = [Self.keyB]
                registrars.made.append(registrar)
                return registrar
            }, layout: HotKeyTests.ansi)
        let errors = refusing.apply(["un": Self.keyA, "deux": Self.keyB, "trois": Self.keyC], onPress: { _ in }, onRelease: { _ in })
        #expect(errors == ["deux": .refused])
        #expect(refusing.active == ["un": Self.keyA, "trois": Self.keyC])
    }

    @Test func anInvalidCombinationIsReportedWithoutAskingTheSystem() {
        let errors = apply(["un": HotKey(keyCode: 0x00, modifiers: []), "deux": Self.keyB])
        #expect(errors == ["un": .invalid(.needsModifier)])
        #expect(registrars.made.first { $0.registerCalls > 0 }?.registered == Self.keyB)
        #expect(hotKeys.active == ["deux": Self.keyB])
    }

    @Test func aLaterApplyReplacesTheHandlers() {
        apply(["un": Self.keyA])
        var second: [String] = []
        _ = hotKeys.apply(["un": Self.keyA], onPress: { second.append($0) }, onRelease: { _ in })
        registrars.press(Self.keyA)
        #expect(second == ["un"])
        #expect(pressed.presses.isEmpty)
    }

    // MARK: - set

    @Test func settingAHotKeyRegistersItAndKeepsTheRegistrarOfTheMode() {
        apply([:])
        #expect(ModeHotKeysTests.failure(hotKeys.set(Self.keyA, for: "un")) == nil)
        #expect(ModeHotKeysTests.failure(hotKeys.set(Self.keyB, for: "un")) == nil)
        #expect(registrars.made.count == 1)
        #expect(hotKeys.active == ["un": Self.keyB])
    }

    @Test func aRefusedNewHotKeyPutsTheModesPreviousOneBack() {
        apply(["un": Self.keyA])
        registrars.made[0].refused = [Self.keyB]
        let result = hotKeys.set(Self.keyB, for: "un")
        #expect(Self.failure(result) == .refused)
        #expect(registrars.made[0].registered == Self.keyA)
        #expect(hotKeys.active == ["un": Self.keyA])
        // Et l'ancienne combinaison répond encore.
        registrars.press(Self.keyA)
        #expect(pressed.presses == ["un"])
    }

    @Test func aRefusedFirstHotKeyLeavesNothingBehind() {
        let registrars = registrars
        let refusing = ModeHotKeys(
            makeRegistrar: {
                let registrar = HotKeyTests.FakeRegistrar()
                registrar.refused = [Self.keyB]
                registrars.made.append(registrar)
                return registrar
            }, layout: HotKeyTests.ansi)
        #expect(Self.failure(refusing.set(Self.keyB, for: "un")) == .refused)
        #expect(refusing.active.isEmpty)
        #expect(registrars.registered.isEmpty)
    }

    @Test func anInvalidHotKeyIsRefusedWithoutAskingTheSystem() {
        let result = hotKeys.set(HotKey(keyCode: 0x00, modifiers: []), for: "un")
        #expect(Self.failure(result) == .invalid(.needsModifier))
        #expect(registrars.made.allSatisfy { $0.registerCalls == 0 })
    }

    @Test func settingNilRemovesTheHotKey() {
        apply(["un": Self.keyA, "deux": Self.keyB])
        #expect(Self.failure(hotKeys.set(nil, for: "un")) == nil)
        #expect(hotKeys.active == ["deux": Self.keyB])
        #expect(registrars.registered == [Self.keyB])
        // Retirer ce qui n'y est pas ne change rien.
        #expect(Self.failure(hotKeys.set(nil, for: "inconnu")) == nil)
    }

    // MARK: - Capture

    @Test func suspendingGivesEveryCombinationBackToTheSystemAndResumingTakesThemAgain() {
        apply(["un": Self.keyA, "deux": Self.keyB])
        hotKeys.suspend()
        #expect(registrars.registered.isEmpty)
        #expect(hotKeys.active == ["un": Self.keyA, "deux": Self.keyB], "gardées, pas oubliées")

        #expect(hotKeys.resume().isEmpty)
        #expect(Set(registrars.registered.map(\.keyCode)) == [Self.keyA.keyCode, Self.keyB.keyCode])
        registrars.press(Self.keyA)
        #expect(pressed.presses == ["un"])
    }

    @Test func aModeThatTheSystemRefusesAfterTheCaptureIsNamed() {
        apply(["un": Self.keyA, "deux": Self.keyB])
        hotKeys.suspend()
        // Une autre application a pris la combinaison de « deux » pendant la capture.
        for registrar in registrars.made { registrar.refused = [Self.keyB] }
        #expect(hotKeys.resume() == ["deux"])
        #expect(hotKeys.active == ["un": Self.keyA])
        #expect(registrars.registered == [Self.keyA])
    }

    @Test func capturingAnotherHotKeyForAModeLeavesTheOthersBack() {
        apply(["un": Self.keyA, "deux": Self.keyB])
        hotKeys.suspend()
        #expect(Self.failure(hotKeys.set(Self.keyC, for: "un")) == nil)
        #expect(hotKeys.resume().isEmpty)
        #expect(Set(registrars.registered.map(\.keyCode)) == [Self.keyC.keyCode, Self.keyB.keyCode])
        #expect(hotKeys.active == ["un": Self.keyC, "deux": Self.keyB])
        // Aucun enregistrement en double : « un » deux fois (A, puis C), « deux » deux fois (B, puis B rétabli).
        #expect(registrars.made.map(\.registerCalls) == [2, 2])
    }

    @Test func applyingWhileSuspendedDoesNotResumeAnUnchangedCombination() {
        apply(["un": Self.keyA, "deux": Self.keyB])
        hotKeys.suspend()
        apply(["un": Self.keyA, "deux": Self.keyB])
        #expect(registrars.registered.isEmpty, "la capture est en cours : rien ne revient au système avant la fin")
        #expect(hotKeys.resume().isEmpty)
        #expect(registrars.registered.count == 2)
    }

    // MARK: - Libération

    @Test func aModeThatLosesItsHotKeyOrDisappearsReallyReleasesItsRegistrar() {
        registrars.retains = false
        apply(["un": Self.keyA, "deux": Self.keyB, "trois": Self.keyC])
        #expect(registrars.createdCount == 3)
        #expect(registrars.releasedCount == 0)

        apply(["un": Self.keyA])
        #expect(registrars.releasedCount == 2, "les registraires des deux modes retirés sont lâchés, pas seulement vidés")
        #expect(registrars.registered == [Self.keyA])

        #expect(Self.failure(hotKeys.set(nil, for: "un")) == nil)
        #expect(registrars.releasedCount == 3)
        #expect(registrars.live.isEmpty)
    }

    @Test func aRefusedFirstHotKeyReleasesTheRegistrarItCreated() {
        registrars.retains = false
        registrars.refusing = [Self.keyB]
        #expect(Self.failure(hotKeys.set(Self.keyB, for: "un")) == .refused)
        #expect(registrars.createdCount == 1)
        #expect(registrars.releasedCount == 1)
    }

    // MARK: - Ordre stable

    @Test func theCombinationsAreTakenInTheOrderOfTheModeIdentifiers() {
        let keys = (0..<8).map { HotKey(keyCode: UInt32($0), modifiers: [.control, .option]) }
        let ids = ["h", "c", "f", "a", "g", "b", "e", "d"]
        let bindings = Dictionary(uniqueKeysWithValues: zip(ids, keys))
        apply(bindings)
        let expected = ids.sorted().map { bindings[$0]! }
        #expect(registrars.made.map { $0.registered } == expected.map { Optional($0) })
    }

    // MARK: - Échange

    @Test func swappingTwoCombinationsInOneApplyWorksWhenTheSystemRefusesTakenOnes() {
        let table = SystemTable()
        let swapping = ModeHotKeys(makeRegistrar: { OccupyingRegistrar(table) }, layout: HotKeyTests.ansi)
        #expect(swapping.apply(["a": Self.keyA, "b": Self.keyB], onPress: { _ in }, onRelease: { _ in }).isEmpty)

        let errors = swapping.apply(["a": Self.keyB, "b": Self.keyA], onPress: { _ in }, onRelease: { _ in })
        #expect(errors.isEmpty)
        #expect(swapping.active == ["a": Self.keyB, "b": Self.keyA])
        #expect(table.held.count == 2)
    }

    // MARK: - Réglages changés pendant une capture

    @Test func applyingDuringACaptureRegistersNothingAndResumeTakesTheNewCombinations() {
        apply(["un": Self.keyA, "deux": Self.keyB])
        hotKeys.suspend()
        let registerCalls = registrars.made.map(\.registerCalls)

        let errors = apply(["un": Self.keyC, "trois": Self.keyD])
        #expect(errors.isEmpty)
        #expect(registrars.registered.isEmpty, "la capture est en cours : rien n'est pris")
        #expect(registrars.made.prefix(2).map(\.registerCalls) == Array(registerCalls.prefix(2)))
        #expect(hotKeys.active == ["un": Self.keyC, "trois": Self.keyD], "celles qui seront prises à la reprise")

        #expect(hotKeys.resume().isEmpty)
        #expect(Set(registrars.registered.map(\.keyCode)) == [Self.keyC.keyCode, Self.keyD.keyCode])
        #expect(hotKeys.active == ["un": Self.keyC, "trois": Self.keyD])
    }

    @Test func aCombinationRefusedAtTheEndOfTheCaptureIsNamedAndTheOldOneComesBack() {
        apply(["un": Self.keyA, "deux": Self.keyB])
        hotKeys.suspend()
        apply(["un": Self.keyC, "deux": Self.keyB, "trois": Self.keyD])
        for registrar in registrars.made { registrar.refused = [Self.keyC, Self.keyD] }
        registrars.refusing = [Self.keyC, Self.keyD]

        #expect(hotKeys.resume() == ["trois", "un"])
        // « un » retrouve son ancienne combinaison, « trois » n'en a pas, « deux » est rétabli.
        #expect(hotKeys.active == ["un": Self.keyA, "deux": Self.keyB])
        #expect(Set(registrars.registered.map(\.keyCode)) == [Self.keyA.keyCode, Self.keyB.keyCode])
    }

    @Test func aModeRemovedDuringACaptureIsGoneAtTheEnd() {
        apply(["un": Self.keyA, "deux": Self.keyB])
        hotKeys.suspend()
        apply(["un": Self.keyA])
        #expect(hotKeys.resume().isEmpty)
        #expect(registrars.registered == [Self.keyA])
        #expect(hotKeys.active == ["un": Self.keyA])
    }

    static func failure(_ result: Result<Void, HotKeyError>) -> HotKeyError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}
