import Foundation
import Observation
import SupervoxCore
import os

/// Mène une dictée brute du raccourci au collage : démarre la session, suit ses instantanés, termine, annule, insère.
///
/// Règles de conception :
/// - Une dictée est une `Run`. Tout ce qui arrive d'une session (instantané, résultat) ou d'une tâche (insertion) est relu
///   contre la dictée courante : un résultat qui arrive après une annulation, ou après qu'une nouvelle dictée a commencé,
///   n'est ni collé ni montré. Le contrôleur n'attend jamais le retour de `finish()` ni d'un moteur : le résultat se lit
///   sur les instantanés, et `finish()` comme `cancel()` partent dans des tâches que rien n'attend.
/// - Le contrat de la session dit qu'un `finish()` reçu avant `start()` est perdu : une fin demandée avant que la
///   préparation ait commencé (touche relâchée très tôt en maintien) est retenue puis rejouée.
/// - Un seul collage à la fois : les insertions s'enchaînent, même quand la dictée qui a lancé la précédente est annulée
///   (le collage, lui, ne s'annule plus une fois ⌘V posté).
/// - Les réglages de transcription sont relus à chaque dictée.
/// - Le texte dicté est une donnée privée : il n'est écrit dans aucun journal ni message. `lastTranscript` le garde en
///   mémoire seulement, jamais dans un fichier.
@MainActor @Observable
public final class DictationController {
    /// Le seul mode dont la dictée est mise en œuvre à cette étape.
    static let rawModeID = "dictee-brute"
    // Les phrases que le panneau montre, publiques pour que l'outil de rendu des écrans montre celles de l'application.
    public static let laterModeNotice = "Ce mode arrive à une étape suivante."
    public static let downloadNotice = "Téléchargement du modèle…"
    public static let interruptedNotice = "La dictée a été interrompue."
    public static let uncountableNotice =
        "Le vocabulaire n'a pas servi à cette dictée : sa longueur n'a pas pu être vérifiée avec ce modèle."
    public static let preparationFailedNotice =
        "La transcription n'a pas pu être préparée. Ouvrez les Réglages, onglet Transcription, pour vérifier le moteur et le modèle choisis, ou pour télécharger le modèle."

    /// Ce que la vue du panneau montre.
    public private(set) var view = DictationViewState()
    /// Le texte de la dernière dictée réussie, que le collage ait réussi ou non : `.pasted` ne prouve pas que
    /// l'application cible a reçu le texte, et l'utilisateur doit pouvoir le récupérer (bouton « Copier »). En mémoire
    /// seulement ; un échec ou une annulation ultérieure ne l'efface pas.
    public private(set) var lastTranscript: String?

    /// Appelé à chaque changement de `view` : le modèle du panneau la relaie à la vue.
    @ObservationIgnored public var onViewChange: (@MainActor (DictationViewState) -> Void)?
    /// Appelé avec le texte de chaque dictée réussie (donc de `lastTranscript`) : le panneau le garde pour « Copier ».
    @ObservationIgnored public var onTranscriptChange: (@MainActor (String) -> Void)?

    @ObservationIgnored private let environment: DictationEnvironment
    @ObservationIgnored private let inserter: TextInserter
    @ObservationIgnored private let settings: @MainActor () -> TranscriptionSettings
    @ObservationIgnored private let behavior: @MainActor () -> HotKeyBehavior
    @ObservationIgnored private let modeID: @MainActor () -> String
    @ObservationIgnored private let microphoneAllowed: @MainActor () -> Bool
    @ObservationIgnored private let panel: any PanelOpening
    @ObservationIgnored private let hotKeyModifiers: @MainActor () -> Modifiers
    @ObservationIgnored private let hold: HoldWatch
    @ObservationIgnored private let log = Logger(subsystem: "dev.supervox.app", category: "dictation")

    /// Vrai de l'appui jusqu'à la fin du collage (ou de l'échec, de l'annulation) : une dictée est en cours. Les réglages s'en
    /// servent pour refuser de supprimer un modèle que la dictée utilise.
    public var isBusy: Bool { run != nil }

    /// La dictée en cours, `nil` hors dictée (y compris pendant que le panneau montre un échec ou une copie).
    @ObservationIgnored private var run: Run?
    /// La dernière insertion lancée : la suivante l'attend.
    @ObservationIgnored private var insertionTail: Task<Void, Never>?

    /// - Parameters:
    ///   - settings: les réglages de transcription, relus à chaque dictée.
    ///   - behavior: bascule ou maintien, relu à chaque appui.
    ///   - modeID: le mode choisi dans le panneau.
    ///   - microphoneAllowed: vrai si le micro est autorisé ; relu (et non supposé) à chaque appui.
    ///   - hotKeyModifiers: les modificateurs du raccourci en vigueur ; relus au début de chaque dictée en maintien.
    ///   - hold: la surveillance des modificateurs, qui rattrape un relâchement perdu (jamais interrogée en bascule).
    public init(
        environment: DictationEnvironment, inserter: TextInserter,
        settings: @escaping @MainActor () -> TranscriptionSettings,
        behavior: @escaping @MainActor () -> HotKeyBehavior,
        modeID: @escaping @MainActor () -> String,
        microphoneAllowed: @escaping @MainActor () -> Bool,
        panel: any PanelOpening,
        hotKeyModifiers: @escaping @MainActor () -> Modifiers,
        hold: HoldWatch
    ) {
        self.environment = environment
        self.inserter = inserter
        self.settings = settings
        self.behavior = behavior
        self.modeID = modeID
        self.microphoneAllowed = microphoneAllowed
        self.panel = panel
        self.hotKeyModifiers = hotKeyModifiers
        self.hold = hold
    }

    // MARK: - Raccourci

    /// Bascule : un appui commence (le panneau s'ouvre), le suivant termine ; ignoré pendant la préparation et la
    /// finalisation. Maintien : un appui commence ; un appui pendant la dictée est ignoré.
    public func hotKeyPressed() {
        let hold = behavior() == .hold
        if let run {
            if view.phase == .recording, !hold { requestFinish(run) }
            return
        }
        begin(hold: hold)
    }

    /// Maintien : le relâchement termine la dictée que ce maintien a commencée. Sans dictée, ou en bascule : ignoré.
    public func hotKeyReleased() {
        guard let run, run.startedByHold, view.phase == .preparing || view.phase == .recording else { return }
        requestFinish(run)
    }

    /// Pendant une dictée : annule (rien n'est collé ni copié) et ferme le panneau. Hors dictée : ferme le panneau.
    public func escapePressed() {
        cancelCurrentRun()
        panel.close()
        setView(DictationViewState())
    }

    /// Le panneau s'est fermé (menu, Quitter, Réglages, Échap, clic en dehors) : une dictée en cours est annulée.
    public func panelClosedByUser() {
        cancelCurrentRun()
        setView(DictationViewState())
    }

    // MARK: - Démarrage

    private func begin(hold: Bool) {
        guard modeID() == Self.rawModeID else {
            // Rien à dicter dans ce mode : l'appui ouvre le panneau, ou le ferme s'il est déjà ouvert.
            if panel.isOpen {
                panel.close()
            } else {
                setView(DictationViewState(notice: Self.laterModeNotice))
                panel.open()
            }
            return
        }
        guard microphoneAllowed() else {
            // Pas de session : la ligne des permissions du panneau dit ce qui manque.
            setView(DictationViewState())
            if !panel.isOpen { panel.open() }
            log.notice("dictée refusée : micro non autorisé")
            return
        }
        let run = Run(startedByHold: hold)
        self.run = run
        // Posé tout de suite : un appui qui arrive avant la première session est déjà ignoré.
        setView(DictationViewState(phase: .preparing))
        if !panel.isOpen { panel.open() }
        // Relus à chaque dictée : un changement de moteur, de modèle, de langue ou de vocabulaire vaut dès la suivante.
        let current = settings()
        log.notice("dictée commencée ; maintien : \(hold, privacy: .public) ; moteur : \(current.engine, privacy: .public)")
        run.task = Task { await self.execute(run, settings: current) }
        if hold { run.watch = Task { await self.watchModifiers(run) } }
    }

    /// Maintien seulement. Tant que la dictée prépare ou écoute, regarde à intervalle court si les modificateurs du
    /// raccourci sont encore enfoncés ; dès qu'aucun ne l'est plus, c'est un relâchement (celui du système peut ne jamais
    /// venir quand les modificateurs sont lâchés avant la touche principale). S'arrête avec la dictée et à l'annulation.
    private func watchModifiers(_ run: Run) async {
        let modifiers = hotKeyModifiers()
        // Sans touche de modification, la sonde ne peut rien dire (« aucune enfoncée » serait toujours vrai) : le relâchement
        // du système, ou la durée maximale de la session, termine la dictée.
        guard !modifiers.isEmpty else { return }
        while isLive(run), view.phase == .preparing || view.phase == .recording {
            await self.hold.wait(self.hold.interval)
            // Une attente annulée rend la main aussitôt : sans cette sortie, la boucle tournerait sans attendre.
            guard !Task.isCancelled, isLive(run), view.phase == .preparing || view.phase == .recording else { return }
            if !self.hold.anyHeld(modifiers) {
                log.notice("maintien : modificateurs relâchés sans relâchement du raccourci")
                requestFinish(run)
                return
            }
            await Task.yield()
        }
    }

    private func execute(_ run: Run, settings: TranscriptionSettings) async {
        let download = await environment.needsModelDownload(settings)
        guard isLive(run) else { return }
        if download {
            run.downloadNotice = Self.downloadNotice
            refreshNotice(run)
            // Par le catalogue des modèles : un seul téléchargement par modèle, visible dans les réglages. Avant le comptage
            // du vocabulaire, qui a besoin du tokenizer que ce téléchargement apporte.
            do {
                try await environment.downloadModels(settings)
            } catch {
                guard isLive(run) else { return }
                log.error("téléchargement des modèles échoué")
                finishRun(
                    run, with: .failed(.engine("le téléchargement du modèle a échoué")),
                    notice: Self.preparationFailedNotice)
                return
            }
            guard isLive(run) else { return }
        }

        var effective = settings
        if settings.engine == "whisperkit", !settings.vocabulary.isEmpty {
            let model = settings.whisperModel
            let environment = self.environment
            let outcome = await VocabularyFit.fit(settings.vocabulary, limit: environment.promptTokenLimit) {
                await environment.promptTokenCount($0, model)
            }
            guard isLive(run) else { return }
            switch outcome {
            case .fits:
                break
            case .trimmed(let kept, let total):
                effective.vocabulary = kept
                run.vocabularyNotice = Self.trimmedNotice(kept: kept.count, of: total)
            case .unknown:
                // Longueur impossible à compter (tokenizer introuvable) : le moteur refuserait une liste trop longue après
                // que l'utilisateur a parlé, et la dictée ne doit jamais échouer à cause du vocabulaire. La liste ne part pas
                // pour cette dictée, et la notice le dit.
                effective.vocabulary = []
                run.vocabularyNotice = Self.uncountableNotice
            }
            refreshNotice(run)
        }

        let session: any DictationSessioning
        do {
            session = try await environment.makeSession(effective)
        } catch {
            guard isLive(run) else { return }
            log.error("session non fabriquée : \(type(of: error), privacy: .public)")
            finishRun(run, with: .failed(.engine("la préparation de la transcription a échoué")), notice: Self.preparationFailedNotice)
            return
        }
        // Annulée pendant la fabrication : la session n'est jamais démarrée, aucun micro ne s'ouvre.
        guard isLive(run) else { return }
        run.session = session
        // Le flux est lu avant que `start()` ne tourne : le premier instantané ne se perd pas.
        Task { await session.start() }
        for await snapshot in session.snapshots {
            guard isLive(run) else { return }
            handle(snapshot, run)
        }
    }

    // MARK: - Instantanés

    private func handle(_ snapshot: DictationSnapshot, _ run: Run) {
        run.sessionPhase = snapshot.phase
        switch snapshot.phase {
        case .idle:
            return
        case .preparing, .recording, .finalizing:
            var next = view
            next.phase = snapshot.phase
            next.liveText = snapshot.liveText
            next.elapsed = snapshot.elapsed
            if snapshot.phase == .recording {
                run.downloadNotice = nil
                next.levels = Array((view.levels + [snapshot.level]).suffix(DictationViewState.levelCount))
            }
            next.notice = notice(for: run, phase: snapshot.phase)
            setView(next)
            // La prise est finie : plus rien à surveiller.
            if snapshot.phase == .finalizing { run.watch?.cancel() }
            replayPendingFinish(run)
        case .finished(let text):
            finished(text, run)
        case .cancelled:
            // Nous n'avons rien demandé : la session s'est arrêtée seule. Le panneau le dit.
            log.notice("session annulée sans demande")
            finishRun(run, with: .cancelled, notice: Self.interruptedNotice)
        case .failed(let failure):
            // Une panne du moteur pendant la préparation : le texte de la raison peut porter une adresse, la phrase est fixe.
            var message = failure.message
            if case .engine = failure, view.phase == .preparing { message = Self.preparationFailedNotice }
            log.notice("dictée en échec : \(Self.kind(of: failure), privacy: .public)")
            finishRun(run, with: .failed(failure), notice: message)
        }
    }

    private func finished(_ text: String, _ run: Run) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finishRun(run, with: .failed(.noSpeech), notice: DictationFailure.noSpeech.message)
            return
        }
        lastTranscript = text
        onTranscriptChange?(text)
        log.notice("dictée terminée ; insertion")
        let previous = insertionTail
        let task = Task { [weak self] in
            // Une insertion encore en route, même d'une dictée annulée, se termine avant celle-ci.
            await previous?.value
            guard let self, self.isLive(run) else { return }
            let outcome = await self.inserter.insert(text)
            self.insertionFinished(run, text: text, outcome: outcome)
        }
        run.insertion = task
        insertionTail = task
    }

    private func insertionFinished(_ run: Run, text: String, outcome: InsertionOutcome) {
        guard isLive(run) else { return }
        switch outcome {
        case .pasted:
            log.notice("texte collé")
            retire(run)
            setView(DictationViewState())
            panel.close()
        case .copied(let reason):
            log.notice("texte copié, non collé")
            finishRun(run, with: .finished(text), notice: reason)
        case .nothing:
            // Ne peut pas arriver pour un texte non vide et une tâche non annulée.
            finishRun(run, with: .failed(.noSpeech), notice: DictationFailure.noSpeech.message)
        }
    }

    /// La dictée est finie : le panneau reste ouvert avec ce qu'il y a à dire.
    private func finishRun(_ run: Run, with phase: DictationPhase, notice: String) {
        guard isLive(run) else { return }
        retire(run)
        var next = view
        next.phase = phase
        next.notice = notice
        setView(next)
    }

    // MARK: - Fin et annulation

    private func requestFinish(_ run: Run) {
        guard !run.finishSent else { return }
        switch run.sessionPhase {
        case .preparing, .recording:
            guard let session = run.session else { return }
            run.finishSent = true
            Task { await session.finish() }
        case .idle:
            // La session n'existe pas encore, ou n'a pas encore commencé : un `finish()` serait perdu.
            run.finishPending = true
        default:
            break
        }
    }

    private func replayPendingFinish(_ run: Run) {
        guard run.finishPending else { return }
        run.finishPending = false
        requestFinish(run)
    }

    private func cancelCurrentRun() {
        guard let run else { return }
        run.task?.cancel()
        run.watch?.cancel()
        run.insertion?.cancel()
        if let session = run.session {
            // Sans attendre : un moteur peut ignorer l'annulation et rendre son résultat plus tard.
            Task { await session.cancel() }
        }
        self.run = nil
        log.notice("dictée annulée")
    }

    // MARK: - État

    /// La dictée est finie : elle n'est plus la dictée courante et sa surveillance des modificateurs s'arrête.
    private func retire(_ run: Run) {
        run.watch?.cancel()
        if self.run === run { self.run = nil }
    }

    /// `run` est la dictée courante : une dictée annulée ou finie n'est plus `self.run`.
    private func isLive(_ run: Run) -> Bool { self.run === run }

    private func setView(_ next: DictationViewState) {
        view = next
        onViewChange?(next)
    }

    private func refreshNotice(_ run: Run) {
        guard isLive(run), view.phase.isActive else { return }
        var next = view
        next.notice = notice(for: run, phase: view.phase)
        setView(next)
    }

    /// L'avis d'une dictée en cours : la mention de téléchargement (tant que la préparation dure), puis celui du vocabulaire.
    private func notice(for run: Run, phase: DictationPhase) -> String? {
        var lines: [String] = []
        if phase == .preparing, let download = run.downloadNotice { lines.append(download) }
        if let vocabulary = run.vocabularyNotice { lines.append(vocabulary) }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// La nature d'un échec pour le journal : jamais sa raison (qui peut porter une adresse).
    private static func kind(of failure: DictationFailure) -> String {
        switch failure {
        case .noSpeech: "aucune parole"
        case .microphone: "micro"
        case .engine: "moteur"
        }
    }

    private static func trimmedNotice(kept: Int, of total: Int) -> String {
        let used =
            switch kept {
            case 0: "aucun terme n'a pu servir"
            case 1: "seul le premier terme sur \(total) sert"
            default: "seuls les \(kept) premiers termes sur \(total) servent"
            }
        return "Vocabulaire trop long pour ce modèle : \(used) à cette dictée. Raccourcissez la liste dans Réglages, onglet Transcription."
    }
}

/// Une dictée : de l'appui à la fin du collage ou de l'échec.
@MainActor
private final class Run {
    /// Commencée par un appui en maintien : seul le relâchement qui suit la termine.
    let startedByHold: Bool
    var session: (any DictationSessioning)?
    /// La dernière phase vue dans les instantanés de la session.
    var sessionPhase: DictationPhase = .idle
    /// Fin demandée avant que la session ait commencé sa préparation ; rejouée ensuite.
    var finishPending = false
    var finishSent = false
    var task: Task<Void, Never>?
    /// La surveillance des modificateurs (maintien seulement).
    var watch: Task<Void, Never>?
    var insertion: Task<Void, Never>?
    var downloadNotice: String?
    var vocabularyNotice: String?

    init(startedByHold: Bool) { self.startedByHold = startedByHold }
}
