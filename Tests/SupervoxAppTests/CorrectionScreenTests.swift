import AppKit
import Foundation
import SwiftUI
import Testing
import SupervoxCore

@testable import SupervoxApp

// Tour de correction 1 de la tâche 9 : ce que l'écran de la correction à la voix relie et promet, testé comme des données (la vue
// SwiftUI ne s'interroge pas hors fenêtre : l'arbre d'accessibilité d'un `NSHostingView` sans fenêtre est vide).

/// Les clics de la vue de dictée arrivent au bon appel du modèle du panneau : `DictationActions.wired(to:)`, ce que `PanelView`
/// donne à `DictationView`. Chaque fermeture ne doit en tirer qu'un.
@MainActor @Suite struct DictationActionsWiringTests {
    /// Les appels du modèle du panneau, comptés par nom.
    @MainActor final class Calls {
        var names: [String] = []
        var copied: [String] = []
        var edits: [String] = []
    }

    private func wired(_ state: DictationViewState) -> (DictationActions, PanelModel, Calls) {
        let model = PanelModel(lastModeID: ModeChip.rawID)
        model.setDictation(state)
        let calls = Calls()
        model.onCorrect = { calls.names.append("correct") }
        model.onFinishCorrection = { calls.names.append("finish") }
        model.onPreviousVersion = { calls.names.append("previous") }
        model.onNextVersion = { calls.names.append("next") }
        model.onPaste = { calls.names.append("paste") }
        model.onCopy = { calls.copied.append($0); return true }
        model.onDraftChange = { calls.edits.append($0) }
        return (DictationActions.wired(to: model), model, calls)
    }

    private let reviewing = DictationViewState(stage: .review, draft: "Un texte.", canGoBack: true, canGoForward: true)

    @Test("« Version précédente » tire la version précédente du modèle, et elle seule ; « Version suivante » de même")
    func eachVersionButtonCallsItsOwnVersion() {
        let (actions, _, calls) = wired(reviewing)
        actions.previousVersion()
        #expect(calls.names == ["previous"])
        actions.nextVersion()
        #expect(calls.names == ["previous", "next"])
    }

    @Test("⌘Z du champ (fin de pile) va à la version précédente, ⇧⌘Z à la suivante, les autres commandes à aucune")
    func theHistoryOfTheFieldIsTheVersions() {
        let (actions, _, calls) = wired(reviewing)
        actions.history(.undo)
        #expect(calls.names == ["previous"])
        actions.history(.redo)
        #expect(calls.names == ["previous", "next"])
        for command in [EditingCommand.cut, .copy, .paste, .selectAll] { actions.history(command) }
        #expect(calls.names == ["previous", "next"])
    }

    @Test("« Corriger à la voix » commence la correction en relecture, « Terminer » la termine pendant l'écoute, jamais les deux")
    func correctStartsOrFinishes() {
        let (inReview, _, reviewCalls) = wired(reviewing)
        inReview.correct()
        #expect(reviewCalls.names == ["correct"])
        let (listening, _, listeningCalls) = wired(
            DictationViewState(stage: .correcting(.recording), draft: "Un texte."))
        listening.correct()
        #expect(listeningCalls.names == ["finish"])
    }

    @Test("« Coller », « Copier » et la frappe vont au modèle, tels quels")
    func pasteCopyAndTypingReachTheModel() {
        let (actions, model, calls) = wired(reviewing)
        actions.paste()
        #expect(calls.names == ["paste"])
        actions.copy()
        #expect(calls.copied == ["Un texte."])
        actions.edit("Un texte, corrigé.")
        #expect(calls.edits == ["Un texte, corrigé."])
        #expect(model.dictation.draft == "Un texte, corrigé.")
    }

    @Test("une saisie en attente dans le champ empêche de changer de version (le relais passe par le modèle)")
    func composingIsRelayedToThePanelModel() {
        let (actions, model, calls) = wired(reviewing)
        actions.composing(true)
        #expect(model.fieldIsComposing)
        actions.previousVersion()
        #expect(calls.names.isEmpty)
        actions.composing(false)
        #expect(!model.fieldIsComposing)
        actions.previousVersion()
        #expect(calls.names == ["previous"])
    }
}

/// La rangée de boutons de la relecture, comme des données : pour chacun, son glyphe, son libellé, son info-bulle, son libellé
/// d'accessibilité, son état actif et ce qu'il déclenche.
@MainActor @Suite struct ReviewButtonsTests {
    private func review(
        _ stage: DictationStage = .review, draft: String = "Un texte.", back: Bool = false, forward: Bool = false,
        copy: CopyState = .idle
    ) throws -> DictationDisplay.Review {
        try #require(
            DictationDisplay(
                state: DictationViewState(stage: stage, draft: draft, canGoBack: back, canGoForward: forward), copy: copy
            ).review)
    }

    private func spec(
        _ action: ReviewButton.Action, symbol: String?, title: String?, help: String? = nil, label: String, enabled: Bool
    ) -> ReviewButton {
        ReviewButton(action: action, symbol: symbol, title: title, help: help, accessibilityLabel: label, isEnabled: enabled)
    }

    @Test("une relecture sans version : « Corriger à la voix », « Copier », « Coller », actifs, dans cet ordre")
    func aPlainReview() throws {
        #expect(
            ReviewActions.buttons(for: try review()) == [
                spec(.correct, symbol: "mic", title: "Corriger à la voix", label: "Corriger à la voix", enabled: true),
                spec(.copy, symbol: "doc.on.doc", title: "Copier", label: "Copier", enabled: true),
                spec(.paste, symbol: nil, title: "Coller", label: "Coller", enabled: true),
            ])
    }

    @Test("« Version précédente » : flèche de retour, info-bulle et libellé VoiceOver « Version précédente », action précédente")
    func thePreviousVersionButton() throws {
        let buttons = ReviewActions.buttons(for: try review(back: true))
        #expect(
            buttons.first
                == spec(
                    .previousVersion, symbol: "arrow.uturn.backward", title: nil, help: "Version précédente",
                    label: "Version précédente", enabled: true))
        #expect(buttons.count == 4)
        #expect(!buttons.contains { $0.action == .nextVersion })
    }

    @Test("« Version suivante » : flèche de reprise, info-bulle et libellé VoiceOver « Version suivante », action suivante")
    func theNextVersionButton() throws {
        let buttons = ReviewActions.buttons(for: try review(forward: true))
        #expect(
            buttons.first
                == spec(
                    .nextVersion, symbol: "arrow.uturn.forward", title: nil, help: "Version suivante",
                    label: "Version suivante", enabled: true))
        #expect(buttons.count == 4)
        #expect(!buttons.contains { $0.action == .previousVersion })
    }

    @Test("les deux versions : précédente puis suivante, à gauche de « Corriger à la voix »")
    func bothVersionButtonsComeFirst() throws {
        #expect(
            ReviewActions.buttons(for: try review(back: true, forward: true)).map(\.action) == [
                .previousVersion, .nextVersion, .correct, .copy, .paste,
            ])
    }

    @Test("tout bouton à icône seule porte un libellé VoiceOver et une info-bulle ; tout bouton un libellé non vide")
    func everyButtonHasALabel() throws {
        for state in [
            try review(back: true, forward: true), try review(.correcting(.recording)), try review(.correcting(.rewriting)),
            try review(draft: " "), try review(copy: .copied), try review(copy: .failed),
        ] {
            for button in ReviewActions.buttons(for: state) {
                #expect(!button.accessibilityLabel.isEmpty, "\(button.action)")
                if button.title == nil {
                    #expect(button.help == button.accessibilityLabel, "\(button.action) : une icône seule dit son nom")
                }
            }
        }
    }

    @Test("« Terminer » à l'écoute (actif), à la préparation (inactif) ; « Corriger à la voix » inactif ensuite ; absent au collage")
    func theCorrectButtonAcrossTheStages() throws {
        func correct(_ stage: DictationStage, draft: String = "Un texte.") throws -> ReviewButton? {
            ReviewActions.buttons(for: try review(stage, draft: draft)).first { $0.action == .correct }
        }
        #expect(
            try correct(.correcting(.recording))
                == spec(.correct, symbol: "stop.fill", title: "Terminer", label: "Terminer", enabled: true))
        #expect(
            try correct(.correcting(.preparing))
                == spec(.correct, symbol: "stop.fill", title: "Terminer", label: "Terminer", enabled: false))
        for step in [CorrectionStep.transcribing, .rewriting] {
            #expect(
                try correct(.correcting(step))
                    == spec(.correct, symbol: "mic", title: "Corriger à la voix", label: "Corriger à la voix", enabled: false),
                "\(step)")
        }
        #expect(try correct(.review, draft: " ")?.isEnabled == false)
        #expect(try correct(.pasting) == nil)
    }

    @Test("règle : on ne copie ni ne colle un texte que l'écran ne montre pas : « Copier » et « Coller » inactifs à toute étape de la correction")
    func copyAndPasteAreInactiveWhileCorrecting() throws {
        for step in [CorrectionStep.preparing, .recording, .transcribing, .rewriting] {
            let buttons = ReviewActions.buttons(for: try review(.correcting(step)))
            #expect(buttons.first { $0.action == .copy }?.isEnabled == false, "Copier : \(step)")
            #expect(buttons.first { $0.action == .paste }?.isEnabled == false, "Coller : \(step)")
        }
        let reviewing = ReviewActions.buttons(for: try review())
        #expect(reviewing.first { $0.action == .copy }?.isEnabled == true)
        #expect(reviewing.first { $0.action == .paste }?.isEnabled == true)
    }

    @Test("« Copier » devient « Copié » avec une coche ; « Copie impossible » laisse « Copier »")
    func theCopyButtonFollowsTheCopyState() throws {
        let copied = ReviewActions.buttons(for: try review(copy: .copied)).first { $0.action == .copy }
        #expect(copied == spec(.copy, symbol: "checkmark", title: "Copié", label: "Copié", enabled: true))
        let failed = ReviewActions.buttons(for: try review(copy: .failed)).first { $0.action == .copy }
        #expect(failed == spec(.copy, symbol: "doc.on.doc", title: "Copier", label: "Copier", enabled: true))
    }

    @Test("chaque action de la rangée appelle sa fermeture, et elle seule")
    func eachActionCallsItsOwnClosure() throws {
        var calls: [String] = []
        let row = ReviewActions(
            review: try review(), paste: { calls.append("paste") }, copy: { calls.append("copy") },
            correct: { calls.append("correct") }, previousVersion: { calls.append("previous") },
            nextVersion: { calls.append("next") })
        for action in [
            ReviewButton.Action.previousVersion, .nextVersion, .correct, .copy, .paste,
        ] {
            row.run(action)
        }
        #expect(calls == ["previous", "next", "correct", "copy", "paste"])
    }
}

/// Ce que l'écran promet pendant la correction est vrai : Échap l'annule seule, le texte ne change pas. Et ce que l'écran ne
/// montre pas ne se colle ni ne se copie.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CorrectionPromisesTests {
    static let original = "Texte original, relu."
    static let typed = " Mot tapé."

    enum Step: CaseIterable { case preparing, recording, transcribing, rewriting }

    private func harness() -> DictationHarness {
        let h = DictationHarness()
        h.knobs.reviewing = [ModeChip.rawID]
        return h
    }

    /// Une relecture, dont le texte est tapé, puis la correction menée jusqu'à cette étape ; rend l'appel de réécriture s'il y en a un.
    private func drive(_ h: DictationHarness, to step: Step) async -> RewriteCall? {
        let first = await h.startRecording()
        first.emit(.finished(Self.original))
        #expect(await until { h.controller.view.stage == .review })
        h.controller.reviewEdited(Self.original + Self.typed)
        h.controller.startCorrection()
        let session = await h.session(1)
        #expect(await until { session.calls.contains("start") })
        if step == .preparing { return nil }
        session.emit(.preparing)
        session.emit(.recording)
        #expect(await until { h.controller.view.stage == .correcting(.recording) })
        if step == .recording { return nil }
        h.controller.finishCorrection()
        session.emit(.finalizing)
        #expect(await until { h.controller.view.stage == .correcting(.transcribing) })
        if step == .transcribing { return nil }
        session.emit(.finished("Mets cela au pluriel."))
        let call = await h.rewriter.call()
        #expect(await until { h.controller.view.stage == .correcting(.rewriting) })
        call.onText("Texte partiel reçu")
        return call
    }

    @Test("la phrase d'Échap : « Échap annule la correction ; le texte ne change pas. », avec ses espaces insécables")
    func theWordsOfTheCancelHint() {
        #expect(DictationText.correctionCancelHint == "Échap annule la correction\u{00A0}; le texte ne change pas.")
    }

    @Test("l'écran de chaque étape de la correction porte la phrase d'Échap, et la correction ne la porte que là",
        arguments: Step.allCases)
    func everyStepOfTheCorrectionShowsTheCancelHint(step: Step) async {
        let h = harness()
        _ = await drive(h, to: step)
        #expect(DictationDisplay(state: h.controller.view).cancelHint == DictationText.correctionCancelHint, "\(step)")
    }

    @Test("ce que la phrase promet est vrai à chaque étape : Échap annule seule la correction, le texte tapé reste, rien n'est collé",
        arguments: Step.allCases)
    func theCancelHintIsTrue(step: Step) async {
        let h = harness()
        let call = await drive(h, to: step)
        let draft = Self.original + Self.typed
        #expect(h.controller.view.draft == draft)
        let promised = DictationDisplay(state: h.controller.view).cancelHint
        #expect(promised?.hasPrefix("Échap annule la correction") == true)

        h.controller.escapePressed()
        let after = DictationDisplay(state: h.controller.view)
        #expect(h.controller.view.stage == .review, "la correction est annulée, pas le panneau")
        #expect(h.panel.isOpen)
        #expect(h.controller.view.draft == draft, "le texte ne change pas")
        #expect(after.review?.text == draft)
        #expect(after.cancelHint == nil, "la phrase s'efface avec la correction")
        if let call { #expect(await until { call.sawCancellation }, "la requête est annulée") }
        await settle()
        #expect(h.pasted.isEmpty && h.writtenTexts == 0)
    }

    @Test("« Coller » (pasteReview, donc aussi ⌘↩) ne fait rien à aucune des quatre étapes de la correction", arguments: Step.allCases)
    func pastingIsRefusedByTheControllerWhileCorrecting(step: Step) async {
        let h = harness()
        _ = await drive(h, to: step)
        let before = h.controller.view
        h.controller.pasteReview()
        await settle()
        #expect(h.controller.view == before, "\(step)")
        #expect(h.pasted.isEmpty && h.writtenTexts == 0, "\(step)")
        #expect(!h.controller.isInserting, "\(step)")
    }

    @Test("« Copier » ne copie rien à aucune des quatre étapes de la correction : ni le brouillon, ni le texte reçu en flux",
        arguments: Step.allCases)
    func copyingIsRefusedWhileCorrecting(step: Step) {
        let model = PanelModel(lastModeID: ModeChip.rawID)
        var copied: [String] = []
        model.onCopy = { copied.append($0); return true }
        let stage: DictationStage = .correcting(
            {
                switch step {
                case .preparing: .preparing
                case .recording: .recording
                case .transcribing: .transcribing
                case .rewriting: .rewriting
                }
            }())
        model.setDictation(
            DictationViewState(stage: stage, liveText: "Texte reçu en flux.", lastTranscript: "Le premier texte.", draft: "Le brouillon."))
        model.copyTranscript()
        #expect(copied.isEmpty, "\(step)")
        #expect(model.copyState == .idle, "\(step) : jamais « Copié » pour un texte qui n'a pas été copié")
        // La relecture qui revient copie de nouveau le brouillon.
        model.setDictation(DictationViewState(stage: .review, lastTranscript: "Le premier texte.", draft: "Le brouillon."))
        model.copyTranscript()
        #expect(copied == ["Le brouillon."])
    }
}

/// Les lignes d'aide sous la rangée : lesquelles, dans quel ordre, et la place qu'elles prennent (aucune, quand il n'y en a pas).
@MainActor @Suite struct ReviewHintsTests {
    private func display(_ state: DictationViewState, keyboard: Bool = true) -> DictationDisplay {
        DictationDisplay(state: state, panelHasKeyboard: keyboard)
    }

    private func lines(_ state: DictationViewState, label: String? = "⌃⌥Espace", keyboard: Bool = true) throws -> [String] {
        let shown = display(state, keyboard: keyboard)
        return ReviewView.hintLines(display: shown, review: try #require(shown.review), hotKeyLabel: label)
    }

    @Test("en relecture : l'aide de la relecture, puis celle de la correction, chacune une seule fois")
    func aReviewHasItsTwoLinesOnce() throws {
        let shown = try lines(DictationViewState(stage: .review, draft: "Un texte."))
        #expect(
            shown == [DictationText.reviewHint, DictationText.correctionHint(hotKeyLabel: "⌃⌥Espace")])
        #expect(Set(shown).count == shown.count)
    }

    @Test("sans raccourci enregistré, l'aide de correction ne nomme que le bouton")
    func withoutAShortcutOnlyTheButtonIsNamed() throws {
        #expect(
            try lines(DictationViewState(stage: .review, draft: "Un texte."), label: nil)
                == [DictationText.reviewHint, DictationText.correctionHint(hotKeyLabel: nil)])
    }

    @Test("un message est affiché : l'aide de correction s'efface, celle de la relecture reste")
    func aMessageHidesTheCorrectionHint() throws {
        #expect(
            try lines(DictationViewState(stage: .review, notice: "Une raison.", draft: "Un texte."))
                == [DictationText.reviewHint])
    }

    @Test("texte blanc : l'aide du champ vide seule ; collage : aucune ligne")
    func blankAndPasting() throws {
        #expect(try lines(DictationViewState(stage: .review, draft: " ")) == [DictationText.reviewEmptyHint])
        #expect(try lines(DictationViewState(stage: .pasting, draft: "Un texte.")).isEmpty)
    }

    @Test("pendant la correction, une seule ligne : la phrase d'Échap, à chaque étape ; ni aide de relecture ni aide de correction")
    func whileCorrectingOnlyTheCancelHint() throws {
        for step in [CorrectionStep.preparing, .recording, .transcribing, .rewriting] {
            #expect(
                try lines(DictationViewState(stage: .correcting(step), draft: "Un texte.")) == [DictationText.correctionCancelHint],
                "\(step)")
        }
    }

    // MARK: La place

    private func height(_ review: DictationDisplay.Review, display shown: DictationDisplay) -> CGFloat {
        let host = NSHostingView(
            rootView: ReviewView(display: shown, review: review, hotKeyLabel: nil, edit: { _ in }, paste: {}, copy: {})
                .frame(width: 520))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func lineHeight(_ text: String) -> CGFloat {
        let host = NSHostingView(rootView: DetailText(text: text).frame(width: 520))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// Une relecture à laquelle on retire ou donne des lignes d'aide à la main (le calcul des lignes est testé plus haut).
    private func bare() throws -> (DictationDisplay, DictationDisplay.Review) {
        let shown = display(DictationViewState(stage: .review, draft: "Un texte."))
        var review = try #require(shown.review)
        review.hint = nil
        review.canCorrect = false
        return (shown, review)
    }

    @Test("sans aucune ligne d'aide, aucun blanc sous la rangée ; une ligne prend sa hauteur plus l'espacement de la pile, une seconde sa hauteur plus 4")
    func noHintTakesNoRoom() throws {
        let (shown, none) = try bare()
        var one = none
        one.hint = "Une première ligne."
        var two = one
        two.canCorrect = true   // l'aide de correction, une ligne sous la première (sans raccourci : une seule ligne)
        let heightNone = height(none, display: shown)
        let heightOne = height(one, display: shown)
        let heightTwo = height(two, display: shown)
        #expect(heightOne - heightNone == lineHeight("Une première ligne.") + 10, "une vue vide ne doit pas ajouter son espacement")
        #expect(heightTwo - heightOne == lineHeight(DictationText.correctionHint(hotKeyLabel: nil)) + 4)
    }
}

/// Un seul gris pour tous les messages et aides du panneau.
@MainActor @Suite struct MessageGrayTests {
    @Test("un message du panneau prend par défaut le gris à 80 % du texte principal, celui des aides")
    func theDefaultGrayOfAMessage() {
        #expect(DetailText(text: "Un message.").color == DetailText.systemSecondary)
    }
}
