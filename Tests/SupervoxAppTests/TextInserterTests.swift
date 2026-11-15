import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import SupervoxApp

/// Journal unique et partagé : le presse-papiers double, le poseur de touches double et `wait` y inscrivent
/// chacun leurs appels, ce qui permet de comparer l'ordre exact de toute l'insertion.
@MainActor final class CallLog {
    var entries: [String] = []
}

/// Presse-papiers double, avec les mêmes règles que le vrai sur ce qui compte ici : `changeCount` monte à chaque
/// écriture (`write` comme `writeText`), `write` remplace tout le contenu. Aucune écriture ne sort du processus.
@MainActor final class FakePasteboard: PasteboardAccess {
    nonisolated static let textType = "public.utf8-plain-text"

    let log: CallLog
    private(set) var contents: PasteboardContents
    private(set) var changeCount = 0

    init(log: CallLog, contents: PasteboardContents = PasteboardContents(items: [])) {
        self.log = log
        self.contents = contents
    }

    func read() -> PasteboardContents {
        log.entries.append("read")
        return contents
    }

    func write(_ contents: PasteboardContents) {
        log.entries.append("write")
        self.contents = contents
        changeCount += 1
    }

    func writeText(_ text: String, transient: Bool) {
        log.entries.append("writeText(transient: \(transient))")
        contents = Self.textContents(text)
        changeCount += 1
    }

    /// Une autre application écrit dans le presse-papiers : rien n'est journalisé, `changeCount` monte.
    func changeFromElsewhere(_ text: String) {
        contents = Self.textContents(text)
        changeCount += 1
    }

    nonisolated static func textContents(_ text: String) -> PasteboardContents {
        PasteboardContents(items: [[textType: Data(text.utf8)]])
    }

    /// Le texte du premier élément, s'il y en a un.
    var text: String? {
        contents.items.first?[Self.textType].flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// Poseur de touches double : `held` donne les réponses successives de `modifiersHeld` (la dernière se répète),
/// `postPaste` ne poste rien et rend `postSucceeds`.
@MainActor final class FakeKeyPoster: KeyPoster {
    let log: CallLog
    var held: [Bool]
    var postSucceeds: Bool

    init(log: CallLog, held: [Bool] = [false], postSucceeds: Bool = true) {
        self.log = log
        self.held = held
        self.postSucceeds = postSucceeds
    }

    /// Soupape : au bout de `releaseAfterPolls` sondages les touches sont relâchées, pour qu'une boucle fautive
    /// de sondage s'arrête (et fasse échouer le test) au lieu de tourner sans fin.
    let releaseAfterPolls = 1000
    private var polls = 0

    /// Appelé à chaque sondage, avant la réponse : un test y annule la tâche, par exemple.
    var onPoll: (() -> Void)?
    /// Appelé quand ⌘V est posté, avant la réponse : un test y lit ce que le presse-papiers contient à cet instant.
    var onPostPaste: (() -> Void)?

    func modifiersHeld() -> Bool {
        log.entries.append("modifiersHeld")
        onPoll?()
        polls += 1
        if polls > releaseAfterPolls { return false }
        return held.count > 1 ? held.removeFirst() : (held.first ?? false)
    }

    func postPaste(keyCode: UInt16) -> Bool {
        log.entries.append("postPaste(\(keyCode))")
        onPostPaste?()
        return postSucceeds
    }
}

/// L'attente double : n'attend rien, inscrit sa durée au journal et la garde. `onWait` laisse un test agir
/// pendant une attente précise (une autre application qui écrit, par exemple).
@MainActor final class FakeWait {
    let log: CallLog
    private(set) var durations: [Double] = []
    var onWait: ((Double) -> Void)?

    init(log: CallLog) { self.log = log }

    func wait(_ seconds: Double) async {
        log.entries.append("wait(\(seconds))")
        durations.append(seconds)
        onWait?(seconds)
    }
}

/// Une attente qui se comporte comme `try? await Task.sleep` : elle dure jusqu'à `release()`, mais rend la main
/// aussitôt si la tâche qui l'attend est annulée. Aucune durée réelle n'est attendue.
@MainActor final class SleepingWait {
    let log: CallLog
    private(set) var isSleeping = false
    private nonisolated let slot = Mutex<CheckedContinuation<Void, Never>?>(nil)

    init(log: CallLog) { self.log = log }

    func wait(_ seconds: Double) async {
        log.entries.append("wait(\(seconds))")
        if Task.isCancelled { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                slot.withLock { $0 = continuation }
                isSleeping = true
            }
        } onCancel: {
            wake()
        }
        isSleeping = false
    }

    func release() { wake() }

    private nonisolated func wake() {
        slot.withLock {
            $0?.resume()
            $0 = nil
        }
    }
}

/// Tout ce qu'il faut pour une insertion : les doubles, leur journal, et l'insertion câblée dessus.
@MainActor final class InsertionRig {
    let log: CallLog
    let board: FakePasteboard
    let keys: FakeKeyPoster
    let waiter: FakeWait
    let inserter: TextInserter

    /// `restoreDelay` et `modifierPatience` à `nil` : les valeurs par défaut de l'insertion.
    init(
        log: CallLog = CallLog(),
        original: PasteboardContents = FakeInsertion.original,
        trusted: Bool = true, held: [Bool] = [false], postSucceeds: Bool = true,
        layout: any KeyboardLayout = HotKeyTests.ansi,
        restoreDelay: Double? = nil, modifierPatience: Double? = nil,
        wait waitOverride: (@MainActor (Double) async -> Void)? = nil
    ) {
        self.log = log
        board = FakePasteboard(log: log, contents: original)
        keys = FakeKeyPoster(log: log, held: held, postSucceeds: postSucceeds)
        let waiter = FakeWait(log: log)
        self.waiter = waiter
        let wait: @MainActor (Double) async -> Void = waitOverride ?? { await waiter.wait($0) }
        switch (restoreDelay, modifierPatience) {
        case (nil, nil):
            inserter = TextInserter(
                pasteboard: board, keys: keys, layout: layout, isTrusted: { trusted }, wait: wait)
        case let (delay?, nil):
            inserter = TextInserter(
                pasteboard: board, keys: keys, layout: layout, isTrusted: { trusted }, wait: wait,
                restoreDelay: delay)
        case let (nil, patience?):
            inserter = TextInserter(
                pasteboard: board, keys: keys, layout: layout, isTrusted: { trusted }, wait: wait,
                modifierPatience: patience)
        case let (delay?, patience?):
            inserter = TextInserter(
                pasteboard: board, keys: keys, layout: layout, isTrusted: { trusted }, wait: wait,
                restoreDelay: delay, modifierPatience: patience)
        }
    }
}

/// Garde la tâche qui exécute `insert`, pour que les doubles puissent l'annuler à un point précis.
@MainActor final class InsertTaskBox {
    var task: Task<InsertionOutcome, Never>?

    /// Lance `insert` sur le fil principal et rend son résultat ; `cancel()` agit sur cette tâche.
    func run(_ inserter: TextInserter, _ text: String) async -> InsertionOutcome {
        let task = Task { @MainActor in await inserter.insert(text) }
        self.task = task
        return await task.value
    }

    func cancel() { task?.cancel() }
}

enum FakeInsertion {
    /// Ce que l'utilisateur avait copié avant de dicter.
    static let original = FakePasteboard.textContents("brouillon de l'utilisateur")
    /// Le texte dicté, accentué pour que rien ne dépende de l'ASCII.
    static let dictated = "Bonjour à tous, voici la dictée."
}

@MainActor @Suite struct TextInserterTests {
    /// Les phrases de repli (`.copied`) sont lues par quelqu'un qui ne connaît pas l'application : on vérifie les mots
    /// qui portent le sens, et que le texte dicté, donnée privée, n'y figure pas.
    private func reason(_ outcome: InsertionOutcome) -> String? {
        if case .copied(let reason) = outcome { return reason }
        return nil
    }

    // MARK: - Rien à insérer

    @Test("un texte vide ou fait d'espaces ne donne rien : presse-papiers intact, aucune touche, aucune attente",
        arguments: ["", "   ", "\n\t ", "\u{00A0}\u{2003}\n"])
    func blankTextDoesNothing(text: String) async {
        let rig = InsertionRig()
        let outcome = await rig.inserter.insert(text)
        #expect(outcome == .nothing)
        #expect(rig.log.entries.isEmpty)
        #expect(rig.board.contents == FakeInsertion.original)
        #expect(rig.board.changeCount == 0)
    }

    // MARK: - Copie demandée par l'utilisateur

    @Test("copier : le texte est écrit comme une copie ordinaire (non transitoire), sans lecture, sans touche, sans attente")
    func copyWritesTheTextAsAnOrdinaryCopyAndNothingElse() {
        let rig = InsertionRig()
        rig.inserter.copy(FakeInsertion.dictated)
        #expect(rig.board.text == FakeInsertion.dictated)
        #expect(rig.log.entries == ["writeText(transient: false)"])
    }

    @Test("copier un texte vide ou d'espaces ne touche pas au presse-papiers", arguments: ["", "  \n "])
    func copyingBlankTextLeavesThePasteboardAlone(text: String) {
        let rig = InsertionRig()
        rig.inserter.copy(text)
        #expect(rig.log.entries.isEmpty)
        #expect(rig.board.contents == FakeInsertion.original)
    }

    // MARK: - Sans Accessibilité

    @Test("sans Accessibilité, le texte reste dans le presse-papiers, marqué transitoire, et la raison nomme ⌘V et l'Accessibilité")
    func withoutAccessibilityTheTextStaysCopied() async throws {
        let rig = InsertionRig(trusted: false)
        let outcome = await rig.inserter.insert(FakeInsertion.dictated)
        let reason = try #require(reason(outcome))
        #expect(reason.contains("copié"))
        #expect(reason.contains("⌘V"))
        #expect(reason.contains("Accessibilité"))
        #expect(!reason.contains(FakeInsertion.dictated))
        #expect(rig.board.text == FakeInsertion.dictated)
        // Ni lecture ni restauration (le texte doit rester), ni touche, ni attente.
        #expect(rig.log.entries == ["writeText(transient: true)"])
    }

    // MARK: - Cas nominal

    @Test("cas nominal : lecture, écriture transitoire, sondage des modificateurs, ⌘V avec le code de « v », attente, restauration")
    func nominalSequence() async {
        let rig = InsertionRig()
        let outcome = await rig.inserter.insert(FakeInsertion.dictated)
        #expect(outcome == .pasted)
        #expect(rig.log.entries == [
            "read",
            "writeText(transient: true)",
            "modifiersHeld",
            "postPaste(\(kVK_ANSI_V))",
            "wait(0.4)",
            "write",
        ])
        #expect(rig.board.contents == FakeInsertion.original)
    }

    @Test("la touche collée est celle de « v » dans la disposition active")
    func pastesWithTheKeyOfVInTheActiveLayout() async {
        let rig = InsertionRig(layout: TextInserterTests.dvorak)
        _ = await rig.inserter.insert(FakeInsertion.dictated)
        #expect(rig.log.entries.contains("postPaste(\(kVK_ANSI_Period))"))
        #expect(!rig.log.entries.contains("postPaste(\(kVK_ANSI_V))"))
    }

    @Test("le délai de restauration est celui qu'on a donné")
    func restoreDelayIsTheOneGiven() async {
        let rig = InsertionRig(restoreDelay: 0.75)
        _ = await rig.inserter.insert(FakeInsertion.dictated)
        #expect(rig.waiter.durations == [0.75])
    }

    // MARK: - Restauration

    @Test("le presse-papiers modifié pendant l'attente n'est pas restauré, et le collage reste réussi")
    func clipboardChangedMeanwhileIsLeftAlone() async {
        let rig = InsertionRig()
        rig.waiter.onWait = { [board = rig.board] _ in board.changeFromElsewhere("copié ailleurs entre-temps") }
        let outcome = await rig.inserter.insert(FakeInsertion.dictated)
        #expect(outcome == .pasted)
        #expect(rig.board.text == "copié ailleurs entre-temps")
        #expect(!rig.log.entries.contains("write"))
    }

    @Test("un contenu d'origine non textuel (image et fichier) est restauré à l'identique")
    func nonTextualOriginalIsRestoredIdentically() async {
        let original = PasteboardContents(items: [
            ["public.png": Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF]), "public.tiff": Data([0x49, 0x49, 0x2A])],
            ["public.file-url": Data("file:///exemple/photo.png".utf8)],
        ])
        let rig = InsertionRig(original: original)
        let outcome = await rig.inserter.insert(FakeInsertion.dictated)
        #expect(outcome == .pasted)
        #expect(rig.board.contents == original)
        #expect(rig.board.contents.items.count == 2)
    }

    @Test("un presse-papiers d'origine vide redevient vide")
    func emptyOriginalBecomesEmptyAgain() async {
        let rig = InsertionRig(original: PasteboardContents(items: []))
        let outcome = await rig.inserter.insert(FakeInsertion.dictated)
        #expect(outcome == .pasted)
        #expect(rig.board.contents == PasteboardContents(items: []))
        #expect(rig.board.text == nil)
    }

    // MARK: - Modificateurs

    @Test("modificateurs tenus jusqu'au bout : aucune touche, le texte reste, une attente de 0,05 s par sondage",
        arguments: [(1.0, 20), (0.2, 4), (0.05, 1), (0.0, 0)])
    func heldModifiersAreWaitedForThenGivenUp(patience: Double, polls: Int) async throws {
        let rig = InsertionRig(held: [true], modifierPatience: patience)
        let outcome = await rig.inserter.insert(FakeInsertion.dictated)
        let reason = try #require(reason(outcome))
        #expect(reason.contains("relâchez"))
        #expect(reason.contains("⌘V"))
        #expect(!reason.contains(FakeInsertion.dictated))
        #expect(rig.waiter.durations == Array(repeating: 0.05, count: polls))
        #expect(!rig.log.entries.contains { $0.hasPrefix("postPaste") })
        #expect(rig.board.text == FakeInsertion.dictated)
        #expect(!rig.log.entries.contains("write"))
    }

    @Test("une patience négative, infinie ou NaN est ramenée à zéro attente : aucun sondage d'attente, aucune touche, le texte reste",
        arguments: [-1.0, -Double.infinity, Double.infinity, Double.nan])
    func unsafePatienceMeansNoWaiting(patience: Double) async {
        let rig = InsertionRig(held: [true], modifierPatience: patience)
        let outcome = await rig.inserter.insert(FakeInsertion.dictated)
        #expect(reason(outcome)?.contains("relâchez") == true)
        #expect(rig.waiter.durations.isEmpty)
        #expect(!rig.log.entries.contains { $0.hasPrefix("postPaste") })
        #expect(rig.board.text == FakeInsertion.dictated)
    }

    @Test("des modificateurs relâchés avant la fin de la patience : le collage a lieu après les attentes")
    func modifiersReleasedInTimeThenPaste() async {
        let rig = InsertionRig(held: [true, true, true, false])
        let outcome = await rig.inserter.insert(FakeInsertion.dictated)
        #expect(outcome == .pasted)
        #expect(rig.log.entries == [
            "read",
            "writeText(transient: true)",
            "modifiersHeld", "wait(0.05)",
            "modifiersHeld", "wait(0.05)",
            "modifiersHeld", "wait(0.05)",
            "modifiersHeld",
            "postPaste(\(kVK_ANSI_V))",
            "wait(0.4)",
            "write",
        ])
        #expect(rig.board.contents == FakeInsertion.original)
    }

    @Test("la patience par défaut est d'une seconde : vingt sondages de 0,05 s")
    func defaultPatienceIsOneSecond() async {
        let rig = InsertionRig(held: [true])
        _ = await rig.inserter.insert(FakeInsertion.dictated)
        #expect(rig.waiter.durations == Array(repeating: 0.05, count: 20))
    }

    // MARK: - Annulation de la tâche

    @Test("une tâche déjà annulée à l'entrée n'écrit rien, ne colle rien et rend .nothing")
    func taskCancelledOnEntryDoesNothing() async {
        let rig = InsertionRig()
        // La tâche démarre sur le fil principal, que ce test occupe jusqu'au prochain `await` : l'annulation
        // est donc posée avant que `insert` ne s'exécute.
        let task = Task { @MainActor in await rig.inserter.insert(FakeInsertion.dictated) }
        task.cancel()
        let outcome = await task.value
        #expect(outcome == .nothing)
        #expect(rig.log.entries.isEmpty)
        #expect(rig.board.contents == FakeInsertion.original)
        #expect(rig.board.changeCount == 0)
    }

    @Test("annulée pendant les sondages des modificateurs : le contenu d'origine est rendu, aucun ⌘V, .nothing")
    func cancellationDuringModifierPollsRestoresAndDoesNotPaste() async {
        let rig = InsertionRig(held: [true])
        let box = InsertTaskBox()
        rig.waiter.onWait = { _ in box.cancel() }
        let outcome = await box.run(rig.inserter, FakeInsertion.dictated)
        #expect(outcome == .nothing)
        #expect(rig.log.entries == [
            "read", "writeText(transient: true)", "modifiersHeld", "wait(0.05)", "write",
        ])
        #expect(rig.board.contents == FakeInsertion.original)
    }

    @Test("annulée au moment où les modificateurs sont relâchés : le contenu d'origine est rendu, aucun ⌘V, .nothing")
    func cancellationWhenModifiersAreReleasedDoesNotPaste() async {
        let rig = InsertionRig(held: [false])
        let box = InsertTaskBox()
        rig.keys.onPoll = { box.cancel() }
        let outcome = await box.run(rig.inserter, FakeInsertion.dictated)
        #expect(outcome == .nothing)
        #expect(rig.log.entries == ["read", "writeText(transient: true)", "modifiersHeld", "write"])
        #expect(rig.board.contents == FakeInsertion.original)
    }

    @Test("annulée après le ⌘V : la restauration n'est ni avancée ni sautée, elle a lieu quand l'attente prévue se termine")
    func cancellationAfterPasteStillWaitsBeforeRestoring() async throws {
        let log = CallLog()
        let sleeper = SleepingWait(log: log)
        let rig = InsertionRig(log: log, wait: { await sleeper.wait($0) })
        let box = InsertTaskBox()
        let task = Task { @MainActor in await box.run(rig.inserter, FakeInsertion.dictated) }

        // Laisse l'insertion avancer jusqu'à l'attente de restauration (aucune durée réelle : des cessions seulement).
        for _ in 0..<1000 where !sleeper.isSleeping { await Task.yield() }
        try #require(sleeper.isSleeping)
        #expect(log.entries.last == "wait(0.4)")

        box.cancel()
        for _ in 0..<100 { await Task.yield() }
        // L'attente de l'application cible n'est pas finie : le presse-papiers porte encore la dictée.
        #expect(!log.entries.contains("write"))
        #expect(rig.board.text == FakeInsertion.dictated)

        sleeper.release()
        let outcome = await task.value
        #expect(outcome == .pasted)
        #expect(log.entries == [
            "read", "writeText(transient: true)", "modifiersHeld", "postPaste(\(kVK_ANSI_V))", "wait(0.4)", "write",
        ])
        #expect(rig.board.contents == FakeInsertion.original)
    }

    // MARK: - Échec de ⌘V

    @Test("si ⌘V n'a pas pu être posté, le texte reste dans le presse-papiers et la raison dit de faire ⌘V")
    func failedPasteLeavesTheTextCopied() async throws {
        let rig = InsertionRig(postSucceeds: false)
        let outcome = await rig.inserter.insert(FakeInsertion.dictated)
        let reason = try #require(reason(outcome))
        #expect(reason.contains("copié"))
        #expect(reason.contains("⌘V"))
        #expect(!reason.contains(FakeInsertion.dictated))
        #expect(rig.board.text == FakeInsertion.dictated)
        #expect(rig.log.entries == [
            "read", "writeText(transient: true)", "modifiersHeld", "postPaste(\(kVK_ANSI_V))",
        ])
    }

    // MARK: - Code de la touche « v »

    /// Dvorak : « v » est sur le code ANSI du point, et le code 9 produit « k ».
    static let dvorak = HotKeyTests.StubLayout(
        characters: HotKeyTests.ansi.characters.merging([
            UInt32(kVK_ANSI_V): "k", UInt32(kVK_ANSI_Period): "v", UInt32(kVK_ANSI_Slash): "z",
        ]) { _, new in new })

    @Test("pasteKeyCode : ANSI donne le code de V ; une disposition qui met « v » ailleurs donne ce code ; sans « v », le code de V")
    func pasteKeyCodeFollowsTheLayout() {
        #expect(TextInserter.pasteKeyCode(layout: HotKeyTests.ansi) == UInt16(kVK_ANSI_V))
        #expect(TextInserter.pasteKeyCode(layout: HotKeyTests.azerty) == UInt16(kVK_ANSI_V))
        #expect(TextInserter.pasteKeyCode(layout: Self.dvorak) == UInt16(kVK_ANSI_Period))
        #expect(TextInserter.pasteKeyCode(layout: HotKeyTests.StubLayout(characters: [:])) == UInt16(kVK_ANSI_V))
        // « v » sur deux codes dont celui de V : celui de V l'emporte, même si l'autre est plus petit.
        let twice = HotKeyTests.StubLayout(characters: [0x02: "v", UInt32(kVK_ANSI_V): "v"])
        #expect(TextInserter.pasteKeyCode(layout: twice) == UInt16(kVK_ANSI_V))
        // Une disposition non latine (aucun « v » nulle part) : repli sur le code de V.
        let cyrillic = HotKeyTests.StubLayout(characters: [0x09: "м", 0x00: "ф", 0x0B: "и"])
        #expect(TextInserter.pasteKeyCode(layout: cyrillic) == UInt16(kVK_ANSI_V))
    }

    @Test("le code de V vaut 9 : la valeur du brief est celle de la constante du système")
    func vKeyCodeIsNine() {
        #expect(kVK_ANSI_V == 9)
    }
}
