import AppKit
import Foundation
import Testing
import SupervoxCore

@testable import SupervoxApp

/// Tour de correction 1 de la tâche 8 : le champ de relecture relié au contrôleur (sans fenêtre), les phrases de la préparation,
/// du maintien et des pannes du modèle fort, et trois trous de test. Un vrai `FocusingTextView` et son coordinateur, le vrai
/// `PanelModel`, le vrai contrôleur de dictée (sessions et réécriture doublées) : le champ est mis à jour comme SwiftUI le ferait
/// après chaque changement de vue.
@MainActor @Suite(.timeLimit(.minutes(1))) struct DictationCorrectionRound1Tests {
    static let original = "Texte original."
    static let rewritten = "Texte réécrit."

    /// La relecture câblée de bout en bout, sans fenêtre.
    @MainActor final class Wired {
        let h = DictationHarness()
        let model = PanelModel(lastModeID: ModeChip.rawID)
        let field: FocusingTextView
        let coordinator: ReviewTextView.Coordinator
        var viewChanges = 0
        private var sessions = 0
        private var calls = 0

        init() {
            h.knobs.reviewing = [ModeChip.rawID]
            let model = model
            let controller = h.controller
            let view = ReviewTextView(
                text: "", isEditable: true, takesFocus: false, onEdit: { model.editDraft($0) },
                onHistoryEnd: { command in
                    if command == .undo { model.previousVersion() } else { model.nextVersion() }
                })
            coordinator = view.makeCoordinator()
            field = FocusingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
            field.allowsUndo = true
            field.isRichText = false
            field.delegate = coordinator
            field.onHistoryEnd = { command in
                if command == .undo { model.previousVersion() } else { model.nextVersion() }
            }
            field.onComposingChange = { model.fieldIsComposing = $0 }
            model.onDraftChange = { controller.reviewEdited($0) }
            model.onPreviousVersion = { controller.previousVersion() }
            model.onNextVersion = { controller.nextVersion() }
            controller.onViewChange = { [unowned self] state in
                model.setDictation(state)
                viewChanges += 1
                refresh()
            }
        }

        /// Ce que SwiftUI ferait au rendu suivant.
        func refresh() {
            guard let review = model.dictationDisplay.review else { return }
            ReviewTextView.update(field, text: review.text, isEditable: review.isEditable, takesFocus: false)
        }

        var draft: String { h.controller.view.draft }

        /// Une dictée menée jusqu'à la relecture de `text`.
        func review(_ text: String) async {
            let session = await h.startRecording()
            session.emit(.finished(text))
            #expect(await until { h.controller.view.stage == .review })
            #expect(field.string == text)
        }

        /// Une correction réussie : `text` remplace le texte, l'ancien est la version précédente.
        func correct(to text: String) async {
            h.controller.startCorrection()
            sessions += 1
            let session = await h.session(sessions)
            #expect(await until { session.calls.contains("start") })
            session.emit(.preparing)
            session.emit(.recording)
            #expect(await until { h.controller.view.stage == .correcting(.recording) })
            h.controller.finishCorrection()
            session.emit(.finalizing)
            session.emit(.finished("Change quelque chose."))
            let call = await h.rewriter.call(calls)
            calls += 1
            #expect(await until { h.controller.view.stage == .correcting(.rewriting) })
            call.finish(.rewritten(text))
            #expect(await until { h.controller.view.stage == .review })
            #expect(field.string == text)
        }

        func type(_ text: String) {
            field.insertText(text, replacementRange: NSRange(location: field.string.utf16.count, length: 0))
        }

        /// Une touche morte : un texte marqué à la fin du champ.
        func startDeadKey(_ mark: String = "^") {
            field.setMarkedText(
                mark, selectedRange: NSRange(location: mark.utf16.count, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        /// La lettre qui valide la touche morte.
        func commit(_ letter: String) {
            field.insertText(letter, replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        /// Toutes les versions, de la plus ancienne à la plus récente (le contrôleur est remis où il était).
        func allVersions() -> [String] {
            var steps = 0
            while h.controller.view.canGoBack {
                h.controller.previousVersion()
                steps += 1
            }
            var all = [h.controller.view.draft]
            while h.controller.view.canGoForward {
                h.controller.nextVersion()
                all.append(h.controller.view.draft)
            }
            for _ in 0..<(all.count - 1 - steps) { h.controller.previousVersion() }
            return all
        }
    }

    // MARK: - I1 : l'annulation du champ remonte au contrôleur

    @Test("I1 : ⌘Z puis ⇧⌘Z dans la pile du champ préviennent le contrôleur : son brouillon est toujours le texte affiché")
    func theFieldsUndoAndRedoReachTheController() async {
        let w = Wired()
        await w.review(Self.original)
        w.type(" mot")
        #expect(w.draft == Self.original + " mot")
        let before = w.viewChanges

        w.field.undoOrPreviousVersion()
        #expect(w.field.string == Self.original)
        #expect(w.draft == Self.original, "le brouillon garde le mot défait : « Coller » collerait ce que l'écran ne montre plus")
        w.field.redoOrNextVersion()
        #expect(w.field.string == Self.original + " mot")
        #expect(w.draft == Self.original + " mot")
        #expect(w.viewChanges - before <= 2, "une notification par geste, aucune boucle (changement, remplacement, pile vidée)")
        #expect(w.field.undoManager?.canUndo == true, "la pile du champ n'a pas été vidée par ce va-et-vient")
        #expect(w.h.controller.view.stage == .review)
    }

    @Test("I1 : ⌘Z défait la frappe, puis la version précédente ; ⇧⌘Z rend la réécriture sans le mot (le scénario (a) de la règle 6, sans fenêtre)")
    func ruleSixScenarioAWithoutAWindow() async {
        let w = Wired()
        await w.review(Self.original)
        await w.correct(to: Self.rewritten)
        w.type(" mot")
        w.field.undoOrPreviousVersion()
        #expect(w.field.string == Self.rewritten)
        #expect(w.draft == Self.rewritten)
        w.field.undoOrPreviousVersion()
        #expect(w.field.string == Self.original)
        #expect(w.draft == Self.original)
        w.field.redoOrNextVersion()
        #expect(w.field.string == Self.rewritten)
        #expect(w.draft == Self.rewritten)
    }

    // MARK: - C1 : un texte marqué ne perd aucune version

    @Test("C1 : correction réussie, ⌘Z, touche morte, ⇧⌘Z, lettre : le champ et le brouillon sont identiques et toutes les versions existent")
    func aDeadKeyThenRedoLosesNothing() async throws {
        let w = Wired()
        await w.review(Self.original)
        await w.correct(to: Self.rewritten)
        w.field.undoOrPreviousVersion()                           // ⌘Z : la pile est vide, la version précédente revient
        #expect(w.field.string == Self.original)
        #expect(w.h.controller.view.canGoForward)

        w.startDeadKey()
        try #require(w.field.hasMarkedText())
        w.field.redoOrNextVersion()                               // ⇧⌘Z pendant le texte marqué : sans effet
        #expect(w.draft == Self.original, "le contrôleur n'a pas changé de version : le champ montre toujours l'original")
        #expect(w.h.controller.view.canGoForward, "la version suivante n'est pas perdue")
        w.commit("ê")

        #expect(w.field.string == w.draft, "le champ et le brouillon divergent")
        #expect(w.draft == Self.original + "ê")
        // Toutes les versions existent encore : la réécriture est devant, l'original (retouché) est le texte courant.
        #expect(w.allVersions() == [Self.original + "ê", Self.rewritten])
        #expect(w.field.string == w.draft)
    }

    @Test("C1 : même scénario avec le bouton « Version précédente » pendant le texte marqué : sans effet, rien ne se perd")
    func aDeadKeyThenTheVersionButtonLosesNothing() async {
        let w = Wired()
        await w.review(Self.original)
        await w.correct(to: Self.rewritten)
        w.startDeadKey()
        #expect(w.model.fieldIsComposing, "le champ dit au panneau qu'une saisie est en attente")

        w.model.previousVersion()                                 // le bouton
        w.model.nextVersion()
        #expect(w.draft == Self.rewritten, "aucun changement de version pendant le texte marqué")
        w.commit("ê")
        #expect(!w.model.fieldIsComposing, "la saisie validée, le panneau le sait")

        #expect(w.field.string == w.draft)
        #expect(w.draft == Self.rewritten + "ê")
        #expect(w.allVersions() == [Self.original, Self.rewritten + "ê"])
    }

    @Test("C1 : le bouton agit de nouveau une fois la saisie validée")
    func theButtonWorksAgainAfterTheDeadKey() async {
        let w = Wired()
        await w.review(Self.original)
        await w.correct(to: Self.rewritten)
        w.startDeadKey()
        w.commit("ê")
        w.model.previousVersion()
        #expect(w.draft == Self.original)
        #expect(w.field.string == Self.original)
    }

    @Test("C1, défense en profondeur : un changement de version venu de l'extérieur pendant le texte marqué attend la fin du marquage, puis s'applique : le champ et le contrôleur ne divergent jamais")
    func anExternalReplacementDuringMarkedTextIsAppliedAtTheEnd() async throws {
        let w = Wired()
        await w.review(Self.original)
        await w.correct(to: Self.rewritten)
        w.startDeadKey()
        try #require(w.field.hasMarkedText())

        w.h.controller.previousVersion()                          // contourne la garde du panneau : le contrôleur change de version
        #expect(w.draft == Self.original)
        #expect(w.field.hasMarkedText(), "la saisie en attente n'est pas effacée")
        #expect(w.field.string == Self.rewritten + "^", "pas de réécriture pendant le texte marqué")

        w.commit("ê")
        #expect(w.field.string == Self.original, "le texte attendu s'applique dès la fin du marquage")
        #expect(w.draft == Self.original)
        #expect(w.field.undoManager?.canUndo == false, "un texte remplacé de l'extérieur vide la pile")
        #expect(w.allVersions() == [Self.original, Self.rewritten])
    }

    @Test("C1 : le champ lui-même ne passe pas à une autre version pendant un texte marqué (ni ⌘Z ni ⇧⌘Z ne préviennent le panneau)")
    func theFieldDoesNotAskForAVersionDuringMarkedText() throws {
        let field = DictationCorrectionTests.Field(text: "Version A.")
        field.textView.setMarkedText(
            "^", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(field.textView.hasMarkedText())
        field.textView.redoOrNextVersion()
        field.textView.undoOrPreviousVersion()
        #expect(field.ends.isEmpty)
        // Hors saisie en attente, une pile vide prévient le panneau.
        let plain = DictationCorrectionTests.Field(text: "Version A.")
        plain.textView.redoOrNextVersion()
        plain.textView.undoOrPreviousVersion()
        #expect(plain.ends == [.redo, .undo])
    }

    @Test("C1 : le retard du modèle pendant un texte marqué (le texte d'avant la saisie) n'est pas un remplacement en attente : la lettre validée reste")
    func aLateEchoIsNotAPendingReplacement() {
        let field = DictationCorrectionTests.Field(text: "ab")
        field.type("c")
        field.textView.setMarkedText(
            "^", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        // SwiftUI redonne le texte du modèle, d'une frappe en retard sur le champ (le texte marqué n'est pas remonté).
        ReviewTextView.update(field.textView, text: "abc", isEditable: true, takesFocus: false)
        #expect(field.textView.pendingText == nil)
        field.textView.insertText("ê", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(field.textView.string == "abcê")
    }

    @Test("C1 : une version qui attend, puis le texte du champ qui lui redevient égal : plus rien n'attend")
    func aPendingTextIsDroppedWhenTheFieldCatchesUp() async {
        let w = Wired()
        await w.review(Self.original)
        w.startDeadKey()
        ReviewTextView.update(w.field, text: "Autre.", isEditable: true, takesFocus: false)
        ReviewTextView.update(w.field, text: w.field.string, isEditable: true, takesFocus: false)
        w.commit("ê")
        #expect(w.field.string == Self.original + "ê", "le texte en attente périmé ne s'applique pas")
        #expect(w.draft == w.field.string)
    }

    @Test("C1 : ⌘Z pendant un texte marqué défait la saisie, sans changer de version")
    func undoDuringMarkedTextKeepsTheVersion() async {
        let w = Wired()
        await w.review(Self.original)
        await w.correct(to: Self.rewritten)
        w.startDeadKey()
        w.field.undoOrPreviousVersion()
        #expect(w.draft == Self.rewritten)
        #expect(w.h.controller.view.canGoBack)
        #expect(w.field.string == w.draft || w.field.hasMarkedText())
    }

    @Test("C1 : PanelModel ne relaie pas « Version précédente » et « Version suivante » pendant une saisie en attente")
    func thePanelModelIgnoresVersionButtonsWhileComposing() {
        var back = 0
        var forward = 0
        let model = PanelModel(lastModeID: ModeChip.rawID)
        model.onPreviousVersion = { back += 1 }
        model.onNextVersion = { forward += 1 }
        model.setDictation(DictationViewState(stage: .review, draft: "t", canGoBack: true, canGoForward: true))
        model.fieldIsComposing = true
        model.previousVersion()
        model.nextVersion()
        #expect((back, forward) == (0, 0))
        model.fieldIsComposing = false
        model.previousVersion()
        model.nextVersion()
        #expect((back, forward) == (1, 1))
        // Hors relecture le champ n'est plus là : l'indicateur ne reste pas coincé.
        model.fieldIsComposing = true
        model.setDictation(DictationViewState())
        #expect(!model.fieldIsComposing)
    }

    // MARK: - I2 : la préparation et le maintien

    private func harness() -> DictationHarness {
        let h = DictationHarness()
        h.knobs.reviewing = [ModeChip.rawID]
        return h
    }

    private func review(_ h: DictationHarness) async {
        let session = await h.startRecording()
        session.emit(.finished(Self.original))
        #expect(await until { h.controller.view.stage == .review })
    }

    @Test("I2 : les phrases de la préparation et du maintien, mot pour mot")
    func theNewSentences() {
        #expect(
            DictationController.correctionPreparingNotice
                == "Patientez un instant : vous pourrez dire ce qu'il faut changer dès que l'écoute commence.")
        #expect(
            DictationController.correctionListeningNotice(hotKeyLabel: "⌃⌥Espace", hold: true)
                == "Dites ce qu'il faut changer, puis relâchez ⌃⌥Espace.")
        #expect(
            DictationController.correctionListeningNotice(hotKeyLabel: nil, hold: true)
                == "Dites ce qu'il faut changer, puis relâchez le raccourci.")
        #expect(
            DictationController.correctionListeningNotice(hotKeyLabel: "⌃⌥Espace", hold: false)
                == DictationController.correctionListeningNotice(hotKeyLabel: "⌃⌥Espace"))
        #expect(
            DictationController.correctionInterruptedNotice
                == "La correction à la voix a été interrompue. Le texte n'a pas changé.")
        #expect(
            DictationController.correctionMicrophoneNotice
                == "Le micro n'est pas autorisé : autorisez-le dans les Réglages Système pour corriger à la voix.")
    }

    @Test("I2 : pendant la préparation, la phrase dit d'attendre (jamais la phrase d'écoute) ; elle ne vient qu'avec l'enregistrement")
    func theListeningSentenceComesWithTheRecordingOnly() async {
        let h = harness()
        await review(h)
        h.controller.startCorrection()
        #expect(h.controller.view.stage == .correcting(.preparing))
        #expect(h.controller.view.notice == DictationController.correctionPreparingNotice)
        let session = await h.session(1)
        #expect(await until { session.calls.contains("start") })
        session.emit(.preparing)
        await settle()
        #expect(h.controller.view.notice == DictationController.correctionPreparingNotice)
        session.emit(.recording)
        #expect(await until { h.controller.view.stage == .correcting(.recording) })
        #expect(h.controller.view.notice == DictationController.correctionListeningNotice(hotKeyLabel: "⌘⇧K"))
        // Plus de phrase d'écoute dès que la consigne est terminée.
        h.controller.finishCorrection()
        session.emit(.finalizing)
        #expect(await until { h.controller.view.stage == .correcting(.transcribing) })
        #expect(h.controller.view.notice == nil)
    }

    @Test("I2 : pendant un téléchargement ou un chargement, la phrase de préparation accompagne la mention, sans la phrase d'écoute")
    func theDownloadNoticeComesWithThePreparationSentence() async {
        let h = harness()
        await review(h)
        let gate = TestGate()
        defer { gate.open() }
        h.engines.configure {
            $0.modelMissing = true
            $0.downloadGate = gate
        }
        h.controller.startCorrection()
        #expect(
            await until {
                h.controller.view.notice
                    == DictationController.correctionPreparingNotice + " " + DictationController.downloadNotice
            })
        #expect(h.controller.view.notice?.contains("Dites") == false)
        #expect(h.controller.isBusy)
    }

    @Test("I2 : en maintien la phrase dit de relâcher le raccourci ; par le bouton, même en maintien, elle garde « appuyez de nouveau »")
    func theHoldSentenceSaysToRelease() async {
        let h = harness()
        await review(h)
        h.knobs.behavior = .hold
        h.controller.hotKeyPressed()
        let session = await h.session(1)
        #expect(await until { session.calls.contains("start") })
        session.emit(.preparing)
        session.emit(.recording)
        #expect(await until { h.controller.view.stage == .correcting(.recording) })
        #expect(h.controller.view.notice == "Dites ce qu'il faut changer, puis relâchez ⌘⇧K.")
        h.controller.hotKeyReleased()
        #expect(await until { session.count(of: "finish") == 1 })

        let button = harness()
        await review(button)
        button.knobs.behavior = .hold
        button.controller.startCorrection()
        let other = await button.session(1)
        #expect(await until { other.calls.contains("start") })
        other.emit(.preparing)
        other.emit(.recording)
        #expect(await until { button.controller.view.stage == .correcting(.recording) })
        #expect(button.controller.view.notice == DictationController.correctionListeningNotice(hotKeyLabel: "⌘⇧K"))
    }

    // MARK: - I3 : les pannes du modèle fort parlent du modèle fort

    /// Miroir de `RewriteFailure` sans valeurs associées : un cas ajouté casse la compilation de `kind(of:)`, puis de `sample`.
    enum Kind: CaseIterable {
        case noModel, providerMissing, noKey, keychain, unauthorized, notFound, rejected, rateLimited, server, unreachable
        case redirected, interrupted, stalled, providerError, truncated, refused, empty, timedOut, malformed
    }

    private static func kind(of failure: RewriteFailure) -> Kind {
        switch failure {
        case .noModel: .noModel
        case .providerMissing: .providerMissing
        case .noKey: .noKey
        case .keychain: .keychain
        case .unauthorized: .unauthorized
        case .notFound: .notFound
        case .rejected: .rejected
        case .rateLimited: .rateLimited
        case .server: .server
        case .unreachable: .unreachable
        case .redirected: .redirected
        case .interrupted: .interrupted
        case .stalled: .stalled
        case .providerError: .providerError
        case .truncated: .truncated
        case .refused: .refused
        case .empty: .empty
        case .timedOut: .timedOut
        case .malformed: .malformed
        }
    }

    private static func sample(_ kind: Kind) -> RewriteFailure {
        switch kind {
        case .noModel: .noModel
        case .providerMissing: .providerMissing
        case .noKey: .noKey(provider: "Fournisseur exemple")
        case .keychain: .keychain
        case .unauthorized: .unauthorized(401)
        case .notFound: .notFound
        case .rejected: .rejected(422)
        case .rateLimited: .rateLimited
        case .server: .server(503)
        case .unreachable: .unreachable
        case .redirected: .redirected
        case .interrupted: .interrupted
        case .stalled: .stalled(120)
        case .providerError: .providerError
        case .truncated: .truncated
        case .refused: .refused
        case .empty: .empty
        case .timedOut: .timedOut(300)
        case .malformed: .malformed
        }
    }

    @Test("I3 : aucune phrase d'échec de la correction ne parle « de ce mode » ni « du mode », et chacune finit sur « Le texte n'a pas changé. » et tient dans le détail",
        arguments: Kind.allCases)
    func noCorrectionFailureSentenceTalksAboutAMode(kind: Kind) {
        let failure = Self.sample(kind)
        #expect(Self.kind(of: failure) == kind)
        let notice = DictationController.correctionNotice(for: failure)
        #expect(!notice.contains("ce mode"), "\(failure) : \(notice)")
        #expect(!notice.contains("du mode"), "\(failure) : \(notice)")
        #expect(!notice.contains("pour ce mode"), "\(failure) : \(notice)")
        #expect(notice.hasSuffix("Le texte n'a pas changé."), "\(failure) : \(notice)")
        #expect(notice.count <= DictationText.detailLimit, "\(failure) : \(notice.count) caractères")
    }

    @Test("I3 : les phrases propres à la correction, mot pour mot ; les autres pannes gardent la phrase du Core")
    func theCorrectionOnlySentences() {
        #expect(
            DictationController.correctionNotice(for: .providerMissing)
                == "Le fournisseur du modèle fort n'existe plus : choisissez un autre modèle fort en tête de Réglages, onglet Modes. Le texte n'a pas changé.")
        #expect(
            DictationController.correctionNotice(for: .notFound)
                == "Le serveur ne connaît pas le modèle fort ou cette adresse (HTTP 404) : vérifiez le modèle fort, en tête de Réglages, onglet Modes, et l'adresse du fournisseur. Le texte n'a pas changé.")
        #expect(DictationController.correctionNotice(for: .noModel) == DictationController.correctionNoModelNotice)
        #expect(
            DictationController.correctionNotice(for: .unreachable) == RewriteFailure.unreachable.message + " Le texte n'a pas changé.")
        // Le Core ne change pas : la mise en forme d'un mode garde ses phrases.
        #expect(RewriteFailure.providerMissing.message.contains("ce mode"))
    }

    @Test("I3 : un fournisseur du modèle fort disparu : la relecture revient avec la phrase du modèle fort, le texte intact")
    func aMissingProviderOfTheStrongModelIsSaidInTheCorrectionWords() async {
        let h = harness()
        await review(h)
        h.controller.startCorrection()
        let session = await h.session(1)
        #expect(await until { session.calls.contains("start") })
        session.emit(.preparing)
        session.emit(.recording)
        #expect(await until { h.controller.view.stage == .correcting(.recording) })
        h.controller.finishCorrection()
        session.emit(.finalizing)
        session.emit(.finished("Change quelque chose."))
        let call = await h.rewriter.call()
        call.finish(.failed(.providerMissing))
        #expect(await until { h.controller.view.stage == .review })
        #expect(h.controller.view.notice == DictationController.correctionNotice(for: .providerMissing))
        #expect(h.controller.view.draft == Self.original)
    }

    // MARK: - Mineurs

    @Test("m2 : une session interrompue pendant la correction parle de la correction, pas de la dictée")
    func anInterruptedCorrectionSaysSo() async {
        let h = harness()
        await review(h)
        h.controller.startCorrection()
        let session = await h.session(1)
        #expect(await until { session.calls.contains("start") })
        session.emit(.preparing)
        session.emit(.recording)
        #expect(await until { h.controller.view.stage == .correcting(.recording) })
        session.emit(.cancelled)
        #expect(await until { h.controller.view.stage == .review })
        #expect(h.controller.view.notice == DictationController.correctionInterruptedNotice)
        #expect(h.controller.view.draft == Self.original)
    }

    @Test("m3 : sans micro autorisé, la relecture reste, avec une phrase qui le dit")
    func noMicrophoneSaysSo() async {
        let h = harness()
        await review(h)
        h.knobs.microphoneAllowed = false
        h.controller.startCorrection()
        await settle()
        #expect(h.controller.view.stage == .review)
        #expect(h.controller.view.draft == Self.original)
        #expect(h.controller.view.notice == DictationController.correctionMicrophoneNotice)
        #expect(h.engines.sessions.count == 1)
    }

    @Test("m4 : une session qui échoue ou s'arrête pendant la réécriture ne coupe pas la correction")
    func theSessionSaysNothingUsefulDuringTheRewriting() async {
        for ending in [DictationPhase.failed(.engine("panne")), .cancelled, .recording, .finalizing] {
            let h = harness()
            await review(h)
            h.controller.startCorrection()
            let session = await h.session(1)
            #expect(await until { session.calls.contains("start") })
            session.emit(.preparing)
            session.emit(.recording)
            #expect(await until { h.controller.view.stage == .correcting(.recording) })
            h.controller.finishCorrection()
            session.emit(.finalizing)
            session.emit(.finished("Change quelque chose."))
            let call = await h.rewriter.call()
            #expect(await until { h.controller.view.stage == .correcting(.rewriting) })

            session.emit(ending)
            await settle()
            #expect(h.controller.view.stage == .correcting(.rewriting), "\(ending)")
            call.finish(.rewritten(Self.rewritten))
            #expect(await until { h.controller.view.stage == .review })
            #expect(h.controller.view.draft == Self.rewritten, "\(ending)")
        }
    }

    @Test("m4 : la consigne envoyée au modèle ne contient que le brouillon et la consigne dite, jamais le texte en direct")
    func theJobDoesNotCarryTheLiveText() async {
        let h = harness()
        await review(h)
        h.controller.startCorrection()
        let session = await h.session(1)
        #expect(await until { session.calls.contains("start") })
        session.emit(.preparing)
        session.emit(.recording)
        #expect(await until { h.controller.view.stage == .correcting(.recording) })
        h.controller.finishCorrection()
        session.emit(.finalizing, liveText: "consigne provisoire")
        #expect(await until { h.controller.view.liveText == "consigne provisoire" })
        session.emit(.finished("Consigne finale."))
        let call = await h.rewriter.call()
        let expected = RewritePrompt.correction(text: Self.original, change: "Consigne finale.", vocabulary: [])
        #expect(call.job == RewriteJob(instruction: expected.instruction, input: expected.input, model: nil))
        #expect(!call.job.input.contains("provisoire"))
    }
}
