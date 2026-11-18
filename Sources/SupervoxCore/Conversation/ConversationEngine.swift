import Foundation

/// Où en est l'entretien. `finished` suit toujours la dernière étape, juste avant `ConversationEvent.finished`.
public enum ConversationState: Equatable, Sendable {
    case preparing, listening, thinking, speaking, concluding, finished
}

/// Un fait que l'interface peut dire à la personne sans que l'entretien s'arrête. La phrase montrée vient d'une table fixe de
/// l'interface : aucun de ces cas ne porte le texte d'une erreur.
public enum ConversationNotice: Equatable, Sendable {
    /// Le tour entendu n'a donné aucun texte : la personne est invitée à répéter.
    case notUnderstood
    /// Le modèle rapide n'a pas répondu : le tour de la personne reste dans la conversation, l'écoute reprend.
    case modelFailed(RewriteFailure)
    /// La voix choisie a échoué : la voix de secours a parlé (dit une seule fois par entretien).
    case voiceFellBack
    /// Aucune voix ne parle : la réplique est affichée, la personne la lit (dit une seule fois par entretien).
    case voiceUnavailable
    /// L'intervieweur demande s'il peut conclure.
    case proposal
    /// La question qui vient est la dernière.
    case lastQuestion
    /// « Conclure » est demandé, mais les derniers mots de la personne n'ont pas pu être transcrits (panne ou délai du moteur) :
    /// le prompt est rédigé avec les tours déjà là, sans eux. Sans aucun tour avant, c'est une panne (`.failed`), pas cet avis.
    case lastWordsLost
}

/// Pourquoi un entretien s'est arrêté sur une panne. La chaîne est un **code** stable (voir `Code`), jamais une phrase ni le message
/// d'une erreur : l'interface le traduit par une table de phrases fixes.
public enum ConversationFailure: Equatable, Sendable {
    case microphone(String)
    case engine(String)

    /// Les codes que rend le moteur, par genre de panne. Une valeur ne change pas de sens d'une version à l'autre.
    public enum Code {
        // Micro (`.microphone`) : le genre de `AudioCaptureError`, puis les pannes en cours d'entretien.
        public static let microphoneAccessDenied = "microphoneAccessDenied"
        public static let noInputDevice = "noInputDevice"
        public static let alreadyRunning = "alreadyRunning"
        public static let engineFailed = "engineFailed"
        public static let notRunning = "notRunning"
        /// Plus aucune tranche n'arrive du micro (casque débranché, entrée changée).
        public static let silent = "silent"
        /// La fréquence du micro ne peut pas être convertie à 16 kHz.
        public static let unusableSampleRate = "unusableSampleRate"
        public static let conversionFailed = "conversionFailed"
        // Moteurs (`.engine`).
        public static let detectorFailed = "detectorFailed"
        public static let transcriptionUnsupportedSampleRate = "transcriptionUnsupportedSampleRate"
        public static let transcriptionNotPrepared = "transcriptionNotPrepared"
        public static let transcriptionUnsupportedLocale = "transcriptionUnsupportedLocale"
        public static let transcriptionVocabularyUnavailable = "transcriptionVocabularyUnavailable"
        public static let transcriptionFailed = "transcriptionFailed"
        /// Le moteur de transcription n'a rien rendu dans `ConversationConfig.transcriptionTimeout`.
        public static let transcriptionTimedOut = "transcriptionTimedOut"
        /// Une erreur dont le genre n'est pas connu (jamais son texte).
        public static let unexpected = "unexpected"
    }
}

/// Comment l'entretien s'est terminé. Toute fin après au moins un tour de la personne rend la conversation : l'appelant ne perd
/// rien de ce qui a été dit.
public enum ConversationEnd: Equatable, Sendable {
    /// Le prompt rédigé par le modèle fort, et la conversation dont il vient.
    case prompt(String, Conversation)
    /// Le modèle fort n'a pas rédigé : la conversation reste.
    case conclusionFailed(RewriteFailure, Conversation)
    case failed(ConversationFailure, Conversation)
    /// La personne n'a rien dit : aucune requête n'a été faite.
    case nothingSaid
    case cancelled
}

/// Ce que l'entretien raconte à l'interface, dans l'ordre où cela arrive.
public enum ConversationEvent: Equatable, Sendable {
    case state(ConversationState)
    /// Le niveau (0 à 1) de la tranche de micro qui vient d'être traitée. L'écoute est continue : pendant que l'outil transcrit,
    /// réfléchit ou parle aussi.
    case level(Float)
    /// Le texte provisoire du passage encore ouvert.
    case partialTranscript(String)
    /// La personne a fini son tour : le texte transcrit.
    case turnEnded(String)
    /// Le texte de la réplique de l'intervieweur, cumulé, sans marqueur.
    case replyText(String)
    /// La première phrase de la réplique commence à être jouée (ou est affichée seule, sans voix). `question` : le numéro de la
    /// question posée (la première est la 1), ou celui de la dernière posée quand la réplique est la phrase de fin. Une réplique coupée
    /// avant ce moment n'est pas une question, et cet événement n'est pas émis.
    case speakingStarted(question: Int)
    /// Une phrase a fini d'être jouée, jusqu'au dernier échantillon.
    case sentencePlayed(String)
    /// La réplique est finie ; `heard` : les phrases entendues, jointes par une espace (ce que la conversation retient).
    case speakingEnded(heard: String)
    /// La personne a coupé la parole (assez fort et assez longtemps pour la porte d'interruption), pendant la réflexion ou la parole :
    /// la réplique est abandonnée, `heard` est ce qu'elle en avait entendu (les phrases jouées jusqu'au bout, plus la phrase coupée
    /// si la moitié au moins de sa durée a été jouée ; vide si elle a coupé avant la moitié de la première phrase), et c'est ce que
    /// la conversation retient. Remplace `speakingEnded` pour cette réplique ; l'écoute reprend ensuite.
    case interrupted(heard: String)
    case notice(ConversationNotice)
    /// Le dernier événement : émis une seule fois, après le retour de `AudioIO.stop()`, puis le flux se termine.
    case finished(ConversationEnd)
}

/// Un entretien vocal, vu de l'interface.
public protocol ConversationEngine: Sendable {
    /// Lance l'entretien et rend le flux de ses événements. À appeler une seule fois ; un second appel rend un flux déjà terminé.
    /// Le flux se termine juste après `ConversationEvent.finished`. Un flux abandonné par son lecteur annule l'entretien.
    func start() async -> AsyncStream<ConversationEvent>
    /// Demande de conclure : ce que la personne a dit est gardé, le modèle fort rédige. Sans effet une fois la conclusion lancée.
    func conclude() async
    /// Annule : aucune requête au modèle fort. Rend la main quand tout est arrêté (micro, lecture, requêtes, tâches).
    func cancel() async
}

/// Les réglages d'un entretien, tels que le moteur les lit.
public struct ConversationConfig: Sendable {
    public var fastModel: String
    public var strongModel: String
    public var maxQuestions: Int
    /// Le gabarit de la conclusion ; vide, `InterviewPrompt.defaultTemplate`.
    public var template: String
    public var language: String
    public var vocabulary: [String]
    /// Secondes de voix au niveau `interruptLevel` au moins, depuis le début d'un passage et à l'intérieur d'une fenêtre glissante
    /// de deux fois cette durée (`InterruptionGate.windowFactor`), qui coupent la parole de l'outil (lues par `InterruptionGate`). Un réglage (0,30 s par défaut, non confirmé sur le matériel).
    public var interruptMinDuration: Double
    /// Le niveau, en dB pleine échelle, à partir duquel une trame de voix compte pour couper la parole (lu par `InterruptionGate`).
    /// Un réglage (−30 dB par défaut, non confirmé sur le matériel : un bruit ambiant a été mesuré une fois jusqu'à −20,5 dB).
    public var interruptLevel: Double
    /// Secondes de silence gardées de chaque côté d'un passage transcrit : 0,3 s, choix non mesuré (même valeur que la dictée).
    public var padding: Double
    /// Secondes entre deux transcriptions provisoires d'un passage ouvert : 1 s, choix non mesuré (même valeur que la dictée).
    public var previewInterval: Double
    /// Secondes accordées au moteur de transcription pour un passage (le tour, ou un aperçu) : au-delà, le moteur est abandonné
    /// (`Deadline`, qui n'attend pas un moteur sourd à l'annulation). 120 s, comme `DictationConfig.finalTimeout` : choix non mesuré.
    public var transcriptionTimeout: Double
    public var turnPolicy: RewritePolicy
    public var conclusionPolicy: RewritePolicy

    public init(fastModel: String, strongModel: String, maxQuestions: Int, template: String, language: String, vocabulary: [String],
                interruptMinDuration: Double, interruptLevel: Double, padding: Double = 0.3, previewInterval: Double = 1,
                transcriptionTimeout: Double = 120, turnPolicy: RewritePolicy = .turn, conclusionPolicy: RewritePolicy = .standard) {
        self.fastModel = fastModel
        self.strongModel = strongModel
        self.maxQuestions = maxQuestions
        self.template = template
        self.language = language
        self.vocabulary = vocabulary
        self.interruptMinDuration = interruptMinDuration
        self.interruptLevel = interruptLevel
        self.padding = padding
        self.previewInterval = previewInterval
        self.transcriptionTimeout = transcriptionTimeout
        self.turnPolicy = turnPolicy
        self.conclusionPolicy = conclusionPolicy
    }
}

extension RewritePolicy {
    /// La requête d'un tour de l'entretien : 1 024 jetons (une réplique de quelques phrases courtes) et 30 secondes. Choix non
    /// mesuré ; la mesure du design (section 9) donne un premier son à 1,87 s de médiane sur 40 tours, le 2026-11-13.
    public static let turn = RewritePolicy(maxTokens: 1_024, timeout: 30)
}
