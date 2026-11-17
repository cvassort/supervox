import Foundation
import SupervoxCore
import Testing

@testable import SupervoxApp

/// Le contrôleur de l'entretien seul : ce qu'il fait des événements du moteur (amendement C), ses fins (règles 5, 7, 8), sa
/// conclusion unique et la durée de vie de la conversation (amendement B), le départ refusé (règle 2). Conversation, environnement
/// et historique doubles ; vraie résolution sur un trousseau en mémoire.
@MainActor @Suite(.timeLimit(.minutes(1))) struct InterviewControllerTests {
    typealias Phase = InterviewPhase

    /// L'issue de l'entretien, attendue.
    func outcome(_ rig: InterviewRig) async throws -> InterviewOutcome {
        try #require(await until { !rig.outcomes.isEmpty }, "aucune issue")
        return rig.outcomes[0]
    }

    /// Émet puis attend que le panneau le montre.
    func emit(_ event: ConversationEvent, _ driver: ConversationDriver, _ rig: InterviewRig, until shown: @MainActor (InterviewViewState) -> Bool) async throws {
        driver.emit(event)
        try #require(await until { rig.panel.interview.map(shown) ?? false }, "\(event)")
    }

    // MARK: - Départ

    @Test("règle 1 : résolution, puis préparation, puis fabrication, puis démarrage ; le panneau montre la préparation jusqu'au premier état")
    func theStartOrderIsResolvePrepareMakeStart() async throws {
        let rig = InterviewRig()
        let gate = TestGate()
        defer { gate.open() }
        rig.resolveGate = gate
        rig.start()
        #expect(rig.controller.isActive)
        #expect(rig.panel.interview?.phase == .preparing)
        #expect(await until { rig.resolveCount == 1 })
        #expect(rig.environment.prepareCount == 0, "rien n'est préparé avant la résolution")
        gate.open()

        let driver = try await rig.driver()
        #expect(rig.journal.entries == ["résolution", "préparation", "fabrication", "conversation démarrée"])
        #expect(rig.panel.interview?.phase == .preparing)
        try await emit(.state(.preparing), driver, rig) { $0.phase == .preparing }
        try await emit(.state(.listening), driver, rig) { $0.phase == .listening }
    }

    @Test("amendement I : la préparation reçoit le moteur du mode et le silence de fin de tour normalisé")
    func preparationReceivesTheEngineAndTheNormalizedTurnSilence() async throws {
        let rig = InterviewRig()
        rig.settings.interview.turnSilence = 9
        rig.controller.start(engine: .whisperKit) { _ in }
        _ = try await rig.driver()
        let setup = try #require(rig.environment.preparedSetups.first)
        #expect(setup.engine == .whisperKit)
        #expect(setup.turnSilence == InterviewSettings.turnSilenceRange.upperBound)
    }

    @Test("un second lancement pendant un entretien est sans effet")
    func aSecondStartIsIgnored() async throws {
        let rig = InterviewRig()
        _ = try await rig.listening()
        rig.start()
        await settle()
        #expect(rig.environment.makeCount == 1)
        #expect(rig.resolveCount == 1)
    }

    @Test("la note de maintien suit le réglage, lu au lancement ; la vie privée vient de la résolution")
    func theHoldNoteAndThePrivacyLine() async throws {
        let hold = InterviewRig()
        hold.behavior = .hold
        hold.start()
        #expect(hold.panel.interview?.holdNote == true)
        let toggle = InterviewRig()
        toggle.start()
        #expect(toggle.panel.interview?.holdNote == false)
        #expect(await until { toggle.environment.prepareCount == 1 })
        #expect(
            toggle.panel.interview?.privacy
                == InterviewText.privacy(
                    provider: "Fournisseur d'exemple", strongProvider: "Fournisseur d'exemple", voiceProvider: nil))
        hold.controller.cancel()
        toggle.controller.cancel()
    }

    // MARK: - Règle 2 : refus

    static let refusals: [(String, @Sendable (inout AppSettings) -> Void, InterviewSetupFailure)] = [
        ("sans modèle rapide", { $0.fastModel = nil }, .noFastModel),
        ("sans modèle fort", { $0.strongModel = nil }, .noStrongModel),
        ("fournisseur disparu", { $0.providers = [] }, .provider(.providerMissing)),
        ("adresse refusée", { $0.providers[0].baseURL = "pas une adresse" }, .provider(.unreachable)),
    ]

    @Test("règle 2 : un refus de la résolution dit sa phrase, sans rien préparer ni fabriquer", arguments: 0..<4)
    func aRefusalSaysItsSentenceAndPreparesNothing(index: Int) async throws {
        let (name, change, failure) = Self.refusals[index]
        let rig = InterviewRig()
        change(&rig.settings)
        rig.start()
        let outcome = try await outcome(rig)
        #expect(outcome == .notice(InterviewText.setupFailure(failure)), "\(name)")
        #expect(rig.environment.prepareCount == 0)
        #expect(rig.environment.makeCount == 0)
        #expect(rig.panel.interview == nil)
        #expect(!rig.controller.isActive)
    }

    @Test("règle 2 : sans clé, la phrase nomme le fournisseur ; rien n'est préparé")
    func withoutAKeyTheSentenceNamesTheProvider() async throws {
        let rig = InterviewRig()
        try rig.secrets.delete(account: InterviewRig.provider.id.uuidString)
        rig.start()
        #expect(try await outcome(rig) == .notice(InterviewText.setupFailure(.provider(.noKey(provider: "Fournisseur d'exemple")))))
        #expect(rig.environment.prepareCount == 0)
    }

    @Test("amendement A : une préparation ou une fabrication qui lève dit « L'entretien n'a pas pu démarrer », sans conversation")
    func aFailingEnvironmentSaysItCouldNotStart() async throws {
        for failing in ["préparation", "fabrication"] {
            let rig = InterviewRig()
            rig.environment.configure {
                if failing == "préparation" { $0.prepareError = InterviewEnvironment.Unavailable() } else {
                    $0.makeError = InterviewEnvironment.Unavailable()
                }
            }
            rig.start()
            #expect(try await outcome(rig) == .notice(InterviewText.couldNotStart), "\(failing)")
            #expect(rig.environment.drivers.isEmpty)
            #expect(rig.panel.interview == nil)
        }
    }

    // MARK: - Amendement C : la table des événements

    @Test("C : écoute, aperçu, fin de tour (sans changer la phase), et l'aperçu d'un passage sans texte disparaît à l'écoute")
    func listeningPartialAndTurnEnded() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        try await emit(.partialTranscript("Je voudrais"), driver, rig) { $0.lastReply == "Je voudrais" }
        try await emit(.turnEnded("Je voudrais un résumé."), driver, rig) { $0.lastReply == "Je voudrais un résumé." }
        #expect(rig.panel.interview?.phase == .listening, "la fin d'un tour ne change pas la phase")
        try await emit(.state(.thinking), driver, rig) { $0.phase == .thinking }
        try await emit(.state(.listening), driver, rig) { $0.phase == .listening }
        #expect(rig.panel.interview?.lastReply == "Je voudrais un résumé.", "une réponse finie reste")
        try await emit(.partialTranscript("euh"), driver, rig) { $0.lastReply == "euh" }
        try await emit(.notice(.notUnderstood), driver, rig) { $0.notice != nil }
        try await emit(.state(.listening), driver, rig) { $0.lastReply == "Je voudrais un résumé." }
    }

    @Test("C : la parole remet le texte à vide, le compteur ne recule jamais, la question 0 n'est jamais un numéro")
    func speakingStartedCounterAndText() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        try await emit(.speakingStarted(question: 0), driver, rig) { $0.phase == .speaking }
        #expect(rig.panel.interview?.question == 0)
        try await emit(.sentencePlayed("Quel est le but ?"), driver, rig) { $0.questionText == "Quel est le but ?" }
        try await emit(.speakingStarted(question: 2), driver, rig) { $0.question == 2 }
        #expect(rig.panel.interview?.questionText == "", "le texte de la nouvelle question repart de vide")
        try await emit(.speakingStarted(question: 1), driver, rig) { $0.questionText == "" }
        try await emit(.sentencePlayed("Pour qui ?"), driver, rig) { $0.questionText == "Pour qui ?" }
        #expect(rig.panel.interview?.question == 2, "max(compteur, n)")
    }

    @Test("C : les phrases JOUÉES s'ajoutent ; le texte généré est ignoré quand la voix parle ; fin de parole = ce qui a été entendu")
    func sentencesPlayedReplyTextIgnoredAndHeard() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        try await emit(.state(.thinking), driver, rig) { $0.phase == .thinking }
        driver.emit(.replyText("Première phrase. Seconde phrase qui n'a pas"))
        try await emit(.speakingStarted(question: 1), driver, rig) { $0.phase == .speaking }
        try await emit(.sentencePlayed("Première phrase."), driver, rig) { $0.questionText == "Première phrase." }
        driver.emit(.replyText("Première phrase. Seconde phrase qui n'a pas été jouée."))
        try await emit(.sentencePlayed("Seconde phrase."), driver, rig) {
            $0.questionText == "Première phrase. Seconde phrase."
        }
        try await emit(.interrupted(heard: "Première phrase."), driver, rig) { $0.questionText == "Première phrase." }
        try await emit(.state(.listening), driver, rig) { $0.phase == .listening }
        try await emit(.state(.thinking), driver, rig) { $0.phase == .thinking }
        driver.emit(.interrupted(heard: ""))
        try await emit(.state(.listening), driver, rig) { $0.phase == .listening }
        #expect(rig.panel.interview?.questionText == "Première phrase.", "rien entendu : la question précédente reste")
        try await emit(.speakingStarted(question: 2), driver, rig) { $0.question == 2 }
        try await emit(.speakingEnded(heard: "Tout."), driver, rig) { $0.questionText == "Tout." }
    }

    @Test("C : en texte seul (voix indisponible), le texte reçu remplit la question, y compris celui arrivé avant l'affichage")
    func inTextOnlyTheReplyTextIsTheQuestion() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        try await emit(.state(.thinking), driver, rig) { $0.phase == .thinking }
        driver.emit(.replyText("Quel est"))
        try await emit(.notice(.voiceUnavailable), driver, rig) { $0.textOnly }
        #expect(rig.panel.interview?.notice == InterviewText.notice(.voiceUnavailable))
        try await emit(.speakingStarted(question: 1), driver, rig) { $0.questionText == "Quel est" }
        try await emit(.replyText("Quel est le but ?"), driver, rig) { $0.questionText == "Quel est le but ?" }
        #expect(rig.panel.interview?.title == InterviewText.title(.speaking, textOnly: true))
        // Un avis plus récent remplace celui de la voix ; le texte seul reste.
        try await emit(.notice(.proposal), driver, rig) { $0.notice == InterviewText.notice(.proposal) }
        #expect(rig.panel.interview?.textOnly == true)
    }

    @Test("C : le niveau n'est suivi qu'à l'écoute")
    func theLevelFollowsOnlyWhileListening() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        try await emit(.level(0.6), driver, rig) { $0.level == 0.6 }
        try await emit(.state(.thinking), driver, rig) { $0.phase == .thinking }
        driver.emit(.level(0.9))
        try await emit(.speakingStarted(question: 1), driver, rig) { $0.phase == .speaking }
        driver.emit(.level(0.2))
        try await emit(.state(.listening), driver, rig) { $0.phase == .listening }
        #expect(rig.panel.interview?.level == 0.6)
    }

    @Test("C, D : un avis est la phrase de la table ; la voix de secours reste dite ; un avis identique est redit à VoiceOver")
    func noticesAndTheirAnnouncements() async throws {
        let rig = InterviewRig()
        var spoken: [String] = []
        rig.panel.onAnnounce = { spoken.append($0) }
        let driver = try await rig.listening()
        try await emit(.notice(.voiceFellBack), driver, rig) { $0.notice == InterviewText.notice(.voiceFellBack) }
        try await emit(.state(.thinking), driver, rig) { $0.phase == .thinking }
        try await emit(.state(.listening), driver, rig) { $0.phase == .listening }
        #expect(rig.panel.interview?.notice == InterviewText.notice(.voiceFellBack), "l'avis de la voix reste")
        #expect(rig.panel.interview?.textOnly == false)
        try await emit(.notice(.notUnderstood), driver, rig) { $0.notice == InterviewText.notice(.notUnderstood) }
        driver.emit(.notice(.notUnderstood))
        #expect(await until { spoken.filter { $0 == InterviewText.notice(.notUnderstood) }.count == 2 })
    }

    @Test("C : la conclusion est définitive ; les derniers mots arrivent encore (conclusion demandée : concluding avant turnEnded)")
    func concludingIsFinalAndTheLastWordsStillArrive() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        rig.panel.concludeInterview()
        #expect(await until { driver.concludes == 1 })
        try await emit(.state(.concluding), driver, rig) { $0.phase == .concluding }
        try await emit(.turnEnded("Derniers mots."), driver, rig) { $0.lastReply == "Derniers mots." }
        for event: ConversationEvent in [.state(.listening), .state(.thinking), .state(.speaking), .speakingStarted(question: 3), .state(.preparing)] {
            driver.emit(event)
        }
        try await emit(.sentencePlayed("Merci."), driver, rig) { $0.questionText == "Merci." }
        #expect(rig.panel.interview?.phase == .concluding, "plus rien ne ramène une autre phase")
        #expect(rig.panel.interview?.question == 3)
    }

    @Test("C : à la limite de questions, turnEnded arrive avant concluding")
    func atTheQuestionLimitTurnEndedComesFirst() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        try await emit(.turnEnded("Ma dernière réponse."), driver, rig) { $0.lastReply == "Ma dernière réponse." }
        try await emit(.state(.concluding), driver, rig) { $0.phase == .concluding }
        #expect(rig.panel.interview?.lastReply == "Ma dernière réponse.")
    }

    @Test("C : la préparation ne revient jamais une fois quittée")
    func preparingNeverComesBack() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        driver.emit(.state(.preparing))
        try await emit(.state(.thinking), driver, rig) { $0.phase == .thinking }
        driver.emit(.state(.preparing))
        try await emit(.level(0), driver, rig) { _ in true }
        await settle()
        #expect(rig.panel.interview?.phase == .thinking)
    }

    // MARK: - Amendement B : une seule conclusion, la durée de vie

    @Test("B : deux conclude() directs, puis le bouton : un seul conclude() au moteur")
    func oneConclusionOnly() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        rig.controller.conclude()
        rig.controller.conclude()
        rig.panel.concludeInterview()
        await settle()
        #expect(driver.concludes == 1)
    }

    @Test("B : avant que la conversation démarre, conclure est sans effet")
    func concludingBeforeTheConversationStartsDoesNothing() async throws {
        let rig = InterviewRig()
        let gate = TestGate()
        defer { gate.open() }
        rig.environment.configure { $0.makeGate = gate }
        rig.start()
        #expect(await until { rig.environment.makeCount == 1 })
        rig.controller.conclude()
        gate.open()
        let driver = try await rig.driver()
        driver.emit(.state(.listening))
        #expect(await until { rig.panel.interview?.phase == .listening })
        #expect(driver.concludes == 0)
        rig.controller.conclude()
        #expect(await until { driver.concludes == 1 })
    }

    @Test("B : la conversation est tenue pendant l'entretien et libérée après sa fin")
    func theConversationLivesUntilItsEnd() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        try await emit(.state(.thinking), driver, rig) { $0.phase == .thinking }
        #expect(rig.environment.conversationIsAlive(0), "tenue pendant l'entretien")
        driver.finish(.nothingSaid)
        _ = try await outcome(rig)
        #expect(await until { !rig.environment.conversationIsAlive(0) }, "libérée après la fin")
    }

    // MARK: - Règles 5 et 8 : les fins

    static let exchange = InterviewRig.conversation([
        (.interviewer, "Quel est le but ?"), (.user, "Résumer des courriels."),
    ])

    @Test("règles 5, 8 : le prompt va en relecture avec sa phrase, et l'entretien est enregistré avec sa conversation")
    func aPromptGoesToReviewAndIsSaved() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        driver.finish(.prompt("Rédige un résumé.", Self.exchange))
        #expect(try await outcome(rig) == .review(text: "Rédige un résumé.", notice: InterviewText.promptReview))
        #expect(rig.panel.interview == nil)
        #expect(!rig.controller.isActive)
        #expect(await until { rig.history.saved.count == 1 })
        let record = try #require(rig.history.saved.first)
        #expect(record.prompt == "Rédige un résumé.")
        #expect(record.conversation == Self.exchange)
        #expect(record.date == rig.date)
    }

    @Test("D : les derniers mots perdus, puis le prompt : la phrase de la relecture le dit")
    func lastWordsLostThenPrompt() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        try await emit(.notice(.lastWordsLost), driver, rig) { $0.notice == InterviewText.notice(.lastWordsLost) }
        driver.finish(.prompt("P.", Self.exchange))
        #expect(try await outcome(rig) == .review(text: "P.", notice: InterviewText.promptReviewWithoutLastWords))
    }

    @Test("règles 5, 8 : la conclusion en échec : la conversation en relecture, enregistrée sans prompt")
    func aFailedConclusionReviewsTheConversation() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        driver.finish(.conclusionFailed(.server(503), Self.exchange))
        #expect(try await outcome(rig) == .review(text: Self.exchange.transcript, notice: InterviewText.conclusionFailedReview))
        #expect(await until { rig.history.saved.count == 1 })
        #expect(rig.history.saved.first?.prompt == nil)
        #expect(rig.history.saved.first?.conversation == Self.exchange)
    }

    static let failures: [(ConversationEnd, InterviewOutcome)] = [
        (.failed(.microphone("silent"), exchange),
         .review(text: exchange.transcript, notice: InterviewText.microphoneStoppedReview)),
        (.failed(.engine("transcriptionFailed"), exchange),
         .review(text: exchange.transcript, notice: InterviewText.transcriptionStoppedReview)),
        (.failed(.microphone("silent"), InterviewRig.conversation([(.interviewer, "Bonjour.")])),
         .notice(InterviewText.microphoneSentNothing)),
        (.failed(.engine("transcriptionFailed"), Conversation()), .notice(InterviewText.transcriptionDidNotStart)),
        (.nothingSaid, .notice(InterviewText.nothingSaid)),
        (.cancelled, .cancelled),
    ]

    @Test("règles 5, 8 : une panne après un tour va en relecture, sans tour elle se dit ; rien de cela n'est enregistré", arguments: 0..<6)
    func failuresAndNothingSaidAreNotSaved(index: Int) async throws {
        let (end, expected) = Self.failures[index]
        let rig = InterviewRig()
        let driver = try await rig.listening()
        driver.finish(end)
        #expect(try await outcome(rig) == expected)
        await settle()
        #expect(rig.history.attempts == 0)
        #expect(rig.panel.interview == nil)
    }

    @Test("règle 8 : la relecture n'attend pas l'historique, et une panne de l'historique ne l'empêche pas")
    func theHistoryIsNotAwaitedAndItsFailureIsHarmless() async throws {
        let held = InterviewRig()
        let gate = TestGate()
        defer { gate.open() }
        held.history.configure(gate: gate)
        let driver = try await held.listening()
        driver.finish(.prompt("P.", Self.exchange))
        #expect(try await outcome(held) == .review(text: "P.", notice: InterviewText.promptReview))
        #expect(await until { held.history.attempts == 1 })
        #expect(held.history.saved.isEmpty, "l'enregistrement est encore retenu")
        gate.open()
        #expect(await until { held.history.saved.count == 1 })

        let failing = InterviewRig()
        failing.history.configure(fails: true)
        let second = try await failing.listening()
        second.finish(.prompt("P.", Self.exchange))
        #expect(try await outcome(failing) == .review(text: "P.", notice: InterviewText.promptReview))
        #expect(await until { failing.history.attempts == 1 })
    }

    // MARK: - Règle 7 : l'annulation, à chaque étape

    enum Stage: String, CaseIterable { case resolving, preparing, making, starting, listening, concluding }

    @Test("règle 7 : annuler à chaque étape : issue « annulé », une seule fois, vue retirée, rien enregistré, aucune conversation démarrée après", arguments: Stage.allCases)
    func cancellingAtEachStage(stage: Stage) async throws {
        let rig = InterviewRig()
        let gate = TestGate()
        defer { gate.open() }
        switch stage {
        case .resolving: rig.resolveGate = gate
        case .preparing: rig.environment.configure { $0.prepareGate = gate }
        case .making: rig.environment.configure { $0.makeGate = gate }
        case .starting: rig.environment.configure { $0.startGate = gate }
        case .listening, .concluding: break
        }
        var driver: ConversationDriver?
        switch stage {
        case .resolving:
            rig.start()
            #expect(await until { rig.resolveCount == 1 })
        case .preparing:
            rig.start()
            #expect(await until { rig.environment.prepareCount == 1 })
        case .making:
            rig.start()
            #expect(await until { rig.environment.makeCount == 1 })
        case .starting:
            rig.start()
            driver = try await rig.driver()
        case .listening:
            driver = try await rig.listening()
        case .concluding:
            let listening = try await rig.listening()
            driver = listening
            rig.panel.concludeInterview()
            try await emit(.state(.concluding), listening, rig) { $0.phase == .concluding }
        }

        rig.controller.cancel()
        rig.controller.cancel()
        #expect(rig.outcomes == [.cancelled])
        #expect(rig.panel.interview == nil)
        #expect(!rig.controller.isActive)
        gate.open()
        if let driver {
            // Annulé pendant `start()` : la première demande arrive avant le démarrage (ignorée par le moteur) ; le contrôleur la refait.
            #expect(await until { driver.cancels >= 1 }, "le moteur reçoit l'annulation, une fois démarré")
            #expect(await until { driver.isFinished }, "le micro est rendu")
            // Un `.finished` tardif ne touche plus rien.
            driver.finish(.prompt("Tardif.", Self.exchange))
        }
        await settle()
        #expect(rig.outcomes == [.cancelled], "une seule issue")
        #expect(rig.history.attempts == 0)
        #expect(rig.panel.interview == nil)
        if driver == nil {
            #expect(rig.environment.drivers.allSatisfy { $0.starts == 0 }, "aucune conversation démarrée après l'annulation")
        }
    }

    @Test("jeton : un entretien annulé pendant sa fabrication ne touche pas le suivant, et sa conversation n'est jamais démarrée")
    func aCancelledAttemptDoesNotTouchTheNextOne() async throws {
        let rig = InterviewRig()
        let gate = TestGate()
        defer { gate.open() }
        rig.environment.configure { $0.makeGate = gate }
        rig.start()
        #expect(await until { rig.environment.makeCount == 1 })
        rig.controller.cancel()
        rig.environment.configure { $0.makeGate = nil }
        rig.start()
        #expect(rig.controller.isActive)
        #expect(rig.panel.interview?.phase == .preparing)
        gate.open()
        let second = try await rig.driver(1)
        second.emit(.state(.listening))
        #expect(await until { rig.panel.interview?.phase == .listening })
        let first = try #require(rig.environment.drivers.first)
        #expect(first.starts == 0, "la conversation fabriquée après l'annulation n'est jamais démarrée")
        #expect(await until { !rig.environment.conversationIsAlive(0) }, "et elle est lâchée")
        #expect(rig.outcomes == [.cancelled])
        #expect(rig.controller.isActive)
    }

    @Test("le micro d'abord : après une annulation, la suite attend que la conversation ait rendu la main")
    func theNextStartWaitsForTheCancelledConversation() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        let cancelGate = TestGate()
        defer { cancelGate.open() }
        driver.configure(cancelGate: cancelGate)
        rig.controller.cancel()
        #expect(await until { driver.cancels == 1 })
        let resolvedBefore = rig.resolveCount

        var waited = false
        let waiter = Task { @MainActor in
            await rig.controller.waitUntilStopped()
            waited = true
        }
        rig.start()
        await settle()
        #expect(!waited, "la conversation annulée n'a pas encore rendu le micro")
        #expect(rig.resolveCount == resolvedBefore, "le suivant attend avant même de résoudre")
        cancelGate.open()
        #expect(await until { waited }, "rendu une fois la conversation arrêtée")
        _ = waiter
        _ = try await rig.driver(1)
        let stopped = try #require(rig.journal.index(of: "audio arrêté"))
        let resolvedAgain = try #require(rig.journal.entries.lastIndex(of: "résolution"))
        #expect(stopped < resolvedAgain, "la résolution du suivant vient après l'arrêt de l'audio")
    }

    @Test("attendre l'arrêt rend la main à l'annulation de la tâche qui attend")
    func waitingForTheStopReturnsOnCancellation() async throws {
        let rig = InterviewRig()
        let driver = try await rig.listening()
        let cancelGate = TestGate()
        defer { cancelGate.open() }
        driver.configure(cancelGate: cancelGate)
        rig.controller.cancel()
        var returned = false
        let waiter = Task { @MainActor in
            await rig.controller.waitUntilStopped()
            returned = true
        }
        await settle()
        #expect(!returned)
        waiter.cancel()
        #expect(await until { returned })
        #expect(!driver.isFinished, "rendu par l'annulation, pas par l'arrêt")
    }
}
