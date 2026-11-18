import Foundation
import Observation
import Synchronization
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
/// - Relecture. Si le réglage « relire avant de coller » du mode est actif à l'appui qui commence la dictée (lu une seule
///   fois), la fin de la dictée n'insère rien : la dictée est finie (`run` est `nil`, `isBusy` est faux) et le texte passe en
///   relecture, un objet `Review` relu comme une `Run` (`isLive`). Seul `pasteReview()` insère, par la même file que les autres
///   insertions ; un résultat qui arrive après la fin de la relecture ne touche plus ni l'écran ni le panneau. Le raccourci est
///   ignoré tant que la relecture dure (étapes `review` et `pasting`).
/// - Correction à la voix. En relecture (texte non blanc), le raccourci GLOBAL (ou `startCorrection()`, le bouton) commence une
///   correction : une `Run` dont le but est la correction de la relecture courante, avec les mêmes réglages de transcription
///   que la dictée relue. La relecture reste vivante (`review` ne bouge pas) ; son texte est en lecture seule (étape
///   `correcting`). Seul le raccourci global (ou le bouton) la termine ; celui d'un mode est ignoré pendant la relecture et
///   pendant la correction. Le texte ne change qu'à la réussite : tout échec (aucun modèle fort, consigne blanche, modèle en
///   panne, réponse identique…) ramène la relecture avec le brouillon intact, tapé compris. Chaque réussite empile l'ancien
///   texte dans les versions précédentes (`Review.previousVersions`) et vide les suivantes.
/// - Le texte dicté est une donnée privée : il n'est écrit dans aucun journal ni message. `lastTranscript` le garde en
///   mémoire seulement, jamais dans un fichier.
/// - Entretien. Le mode Entretien ne dicte pas : l'appui (ou un clic sur sa pastille au repos, `modeChosen`) lance un entretien
///   (`InterviewRunning`), que ce contrôleur ne mène pas mais dont il garde les règles communes : propriétaire du raccourci (celui
///   qui l'a lancé conclut, ou tout raccourci si le sien n'est plus enregistré), relâchement toujours ignoré, Échap et fermeture du
///   panneau qui l'annulent, relecture de son texte (`openReview`). Pendant l'entretien, un appui est intercepté avant tout le
///   chemin de la dictée : aucune dictée, aucun changement de mode, aucune fermeture du panneau. Une dictée ne prend le micro
///   qu'une fois celui d'un entretien rendu (`InterviewRunning.waitUntilStopped`).
@MainActor @Observable
public final class DictationController {
    // Les phrases que le panneau montre, publiques pour que l'outil de rendu des écrans montre celles de l'application.
    public static let downloadNotice = "Téléchargement du modèle…"
    /// Pendant que les moteurs se chargent en mémoire (après le téléchargement, ou au premier appui qui suit le lancement).
    public static let loadingNotice = "Chargement du modèle…"
    public static let interruptedNotice = "La dictée a été interrompue."
    /// Les avis du vocabulaire viennent de la règle partagée avec l'entretien (`EffectiveVocabulary`).
    nonisolated public static let uncountableNotice = EffectiveVocabulary.uncountableNotice(.dictation)
    nonisolated public static let vocabularyModelNotice = EffectiveVocabulary.modelUnavailableNotice(.dictation)
    public static let preparationFailedNotice =
        "La transcription n'a pas pu être préparée. Ouvrez les Réglages, onglet Transcription : vérifiez le moteur et le modèle choisis ; si le modèle manque, téléchargez-le ; s'il est indiqué « Prêt », vous pouvez le supprimer puis le télécharger de nouveau (cela demande une connexion à Internet)."

    /// Entre le retrait de la frappe (le panneau la rend à l'application de dessous) et l'insertion : le temps que cette
    /// application reprenne la touche clé avant que le ⌘V parte. Choix de conception, non mesuré.
    public static let focusHandoverDelay = 0.15
    /// Ce que le panneau dit quand le presse-papiers refuse le texte de la relecture. Le texte reste dans le champ.
    public static let reviewClipboardNotice =
        "Le presse-papiers a refusé le texte : il n'a été ni collé ni copié. Il est toujours ci-dessus : réessayez « Coller » ou « Copier »."
    /// Ce que le panneau dit pendant la mise en forme : où part le texte. `provider` est le nom du fournisseur, rogné à 40
    /// caractères par la règle commune (`Provider.shortName`).
    public static func formattingNotice(provider: String) -> String {
        "Le texte est envoyé à « \(Provider.shortName(provider)) » pour être mis en forme."
    }
    /// Ce que le panneau dit quand l'utilisateur est allé dans une autre application pendant la mise en forme d'un mode sans
    /// relecture : le texte n'est pas collé là où il ne l'attend plus.
    public static let frontApplicationChangedNotice =
        "L'application au premier plan a changé pendant la mise en forme : le texte n'a pas été collé. Collez-le ou copiez-le."
    /// Ce que le panneau ajoute à la phrase d'une panne du modèle : le texte en relecture est la transcription brute.
    public static let rawTextNotice =
        "Le texte ci-dessus est la transcription brute : corrigez-la, collez-la ou copiez-la."

    /// Pendant que la consigne se dit : le raccourci GLOBAL réel (`hotKeyLabel`, celui que le panneau montre) ou le bouton
    /// terminent. Sans raccourci, seul le bouton. En maintien (`hold` : la correction a été commencée par l'appui tenu du
    /// raccourci), c'est le relâchement qui termine : un appui serait ignoré.
    public static func correctionListeningNotice(hotKeyLabel: String?, hold: Bool = false) -> String {
        if hold {
            guard let hotKeyLabel else { return "Dites ce qu'il faut changer, puis relâchez le raccourci." }
            return "Dites ce qu'il faut changer, puis relâchez \(hotKeyLabel)."
        }
        guard let hotKeyLabel else { return "Dites ce qu'il faut changer, puis cliquez sur « Terminer »." }
        return "Dites ce qu'il faut changer, puis appuyez de nouveau sur \(hotKeyLabel) ou cliquez sur « Terminer »."
    }
    /// Tant que le micro n'écoute pas (préparation, téléchargement, chargement) : un appui ou « Terminer » n'y a aucun effet.
    public static let correctionPreparingNotice =
        "Patientez un instant : vous pourrez dire ce qu'il faut changer dès que l'écoute commencera."
    /// La même, en maintien (la correction a été commencée par l'appui tenu du raccourci) : le relâchement terminerait la
    /// consigne, qui serait vide ; la phrase dit de garder la touche.
    public static func correctionPreparingSentence(hotKeyLabel: String?, hold: Bool) -> String {
        guard hold else { return correctionPreparingNotice }
        return "Gardez \(hotKeyLabel ?? "le raccourci") enfoncé : vous pourrez dire ce qu'il faut changer dès que l'écoute commencera."
    }
    /// La session s'est arrêtée seule pendant la correction.
    public static let correctionInterruptedNotice = "La correction à la voix a été interrompue. Le texte n'a pas changé."
    /// L'autorisation du micro manque au moment de corriger.
    public static let correctionMicrophoneNotice =
        "Le micro n'est pas autorisé : autorisez-le dans les Réglages Système pour corriger à la voix."
    public static let correctionProviderMissingNotice =
        "Le fournisseur du modèle fort n'existe plus : choisissez un autre modèle fort en tête de Réglages, onglet Modes. Le texte n'a pas changé."
    public static let correctionNotFoundNotice =
        "Le serveur ne connaît pas le modèle fort ou cette adresse (HTTP 404) : vérifiez le modèle fort, en tête de Réglages, onglet Modes, et l'adresse du fournisseur. Le texte n'a pas changé."

    /// La phrase d'une panne du modèle pendant une correction : celle du Core (qui parle du modèle « du mode ») sauf pour les
    /// pannes qui désignent le réglage du modèle, dont la correction a ses propres phrases (le modèle fort, en tête de l'onglet
    /// Modes), suivie de « Le texte n'a pas changé. ».
    public static func correctionNotice(for failure: RewriteFailure) -> String {
        switch failure {
        case .noModel: correctionNoModelNotice
        case .providerMissing: correctionProviderMissingNotice
        case .notFound: correctionNotFoundNotice
        default: failure.message + " " + correctionKeptSentence
        }
    }
    public static let correctionRewritingNotice = "Réécriture du texte selon votre consigne…"
    public static let correctionEmptyNotice = "Aucune consigne n'a été entendue : le texte n'a pas changé."
    public static let correctionUnchangedNotice = "Le modèle n'a rien changé au texte."
    public static let correctionNoModelNotice =
        "Aucun modèle fort n'est choisi : choisissez-en un en tête de Réglages, onglet Modes, pour corriger à la voix. Le texte n'a pas changé."
    /// Ajoutée à la phrase d'un échec de la correction (modèle en panne, préparation, interruption).
    static let correctionKeptSentence = "Le texte n'a pas changé."

    /// Ce que la vue du panneau montre.
    public private(set) var view = DictationViewState()
    /// Le texte de la dernière dictée réussie, que le collage ait réussi ou non : `.pasted` ne prouve pas que
    /// l'application cible a reçu le texte, et l'utilisateur doit pouvoir le récupérer (bouton « Copier »). En mémoire
    /// seulement ; un échec ou une annulation ultérieure ne l'efface pas. C'est la seule copie stockée : `view.lastTranscript`
    /// en est le reflet, posé par `setView`.
    public private(set) var lastTranscript: String?

    /// Appelé à chaque changement de `view` : le modèle du panneau la relaie à la vue.
    @ObservationIgnored public var onViewChange: (@MainActor (DictationViewState) -> Void)?

    @ObservationIgnored private let environment: DictationEnvironment
    @ObservationIgnored private let inserter: TextInserter
    @ObservationIgnored private let settings: @MainActor () -> TranscriptionSettings
    @ObservationIgnored private let behavior: @MainActor () -> HotKeyBehavior
    @ObservationIgnored private let modeID: @MainActor () -> String
    @ObservationIgnored private let microphoneAllowed: @MainActor () -> Bool
    @ObservationIgnored private let panel: any PanelOpening
    @ObservationIgnored private let hotKeyModifiers: @MainActor () -> Modifiers
    @ObservationIgnored private let modeHotKeyModifiers: @MainActor (String) -> Modifiers
    @ObservationIgnored private let selectMode: @MainActor (String) -> Void
    @ObservationIgnored private let ownerIsBound: @MainActor (HotKeyOwner) -> Bool
    @ObservationIgnored private let hold: HoldWatch
    @ObservationIgnored private let reviewBeforePaste: @MainActor (String) -> Bool
    @ObservationIgnored private let modes: @MainActor (String) -> ModeRun
    @ObservationIgnored private let rewriter: RewriteEnvironment
    @ObservationIgnored private let frontApplication: @MainActor () -> Int32?
    @ObservationIgnored private let hotKeyLabel: @MainActor () -> String?
    @ObservationIgnored private let wait: @MainActor (Double) async -> Void
    @ObservationIgnored private let interview: (any InterviewRunning)?
    @ObservationIgnored private let concludeInterview: @MainActor () -> Void
    @ObservationIgnored private let log = Logger(subsystem: "dev.supervox.app", category: "dictation")

    /// Vrai de l'appui jusqu'à la fin de la dictée : fin du collage (sans relecture), échec, annulation, ou arrivée du texte en
    /// relecture. Faux pendant la relecture et le collage qui la suit : la dictée est finie, plus aucun modèle ne sert. Les
    /// réglages s'en servent pour refuser de supprimer un modèle que la dictée utilise ; `isInserting`, lui, reste vrai pendant
    /// le collage d'une relecture.
    ///
    /// Pendant une correction : vrai tant qu'une session tient le modèle de transcription (`preparing`, `recording`,
    /// `transcribing`), faux pendant la réécriture, qui ne passe que par le modèle de langage.
    ///
    /// Pendant un entretien, de son lancement à sa fin : vrai (le moteur de transcription sert à l'entretien).
    public var isBusy: Bool {
        if interview?.isActive == true { return true }
        guard let run else { return false }
        return !(run.isCorrection && run.rewriting)
    }

    /// La dictée en cours, `nil` hors dictée (y compris pendant que le panneau montre un échec ou une copie, et pendant la
    /// relecture).
    @ObservationIgnored private var run: Run?
    /// La relecture en cours (étapes `review` et `pasting`), `nil` sinon. Jamais en même temps qu'une dictée.
    @ObservationIgnored private var review: Review?
    /// La dernière insertion lancée : la suivante l'attend.
    @ObservationIgnored private var insertionTail: Task<Void, Never>?
    /// Insertions lancées et pas encore finies (voir `isInserting`).
    @ObservationIgnored private var insertionsInFlight = 0
    /// Le raccourci qui a lancé l'entretien en cours (une pastille : le raccourci global), `nil` hors entretien.
    @ObservationIgnored private var interviewOwner: HotKeyOwner?
    /// Vrai pendant que le raccourci d'un mode choisit ce mode : `modeChosen`, appelé par ce choix, ne lance rien (l'appui
    /// lui-même lance, avec son propriétaire).
    @ObservationIgnored private var choosingByHotKey = false

    /// - Parameters:
    ///   - settings: les réglages de transcription, relus à chaque dictée.
    ///   - behavior: bascule ou maintien, relu à chaque appui.
    ///   - modeID: le mode choisi dans le panneau.
    ///   - microphoneAllowed: vrai si le micro est autorisé ; relu (et non supposé) à chaque appui.
    ///   - hotKeyModifiers: les modificateurs du raccourci en vigueur ; relus au début de chaque dictée en maintien.
    ///   - modeHotKeyModifiers: les modificateurs du raccourci de ce mode ; lus au début de chaque dictée en maintien que ce
    ///     raccourci commence.
    ///   - selectMode: choisit ce mode dans le panneau (et l'enregistre) quand son raccourci commence une dictée.
    ///   - ownerIsBound: vrai si ce raccourci est encore enregistré. Une dictée dont le raccourci propriétaire ne l'est plus (mode
    ///     supprimé, raccourci retiré pendant la dictée) peut être terminée par n'importe quel autre raccourci.
    ///   - hold: la surveillance des modificateurs, qui rattrape un relâchement perdu (jamais interrogée en bascule).
    ///   - reviewBeforePaste: vrai si le texte de ce mode passe par la relecture ; lu une fois, à l'appui qui commence la dictée.
    ///   - modes: ce que fait la dictée de ce mode (`ModeRun`) ; lu une fois, à l'appui qui commence la dictée. Par défaut, seule
    ///     la dictée brute dicte (`ModeRun.legacy`).
    ///   - rewriter: la mise en forme par le modèle de langage, pour les modes à consigne. Par défaut, aucun modèle : elle échoue.
    ///   - frontApplication: l'identifiant du processus de l'application au premier plan, `nil` si l'on ne sait pas le dire ;
    ///     lu au début et à la fin de la mise en forme d'un mode sans relecture, pour ne pas coller dans une autre application.
    ///   - hotKeyLabel: le libellé du raccourci GLOBAL réellement enregistré (celui que le panneau montre), `nil` s'il n'y en a
    ///     aucun ; lu chaque fois que la phrase de la correction est composée.
    ///   - wait: attend ce nombre de secondes (`focusHandoverDelay`) ; injectée pour qu'aucun test n'attende une durée réelle.
    ///   - interview: l'entretien du mode Entretien ; `nil` (tests de la dictée seulement) : le mode Entretien dit « L'entretien n'a
    ///     pas pu démarrer : relancez Supervox. » sans toucher au micro.
    ///   - concludeInterview: ce que fait l'appui qui conclut l'entretien. Dans l'application, `PanelModel.concludeInterview()`, le
    ///     chemin du bouton « Conclure » (qui se grise) ; par défaut, `interview.conclude()`.
    public init(
        environment: DictationEnvironment, inserter: TextInserter,
        settings: @escaping @MainActor () -> TranscriptionSettings,
        behavior: @escaping @MainActor () -> HotKeyBehavior,
        modeID: @escaping @MainActor () -> String,
        microphoneAllowed: @escaping @MainActor () -> Bool,
        panel: any PanelOpening,
        hotKeyModifiers: @escaping @MainActor () -> Modifiers,
        modeHotKeyModifiers: @escaping @MainActor (String) -> Modifiers = { _ in [] },
        selectMode: @escaping @MainActor (String) -> Void = { _ in },
        ownerIsBound: @escaping @MainActor (HotKeyOwner) -> Bool = { _ in true },
        hold: HoldWatch,
        reviewBeforePaste: @escaping @MainActor (String) -> Bool = { _ in false },
        modes: @escaping @MainActor (String) -> ModeRun = ModeRun.legacy,
        rewriter: RewriteEnvironment = .unavailable,
        frontApplication: @escaping @MainActor () -> Int32? = { nil },
        hotKeyLabel: @escaping @MainActor () -> String? = { nil },
        wait: @escaping @MainActor (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        interview: (any InterviewRunning)? = nil,
        concludeInterview: (@MainActor () -> Void)? = nil
    ) {
        self.environment = environment
        self.inserter = inserter
        self.settings = settings
        self.behavior = behavior
        self.modeID = modeID
        self.microphoneAllowed = microphoneAllowed
        self.panel = panel
        self.hotKeyModifiers = hotKeyModifiers
        self.modeHotKeyModifiers = modeHotKeyModifiers
        self.selectMode = selectMode
        self.ownerIsBound = ownerIsBound
        self.hold = hold
        self.reviewBeforePaste = reviewBeforePaste
        self.modes = modes
        self.rewriter = rewriter
        self.frontApplication = frontApplication
        self.hotKeyLabel = hotKeyLabel
        self.wait = wait
        self.interview = interview
        self.concludeInterview = concludeInterview ?? { [weak interview] in interview?.conclude() }
    }

    // MARK: - Raccourci

    /// Bascule : un appui commence (le panneau s'ouvre), le suivant termine ; ignoré pendant la préparation et la
    /// finalisation. Maintien : un appui commence ; un appui pendant la dictée est ignoré.
    ///
    /// Une dictée garde le comportement avec lequel elle a commencé (`Run.startedByHold`), même si le réglage change pendant :
    /// le réglage n'est lu que pour en commencer une nouvelle. Une dictée commencée par le raccourci d'un mode n'écoute que
    /// celui-là : le raccourci global l'ignore. **Exception, en bascule seulement** : si le raccourci qui l'a commencée n'est
    /// plus enregistré (mode supprimé, raccourci retiré pendant la dictée), la dictée est orpheline et n'importe quel autre
    /// raccourci, global ou de mode, la termine ; en maintien, les autres raccourcis restent ignorés (appui comme relâchement).
    public func hotKeyPressed() {
        press(by: .global)
    }

    /// Maintien : le relâchement termine la dictée que ce maintien a commencée. Sans dictée, ou en bascule : ignoré.
    public func hotKeyReleased() {
        release(by: .global)
    }

    /// Le raccourci propre à un mode. Au repos (aucune dictée, aucune relecture), il choisit ce mode puis agit comme le
    /// raccourci global : la dictée commence, ou, pour un mode qui ne dicte pas encore, le panneau montre la phrase qui le dit.
    /// Pendant une dictée, seul le raccourci du mode qui l'a commencée compte (bascule : il la termine) ; celui d'un autre mode
    /// est ignoré, et le mode ne change pas, sauf pour une dictée orpheline en bascule (voir `hotKeyPressed`) : le raccourci de
    /// n'importe quel mode la termine alors, sans changer de mode. Pendant la relecture et le collage, il est ignoré.
    public func modeHotKeyPressed(_ modeID: String) {
        press(by: .mode(modeID))
    }

    /// Maintien : le relâchement du raccourci du mode qui a commencé la dictée la termine ; tout autre est ignoré.
    public func modeHotKeyReleased(_ modeID: String) {
        release(by: .mode(modeID))
    }

    private func press(by owner: HotKeyOwner) {
        // Pendant l'entretien, avant tout le chemin de la dictée : le propriétaire conclut (tout raccourci si le sien n'est plus
        // enregistré), tout autre appui est ignoré, sans choisir de mode ni fermer le panneau. Le relâchement ne compte jamais.
        if interview?.isActive == true {
            guard let interviewOwner else { return }
            if owner == interviewOwner || !ownerIsBound(interviewOwner) { concludeInterview() }
            return
        }
        if let run {
            // Le propriétaire seul la termine, tant que son raccourci existe ; sinon n'importe quel autre le peut (la dictée ne
            // reste pas sans issue, et son texte n'est pas perdu avec Échap). Une correction n'a pas cette échappatoire : seul le
            // raccourci global (ou le bouton) la termine, et le bouton existe toujours.
            let ownerCanEnd = run.isCorrection ? owner == .global : run.owner == owner || !ownerIsBound(run.owner)
            let listening = run.isCorrection ? view.stage == .correcting(.recording) : view.stage == .recording
            if ownerCanEnd, listening, !run.startedByHold { requestFinish(run) }
            return
        }
        // Le texte attend d'être relu ou se colle : le raccourci global commence une correction (en relecture), celui d'un mode
        // est ignoré, quel que soit le mode choisi entre-temps. Avant tout choix de mode : un raccourci ignoré ne change rien.
        guard review == nil else {
            if owner == .global { beginCorrection(hold: behavior() == .hold) }
            return
        }
        var modeChanged = false
        if case .mode(let id) = owner, modeID() != id {
            choosingByHotKey = true
            selectMode(id)
            choosingByHotKey = false
            // Une sélection refusée (mode inconnu, pastilles verrouillées) ne lance rien : pas de dictée sur un autre mode que
            // celui du raccourci, et aucun effet de bord (T9-1).
            guard modeID() == id else { return }
            modeChanged = true
        }
        begin(hold: behavior() == .hold, owner: owner, modeChanged: modeChanged)
    }

    private func release(by owner: HotKeyOwner) {
        // En entretien, le raccourci fonctionne toujours en bascule : un relâchement n'y fait rien, même en maintien.
        guard interview?.isActive != true else { return }
        guard let run, run.owner == owner, run.startedByHold, view.stage.isCapturing else { return }
        requestFinish(run)
    }

    /// Pendant une dictée : annule (rien n'est collé ni copié) et ferme le panneau. Hors dictée : ferme le panneau.
    /// En relecture ou pendant le collage : rien n'est inséré ni copié (un collage qui n'a pas encore posé ⌘V est annulé), et le
    /// brouillon devient le dernier texte.
    ///
    /// Pendant une correction, Échap l'annule seule (session et requête annulées, rien d'inséré) : la relecture revient, texte
    /// intact, panneau ouvert ; un second Échap ferme.
    public func escapePressed() {
        if let run, run.isCorrection {
            cancelCurrentRun()
            returnToReview(notice: nil)
            return
        }
        // Un entretien est annulé sans rien garder : ni relecture, ni historique, ni presse-papiers.
        interview?.cancel()
        closeReview()
        cancelCurrentRun()
        panel.close()
        setView(DictationViewState())
    }

    /// Le panneau s'est fermé (menu, Quitter, Réglages, Échap, clic en dehors) : une dictée en cours est annulée.
    public func panelClosedByUser() {
        interview?.cancel()
        closeReview()
        cancelCurrentRun()
        setView(DictationViewState())
    }

    // MARK: - Démarrage

    private func begin(hold: Bool, owner: HotKeyOwner, modeChanged: Bool) {
        let mode = modeID()
        // Lu ici, une seule fois, avec le réglage de relecture : modifier ou supprimer le mode pendant la dictée ne la change pas.
        let plan = modes(mode)
        switch plan {
        case .interview(let engine):
            beginInterview(owner: owner, engine: engine, modeChanged: modeChanged)
            return
        case .missing:
            // Le mode n'existe plus : rien ne démarre. L'appui ouvre le panneau, ou le ferme s'il est déjà ouvert.
            showOrClose(DictationViewState(), modeChanged: modeChanged)
            return
        case .raw, .rewrite:
            break
        }
        guard microphoneAllowed() else {
            // Pas de session : la ligne des permissions du panneau dit ce qui manque.
            setView(DictationViewState())
            if !panel.isOpen { panel.open() }
            log.notice("dictée refusée : micro non autorisé")
            return
        }
        // Lu ici, une seule fois : le changer pendant l'enregistrement ne change pas cette dictée.
        // Les modificateurs à surveiller sont ceux du raccourci qui commence la dictée, lus ici une seule fois.
        let watched: Modifiers
        if hold {
            switch owner {
            case .global: watched = hotKeyModifiers()
            case .mode(let id): watched = modeHotKeyModifiers(id)
            }
        } else {
            watched = []
        }
        // Relus à chaque dictée : un changement de moteur, de modèle, de langue ou de vocabulaire vaut dès la suivante.
        var current = settings()
        // Le moteur du mode remplace celui de l'onglet Transcription pour cette dictée seulement.
        if let engine = plan.engine { current.engine = engine }
        let run = Run(
            startedByHold: hold, owner: owner, modifiers: watched, reviewsBeforePaste: reviewBeforePaste(mode), plan: plan,
            settings: current)
        self.run = run
        // Posé tout de suite : un appui qui arrive avant la première session est déjà ignoré.
        setView(DictationViewState(stage: .preparing))
        if !panel.isOpen { panel.open() }
        log.notice("dictée commencée ; maintien : \(hold, privacy: .public) ; moteur : \(current.engine.rawValue, privacy: .public)")
        run.task = Task { await self.execute(run, settings: current) }
        if hold { run.watch = Task { await self.watchModifiers(run) } }
    }

    /// Rien ne démarre : l'appui ouvre le panneau sur cette vue, ou le ferme s'il est déjà ouvert. Le raccourci d'un mode qui vient
    /// de le choisir ne ferme pas : le panneau, déjà ouvert sur un autre mode, montre la vue.
    private func showOrClose(_ state: DictationViewState, modeChanged: Bool) {
        if panel.isOpen, !modeChanged {
            panel.close()
        } else {
            setView(state)
            if !panel.isOpen { panel.open() }
        }
    }

    // MARK: - Entretien

    /// Un clic sur une pastille, qu'elle ait été choisie à l'instant (et enregistrée) ou qu'elle le soit déjà (`PanelModel.chipTapped`).
    /// Au repos (aucune dictée, relecture ni entretien), la pastille Entretien lance l'entretien, avec le raccourci global pour
    /// propriétaire ; toute autre pastille ne fait que choisir. `modeChanged: true` : un clic montre, il ne referme jamais le panneau.
    public func modeChosen(_ id: String) {
        guard !choosingByHotKey, run == nil, review == nil, interview?.isActive != true else { return }
        guard case .interview(let engine) = modes(id) else { return }
        beginInterview(owner: .global, engine: engine, modeChanged: true)
    }

    private func beginInterview(owner: HotKeyOwner, engine: TranscriptionEngine?, modeChanged: Bool) {
        guard let interview else {
            showOrClose(DictationViewState(notice: InterviewText.couldNotStart), modeChanged: modeChanged)
            return
        }
        guard microphoneAllowed() else {
            // Comme la dictée : pas d'entretien, la ligne des permissions du panneau dit ce qui manque.
            setView(DictationViewState())
            if !panel.isOpen { panel.open() }
            log.notice("entretien refusé : micro non autorisé")
            return
        }
        interviewOwner = owner
        // L'écran de la dictée précédente (échec, copie) ne reste pas sous l'entretien : il revient au repos.
        setView(DictationViewState())
        interview.start(engine: engine) { [weak self] outcome in self?.interviewEnded(outcome) }
        if !panel.isOpen { panel.open() }
    }

    private func interviewEnded(_ outcome: InterviewOutcome) {
        interviewOwner = nil
        switch outcome {
        case .review(let text, let notice):
            openReview(text, notice: notice)
        case .notice(let notice):
            setView(DictationViewState(notice: notice))
            if !panel.isOpen { panel.open() }
        case .cancelled:
            break
        }
    }

    /// Maintien seulement. Tant que la dictée prépare ou écoute, regarde à intervalle court si Échap est enfoncée (annulation,
    /// comme `escapePressed()` : le raccourci réservé d'Échap ne voit pas ⌃⌥Échap), puis si les modificateurs du
    /// raccourci sont encore enfoncés ; dès qu'aucun ne l'est plus, c'est un relâchement (celui du système peut ne jamais
    /// venir quand les modificateurs sont lâchés avant la touche principale). S'arrête avec la dictée et à l'annulation.
    private func watchModifiers(_ run: Run) async {
        let modifiers = run.modifiers
        // Sans touche de modification, la sonde ne peut rien dire (« aucune enfoncée » serait toujours vrai) : le relâchement
        // du système, ou la durée maximale de la session, termine la dictée.
        guard !modifiers.isEmpty else { return }
        while isLive(run), view.stage.isCapturing {
            await self.hold.wait(self.hold.interval)
            // Une attente annulée rend la main aussitôt : sans cette sortie, la boucle tournerait sans attendre.
            guard !Task.isCancelled, isLive(run), view.stage.isCapturing else { return }
            // Échap d'abord : annuler l'emporte sur terminer, si les deux se produisent dans le même intervalle.
            if self.hold.escapeHeld() {
                log.notice("maintien : Échap lu pendant la dictée")
                escapePressed()
                return
            }
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
        var vocabularyModelUnavailable = false
        if download {
            run.downloadNotice = Self.downloadNotice
            refreshNotice(run)
            // Par le catalogue des modèles : un seul téléchargement par modèle, visible dans les réglages. Avant le comptage
            // du vocabulaire, qui a besoin du tokenizer que ce téléchargement apporte.
            do {
                vocabularyModelUnavailable = try await environment.downloadModels(settings).vocabularyModelUnavailable
            } catch {
                guard isLive(run) else { return }
                log.error("téléchargement des modèles échoué")
                finishRun(
                    run, with: .failed(.engine("le téléchargement du modèle a échoué")),
                    notice: Self.preparationFailedNotice)
                return
            }
            guard isLive(run) else { return }
            // Le téléchargement est fini : sa mention ne reste pas pendant le chargement qui suit.
            run.downloadNotice = nil
        }

        // Les moteurs se chargent en mémoire pendant la préparation de la session : la mention le dit, sauf s'ils le sont déjà
        // (préchargement au lancement, dictée précédente), où la préparation est instantanée.
        let loaded = await environment.enginesLoaded(settings)
        guard isLive(run) else { return }
        run.loadingNotice = loaded ? nil : Self.loadingNotice
        refreshNotice(run)

        // La règle du vocabulaire, la même que celle de l'entretien (`EffectiveVocabulary`) : petit modèle absent, aucun terme ;
        // sous WhisperKit, les premiers termes qui tiennent dans l'amorce, aucun si la longueur ne se compte pas. La dictée ne doit
        // jamais échouer à cause du vocabulaire ; la notice dit ce qui n'a pas servi.
        var effective = settings
        if let vocabulary = await EffectiveVocabulary.resolve(
            for: settings, vocabularyModelUnavailable: vocabularyModelUnavailable, activity: .dictation,
            limit: environment.promptTokenLimit, count: environment.promptTokenCount)
        {
            guard isLive(run) else { return }
            effective.vocabulary = vocabulary.terms
            run.vocabularyNotice = vocabulary.notice
            refreshNotice(run)
        }

        // Ce que la mise en forme enverra avec la consigne : le vocabulaire que cette dictée a réellement reçu.
        run.vocabulary = effective.vocabulary
        // Le micro d'un entretien qui s'arrête (annulé à l'instant) est rendu avant d'en ouvrir un autre.
        await interview?.waitUntilStopped()
        guard isLive(run) else { return }
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
        // Le texte final est parti au modèle : ce que la session dit ensuite ne change plus l'écran.
        guard !run.rewriting else { return }
        switch snapshot.phase {
        case .idle:
            return
        case .preparing: handleActive(snapshot, run, stage: .preparing)
        case .recording: handleActive(snapshot, run, stage: .recording)
        case .finalizing: handleActive(snapshot, run, stage: .finalizing)
        case .finished(let text):
            finished(text, run)
        case .cancelled:
            // Nous n'avons rien demandé : la session s'est arrêtée seule. Le panneau le dit.
            log.notice("session annulée sans demande")
            finishRun(run, with: .cancelled, notice: Self.interruptedNotice)
        case .failed(let failure):
            // Une panne du moteur pendant la préparation : le texte de la raison peut porter une adresse, la phrase est fixe.
            var message = failure.message
            if case .engine = failure, view.stage == .preparing || view.stage == .correcting(.preparing) {
                message = Self.preparationFailedNotice
            }
            log.notice("dictée en échec : \(Self.kind(of: failure), privacy: .public)")
            finishRun(run, with: .failed(failure), notice: message)
        }
    }

    /// Une phase active de la session (`preparing`, `recording`, `finalizing`) : l'étape d'écran est donnée par chacun des trois
    /// cas de `handle`, de sorte qu'un futur cas de `DictationPhase` ne puisse pas être avalé par un défaut.
    private func handleActive(_ snapshot: DictationSnapshot, _ run: Run, stage: DictationStage) {
        var next = view
        // Une correction montre les mêmes phases sous ses propres étapes ; le texte en direct est celui de la consigne.
        let shown: DictationStage = run.isCorrection ? .correcting(Self.step(of: stage)) : stage
        next.stage = shown
        next.liveText = snapshot.liveText
        next.elapsed = snapshot.elapsed
        if stage == .recording {
            run.downloadNotice = nil
            run.loadingNotice = nil
            next.levels = Array((view.levels + [snapshot.level]).suffix(DictationViewState.levelCount))
        }
        next.notice = notice(for: run, stage: shown)
        setView(next)
        // La prise est finie : plus rien à surveiller.
        if stage == .finalizing { run.watch?.cancel() }
        replayPendingFinish(run)
    }

    private func finished(_ text: String, _ run: Run) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            finishRun(run, with: .failed(.noSpeech), notice: DictationFailure.noSpeech.message)
            return
        }
        // La session d'une correction rend la consigne dite : elle n'est ni collée ni gardée comme dernier texte.
        if run.isCorrection {
            startRewriting(change: text, run)
            return
        }
        lastTranscript = text
        switch run.plan {
        case .rewrite(let instruction, let model, _):
            startFormatting(text, instruction: instruction, model: model, run)
        case .raw, .interview, .missing:
            deliver(text, run)
        }
    }

    /// Le texte final est prêt : il passe en relecture, ou s'insère. `previous` : le texte d'avant la mise en forme.
    private func deliver(_ text: String, _ run: Run, previous: String? = nil) {
        if run.reviewsBeforePaste {
            startReview(text, notice: notice(for: run, stage: .review), previous: previous, after: run)
            return
        }
        // Le panneau garde « Copier » à jour dès que le texte existe, sans attendre la fin de l'insertion.
        setView(view)
        log.notice("dictée terminée ; insertion")
        let previous = insertionTail
        insertionsInFlight += 1
        let task = Task { [weak self] in
            guard let self else { return }
            defer { insertionsInFlight -= 1 }
            // Une insertion encore en route, même d'une dictée annulée, se termine avant celle-ci.
            await previous?.value
            guard self.isLive(run) else { return }
            let outcome = await self.inserter.insert(text)
            self.insertionFinished(run, text: text, outcome: outcome)
        }
        run.insertion = task
        insertionTail = task
    }

    /// Le texte que la relecture remplace : la transcription brute d'un texte mis en forme, `nil` sinon. La relecture le rend
    /// comme « version précédente ».
    var reviewPreviousText: String? { review?.previous }

    /// Vrai tant qu'une insertion est en route : le texte est (peut-être) dans le presse-papiers, le ⌘V est (peut-être) posté,
    /// et le contenu d'origine n'est pas encore rendu. Quitter à ce moment le perdrait.
    public var isInserting: Bool { insertionsInFlight > 0 }

    /// Rend la main quand les insertions en route sont finies (restauration du presse-papiers comprise), ou au bout de `timeout`
    /// secondes (`wait` : injectée, aucun test n'attend une durée réelle). Sans insertion en route, rend aussitôt. L'insertion
    /// elle-même n'est pas interrompue par le délai : seule l'attente l'est.
    public func finishInsertion(timeout: Double, wait: @escaping @Sendable (Double) async -> Void) async {
        guard isInserting, let tail = insertionTail else { return }
        // Une course entre la fin de l'insertion et le délai, sans `TaskGroup` : un groupe attendrait aussi la tâche perdante
        // avant de rendre la main, et `await tail.value` ne s'interrompt pas.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let first = FirstToFinish(continuation)
            Task { await tail.value; first.resume() }
            Task { await wait(timeout); first.resume() }
        }
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
            finishRun(run, with: .copied, notice: reason)
        case .clipboardRefused:
            // Rien n'est collé ni copié : le texte reste dans « Dernière dictée » (`lastTranscript`), que l'on peut copier.
            log.notice("presse-papiers : texte refusé")
            finishRun(run, with: .failed(.clipboard), notice: DictationFailure.clipboard.message)
        case .nothing:
            // Ne peut pas arriver pour un texte non vide et une tâche non annulée.
            finishRun(run, with: .failed(.noSpeech), notice: DictationFailure.noSpeech.message)
        }
    }

    /// La dictée est finie : le panneau reste ouvert avec ce qu'il y a à dire.
    private func finishRun(_ run: Run, with stage: DictationStage, notice: String) {
        guard isLive(run) else { return }
        if run.isCorrection {
            // Une correction n'a pas d'écran d'échec : la relecture revient, le texte intact, avec la phrase de la panne.
            let said = stage == .cancelled ? Self.correctionInterruptedNotice : notice + " " + Self.correctionKeptSentence
            correctionFailed(run, noSpeech: stage == .failed(.noSpeech), notice: said)
            return
        }
        retire(run)
        var next = view
        next.stage = stage
        next.notice = notice
        setView(next)
    }

    // MARK: - Mise en forme

    /// Le texte brut part au modèle du mode. La dictée reste vivante (`isBusy` : le modèle sert) mais ne reçoit plus rien d'une
    /// session : seuls le texte et l'issue de cette mise en forme comptent, tant que `run` est la dictée courante et qu'elle
    /// attend encore sa réponse (`Run.rewriting`). Annulée (Échap, fermeture du panneau), ce qui arrive ensuite est ignoré.
    private func startFormatting(_ text: String, instruction: String, model: ModelChoice?, _ run: Run) {
        log.notice("dictée terminée ; mise en forme")
        let prompt = RewritePrompt.format(instruction: instruction, text: text, vocabulary: run.vocabulary)
        let job = RewriteJob(instruction: prompt.instruction, input: prompt.input, model: model)
        run.rewriting = true
        // Sans relecture, le texte se collera tout seul à l'arrivée : on retient où l'utilisateur est maintenant.
        if !run.reviewsBeforePaste { run.frontApplicationAtStart = frontApplication() }
        var next = view
        next.stage = .formatting
        next.liveText = ""
        next.notice = rewriter.providerName(model).map(Self.formattingNotice(provider:))
        setView(next)
        let environment = rewriter
        run.rewrite = Task { [weak self] in
            let outcome = await environment.rewrite(job) { [weak self] partial in self?.formattingText(partial, run) }
            self?.formattingFinished(outcome, raw: text, run)
        }
    }

    private func formattingText(_ text: String, _ run: Run) {
        guard isLive(run), run.rewriting, view.stage == .formatting else { return }
        var next = view
        next.liveText = text
        setView(next)
    }

    private func formattingFinished(_ outcome: RewriteOutcome, raw: String, _ run: Run) {
        guard isLive(run), run.rewriting else { return }
        run.rewriting = false
        run.rewrite = nil
        switch outcome {
        case .rewritten(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            log.notice("mise en forme terminée")
            // Voulu : le texte mis en forme remplace la transcription brute comme dernier texte (sans relecture, elle n'est plus
            // récupérable après le collage ; avec relecture, elle est la version précédente).
            lastTranscript = text
            var next = view
            next.liveText = text
            setView(next)
            // Sans relecture, le texte se collerait dans l'application où l'utilisateur est allé entre-temps : il attend en
            // relecture. Si l'une des deux lectures ne sait pas dire, on colle comme avant.
            if !run.reviewsBeforePaste, let start = run.frontApplicationAtStart, let now = frontApplication(), start != now {
                log.notice("mise en forme terminée ; application au premier plan changée : relecture")
                startReview(
                    text, notice: Self.frontApplicationChangedNotice, previous: raw, keyboard: .available, after: run)
                return
            }
            deliver(text, run, previous: raw)
        case .rewritten:
            formattingFailed(.empty, raw: raw, run)
        case .failed(let failure):
            formattingFailed(failure, raw: raw, run)
        case .cancelled:
            // Seule l'annulation de la dictée annule la tâche, et elle la retire d'abord : une dictée vivante n'a pas demandé cette fin.
            formattingFailed(.interrupted, raw: raw, run)
        }
    }

    /// Le modèle a échoué : la transcription brute revient en relecture, avec la phrase de la panne, que le mode relise ou non.
    /// Rien n'est inséré : le texte brut n'est pas celui que l'utilisateur attendait.
    private func formattingFailed(_ failure: RewriteFailure, raw: String, _ run: Run) {
        log.notice("mise en forme échouée ; relecture du texte brut")
        startReview(raw, notice: failure.message + " " + Self.rawTextNotice, after: run)
    }

    // MARK: - Relecture

    /// Le texte final n'est pas inséré : la dictée est finie, le texte attend dans `draft` et le panneau prend la frappe.
    private func startReview(
        _ text: String, notice: String?, previous: String? = nil, keyboard: PanelKeyboard = .focused, after run: Run
    ) {
        log.notice("dictée terminée ; relecture")
        retire(run)
        review = Review(previous: previous, settings: run.settings)
        setView(DictationViewState(stage: .review, notice: notice, draft: text))
        if !panel.isOpen { panel.open() }
        panel.setKeyboard(keyboard)
    }

    /// Le texte d'un entretien (prompt rédigé, ou conversation gardée) passe en relecture, sans dictée : mêmes vues, mêmes versions,
    /// même correction à la voix que la relecture d'une dictée, avec les réglages de transcription en vigueur.
    private func openReview(_ text: String, notice: String) {
        log.notice("entretien terminé ; relecture")
        review = Review(previous: nil, settings: settings())
        setView(DictationViewState(stage: .review, notice: notice, draft: text))
        if !panel.isOpen { panel.open() }
        panel.setKeyboard(.focused)
    }

    /// L'utilisateur a modifié le texte. Ignoré hors relecture (et pendant le collage : le texte qui part est celui qu'on a vu).
    public func reviewEdited(_ text: String) {
        guard review != nil, view.stage == .review else { return }
        var next = view
        next.draft = text
        setView(next)
    }

    /// « Coller » : le brouillon est inséré dans l'application de dessous. Dans l'ordre : l'étape `pasting` et le dernier texte,
    /// la frappe rendue à l'application, l'attente de `focusHandoverDelay`, l'insertion qui laisse le texte copié. Le tout par
    /// la file des insertions. Ignoré hors relecture, pendant un collage déjà lancé, et si le brouillon est blanc.
    public func pasteReview() {
        guard let review, view.stage == .review else { return }
        let text = view.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        log.notice("relecture : collage")
        // Dès l'étape `pasting` : quitter attend la fin du collage, la tâche qui suit défait ce compte.
        insertionsInFlight += 1
        lastTranscript = text
        var next = view
        next.stage = .pasting
        next.notice = nil
        setView(next)
        panel.setKeyboard(.none)
        let previous = insertionTail
        let task = Task { [weak self] in
            guard let self else { return }
            defer { insertionsInFlight -= 1 }
            await self.wait(Self.focusHandoverDelay)
            // Une insertion encore en route, même d'une dictée annulée, se termine avant celle-ci.
            await previous?.value
            // Échap ou la fermeture du panneau pendant l'attente : rien n'est inséré.
            guard self.isLive(review), !Task.isCancelled else { return }
            let outcome = await self.inserter.insert(text, leaveCopied: true)
            self.reviewInsertionFinished(review, outcome: outcome)
        }
        review.pasting = task
        insertionTail = task
    }

    private func reviewInsertionFinished(_ review: Review, outcome: InsertionOutcome) {
        guard isLive(review) else { return }
        switch outcome {
        case .pasted:
            log.notice("texte collé")
            self.review = nil
            setView(DictationViewState())
            panel.close()
        case .copied(let reason):
            log.notice("relecture : texte copié, non collé")
            backToReview(review, notice: reason)
        case .clipboardRefused:
            log.notice("relecture : presse-papiers : texte refusé")
            backToReview(review, notice: Self.reviewClipboardNotice)
        case .nothing:
            // Ne peut pas arriver pour un texte non blanc et une tâche non annulée : le texte reste à relire.
            backToReview(review, notice: nil)
        }
    }

    /// Le collage n'a pas eu lieu : le texte revient en relecture, intact, avec ce qu'il y a à dire. La frappe reste à
    /// l'application de dessous tant que l'utilisateur n'a pas cliqué dans le panneau.
    private func backToReview(_ review: Review, notice: String?) {
        review.pasting = nil
        var next = view
        next.stage = .review
        next.notice = notice
        setView(next)
        panel.setKeyboard(.available)
    }

    /// La relecture est finie sans collage (Échap, fermeture du panneau) : un collage qui n'a pas posé ⌘V est annulé, et le
    /// brouillon, s'il n'est pas blanc, devient le dernier texte (sinon le texte d'origine reste).
    private func closeReview() {
        guard let review else { return }
        review.pasting?.cancel()
        self.review = nil
        if !view.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastTranscript = view.draft }
        log.notice("relecture fermée")
    }

    // MARK: - Correction à la voix

    /// « Corriger à la voix » (le bouton), ou l'appui global en relecture. Ignoré hors relecture (au repos, en dictée, pendant le
    /// collage), pour un texte blanc, et pendant une correction. Le bouton ne tient aucune touche : la correction se termine par
    /// `finishCorrection()` ou par un appui global, même si le réglage est « maintien ».
    public func startCorrection() {
        beginCorrection(hold: false)
    }

    private func beginCorrection(hold: Bool) {
        guard run == nil, let review, view.stage == .review,
            !view.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        guard microphoneAllowed() else {
            // La ligne des permissions du panneau dit ce qui manque ; la relecture reste telle quelle.
            log.notice("correction refusée : micro non autorisé")
            var next = view
            next.notice = Self.correctionMicrophoneNotice
            setView(next)
            return
        }
        // Les modificateurs du raccourci global, lus ici une seule fois (maintien seulement : le bouton ne tient aucune touche).
        let run = Run(
            startedByHold: hold, owner: .global, modifiers: hold ? hotKeyModifiers() : [], reviewsBeforePaste: true,
            plan: .raw(engine: nil), settings: review.settings, isCorrection: true)
        self.run = run
        // Posé tout de suite : un appui qui arrive avant la première session est déjà ignoré. Le brouillon n'y bouge pas.
        var next = view
        next.stage = .correcting(.preparing)
        next.liveText = ""
        next.levels = []
        next.elapsed = 0
        next.notice = notice(for: run, stage: next.stage)
        setView(next)
        log.notice("correction commencée ; maintien : \(hold, privacy: .public)")
        run.task = Task { await self.execute(run, settings: review.settings) }
        if hold { run.watch = Task { await self.watchModifiers(run) } }
    }

    /// « Terminer » : la consigne est dite. Sans effet hors enregistrement d'une correction.
    public func finishCorrection() {
        guard let run, run.isCorrection, view.stage == .correcting(.recording) else { return }
        requestFinish(run)
    }

    /// La consigne est transcrite : le texte du brouillon et elle partent au modèle fort. Le brouillon reste en place ; seul le
    /// texte reçu en flux est montré à sa place.
    private func startRewriting(change: String, _ run: Run) {
        log.notice("correction : consigne transcrite ; réécriture")
        let prompt = RewritePrompt.correction(text: view.draft, change: change, vocabulary: run.vocabulary)
        let job = RewriteJob(instruction: prompt.instruction, input: prompt.input, model: nil)
        run.rewriting = true
        run.watch?.cancel()
        var next = view
        next.stage = .correcting(.rewriting)
        next.liveText = ""
        next.notice = Self.correctionRewritingNotice
        setView(next)
        let environment = rewriter
        run.rewrite = Task { [weak self] in
            let outcome = await environment.rewrite(job) { [weak self] partial in self?.correctionText(partial, run) }
            self?.correctionFinished(outcome, run)
        }
    }

    /// Seuls le texte et l'issue de la correction courante comptent (règle commune avec la mise en forme).
    private func correctionText(_ text: String, _ run: Run) {
        guard isLive(run), run.isCorrection, run.rewriting, view.stage == .correcting(.rewriting) else { return }
        var next = view
        next.liveText = text
        setView(next)
    }

    private func correctionFinished(_ outcome: RewriteOutcome, _ run: Run) {
        guard isLive(run), run.isCorrection, run.rewriting, let review else { return }
        run.rewriting = false
        run.rewrite = nil
        let draft = view.draft
        switch outcome {
        case .rewritten(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                correctionFailed(run, failure: .empty)
            } else if trimmed == draft.trimmingCharacters(in: .whitespacesAndNewlines) {
                log.notice("correction : texte inchangé")
                retire(run)
                returnToReview(notice: Self.correctionUnchangedNotice)
            } else {
                log.notice("correction terminée")
                retire(run)
                review.previousVersions.append(draft)
                review.nextVersions.removeAll()
                returnToReview(notice: nil, draft: text)
            }
        case .failed(let failure):
            correctionFailed(run, failure: failure)
        case .cancelled:
            // Seule l'annulation de la correction annule la tâche, et elle la retire d'abord : une correction vivante n'a pas demandé cette fin.
            correctionFailed(run, failure: .interrupted)
        }
    }

    /// Le modèle a échoué : sa phrase, et le texte n'a pas changé (sauf `noModel`, dont la phrase le dit).
    private func correctionFailed(_ run: Run, failure: RewriteFailure) {
        log.notice("correction échouée")
        retire(run)
        returnToReview(notice: Self.correctionNotice(for: failure))
    }

    /// Une autre fin de la correction : consigne blanche (ou « aucune parole »), préparation en échec, session interrompue.
    private func correctionFailed(_ run: Run, noSpeech: Bool, notice: String) {
        log.notice("correction échouée avant la réécriture")
        retire(run)
        returnToReview(notice: noSpeech ? Self.correctionEmptyNotice : notice)
    }

    /// La correction est finie ou annulée : la relecture revient, éditable, avec ce qu'il y a à dire. Le brouillon n'est jamais
    /// touché ici. La frappe revient au champ : le panneau n'a pas changé de clavier, le champ redevient éditable.
    private func returnToReview(notice: String?, draft: String? = nil) {
        guard review != nil, view.stage.isCorrecting || view.stage == .review else { return }
        var next = view
        next.stage = .review
        if let draft { next.draft = draft }
        next.notice = notice
        next.liveText = ""
        next.levels = []
        next.elapsed = 0
        setView(next)
    }

    private static func step(of stage: DictationStage) -> CorrectionStep {
        switch stage {
        case .recording: .recording
        case .finalizing: .transcribing
        default: .preparing
        }
    }

    /// « Version précédente » (et ⌘Z quand la pile du champ est vide) : le texte courant, avec ce qui y a été tapé, passe dans les
    /// versions suivantes ; la précédente devient le texte. Sans version précédente, ou hors relecture : sans effet.
    public func previousVersion() {
        guard let review, view.stage == .review, let version = review.previousVersions.popLast() else { return }
        review.nextVersions.append(view.draft)
        show(version)
    }

    /// L'inverse de `previousVersion()` (⇧⌘Z quand la pile du champ n'a plus rien à refaire).
    public func nextVersion() {
        guard let review, view.stage == .review, let version = review.nextVersions.popLast() else { return }
        review.previousVersions.append(view.draft)
        show(version)
    }

    private func show(_ version: String) {
        var next = view
        next.draft = version
        next.notice = nil
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
        run.rewrite?.cancel()
        run.rewriting = false
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

    /// `review` est la relecture courante : une relecture fermée ou collée n'est plus `self.review`.
    private func isLive(_ review: Review) -> Bool { self.review === review }

    /// Toute vue passe ici : elle porte toujours le dernier texte du contrôleur, jamais une autre copie.
    private func setView(_ next: DictationViewState) {
        var next = next
        next.lastTranscript = lastTranscript
        // Les versions ne se parcourent qu'en relecture : ni pendant une correction, ni pendant le collage.
        next.canGoBack = next.stage == .review && review?.previousVersions.isEmpty == false
        next.canGoForward = next.stage == .review && review?.nextVersions.isEmpty == false
        view = next
        onViewChange?(next)
    }

    private func refreshNotice(_ run: Run) {
        guard isLive(run), view.stage.isActive || view.stage.isCorrecting else { return }
        var next = view
        next.notice = notice(for: run, stage: view.stage)
        setView(next)
    }

    /// L'avis d'une dictée en cours : la mention de téléchargement (pendant le téléchargement), celle de chargement (pendant le
    /// chargement des moteurs), puis celui du vocabulaire.
    private func notice(for run: Run, stage: DictationStage) -> String? {
        var lines: [String] = []
        // Avant l'écoute, rien ne s'entend et ni un appui ni « Terminer » n'agit : la phrase dit d'attendre (en maintien, de garder
        // la touche) ; la phrase qui dit comment terminer ne vient qu'avec l'enregistrement.
        if stage == .correcting(.preparing) {
            lines.append(Self.correctionPreparingSentence(hotKeyLabel: hotKeyLabel(), hold: run.startedByHold))
        } else if stage == .correcting(.recording) {
            lines.append(Self.correctionListeningNotice(hotKeyLabel: hotKeyLabel(), hold: run.startedByHold))
        }
        if stage == .preparing || stage == .correcting(.preparing), let download = run.downloadNotice { lines.append(download) }
        if stage == .preparing || stage == .correcting(.preparing), let loading = run.loadingNotice { lines.append(loading) }
        if let vocabulary = run.vocabularyNotice { lines.append(vocabulary) }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// La nature d'un échec pour le journal : jamais sa raison (qui peut porter une adresse).
    private static func kind(of failure: DictationFailure) -> String {
        switch failure {
        case .noSpeech: "aucune parole"
        case .microphone: "micro"
        case .clipboard: "presse-papiers"
        case .engine: "moteur"
        }
    }

}

/// Reprend la continuation une seule fois, par le premier qui arrive.
private final class FirstToFinish: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?>

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = Mutex(continuation) }

    func resume() {
        let taken = continuation.withLock { value -> CheckedContinuation<Void, Never>? in
            defer { value = nil }
            return value
        }
        taken?.resume()
    }
}

/// Une dictée : de l'appui à la fin du collage ou de l'échec.
@MainActor
private final class Run {
    /// Commencée par un appui en maintien : seul le relâchement qui suit la termine.
    let startedByHold: Bool
    /// Le raccourci qui l'a commencée : lui seul la termine, en bascule comme en maintien.
    let owner: HotKeyOwner
    /// Les modificateurs de ce raccourci, que la surveillance du maintien lit ; vides hors maintien.
    let modifiers: Modifiers
    /// Le réglage « relire avant de coller » du mode, tel qu'il était à l'appui.
    let reviewsBeforePaste: Bool
    /// Ce que le mode fait du texte, tel qu'il était à l'appui.
    let plan: ModeRun
    /// Le vocabulaire que la session a reçu (celui de la mise en forme).
    var vocabulary: [String] = []
    /// La mise en forme attend sa réponse : tant que c'est vrai, son texte et son issue comptent.
    var rewriting = false
    /// L'application au premier plan au début de la mise en forme d'un mode sans relecture (`nil` : inconnue, ou relecture).
    var frontApplicationAtStart: Int32?
    var rewrite: Task<Void, Never>?
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
    var loadingNotice: String?
    var vocabularyNotice: String?

    /// Les réglages de transcription de cette dictée, moteur du mode compris.
    let settings: TranscriptionSettings
    /// Cette `Run` corrige la relecture courante (`DictationController.beginCorrection`) au lieu de dicter un texte.
    let isCorrection: Bool

    init(
        startedByHold: Bool, owner: HotKeyOwner, modifiers: Modifiers, reviewsBeforePaste: Bool, plan: ModeRun,
        settings: TranscriptionSettings, isCorrection: Bool = false
    ) {
        self.startedByHold = startedByHold
        self.owner = owner
        self.modifiers = modifiers
        self.reviewsBeforePaste = reviewsBeforePaste
        self.plan = plan
        self.settings = settings
        self.isCorrection = isCorrection
    }
}

/// Une relecture : du texte final au collage, à l'annulation ou à la fermeture du panneau. Relue comme une `Run`
/// (`DictationController.isLive`) : ce qui arrive d'une insertion de cette relecture ne compte que tant qu'elle est la
/// relecture courante.
@MainActor
private final class Review {
    /// La tâche de collage lancée par `pasteReview()` ; `nil` tant que le texte n'a pas été collé, et de nouveau `nil` si
    /// le collage a laissé le texte en relecture.
    var pasting: Task<Void, Never>?
    /// Le texte d'avant la mise en forme (la transcription brute), `nil` si le texte n'a pas été mis en forme.
    let previous: String?

    /// Les réglages de transcription de la dictée relue (moteur du mode compris) : une correction les reprend.
    let settings: TranscriptionSettings
    /// Les versions d'avant le texte courant, la plus proche en dernier ; la transcription brute d'un texte mis en forme est la
    /// première (`previous`).
    var previousVersions: [String]
    /// Les versions d'après, la plus proche en dernier : ce que « Version précédente » a laissé derrière.
    var nextVersions: [String] = []

    init(previous: String? = nil, settings: TranscriptionSettings) {
        self.previous = previous
        self.settings = settings
        previousVersions = previous.map { [$0] } ?? []
    }
}
