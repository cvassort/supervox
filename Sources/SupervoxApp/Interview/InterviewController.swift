import Foundation
import SupervoxCore
import os

/// Comment un entretien s'est terminé, vu du contrôleur de dictée : ce qu'il doit montrer ensuite.
public enum InterviewOutcome: Equatable, Sendable {
    /// Le texte va en relecture (prompt rédigé, ou conversation gardée après une panne), avec sa phrase.
    case review(text: String, notice: String)
    /// Rien à relire : le panneau dit pourquoi (refus au départ, rien dit, panne avant le premier tour).
    case notice(String)
    /// Annulé (Échap, fermeture du panneau, Réglages, Quitter) : rien à montrer, rien de gardé.
    case cancelled
}

/// Ce que le contrôleur de dictée sait de l'entretien : il le lance, le conclut, l'annule, et attend que son micro soit rendu.
@MainActor
public protocol InterviewRunning: AnyObject {
    /// Vrai du lancement jusqu'à la fin : résolution, préparation, conversation, conclusion. Faux dès que `onEnd` est appelé.
    var isActive: Bool { get }
    /// Lance un entretien ; sans effet s'il y en a déjà un. `onEnd` est appelé une seule fois, à la fin, quelle qu'elle soit
    /// (`cancel()` compris, pendant l'appel).
    func start(engine: TranscriptionEngine?, onEnd: @escaping @MainActor (InterviewOutcome) -> Void)
    /// Demande la conclusion au moteur ; une seule fois par entretien, sans effet avant que la conversation ait démarré.
    func conclude()
    /// Annule l'entretien en cours (rien n'est gardé) ; sans effet sans entretien.
    func cancel()
    /// Rend la main quand la conversation précédente a rendu le micro (son `cancel()` ou sa fin a rendu la main), ou quand la tâche
    /// qui attend est annulée. Sans conversation en cours d'arrêt, rend aussitôt.
    func waitUntilStopped() async
}

/// Mène un entretien : résout les réglages, prépare les moteurs, construit la conversation, lit ses événements et en tire l'état
/// du panneau (`PanelModel.setInterview`), puis rend une issue au contrôleur de dictée.
///
/// Règles de conception :
/// - Un lancement est une `Attempt`, relue après chaque `await` (comme une `Run` de la dictée) : une conversation fabriquée après
///   une annulation n'est jamais démarrée, et ce qui arrive d'un entretien annulé ne touche plus ni le panneau ni l'historique.
/// - La conversation est tenue fortement de sa fabrication à la fin de son flux (la façade annule l'entretien quand elle est
///   libérée), par la tâche qui lit ce flux : une tâche du contrôleur, pas de la vue. Cette tâche ne s'arrête qu'à la fin du flux,
///   que le moteur ne termine qu'après `.finished`, son micro arrêté ; `cancel()` demande l'arrêt au moteur et la laisse lire
///   jusque-là, ce qui garde le micro sous contrôle jusqu'à son arrêt réel.
/// - La phase montrée ne revient jamais en arrière : jamais à la préparation une fois quittée, jamais hors de la conclusion.
/// - Aucune phrase montrée ne vient d'une erreur : `InterviewText` seulement. Le journal ne porte que la nature d'un fait.
@MainActor
public final class InterviewController: InterviewRunning {
    private let environment: InterviewEnvironment
    private let settings: @MainActor () -> AppSettings
    private let behavior: @MainActor () -> HotKeyBehavior
    private let resolve: @MainActor (AppSettings, TranscriptionEngine?) async throws -> InterviewSetup
    private let history: any InterviewHistoryStoring
    private let panel: PanelModel
    private let now: @Sendable () -> Date
    private let saveWait: @Sendable (Double) async throws -> Void
    private let log = Logger(subsystem: "dev.supervox.app", category: "interview")

    /// L'entretien en cours, `nil` hors entretien.
    private var current: Attempt?
    /// Les tâches de chaque entretien pas encore terminées (résolution, préparation, lecture du flux d'une conversation finie ou
    /// annulée qui s'arrête), et ceux qui attendent leur fin.
    private var stopping: [ObjectIdentifier: (attempt: Attempt, reader: Task<Void, Never>)] = [:]
    private var stopWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// - Parameters:
    ///   - settings: les réglages en vigueur, lus une fois au lancement.
    ///   - behavior: bascule ou maintien, lu au lancement (en maintien, la vue dit qu'un appui conclut).
    ///   - resolve: la résolution des réglages (`InterviewSetup.resolve` dans l'application ; un double dans les tests).
    ///   - history: où va un entretien conclu.
    ///   - panel: le modèle du panneau, où l'état de l'entretien est posé.
    public init(
        environment: InterviewEnvironment, settings: @escaping @MainActor () -> AppSettings,
        behavior: @escaping @MainActor () -> HotKeyBehavior,
        resolve: @escaping @MainActor (AppSettings, TranscriptionEngine?) async throws -> InterviewSetup,
        history: any InterviewHistoryStoring, panel: PanelModel, now: @escaping @Sendable () -> Date = Date.init,
        saveWait: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.environment = environment
        self.settings = settings
        self.behavior = behavior
        self.resolve = resolve
        self.history = history
        self.panel = panel
        self.now = now
        self.saveWait = saveWait
    }

    public var isActive: Bool { current != nil }

    // MARK: - Lancement

    public func start(engine: TranscriptionEngine?, onEnd: @escaping @MainActor (InterviewOutcome) -> Void) {
        guard current == nil else { return }
        let settings = settings()
        let attempt = Attempt(onEnd: onEnd)
        current = attempt
        // Posé tout de suite : le panneau montre la préparation pendant la résolution (le trousseau peut demander une autorisation),
        // le téléchargement et le chargement des moteurs. La ligne de vie privée est celle des réglages ; elle est reprise de la
        // résolution dès qu'elle est faite (la voix de fournisseur peut y retomber sur celle du système).
        var view = InterviewViewState(
            maxQuestions: settings.interview.normalized.maxQuestions, privacy: Self.privacy(before: settings))
        view.holdNote = behavior() == .hold
        attempt.view = view
        panel.setInterview(view)
        log.notice("entretien lancé")
        let task = Task { [weak self] in _ = await self?.run(attempt, settings: settings, engine: engine) }
        attempt.reader = task
        stopping[ObjectIdentifier(attempt)] = (attempt, task)
        Task { [weak self] in
            await task.value
            self?.readerFinished(attempt)
        }
    }

    /// La ligne de vie privée avant la résolution : les noms des fournisseurs des deux modèles tels que les réglages les donnent,
    /// sans voix de fournisseur (rien n'est encore envoyé).
    private static func privacy(before settings: AppSettings) -> String {
        func name(_ choice: ModelChoice?) -> String {
            guard let id = choice?.providerID else { return "" }
            return settings.providers.first { $0.id == id }?.name ?? ""
        }
        // Un modèle absent ou sans fournisseur : la résolution va le refuser, la ligne ne nomme personne.
        guard !name(settings.fastModel).isEmpty, !name(settings.strongModel).isEmpty else { return "" }
        return InterviewText.privacy(
            provider: name(settings.fastModel), strongProvider: name(settings.strongModel), voiceProvider: nil)
    }

    private func run(_ attempt: Attempt, settings: AppSettings, engine: TranscriptionEngine?) async {
        // Un entretien précédent annulé rend d'abord son micro.
        await waitForOthers(than: attempt)
        guard isLive(attempt) else { return }
        let setup: InterviewSetup
        do {
            setup = try await resolve(settings, engine)
        } catch let failure as InterviewSetupFailure {
            guard isLive(attempt) else { return }
            log.notice("entretien refusé : \(self.kind(of: failure), privacy: .public)")
            end(attempt, .notice(InterviewText.setupFailure(failure)))
            return
        } catch {
            guard isLive(attempt) else { return }
            log.notice("entretien non résolu")
            end(attempt, .notice(InterviewText.couldNotStart))
            return
        }
        guard isLive(attempt) else { return }
        update(attempt) { $0.privacy = setup.privacy }
        let prepared: InterviewPreparation
        do {
            prepared = try await environment.prepare(setup)
        } catch {
            guard isLive(attempt) else { return }
            log.notice("entretien : préparation échouée")
            end(attempt, .notice(InterviewText.couldNotStart))
            return
        }
        guard isLive(attempt) else { return }
        // Le vocabulaire qui ne sert pas (petit modèle absent, liste trop longue) : l'avis le dit dès la préparation.
        if let notice = prepared.notice { update(attempt) { $0.notice = notice } }
        let conversation: any ConversationEngine
        do {
            conversation = try await environment.makeConversation(prepared.setup)
        } catch {
            guard isLive(attempt) else { return }
            log.notice("entretien : conversation non construite")
            end(attempt, .notice(InterviewText.couldNotStart))
            return
        }
        // Annulé pendant la fabrication : la conversation n'est jamais démarrée (aucun micro) et se libère ici.
        guard isLive(attempt) else { return }
        attempt.conversation = conversation
        attempt.holdsConversation = true
        let events = await conversation.start()
        attempt.started = true
        // Annulé pendant `start()` : la demande d'arrêt partie de `cancel()` a pu arriver avant le démarrage (le moteur ignore un
        // `cancel()` reçu avant `start()`). Elle est refaite ici, le micro ouvert : il ne reste pas ouvert sans personne.
        if !isLive(attempt) { await conversation.cancel() }
        // Conclure demandé pendant `start()` : gardé jusqu'ici (le moteur l'aurait ignoré), envoyé maintenant, une seule fois.
        if isLive(attempt), attempt.concludePending { Task { await conversation.conclude() } }
        // Lu jusqu'à la fin du flux, même après `.finished` ou une annulation : le moteur ne le termine qu'une fois son micro arrêté.
        // La conversation reste tenue jusque-là, et ce qui attend le micro (`waitUntilStopped`) aussi.
        for await event in events {
            if case .finished(let end) = event {
                await finished(end, attempt)
                continue
            }
            guard isLive(attempt) else { continue }
            handle(event, attempt)
        }
        attempt.conversation = nil
    }

    /// La lecture du flux de cet entretien est finie : son micro est rendu, ceux qui attendaient reprennent.
    private func readerFinished(_ attempt: Attempt) {
        stopping[ObjectIdentifier(attempt)] = nil
        attempt.conversation = nil
        // Un flux qui finirait sans `.finished` (contrat rompu) ne laisse pas l'entretien ouvert.
        if isLive(attempt) {
            log.notice("entretien : flux terminé sans fin")
            end(attempt, .notice(InterviewText.couldNotStart))
        }
        guard !isStoppingFinishedAttempts else { return }
        let waiters = stopWaiters
        stopWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    /// Une conversation d'un entretien fini (annulé, le plus souvent) n'a pas encore rendu son micro. Celle de l'entretien en cours
    /// ne compte pas : elle n'a rien à rendre tant qu'il dure. Un entretien annulé avant d'avoir une conversation (résolution,
    /// préparation, fabrication) ne compte pas non plus : il n'a ouvert aucun micro, une dictée n'attend pas son trousseau ni son
    /// téléchargement.
    private var isStoppingFinishedAttempts: Bool {
        stopping.values.contains { !isLive($0.attempt) && $0.attempt.holdsConversation }
    }

    /// Un entretien qui commence attend la fin de toutes les tâches des précédents, y compris leur préparation : deux préparations
    /// des mêmes moteurs ne se croisent pas.
    private func waitForOthers(than attempt: Attempt) async {
        let others = stopping.filter { $0.key != ObjectIdentifier(attempt) }.map(\.value.reader)
        for other in others { await other.value }
    }

    public func waitUntilStopped() async {
        guard isStoppingFinishedAttempts else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if !isStoppingFinishedAttempts || Task.isCancelled {
                    continuation.resume()
                } else {
                    stopWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopWaiters.removeValue(forKey: id)?.resume() }
        }
    }

    // MARK: - Conclure, annuler

    public func conclude() {
        guard let attempt = current, let conversation = attempt.conversation, !attempt.concludeSent else { return }
        attempt.concludeSent = true
        log.notice("entretien : conclusion demandée")
        // Pendant `start()`, le moteur ignorerait la demande : elle part dès le démarrage fini (`run`), jamais perdue.
        guard attempt.started else {
            attempt.concludePending = true
            return
        }
        Task { await conversation.conclude() }
    }

    public func cancel() {
        guard let attempt = current else { return }
        log.notice("entretien annulé")
        if let conversation = attempt.conversation {
            // La lecture continue jusqu'à `.finished(.cancelled)` : elle tient la conversation jusqu'à l'arrêt de son micro.
            Task { await conversation.cancel() }
        } else {
            // Avant la conversation : la résolution, la préparation ou la fabrication s'arrêtent.
            attempt.reader?.cancel()
        }
        end(attempt, .cancelled)
    }

    // MARK: - Événements

    private func handle(_ event: ConversationEvent, _ attempt: Attempt) {
        switch event {
        case .state(let state):
            guard let phase = InterviewPhase(state) else { return }
            update(attempt) { view in
                // Jamais de retour en arrière : la préparation n'est que le début, la conclusion est définitive.
                guard view.phase != .concluding, phase != .preparing else { return }
                view.phase = phase
                switch phase {
                case .listening:
                    // L'aperçu d'un passage qui n'a rien donné disparaît : la dernière réponse dite revient.
                    if attempt.replyIsPartial {
                        view.lastReply = attempt.lastFinalReply
                        attempt.replyIsPartial = false
                    }
                case .thinking:
                    attempt.replyVisible = ""
                case .preparing, .speaking, .concluding:
                    break
                }
            }
        case .partialTranscript(let text):
            attempt.replyIsPartial = true
            update(attempt) { $0.lastReply = text }
        case .turnEnded(let text):
            attempt.replyIsPartial = false
            attempt.lastFinalReply = text
            update(attempt) { $0.lastReply = text }
        case .speakingStarted(let question):
            update(attempt) { view in
                if view.phase != .concluding { view.phase = .speaking }
                view.question = max(view.question, question)
                // En texte seul, le texte reçu avant que la réplique ne soit affichée est déjà la question.
                view.questionText = view.textOnly ? attempt.replyVisible : ""
            }
        case .sentencePlayed(let sentence):
            update(attempt) { view in
                guard !view.textOnly else { return }
                view.questionText = view.questionText.isEmpty ? sentence : view.questionText + " " + sentence
            }
        case .replyText(let text):
            attempt.replyVisible = text
            update(attempt) { view in
                guard view.textOnly, view.phase == .speaking else { return }
                view.questionText = text
            }
        case .speakingEnded(let heard), .interrupted(let heard):
            // Rien entendu (coupée pendant la réflexion, ou avant la fin de la première phrase) : la question montrée reste.
            guard !heard.isEmpty else { return }
            update(attempt) { $0.questionText = heard }
        case .level(let level):
            guard attempt.view.phase == .listening else { return }
            update(attempt) { $0.level = level }
        case .notice(let notice):
            if notice == .lastWordsLost { attempt.lastWordsLost = true }
            let sentence = InterviewText.notice(notice)
            if attempt.view.notice == sentence {
                // Un avis identique n'est redit à VoiceOver que s'il a disparu entre-temps.
                update(attempt) { $0.notice = nil }
            }
            update(attempt) { view in
                view.notice = sentence
                if notice == .voiceUnavailable {
                    view.textOnly = true
                    if view.phase == .speaking { view.questionText = attempt.replyVisible }
                }
            }
        case .finished:
            break
        }
    }

    /// La fin de la conversation. Pour un entretien conclu (`.prompt`, `.conclusionFailed`), l'écriture dans l'historique est
    /// attendue UN DÉLAI BORNÉ (`saveWaitSeconds`) avant d'ouvrir la relecture : si elle échoue, l'avis de relecture le dit
    /// (`InterviewText.withHistoryWarning`) ; si elle tient plus longtemps, la relecture s'ouvre sans avis et l'écriture finit après.
    /// Annulé pendant l'attente : rien n'est ouvert.
    private func finished(_ end: ConversationEnd, _ attempt: Attempt) async {
        guard isLive(attempt) else { return }
        log.notice("entretien fini : \(self.kind(of: end), privacy: .public)")
        switch end {
        case .prompt(let prompt, let conversation):
            let saved = await save(InterviewRecord(id: UUID(), date: now(), prompt: prompt, conversation: conversation))
            guard isLive(attempt) else { return }
            let notice =
                attempt.lastWordsLost ? InterviewText.promptReviewWithoutLastWords : InterviewText.promptReview
            self.end(attempt, .review(text: prompt, notice: saved ? notice : InterviewText.withHistoryWarning(notice)))
        case .conclusionFailed(_, let conversation):
            let saved = await save(InterviewRecord(id: UUID(), date: now(), prompt: nil, conversation: conversation))
            guard isLive(attempt) else { return }
            let notice =
                attempt.lastWordsLost ? InterviewText.conclusionFailedReviewWithoutLastWords : InterviewText.conclusionFailedReview
            self.end(
                attempt, .review(text: conversation.transcript, notice: saved ? notice : InterviewText.withHistoryWarning(notice)))
        case .failed(let failure, let conversation):
            // Rien n'est enregistré, mais rien n'est perdu : la conversation va en relecture dès qu'elle a un tour de la personne.
            if conversation.hasUserTurn {
                let notice: String
                switch failure {
                case .microphone: notice = InterviewText.microphoneStoppedReview
                case .engine: notice = InterviewText.transcriptionStoppedReview
                }
                self.end(attempt, .review(text: conversation.transcript, notice: notice))
            } else {
                // Sans tour, rien à relire : la phrase du code dit la cause et quoi faire (vocabulaire, micro refusé…).
                self.end(attempt, .notice(InterviewText.failureWithoutTurn(failure)))
            }
        case .nothingSaid:
            self.end(attempt, .notice(InterviewText.nothingSaid))
        case .cancelled:
            self.end(attempt, .cancelled)
        }
    }

    /// Combien de temps la relecture attend l'écriture de l'historique, en secondes : une écriture de quelques centaines d'octets
    /// prend des millisecondes, ce délai ne sert qu'à une écriture qui ne rend pas la main. Choix non mesuré.
    static let saveWaitSeconds = 2.0

    /// Les écritures en cours : chacune est une tâche que `waitForSaves()` attend (les tests, pour prouver qu'une fin n'écrit RIEN
    /// sans compter sur une durée fixe).
    private var savesInFlight: [UUID: Task<Bool, Never>] = [:]

    /// Un entretien conclu va dans l'historique. Rend `false` si l'écriture a échoué (le journal ne dit que sa nature), `true` si elle
    /// a réussi, ou si le délai est écoulé avant son issue (rien n'est alors affirmé : la relecture s'ouvre sans avis, l'écriture
    /// continue). Une durée « Ne rien garder » n'écrit rien et ne lève pas : ce n'est pas un échec.
    private func save(_ record: InterviewRecord) async -> Bool {
        let history = history
        let log = log
        let id = UUID()
        let task = Task { [weak self] () -> Bool in
            defer { self?.savesInFlight[id] = nil }
            do {
                try await history.save(record)
                return true
            } catch {
                log.error("entretien non enregistré dans l'historique")
                return false
            }
        }
        savesInFlight[id] = task
        do {
            return try await Deadline.run(seconds: Self.saveWaitSeconds, sleep: saveWait) { await task.value }
        } catch is DeadlineExceeded {
            log.notice("entretien : écriture de l'historique encore en cours")
            return true
        } catch {
            return true
        }
    }

    /// Attend la fin de toutes les écritures de l'historique en cours.
    func waitForSaves() async {
        for task in Array(savesInFlight.values) { _ = await task.value }
    }

    // MARK: - État

    /// La fin, une seule fois par entretien : la vue de l'entretien est retirée, puis le contrôleur de dictée reçoit l'issue.
    private func end(_ attempt: Attempt, _ outcome: InterviewOutcome) {
        guard isLive(attempt) else { return }
        current = nil
        panel.setInterview(nil)
        attempt.onEnd(outcome)
    }

    private func isLive(_ attempt: Attempt) -> Bool { current === attempt }

    /// Toute vue passe ici, et seulement pour l'entretien courant.
    private func update(_ attempt: Attempt, _ change: (inout InterviewViewState) -> Void) {
        guard isLive(attempt) else { return }
        var next = attempt.view
        change(&next)
        guard next != attempt.view else { return }
        attempt.view = next
        panel.setInterview(next)
    }

    /// La nature d'un refus pour le journal : jamais le nom du fournisseur ni le texte d'une erreur.
    private func kind(of failure: InterviewSetupFailure) -> String {
        switch failure {
        case .noFastModel: "modèle rapide absent"
        case .noStrongModel: "modèle fort absent"
        case .provider: "fournisseur"
        }
    }

    /// La nature d'une fin pour le journal.
    private func kind(of end: ConversationEnd) -> String {
        switch end {
        case .prompt: "prompt"
        case .conclusionFailed: "conclusion en échec"
        case .failed(.microphone, _): "panne du micro"
        case .failed(.engine, _): "panne d'un moteur"
        case .nothingSaid: "rien dit"
        case .cancelled: "annulé"
        }
    }
}

/// Un entretien, du lancement à sa fin.
@MainActor
private final class Attempt {
    let onEnd: @MainActor (InterviewOutcome) -> Void
    /// L'état que la vue montre.
    var view = InterviewViewState(maxQuestions: 0, privacy: "")
    /// La tâche qui résout, prépare, construit puis lit le flux.
    var reader: Task<Void, Never>?
    /// La conversation, de sa fabrication à sa fin.
    var conversation: (any ConversationEngine)?
    /// Une conversation lui a été confiée (elle peut ouvrir le micro) : ce qui attend le micro attend la fin de sa lecture.
    var holdsConversation = false
    var concludeSent = false
    /// `start()` de la conversation a rendu la main : le moteur prend désormais une conclusion.
    var started = false
    /// Conclure a été demandé pendant `start()` : la demande part dès son retour.
    var concludePending = false
    /// `.lastWordsLost` a été signalé : la phrase de la relecture le dit (la vue de l'entretien disparaît avec l'avis).
    var lastWordsLost = false
    /// La carte « Vous » montre un aperçu, pas une réponse finie.
    var replyIsPartial = false
    var lastFinalReply = ""
    /// Le texte de la réplique en cours tel que le moteur l'a reçu (`.replyText`) : en texte seul, c'est la question.
    var replyVisible = ""

    init(onEnd: @escaping @MainActor (InterviewOutcome) -> Void) { self.onEnd = onEnd }
}
