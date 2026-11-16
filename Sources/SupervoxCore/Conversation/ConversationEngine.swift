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
}

/// Pourquoi un entretien s'est arrêté sur une panne. La chaîne est une raison technique (un code), jamais montrée.
public enum ConversationFailure: Equatable, Sendable {
    case microphone(String)
    case engine(String)
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
    /// Le niveau (0 à 1) de la tranche de micro qui vient d'être traitée, pendant l'écoute.
    case level(Float)
    /// Le texte provisoire du passage encore ouvert.
    case partialTranscript(String)
    /// La personne a fini son tour : le texte transcrit.
    case turnEnded(String)
    /// Le texte de la réplique de l'intervieweur, cumulé, sans marqueur.
    case replyText(String)
    /// La première phrase de la réplique est mise en file (ou affichée seule, sans voix). `question` : le numéro de la question
    /// posée (la première est la 1), ou celui de la dernière posée quand la réplique est la phrase de fin.
    case speakingStarted(question: Int)
    /// Une phrase a fini d'être jouée, jusqu'au dernier échantillon.
    case sentencePlayed(String)
    /// La réplique est finie ; `heard` : les phrases entendues, jointes par une espace (ce que la conversation retient).
    case speakingEnded(heard: String)
    /// La personne a coupé la parole : `heard` est ce qu'elle avait entendu. (Réservé à l'interruption.)
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
    /// La durée de voix au-dessus de `interruptLevel` qui coupe la parole de l'outil (lue par l'interruption).
    public var interruptMinDuration: Double
    /// Le niveau, en dB pleine échelle, au-dessus duquel la voix compte pour couper la parole (lu par l'interruption).
    public var interruptLevel: Double
    /// Secondes de silence gardées de chaque côté d'un passage transcrit.
    public var padding: Double
    /// Secondes entre deux transcriptions provisoires d'un passage ouvert.
    public var previewInterval: Double
    public var turnPolicy: RewritePolicy
    public var conclusionPolicy: RewritePolicy

    public init(fastModel: String, strongModel: String, maxQuestions: Int, template: String, language: String, vocabulary: [String],
                interruptMinDuration: Double, interruptLevel: Double, padding: Double = 0.3, previewInterval: Double = 1,
                turnPolicy: RewritePolicy = .turn, conclusionPolicy: RewritePolicy = .standard) {
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
        self.turnPolicy = turnPolicy
        self.conclusionPolicy = conclusionPolicy
    }
}

extension RewritePolicy {
    /// La requête d'un tour de l'entretien : 1 024 jetons (une réplique de quelques phrases courtes) et 30 secondes. Choix non
    /// mesuré ; la mesure du design (section 9) donne un premier son à 1,87 s de médiane sur 40 tours, le 2026-11-13.
    public static let turn = RewritePolicy(maxTokens: 1_024, timeout: 30)
}
