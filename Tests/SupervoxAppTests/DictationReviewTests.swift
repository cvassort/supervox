import Carbon.HIToolbox
import Foundation
import Testing
import SupervoxCore

@testable import SupervoxApp

/// La relecture dans le contrôleur de dictée : le texte final n'est pas inséré, il attend dans `draft` ; seul « Coller »
/// (`pasteReview()`) l'insère. Sessions, presse-papiers, touches et attentes doubles : aucun micro, aucun ⌘V, aucun
/// presse-papiers du système. Chaque test porte le numéro de la règle de la tâche qu'il prouve.
@MainActor @Suite(.timeLimit(.minutes(1))) struct DictationReviewTests {
    static let text = "Bonjour à tous, voici la dictée."
    static let notice =
        "Le presse-papiers a refusé le texte : il n'a été ni collé ni copié. Il est toujours ci-dessus : réessayez « Coller » ou « Copier »."

    /// Le harnais, avec la relecture activée pour la dictée brute (sauf `reviewing: false`).
    private func harness(
        reviewing: Bool = true, trusted: Bool = true, wait: (@MainActor (Double) async -> Void)? = nil,
        log: CallLog = CallLog(), heldModifiers: [Bool] = [false]
    ) -> DictationHarness {
        let h = DictationHarness(trusted: trusted, wait: wait, log: log, heldModifiers: heldModifiers)
        if reviewing { h.knobs.reviewing = [ModeChip.rawID] }
        return h
    }

    /// Une dictée menée jusqu'à la relecture de `text`. Le journal partagé est vidé à l'arrivée en relecture (`clearLog`) : il
    /// ne montre plus que ce qui suit.
    @discardableResult
    private func review(
        _ h: DictationHarness, _ text: String = DictationReviewTests.text, index: Int = 0, clearLog: Bool = true
    ) async -> FakeSession {
        let session = await h.startRecording(index: index)
        session.emit(.finished(text))
        #expect(await until { h.controller.view.stage == .review })
        #expect(!h.controller.view.keyboardReleased, "le panneau a la frappe au début de la relecture")
        if clearLog { h.rig.log.entries.removeAll() }
        return session
    }

    /// Une relecture lancée puis « Coller » : l'attente de la frappe est retenue, le collage n'a pas encore commencé.
    private func pastingAtHandover(_ h: DictationHarness, edited: String? = nil) async {
        h.handover.holds = true
        await review(h)
        if let edited { h.controller.reviewEdited(edited) }
        h.controller.pasteReview()
        #expect(await until { h.handover.sleeper.isSleeping })
    }

    // MARK: - Règle 1 : le réglage est lu une fois, à l'appui

    @Test("règle 1 : le réglage est lu une fois, à l'appui, pour le mode choisi ; le changer pendant l'enregistrement ne change pas cette dictée",
        arguments: [HotKeyBehavior.toggle, .hold])
    func theSettingIsReadOnceAtThePress(behavior: HotKeyBehavior) async {
        // Activé à l'appui, désactivé pendant l'enregistrement : la dictée est relue.
        let on = harness()
        on.knobs.behavior = behavior
        let session = await on.startRecording()
        #expect(on.knobs.reviewReads == [ModeChip.rawID])
        on.knobs.reviewing = []
        session.emit(.finished(Self.text))
        #expect(await until { on.controller.view.stage == .review })
        await settle()
        #expect(on.knobs.reviewReads == [ModeChip.rawID], "lu une seule fois")
        #expect(on.rig.log.entries.filter { $0.hasPrefix("writeText") }.isEmpty)

        // Désactivé à l'appui, activé pendant l'enregistrement : la dictée est collée tout de suite, comme à l'étape 3.
        let off = harness(reviewing: false)
        off.knobs.behavior = behavior
        let second = await off.startRecording()
        off.knobs.reviewing = [ModeChip.rawID]
        second.emit(.finished(Self.text))
        #expect(await until { off.controller.view.stage == .idle && !off.panel.isOpen })
        #expect(off.knobs.reviewReads == [ModeChip.rawID])
        #expect(off.pasted == [Self.text])
    }

    // MARK: - Règle 3 : relecture activée

    @Test("règle 3 : le texte final passe en relecture (draft, lastTranscript, panneau, clavier) et n'est jamais inséré")
    func aReviewedTextWaitsInTheReviewAndIsNeverInserted() async {
        let h = harness()
        let session = await review(h, clearLog: false)
        #expect(h.controller.view.draft == Self.text)
        #expect(h.controller.view.lastTranscript == Self.text)
        #expect(h.controller.lastTranscript == Self.text)
        #expect(h.panel.isOpen)
        #expect(h.panel.keyboards == [.focused])
        // Même après la fin du flux de la session et l'écoulement des tâches : aucun appel à `insert`.
        session.end()
        await settle()
        #expect(h.rig.log.entries == ["keyboard(focused)"], "ni lecture ni écriture du presse-papiers, ni touche, ni attente")
        #expect(h.pasted.isEmpty)
        #expect(!h.controller.isInserting)
        #expect(h.controller.view.stage == .review)
        #expect(h.panel.keyboards == [.focused], "le clavier n'est demandé qu'une fois")
    }

    @Test("règle 3 : un texte final blanc est un échec « aucune parole », comme avant, sans relecture",
        arguments: ["", "   ", "\n\t "])
    func aBlankFinalTextIsStillNoSpeech(text: String) async {
        let h = harness()
        let session = await h.startRecording()
        session.emit(.finished(text))
        #expect(await until { h.controller.view.stage == .failed(.noSpeech) })
        #expect(h.controller.view.draft == "")
        #expect(h.controller.view.notice == DictationFailure.noSpeech.message)
        #expect(h.panel.keyboards.isEmpty)
        #expect(h.panel.isOpen)
    }

    @Test("règle 3 : la relecture n'utilise aucun modèle : la dictée n'est plus en cours (isBusy faux, aucune insertion)")
    func theReviewIsNotBusy() async {
        let h = harness()
        await review(h)
        #expect(!h.controller.isBusy)
        #expect(!h.controller.isInserting)
    }

    // MARK: - Règle 4 : les corrections

    @Test("règle 4 : reviewEdited change le brouillon en relecture, et lastTranscript ne bouge pas")
    func editingChangesTheDraftOnly() async {
        let h = harness()
        await review(h)
        h.controller.reviewEdited("Bonjour, voici le texte corrigé.")
        #expect(h.controller.view.draft == "Bonjour, voici le texte corrigé.")
        #expect(h.controller.view.stage == .review)
        #expect(h.controller.lastTranscript == Self.text)
        #expect(h.controller.view.lastTranscript == Self.text)
        #expect(h.views.last?.draft == "Bonjour, voici le texte corrigé.", "la vue du panneau est prévenue")
    }

    @Test("règle 4 : reviewEdited est ignoré hors relecture (repos, enregistrement, collage)")
    func editingOutsideTheReviewIsIgnored() async {
        let h = harness()
        h.controller.reviewEdited("x")
        #expect(h.controller.view == DictationViewState())

        let session = await h.startRecording()
        h.controller.reviewEdited("x")
        #expect(h.controller.view.draft == "")
        #expect(h.controller.view.stage == .recording)

        session.emit(.finished(Self.text))
        #expect(await until { h.controller.view.stage == .review })
        h.handover.holds = true
        h.controller.pasteReview()
        #expect(await until { h.handover.sleeper.isSleeping })
        h.controller.reviewEdited("pendant le collage")
        #expect(h.controller.view.draft == Self.text)
        #expect(h.controller.view.stage == .pasting)
        h.handover.sleeper.release()
        #expect(await until { h.controller.view.stage == .idle })
    }

    // MARK: - Règles 5 et 6 : Coller

    @Test("règle 5 : Coller, dans cet ordre : étape pasting et lastTranscript, clavier rendu, attente, insertion du brouillon qui reste copié")
    func pasteIsOrdered() async {
        let h = harness()
        await review(h)
        h.controller.reviewEdited("Texte relu et corrigé.")

        struct Seen: Equatable {
            var keyboard: PanelKeyboard
            var stage: DictationStage
            var lastTranscript: String?
            var isInserting: Bool
        }
        var seen: [Seen] = []
        h.panel.onSetKeyboard = { [controller = h.controller] keyboard in
            seen.append(
                Seen(
                    keyboard: keyboard, stage: controller.view.stage, lastTranscript: controller.lastTranscript,
                    isInserting: controller.isInserting))
        }
        h.handover.holds = true
        h.controller.pasteReview()
        // Un second « Coller » pendant le collage est ignoré.
        h.controller.pasteReview()
        #expect(h.controller.view.stage == .pasting)
        #expect(h.controller.isInserting, "la file d'insertion tient dès l'appui : quitter attendrait")
        #expect(
            seen == [Seen(keyboard: .none, stage: .pasting, lastTranscript: "Texte relu et corrigé.", isInserting: true)])
        #expect(await until { h.handover.sleeper.isSleeping })
        #expect(h.controller.isInserting, "et pendant l'attente de la frappe")
        #expect(h.rig.log.entries == ["keyboard(none)", "wait(0.15)"], "rien n'est inséré avant la fin de l'attente")
        #expect(h.handover.durations == [DictationController.focusHandoverDelay])

        h.handover.sleeper.release()
        #expect(await until { h.controller.view.stage == .idle })
        #expect(h.rig.log.entries == [
            "keyboard(none)", "wait(0.15)",
            "read", "writeText(transient: true)", "modifiersHeld", "postPaste(\(kVK_ANSI_V))", "wait(0.4)",
            "writeText(transient: false)",
        ])
        #expect(h.pasted == ["Texte relu et corrigé."], "un seul ⌘V : le second Coller n'a rien fait")
        #expect(!h.controller.isInserting)
    }

    @Test("règle 5 : le délai de passation de la frappe vaut 0,15 s")
    func theHandoverDelay() {
        #expect(DictationController.focusHandoverDelay == 0.15)
    }

    @Test("règle 6 : .pasted ferme le panneau, la dictée est finie, le texte collé reste copié et lastTranscript le garde")
    func aPastedTextClosesThePanelAndStaysCopied() async {
        let h = harness()
        await review(h)
        h.controller.reviewEdited("Le texte collé.")
        h.controller.pasteReview()
        #expect(await until { !h.panel.isOpen })
        #expect(h.controller.view.stage == .idle)
        #expect(h.controller.view.draft == "")
        #expect(h.controller.lastTranscript == "Le texte collé.")
        #expect(h.controller.view.lastTranscript == "Le texte collé.")
        #expect(h.rig.board.text == "Le texte collé.")
        #expect(h.rig.board.contents != FakeInsertion.original)
        #expect(!h.controller.isBusy)
    }

    // MARK: - Règles 7 et 8 : les replis

    @Test("règle 7 : .copied remet la relecture, avec la raison, le brouillon intact et le clavier disponible ; on peut recoller",
        arguments: [false, true])
    func aCopiedFallbackReturnsToTheReview(heldModifiers: Bool) async throws {
        let log = CallLog()
        let h = heldModifiers
            ? harness(log: log, heldModifiers: [true]) : harness(trusted: false, log: log)
        // La phrase attendue est celle de l'insertion, inchangée.
        let reference = heldModifiers
            ? InsertionRig(held: [true]) : InsertionRig(trusted: false)
        let expected = await reference.inserter.insert("x")
        guard case .copied(let reason) = expected else {
            Issue.record("le repli de référence n'est pas .copied")
            return
        }

        await review(h)
        h.controller.reviewEdited("Première version.")
        h.controller.pasteReview()
        #expect(await until { h.controller.view.notice == reason })
        #expect(h.controller.view.stage == .review)
        #expect(h.controller.view.draft == "Première version.")
        #expect(h.panel.keyboards == [.focused, .none, .available])
        #expect(h.controller.view.keyboardReleased, "la frappe est rendue à l'application : l'aide ne doit pas annoncer ⌘↩")
        #expect(h.panel.isOpen)
        #expect(h.controller.lastTranscript == "Première version.")
        #expect(h.pasted.isEmpty)

        // Le texte reste modifiable, et « Coller » peut être refait avec la version corrigée.
        h.controller.reviewEdited("Seconde version.")
        #expect(h.controller.view.draft == "Seconde version.")
        #expect(!h.controller.view.keyboardReleased, "taper suppose que le panneau a repris la frappe")
        h.controller.pasteReview()
        #expect(await until { h.panel.keyboards.count == 5 })
        #expect(h.controller.view.stage == .review)
        #expect(h.rig.board.text == "Seconde version.")
        #expect(h.panel.keyboards == [.focused, .none, .available, .none, .available])
    }

    @Test("règle 8 : .clipboardRefused remet la relecture, avec la phrase fixe, le brouillon intact et le clavier disponible")
    func aRefusedClipboardReturnsToTheReview() async {
        let h = harness()
        await review(h)
        h.rig.board.refusesTextWrites = true
        h.controller.pasteReview()
        #expect(await until { h.controller.view.notice != nil })
        #expect(DictationController.reviewClipboardNotice == Self.notice)
        #expect(h.controller.view.notice == Self.notice)
        #expect(h.controller.view.stage == .review)
        #expect(h.controller.view.draft == Self.text)
        #expect(h.panel.keyboards == [.focused, .none, .available])
        #expect(h.controller.view.keyboardReleased)
        #expect(h.panel.isOpen)
        #expect(h.rig.board.contents == FakeInsertion.original)
        #expect(h.pasted.isEmpty)
    }

    // MARK: - Règle 9 : brouillon blanc

    @Test("règle 9 : avec un brouillon blanc, Coller ne fait rien (ni insertion, ni clavier)", arguments: ["", "  ", "\n\t "])
    func pasteWithABlankDraftDoesNothing(draft: String) async {
        let h = harness()
        await review(h)
        h.controller.reviewEdited(draft)
        h.controller.pasteReview()
        await settle()
        #expect(h.controller.view.stage == .review)
        #expect(h.panel.keyboards == [.focused])
        #expect(h.rig.log.entries.isEmpty)
        #expect(h.handover.durations.isEmpty)
        #expect(!h.controller.isInserting)
    }

    @Test("règle 9 : Coller hors relecture ne fait rien")
    func pasteOutsideTheReviewDoesNothing() async {
        let h = harness()
        h.controller.pasteReview()
        let session = await h.startRecording()
        h.controller.pasteReview()
        await settle()
        #expect(h.controller.view.stage == .recording)
        #expect(h.rig.log.entries.isEmpty)
        #expect(session.count(of: "cancel") == 0)
    }

    // MARK: - Règle 10 : Échap et fermeture en relecture

    @Test("règle 10 : Échap ou la fermeture du panneau en relecture : rien n'est inséré ni copié, le brouillon devient le dernier texte",
        arguments: ["escape", "closed"])
    func closingTheReviewKeepsTheDraftAndInsertsNothing(path: String) async {
        let h = harness()
        await review(h)
        h.controller.reviewEdited("Le brouillon relu.")
        if path == "escape" { h.controller.escapePressed() } else { h.panel.close() }

        #expect(!h.panel.isOpen)
        #expect(h.controller.view == DictationViewState(lastTranscript: "Le brouillon relu."))
        #expect(h.controller.lastTranscript == "Le brouillon relu.")
        await settle()
        #expect(h.rig.log.entries.isEmpty, "ni insertion ni copie")
        #expect(h.rig.board.contents == FakeInsertion.original)

        // La relecture est finie : plus rien ne la concerne.
        h.controller.reviewEdited("tardif")
        h.controller.pasteReview()
        await settle()
        #expect(h.controller.view.draft == "")
        #expect(h.rig.log.entries.isEmpty)
        // Et l'on peut dicter de nouveau.
        h.controller.hotKeyPressed()
        #expect(await until { h.engines.sessions.count == 2 })
    }

    @Test("règle 10 : un brouillon blanc ne remplace pas le texte d'origine", arguments: ["escape", "closed"])
    func aBlankDraftLeavesTheOriginalText(path: String) async {
        let h = harness()
        await review(h)
        h.controller.reviewEdited("  \n ")
        if path == "escape" { h.controller.escapePressed() } else { h.panel.close() }
        #expect(h.controller.lastTranscript == Self.text)
        #expect(h.controller.view.lastTranscript == Self.text)
        #expect(h.controller.view.stage == .idle)
    }

    // MARK: - Règle 11 : Échap pendant le collage

    @Test("règle 11 : Échap ou la fermeture du panneau pendant le collage, avant le ⌘V : la tâche est annulée, rien n'est collé, le presse-papiers est rendu",
        arguments: ["escape", "closed"])
    func escapeWhilePastingBeforeTheKeystrokeCancelsTheInsertion(path: String) async {
        let log = CallLog()
        let sleeper = SleepingWait(log: log)
        // Les modificateurs sont tenus : l'insertion attend leur relâchement, dans une attente qui rend la main à l'annulation.
        let h = harness(wait: { await sleeper.wait($0) }, log: log, heldModifiers: [true])
        await review(h)
        h.controller.reviewEdited("Texte à ne pas coller.")
        h.controller.pasteReview()
        #expect(await until { sleeper.isSleeping })
        #expect(h.rig.board.text == "Texte à ne pas coller.", "l'insertion est en route : le texte est dans le presse-papiers")
        #expect(h.controller.view.stage == .pasting)

        if path == "escape" { h.controller.escapePressed() } else { h.panel.close() }
        #expect(!h.panel.isOpen)
        #expect(await until { !h.controller.isInserting })
        #expect(h.rig.board.contents == FakeInsertion.original, "le presse-papiers d'origine est rendu")
        #expect(h.pasted.isEmpty)
        #expect(!log.entries.contains { $0.hasPrefix("postPaste") })
        #expect(h.controller.lastTranscript == "Texte à ne pas coller.")
        #expect(h.controller.view == DictationViewState(lastTranscript: "Texte à ne pas coller."))
    }

    // MARK: - Règle 12 : le raccourci pendant la relecture

    @Test("règle 12 : le raccourci en relecture ou pendant le collage est ignoré, appui comme relâchement, en bascule comme en maintien",
        arguments: [HotKeyBehavior.toggle, .hold], [DictationStage.review, .pasting])
    func theHotKeyIsIgnoredDuringTheReview(behavior: HotKeyBehavior, stage: DictationStage) async {
        let h = harness()
        h.knobs.behavior = behavior
        h.handover.holds = stage == .pasting
        await review(h)
        if stage == .pasting {
            h.controller.pasteReview()
            #expect(await until { h.handover.sleeper.isSleeping })
        }
        let before = h.controller.view

        h.controller.hotKeyPressed()
        h.controller.hotKeyReleased()
        h.controller.hotKeyPressed()
        await settle()
        #expect(h.engines.sessions.count == 1, "aucune session fabriquée")
        #expect(h.controller.view == before)
        #expect(h.controller.view.stage == stage)
        #expect(h.panel.isOpen)
        #expect(h.panel.closeCount == 0)
        #expect(!h.controller.isBusy)
        h.handover.sleeper.release()
    }

    @Test("règle 12 : après un changement de pastille vers un autre mode, le raccourci laisse le panneau ouvert et la relecture intacte",
        arguments: [DictationStage.review, .pasting])
    func aChipChangeDuringTheReviewDoesNotLetTheHotKeyClosePanel(stage: DictationStage) async {
        let h = harness()
        h.handover.holds = stage == .pasting
        await review(h)
        h.controller.reviewEdited("Brouillon à garder.")
        if stage == .pasting {
            h.controller.pasteReview()
            #expect(await until { h.handover.sleeper.isSleeping })
        }
        let before = h.controller.view

        h.knobs.modeID = ModeChip.promptID
        h.controller.hotKeyPressed()
        await settle()
        #expect(h.panel.isOpen)
        #expect(h.panel.closeCount == 0)
        #expect(h.controller.view == before)
        #expect(h.controller.view.draft == "Brouillon à garder.")
        #expect(h.engines.sessions.count == 1)
        h.handover.sleeper.release()
    }

    // MARK: - Règle 16 : un résultat d'insertion tardif

    @Test("règle 16 : un résultat d'insertion qui arrive après Échap ne change ni l'écran ni le panneau, même pendant une nouvelle dictée",
        arguments: [DictationStage.recording, .review])
    func aLateInsertionResultIsIgnored(newStage: DictationStage) async {
        let log = CallLog()
        let sleeper = SleepingWait(log: log)
        let h = harness(wait: { await sleeper.wait($0) }, log: log)
        await review(h)
        h.controller.pasteReview()
        // Le ⌘V est posté ; l'attente de la restauration est retenue par le test.
        #expect(await until { sleeper.isSleeping })
        #expect(h.pasted == [Self.text])

        h.controller.escapePressed()
        #expect(!h.panel.isOpen)
        #expect(h.controller.isInserting, "l'insertion tient encore le presse-papiers : quitter l'attendrait")

        // Une nouvelle dictée commence, puis éventuellement arrive jusqu'à sa propre relecture.
        let second = await h.startRecording(index: 1)
        if newStage == .review {
            second.emit(.finished("Deuxième texte."))
            #expect(await until { h.controller.view.stage == .review })
        }
        let before = h.controller.view
        let keyboards = h.panel.keyboards
        let closings = h.panel.closeCount

        sleeper.release()
        #expect(await until { !h.controller.isInserting })
        await settle()
        #expect(h.controller.view == before)
        #expect(h.controller.view.stage == newStage)
        #expect(h.panel.isOpen)
        #expect(h.panel.closeCount == closings)
        #expect(h.panel.keyboards == keyboards, "aucun clavier « disponible » ni rien d'autre")
        #expect(h.controller.lastTranscript == (newStage == .review ? "Deuxième texte." : Self.text))
    }

    // MARK: - Règle 17 : Échap pendant l'attente de la frappe

    @Test("règle 17 : Échap ou la fermeture du panneau pendant l'attente de la passation de la frappe : insert n'est jamais appelé",
        arguments: ["escape", "closed"])
    func escapeDuringTheHandoverWaitNeverInserts(path: String) async {
        let h = harness()
        await pastingAtHandover(h)
        #expect(h.rig.log.entries == ["keyboard(none)", "wait(0.15)"])

        if path == "escape" { h.controller.escapePressed() } else { h.panel.close() }
        #expect(!h.panel.isOpen)
        #expect(await until { !h.controller.isInserting })
        await settle()
        #expect(h.rig.log.entries.filter { $0 != "keyboard(none)" && $0 != "wait(0.15)" }.isEmpty)
        #expect(h.pasted.isEmpty)
        #expect(h.rig.board.contents == FakeInsertion.original)
        #expect(h.controller.lastTranscript == Self.text)
        #expect(h.controller.view == DictationViewState(lastTranscript: Self.text))
    }

    /// Une attente de passation qui ignore l'annulation se réveille quand même après Échap : la tâche, annulée et plus
    /// courante, ne doit alors toucher à rien. Le journal de l'insertion le dit par une assertion (aucune lecture ni écriture du
    /// presse-papiers, aucun sondage des modificateurs, aucun ⌘V), non par un blocage.
    @Test("règle 17 : une attente qui ignore l'annulation se réveille après Échap : aucune lecture ni écriture du presse-papiers, aucun ⌘V",
        arguments: ["escape", "closed"])
    func aHandoverWaitThatIgnoresCancellationStillNeverInserts(path: String) async {
        let h = harness()
        let gate = TestGate()
        defer { gate.open() }
        h.handover.gate = gate
        await review(h)
        h.controller.pasteReview()
        #expect(await until { h.rig.log.entries.contains("wait(0.15)") })
        #expect(h.controller.isInserting)

        if path == "escape" { h.controller.escapePressed() } else { h.panel.close() }
        #expect(!h.panel.isOpen)
        // L'attente est encore là (elle ignore l'annulation) : la tâche vit toujours.
        #expect(h.controller.isInserting)
        gate.open()
        #expect(await until { !h.controller.isInserting })
        await settle()
        #expect(h.rig.log.entries == ["keyboard(none)", "wait(0.15)"], "ni read, ni write, ni modifiersHeld, ni postPaste")
        #expect(h.pasted.isEmpty)
        #expect(h.rig.board.contents == FakeInsertion.original)
        #expect(h.rig.board.changeCount == 0)
        #expect(h.controller.lastTranscript == Self.text)
        #expect(h.controller.view == DictationViewState(lastTranscript: Self.text))
    }
}
