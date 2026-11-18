import Foundation
import SupervoxCore
import Testing

@testable import SupervoxApp

/// La dictée et l'entretien ensemble : un vrai `DictationController` et un vrai `InterviewController`, avec les doubles de la
/// dictée (sessions, presse-papiers, touches) et ceux de l'entretien (environnement, conversation, historique). « Conclure » à
/// la touche passe par le modèle du panneau, comme dans l'application (amendement H). Aucun micro, aucun son, aucun ⌘V réel.
@MainActor final class InterviewDictationRig {
    let interview: InterviewRig
    let dictation: DictationHarness

    init(hold: Bool = false) {
        interview = InterviewRig()
        let panel = interview.panel
        dictation = DictationHarness(interview: interview.controller, concludeInterview: { panel.concludeInterview() })
        dictation.knobs.modeID = ModeChip.interviewID
        dictation.knobs.modeModifiers[ModeChip.interviewID] = [.control, .option]
        dictation.engines.configure { [journal = interview.journal] in $0.journal = journal }
        if hold {
            interview.behavior = .hold
            dictation.knobs.behavior = .hold
        }
    }

    var controller: DictationController { dictation.controller }
    var panel: FakeDictationPanel { dictation.panel }
    /// Ce que le panneau montre de l'entretien.
    var view: InterviewViewState? { interview.panel.interview }

    /// Lance par le raccourci global (le mode choisi est Entretien), puis attend la conversation `index` à l'écoute.
    func listening(index: Int = 0) async throws -> ConversationDriver {
        controller.hotKeyPressed()
        return try await toListening(index: index)
    }

    func toListening(index: Int = 0) async throws -> ConversationDriver {
        let driver = try await interview.driver(index)
        driver.emit(.state(.listening))
        try #require(await until { self.view?.phase == .listening })
        return driver
    }

    /// Rien n'a été collé ni copié, et rien n'est parti à l'historique.
    func nothingKept() async {
        // La fin observée (lecture du flux finie, écritures finies), pas une durée : après elle, « rien » est un fait.
        #expect(await interview.controller.drained(), "la lecture et les écritures de l'entretien finissent")
        #expect(dictation.pasted.isEmpty)
        #expect(dictation.writtenTexts == 0)
        #expect(interview.history.attempts == 0)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct DictationInterviewTests {
    static let exchange = InterviewRig.conversation([
        (.interviewer, "Quel est le but ?"), (.user, "Résumer des courriels."),
    ])

    // MARK: - Règle 1 : lancer

    enum Launch: String, CaseIterable, Sendable { case globalHotKey, modeHotKey, pill }

    @Test("règle 1 : trois chemins lancent l'entretien ; chacun : résolution, préparation, fabrication, panneau ouvert, vue posée ; son propriétaire conclut", arguments: Launch.allCases)
    func threePathsLaunchTheInterview(launch: Launch) async throws {
        let rig = InterviewDictationRig()
        switch launch {
        case .globalHotKey:
            rig.controller.hotKeyPressed()
        case .modeHotKey:
            rig.dictation.knobs.modeID = ModeChip.rawID
            rig.controller.modeHotKeyPressed(ModeChip.interviewID)
            #expect(rig.dictation.knobs.selectedModes == [ModeChip.interviewID], "le raccourci choisit le mode Entretien")
        case .pill:
            // Le panneau a déjà choisi et enregistré la pastille ; `modeChosen` vient ensuite (relais d'`AppController`).
            rig.controller.modeChosen(ModeChip.interviewID)
        }
        #expect(rig.panel.isOpen)
        #expect(rig.view?.phase == .preparing, "la vue de l'entretien est posée tout de suite")
        #expect(rig.controller.isBusy)
        let driver = try await rig.toListening()
        #expect(rig.interview.journal.entries.prefix(4) == ["résolution", "préparation", "fabrication", "conversation démarrée"])
        #expect(rig.dictation.engines.sessions.isEmpty, "aucune session de dictée")

        // Le propriétaire : le raccourci du mode pour ce chemin, le raccourci global pour les deux autres.
        let other = launch == .modeHotKey ? { rig.controller.hotKeyPressed() } : { rig.controller.modeHotKeyPressed(ModeChip.interviewID) }
        let owner = launch == .modeHotKey ? { rig.controller.modeHotKeyPressed(ModeChip.interviewID) } : { rig.controller.hotKeyPressed() }
        other()
        await settle()
        #expect(driver.concludes == 0, "un raccourci qui n'est pas le propriétaire ne conclut pas")
        owner()
        #expect(await until { driver.concludes == 1 })
    }

    @Test("règle 1 : la pastille ne lance rien pendant une dictée, une relecture ou un entretien ; une autre pastille ne fait que choisir")
    func thePillLaunchesOnlyAtRest() async throws {
        let rig = InterviewDictationRig()
        rig.controller.modeChosen(ModeChip.rawID)
        rig.dictation.knobs.modeID = ModeChip.rawID
        rig.controller.modeChosen(ModeChip.rawID)
        await settle()
        #expect(!rig.panel.isOpen && rig.view == nil, "une pastille de dictée ne lance rien")

        // Pendant une dictée.
        await rig.dictation.startRecording()
        rig.controller.modeChosen(ModeChip.interviewID)
        await settle()
        #expect(rig.interview.resolveCount == 0 && rig.view == nil, "pendant une dictée")
        #expect(rig.controller.view.stage == .recording)

        // Pendant une relecture.
        let review = InterviewDictationRig()
        review.dictation.knobs.modeID = ModeChip.rawID
        review.dictation.knobs.reviewing = [ModeChip.rawID]
        let reviewed = await review.dictation.startRecording()
        review.controller.hotKeyPressed()
        reviewed.emit(.finished("À relire."))
        #expect(await until { review.controller.view.stage == .review })
        review.controller.modeChosen(ModeChip.interviewID)
        await settle()
        #expect(review.interview.resolveCount == 0 && review.view == nil, "pendant une relecture")
        #expect(review.controller.view.stage == .review)

        // Pendant un entretien : un second clic ne relance pas.
        let running = InterviewDictationRig()
        _ = try await running.listening()
        running.controller.modeChosen(ModeChip.interviewID)
        await settle()
        #expect(running.interview.resolveCount == 1, "pendant un entretien")
    }

    @Test("T9-1 : une sélection refusée par le panneau ne lance rien : ni dictée sur un autre mode, ni panneau, ni entretien")
    func aRefusedSelectionStartsNothing() async {
        let rig = InterviewDictationRig()
        rig.dictation.knobs.modeID = ModeChip.rawID
        rig.dictation.knobs.refusesSelection = true
        rig.controller.modeHotKeyPressed(ModeChip.interviewID)
        rig.controller.modeHotKeyPressed("perso-un")
        await settle()
        #expect(rig.dictation.knobs.selectedModes == [ModeChip.interviewID, "perso-un"], "la sélection a été demandée")
        #expect(rig.dictation.knobs.modeID == ModeChip.rawID)
        #expect(rig.dictation.engines.sessions.isEmpty, "pas de dictée sur le mode resté choisi")
        #expect(rig.interview.resolveCount == 0 && rig.view == nil)
        #expect(!rig.panel.isOpen && rig.panel.openCount == 0)
        #expect(rig.controller.view == DictationViewState())
    }

    // MARK: - Règle 2 : refus

    @Test("règle 2 : micro non autorisé : ni résolution ni préparation, le panneau s'ouvre sur la ligne des permissions")
    func aRefusedMicrophoneStartsNothing() async {
        let rig = InterviewDictationRig()
        rig.dictation.knobs.microphoneAllowed = false
        rig.controller.hotKeyPressed()
        await settle()
        #expect(rig.panel.isOpen)
        #expect(rig.controller.view == DictationViewState())
        #expect(rig.view == nil)
        #expect(rig.interview.resolveCount == 0 && rig.interview.environment.prepareCount == 0)
        #expect(!rig.controller.isBusy)
    }

    @Test("règle 2 : un refus de la résolution est dit dans le panneau, sans rien préparer ; l'appui suivant relance")
    func aResolutionRefusalIsShownInThePanel() async {
        let rig = InterviewDictationRig()
        rig.interview.settings.fastModel = nil
        rig.controller.hotKeyPressed()
        #expect(await until { rig.view == nil })
        #expect(rig.controller.view.notice == InterviewText.setupFailure(.noFastModel))
        #expect(rig.panel.isOpen)
        #expect(rig.interview.environment.prepareCount == 0)
        #expect(!rig.controller.isBusy)

        rig.controller.hotKeyPressed()
        #expect(rig.view?.phase == .preparing, "l'appui suivant relance l'entretien")
        #expect(await until { rig.interview.resolveCount == 2 })
    }

    // MARK: - Règle 3 : conclure par la touche

    @Test("T9-1 : le raccourci d'un autre mode pendant l'entretien est ignoré sans effet de bord")
    func anotherModesHotKeyIsIgnoredWithoutSideEffects() async throws {
        let rig = InterviewDictationRig()
        let driver = try await rig.listening()
        let view = rig.controller.view
        let shown = rig.view

        rig.controller.modeHotKeyPressed(ModeChip.rawID)
        rig.controller.modeHotKeyReleased(ModeChip.rawID)
        await settle()
        #expect(rig.dictation.knobs.selectedModes.isEmpty, "aucun mode choisi")
        #expect(rig.dictation.knobs.modeID == ModeChip.interviewID)
        #expect(rig.controller.view == view, "l'avis et l'état de la dictée sont inchangés")
        #expect(rig.view == shown)
        #expect(rig.panel.isOpen && rig.panel.closeCount == 0, "le panneau n'est pas fermé")
        #expect(driver.concludes == 0 && driver.cancels == 0)
        #expect(rig.dictation.engines.sessions.isEmpty)
        #expect(!rig.interview.panel.concludeRequested)
    }

    @Test("règle 3 : la touche passe par le modèle du panneau (« Conclure » grisé) et ne conclut qu'une fois")
    func theHotKeyConcludesThroughThePanelModelOnce() async throws {
        let rig = InterviewDictationRig()
        let driver = try await rig.listening()
        rig.controller.hotKeyPressed()
        #expect(rig.interview.panel.concludeRequested, "le bouton se grise")
        #expect(await until { driver.concludes == 1 })
        rig.controller.hotKeyPressed()
        rig.interview.panel.concludeInterview()
        await settle()
        #expect(driver.concludes == 1)
    }

    @Test("règle 3 : propriétaire orphelin (son raccourci n'est plus enregistré) : tout raccourci conclut")
    func anOrphanInterviewIsConcludedByAnyHotKey() async throws {
        let rig = InterviewDictationRig()
        rig.dictation.knobs.modeID = ModeChip.rawID
        rig.controller.modeHotKeyPressed(ModeChip.interviewID)
        let driver = try await rig.toListening()
        rig.controller.hotKeyPressed()
        await settle()
        #expect(driver.concludes == 0, "le propriétaire existe encore : le global est ignoré")
        rig.dictation.knobs.unbound = [.mode(ModeChip.interviewID)]
        rig.controller.hotKeyPressed()
        #expect(await until { driver.concludes == 1 })
    }

    @Test("règle 3, T9-4 : en maintien, la note le dit (« un appui conclut ») ; le relâchement est ignoré, un appui conclut")
    func inHoldTheReleaseIsIgnoredAndOnePressConcludes() async throws {
        let rig = InterviewDictationRig(hold: true)
        rig.dictation.knobs.modifiersHeld = false
        let driver = try await rig.listening()
        let note = try #require(rig.view?.shownHoldNote)
        #expect(note == InterviewText.holdNote)
        #expect(note.contains("un appui conclut"))

        rig.controller.hotKeyReleased()
        rig.dictation.holdSleeper.release()
        await settle()
        #expect(driver.concludes == 0, "le relâchement ne conclut pas, même modificateurs lâchés")
        #expect(rig.dictation.knobs.probes.isEmpty, "aucune surveillance du maintien pendant l'entretien")
        #expect(rig.view?.phase == .listening)
        rig.controller.hotKeyPressed()
        #expect(await until { driver.concludes == 1 })
    }

    @Test("règle 3 : pendant la conclusion, tout appui est ignoré")
    func everyPressIsIgnoredWhileConcluding() async throws {
        let rig = InterviewDictationRig()
        let driver = try await rig.listening()
        rig.controller.hotKeyPressed()
        #expect(await until { driver.concludes == 1 })
        driver.emit(.state(.concluding))
        #expect(await until { rig.view?.phase == .concluding })

        rig.controller.hotKeyPressed()
        rig.controller.hotKeyReleased()
        rig.controller.modeHotKeyPressed(ModeChip.interviewID)
        rig.controller.modeHotKeyPressed(ModeChip.rawID)
        await settle()
        #expect(driver.concludes == 1 && driver.cancels == 0)
        #expect(rig.view?.phase == .concluding)
        #expect(rig.panel.isOpen)
        #expect(rig.dictation.engines.sessions.isEmpty)
        #expect(rig.dictation.knobs.selectedModes.isEmpty)
    }

    // MARK: - Règle 4 : le bouton

    @Test("règle 4 : « Conclure » conclut ; la touche ensuite ne conclut pas une seconde fois")
    func theButtonConcludes() async throws {
        let rig = InterviewDictationRig()
        let driver = try await rig.listening()
        rig.interview.panel.concludeInterview()
        #expect(await until { driver.concludes == 1 })
        rig.controller.hotKeyPressed()
        await settle()
        #expect(driver.concludes == 1)
    }

    // MARK: - Règles 5 et 6 : la relecture

    @Test("règle 5 : le prompt ouvre la relecture de la dictée, avec la frappe ; rien n'est collé sans « Coller »")
    func thePromptOpensTheReviewAndNothingIsPastedWithoutAGesture() async throws {
        let rig = InterviewDictationRig()
        let driver = try await rig.listening()
        driver.finish(.prompt("Le prompt rédigé.", Self.exchange))
        #expect(await until { rig.controller.view.stage == .review })
        #expect(rig.controller.view.draft == "Le prompt rédigé.")
        #expect(rig.controller.view.notice == InterviewText.promptReview)
        #expect(rig.view == nil)
        #expect(rig.panel.isOpen)
        #expect(rig.panel.keyboards.last == .focused)
        #expect(!rig.controller.isBusy)
        await settle()
        #expect(rig.dictation.pasted.isEmpty && rig.dictation.writtenTexts == 0, "aucun collage sans geste")

        rig.controller.pasteReview()
        #expect(await until { rig.dictation.pasted == ["Le prompt rédigé."] })
    }

    @Test("règle 5 : une issue sans relecture est dite dans le panneau ouvert")
    func anOutcomeWithoutReviewIsShown() async throws {
        let rig = InterviewDictationRig()
        let driver = try await rig.listening()
        driver.finish(.nothingSaid)
        #expect(await until { rig.view == nil })
        #expect(rig.controller.view == DictationViewState(notice: InterviewText.nothingSaid))
        #expect(rig.panel.isOpen)
        await rig.nothingKept()
    }

    /// M-6 : la relecture s'ouvre sur `.finished`, mais le flux de la conversation n'est pas encore fini (porte tenue par le double) ;
    /// la correction, qui ouvre le micro, attend sa fin.
    @Test("règle 6 : « Corriger à la voix » ne démarre qu'une fois la conversation finie (son flux terminé)")
    func theCorrectionStartsAfterTheConversationFinished() async throws {
        let rig = InterviewDictationRig()
        let driver = try await rig.listening()
        let streamEnd = TestGate()
        defer { streamEnd.open() }
        driver.configure(streamEndGate: streamEnd)
        driver.finish(.prompt("Le prompt rédigé.", Self.exchange))
        #expect(await until { rig.controller.view.stage == .review })
        rig.controller.startCorrection()
        await settle()
        #expect(rig.dictation.engines.sessions.isEmpty, "le flux de la conversation n'est pas fini : aucune session")

        streamEnd.open()
        _ = await rig.dictation.session()
        let entries = rig.interview.journal.entries
        let ended = try #require(entries.firstIndex(of: "flux terminé"))
        let made = try #require(entries.firstIndex(of: "session de dictée fabriquée"))
        #expect(ended < made)
    }

    @Test("règle 6 : une dictée lancée juste après Échap attend que la conversation annulée ait rendu le micro")
    func aDictationRightAfterEscapeWaitsForTheMicrophone() async throws {
        let rig = InterviewDictationRig()
        let driver = try await rig.listening()
        let cancelGate = TestGate()
        defer { cancelGate.open() }
        driver.configure(cancelGate: cancelGate)
        rig.controller.escapePressed()
        #expect(await until { driver.cancels == 1 })
        #expect(rig.view == nil && !rig.controller.isBusy)

        rig.dictation.knobs.modeID = ModeChip.rawID
        rig.controller.hotKeyPressed()
        await settle()
        #expect(rig.dictation.engines.sessions.isEmpty, "le micro de l'entretien n'est pas encore rendu")
        cancelGate.open()
        _ = await rig.dictation.session()
        let entries = rig.interview.journal.entries
        let stopped = try #require(entries.firstIndex(of: "audio arrêté"))
        let made = try #require(entries.firstIndex(of: "session de dictée fabriquée"))
        #expect(stopped < made)
    }

    @Test("M-1 : Échap pendant la résolution (invite du trousseau tenue) : aucun micro n'est à rendre, une dictée démarre aussitôt")
    func aDictationAfterEscapeDuringTheResolutionDoesNotWait() async throws {
        let rig = InterviewDictationRig()
        let resolution = TestGate()
        defer { resolution.open() }
        rig.interview.resolveGate = resolution
        rig.controller.hotKeyPressed()
        #expect(await until { rig.interview.resolveCount == 1 })
        rig.controller.escapePressed()
        #expect(rig.view == nil && !rig.controller.isBusy)

        rig.dictation.knobs.modeID = ModeChip.rawID
        rig.controller.hotKeyPressed()
        _ = await rig.dictation.session()
        #expect(rig.dictation.engines.sessions.count == 1, "la dictée n'attend pas une résolution qui n'a ouvert aucun micro")
        #expect(rig.interview.environment.makeCount == 0, "l'entretien annulé n'a rien fabriqué")
    }

    // MARK: - Règle 7, T9-2 : Échap et fermeture

    enum Moment: String, CaseIterable, Sendable { case preparing, listening, thinking, speaking, concluding }
    enum Ending: String, CaseIterable, Sendable { case escape, panelClosed }

    static let cancellations: [(Moment, Ending)] = Moment.allCases.flatMap { moment in Ending.allCases.map { (moment, $0) } }

    @Test("règle 7, T9-2 : Échap ou la fermeture du panneau, à chaque phase : annulé, rien gardé, vue retirée, panneau fermé", arguments: 0..<10)
    func escapeAndClosingCancelAtEveryPhase(index: Int) async throws {
        let (moment, ending) = Self.cancellations[index]
        let rig = InterviewDictationRig()
        var driver: ConversationDriver?
        let resolveGate = TestGate()
        defer { resolveGate.open() }
        if moment == .preparing {
            rig.interview.resolveGate = resolveGate
            rig.controller.hotKeyPressed()
            #expect(await until { rig.interview.resolveCount == 1 })
        } else {
            let live = try await rig.listening()
            driver = live
            switch moment {
            case .thinking: live.emit(.state(.thinking))
            case .speaking: live.emit(.speakingStarted(question: 1))
            case .concluding:
                rig.controller.hotKeyPressed()
                live.emit(.state(.concluding))
            case .preparing, .listening: break
            }
            #expect(await until { rig.view?.phase == InterviewPhase(moment) })
        }

        switch ending {
        case .escape: rig.controller.escapePressed()
        case .panelClosed: rig.panel.close()
        }
        #expect(rig.view == nil, "\(moment) \(ending)")
        #expect(!rig.panel.isOpen)
        #expect(!rig.controller.isBusy)
        #expect(!rig.interview.panel.holdsPanel && !rig.interview.panel.modesLocked)
        #expect(rig.controller.view == DictationViewState())
        if let driver { #expect(await until { driver.isFinished }, "la conversation est annulée") }
        resolveGate.open()
        await rig.nothingKept()
        #expect(rig.interview.environment.drivers.allSatisfy { $0.isFinished || $0.starts == 0 })
        #expect(rig.controller.view == DictationViewState(), "rien ne revient après l'annulation")
    }

    @Test("T9-4 : « Échap annule l'entretien sans rien garder » est montré, et tenu")
    func theEscapePromiseIsKept() async throws {
        let rig = InterviewDictationRig()
        let driver = try await rig.listening()
        driver.emit(.turnEnded("Résumer des courriels."))
        #expect(await until { rig.view?.lastReply == "Résumer des courriels." })
        let promised = try #require(rig.view?.cancelHint)
        #expect(promised.hasPrefix("Échap annule l'entretien sans rien garder"))

        rig.controller.escapePressed()
        #expect(await until { driver.isFinished })
        await rig.nothingKept()
        #expect(rig.controller.view.draft.isEmpty && rig.controller.view.lastTranscript == nil, "aucun texte gardé")
    }

    // MARK: - T9-4 : les aides de la parole et de la réflexion

    @Test("T9-4 : l'aide « couper la parole » n'est montrée que quand la voix parle, jamais en texte seul")
    func theInterruptHintIsNeverShownInTextOnly() async throws {
        let rig = InterviewDictationRig()
        let driver = try await rig.listening()
        driver.emit(.speakingStarted(question: 1))
        #expect(await until { rig.view?.phase == .speaking })
        #expect(rig.view?.hint?.contains("couper la parole") == true)

        driver.emit(.notice(.voiceUnavailable))
        #expect(await until { rig.view?.textOnly == true })
        let hint = try #require(rig.view?.hint)
        #expect(!hint.contains("couper"), "en texte seul, personne ne parle : rien à couper")
        #expect(hint == InterviewText.hint(.speaking, textOnly: true))
    }

    @Test("T9-4 : pendant la réflexion, l'aide invite à parler ; ce qui est dit est montré dans « Vous »")
    func theThinkingHintIsKept() async throws {
        let rig = InterviewDictationRig()
        let driver = try await rig.listening()
        driver.emit(.turnEnded("Résumer des courriels."))
        driver.emit(.state(.thinking))
        #expect(await until { rig.view?.phase == .thinking })
        #expect(rig.view?.hint == InterviewText.hint(.thinking))
        #expect(rig.view?.hint?.hasPrefix("Parlez pour ajouter") == true)

        driver.emit(.partialTranscript("Et en français."))
        #expect(await until { rig.view?.shownReply == "Et en français." })
    }

    // MARK: - Règle 9, T9-3 : cohabitation

    @Test("règle 9, T9-3 : pendant l'entretien, occupé ; aucune dictée ne démarre, quel que soit l'appui ou la pastille")
    func noDictationDuringTheInterview() async throws {
        let rig = InterviewDictationRig()
        rig.interview.resolveGate = TestGate()
        rig.controller.hotKeyPressed()
        #expect(rig.controller.isBusy, "occupé dès la préparation")
        rig.interview.resolveGate?.open()
        let driver = try await rig.toListening()
        #expect(rig.controller.isBusy)

        rig.controller.modeChosen(ModeChip.rawID)
        rig.controller.modeHotKeyPressed(ModeChip.rawID)
        rig.controller.modeHotKeyPressed("perso-un")
        rig.controller.startCorrection()
        await settle()
        #expect(rig.dictation.engines.sessions.isEmpty)
        #expect(rig.controller.view == DictationViewState())
        #expect(driver.concludes == 0)
    }

    @Test("règle 9, T9-3 : pendant une dictée, le raccourci du mode Entretien est ignoré ; aucun entretien ne démarre")
    func noInterviewDuringADictation() async {
        let rig = InterviewDictationRig()
        rig.dictation.knobs.modeID = ModeChip.rawID
        let session = await rig.dictation.startRecording()
        rig.controller.modeHotKeyPressed(ModeChip.interviewID)
        await settle()
        #expect(rig.interview.resolveCount == 0 && rig.view == nil)
        #expect(rig.dictation.knobs.selectedModes.isEmpty)
        #expect(session.count(of: "finish") == 0)
        #expect(rig.controller.view.stage == .recording)
    }

    @Test("règle 9, T9-3 : en relecture, le raccourci du mode Entretien est ignoré, le global commence une correction")
    func duringAReviewTheInterviewHotKeyIsIgnored() async {
        let rig = InterviewDictationRig()
        rig.dictation.knobs.modeID = ModeChip.rawID
        rig.dictation.knobs.reviewing = [ModeChip.rawID]
        let session = await rig.dictation.startRecording()
        rig.controller.hotKeyPressed()
        session.emit(.finished("À relire."))
        #expect(await until { rig.controller.view.stage == .review })

        rig.controller.modeHotKeyPressed(ModeChip.interviewID)
        await settle()
        #expect(rig.interview.resolveCount == 0 && rig.view == nil)
        #expect(rig.controller.view.stage == .review)
        rig.controller.hotKeyPressed()
        #expect(rig.controller.view.stage == .correcting(.preparing))
        #expect(rig.interview.resolveCount == 0)
    }
}

extension InterviewPhase {
    fileprivate init(_ moment: DictationInterviewTests.Moment) {
        switch moment {
        case .preparing: self = .preparing
        case .listening: self = .listening
        case .thinking: self = .thinking
        case .speaking: self = .speaking
        case .concluding: self = .concluding
        }
    }
}
