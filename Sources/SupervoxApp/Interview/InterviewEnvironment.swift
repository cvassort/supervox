import Foundation
import SupervoxCore

/// Pourquoi un entretien ne démarre pas : ce que les réglages ne permettent pas, dit avant d'ouvrir le micro ou de télécharger quoi
/// que ce soit. La phrase montrée vient de `InterviewText.setupFailure`.
public enum InterviewSetupFailure: Error, Equatable, Sendable {
    /// Aucun modèle rapide n'est choisi (il pose les questions).
    case noFastModel
    /// Aucun modèle fort n'est choisi (il rédige le prompt).
    case noStrongModel
    /// Le fournisseur d'un des deux modèles n'a pas pu être résolu (`ProviderResolver`).
    case provider(RewriteFailure)
}

/// Tout ce qu'il faut pour construire un entretien, résolu à partir des réglages et du trousseau, avant d'ouvrir le micro.
public struct InterviewSetup: Sendable {
    /// Le moteur de transcription (celui du mode Entretien, ou `TranscriptionEngine.interviewDefault`).
    public var engine: TranscriptionEngine
    public var fastModel: any LanguageModel
    public var strongModel: any LanguageModel
    /// La voix de l'assistant : celle d'un fournisseur avec la voix du système en secours, ou la voix du système seule.
    public var voice: any SpeechSynthesizer
    /// Les réglages du moteur de conversation (réglages de l'entretien normalisés, langue et vocabulaire de la transcription).
    public var config: ConversationConfig
    /// Le silence qui marque la fin d'un tour, en secondes, borné (`InterviewSettings.normalized`). `ConversationConfig` ne le porte
    /// pas : c'est le détecteur de voix qui le lit, et il est construit hors du moteur (`EngineCache.detector(minSilence:)`).
    public var turnSilence: Double
    /// Les réglages de transcription de l'entretien, lus avec le reste : ceux de l'onglet Transcription, avec `engine` pour moteur.
    /// La préparation et la construction en ont besoin (variante WhisperKit, vocabulaire), et les lisent ici, une seule fois.
    public var transcription: TranscriptionSettings
    /// Le fournisseur du modèle rapide, tel que l'utilisateur l'a nommé : celui qui reçoit le texte des réponses de la personne
    /// à chaque tour (`InterviewText.privacy` le rogne).
    public var providerName: String
    /// Le fournisseur du modèle fort : celui qui reçoit la conversation entière à la conclusion. Le même que `providerName` quand
    /// les deux modèles viennent du même fournisseur ; la ligne de vie privée nomme les deux sinon.
    public var strongProviderName: String
    /// Le fournisseur de la voix quand elle en vient (le texte que dit Supervox part chez lui) ; `nil` quand c'est la voix du système,
    /// y compris quand la voix choisie n'a pas pu être résolue.
    public var voiceProviderName: String?

    public init(
        engine: TranscriptionEngine, fastModel: any LanguageModel, strongModel: any LanguageModel,
        voice: any SpeechSynthesizer, config: ConversationConfig, turnSilence: Double, transcription: TranscriptionSettings,
        providerName: String, strongProviderName: String, voiceProviderName: String?
    ) {
        self.engine = engine
        self.fastModel = fastModel
        self.strongModel = strongModel
        self.voice = voice
        self.config = config
        self.turnSilence = turnSilence
        var transcription = transcription
        transcription.engine = engine
        self.transcription = transcription
        self.providerName = providerName
        self.strongProviderName = strongProviderName
        self.voiceProviderName = voiceProviderName
    }

    /// La ligne de vie privée de cet entretien : les fournisseurs qui reçoivent du texte, et celui de la voix.
    public var privacy: String {
        InterviewText.privacy(provider: providerName, strongProvider: strongProviderName, voiceProvider: voiceProviderName)
    }

    /// Résout un entretien : les deux modèles (chacun par `ProviderResolver`, la clé lue hors du fil principal), la configuration et
    /// la voix. Rien n'est lu dans le trousseau tant que les deux modèles ne sont pas choisis.
    ///
    /// - Parameters:
    ///   - engine: le moteur du mode Entretien ; `nil` : `TranscriptionEngine.interviewDefault`.
    ///   - makeModel: fabrique le client d'un modèle (injectée : les tests n'ouvrent aucune connexion).
    ///   - makeVoice: fabrique une voix, toujours pour un choix normalisé (`VoiceChoice.normalized`). Avec `nil`, la voix du système,
    ///     pour le choix donné (`providerID`, `model` et `identifier` à `nil` quand c'est un repli : l'identifiant d'une voix de
    ///     fournisseur ne veut rien dire pour le système). Avec un fournisseur résolu, la voix de ce fournisseur pour le choix donné.
    /// - Throws: `InterviewSetupFailure`, ou `CancellationError`. Une voix de fournisseur qui ne se résout pas n'est pas une panne :
    ///   voix du système.
    @MainActor
    public static func resolve(
        settings: AppSettings, engine: TranscriptionEngine?, secrets: SecretAccess,
        makeModel: @escaping @Sendable (ProviderKind, EndpointConfig) -> any LanguageModel,
        makeVoice: @escaping @Sendable (VoiceChoice, ResolvedProvider?) -> any SpeechSynthesizer
    ) async throws -> InterviewSetup {
        guard let fastChoice = settings.fastModel else { throw InterviewSetupFailure.noFastModel }
        guard let strongChoice = settings.strongModel else { throw InterviewSetupFailure.noStrongModel }
        let fast = try await resolveModel(fastChoice, settings: settings, secrets: secrets)
        let strong = try await resolveModel(strongChoice, settings: settings, secrets: secrets)
        let (voice, voiceProviderName) = try await resolveVoice(
            settings.voice, settings: settings, secrets: secrets, makeVoice: makeVoice)

        let interview = settings.interview.normalized
        let config = ConversationConfig(
            fastModel: fastChoice.model, strongModel: strongChoice.model, maxQuestions: interview.maxQuestions,
            template: interview.template ?? InterviewPrompt.defaultTemplate, language: settings.transcription.language,
            vocabulary: settings.transcription.vocabulary, interruptMinDuration: interview.interruptMinDuration,
            interruptLevel: interview.interruptLevel)
        return InterviewSetup(
            engine: engine ?? .interviewDefault, fastModel: makeModel(fast.kind, fast.config),
            strongModel: makeModel(strong.kind, strong.config), voice: voice, config: config,
            turnSilence: interview.turnSilence, transcription: settings.transcription, providerName: fast.name,
            strongProviderName: strong.name, voiceProviderName: voiceProviderName)
    }

    @MainActor
    private static func resolveModel(
        _ choice: ModelChoice, settings: AppSettings, secrets: SecretAccess
    ) async throws -> ResolvedProvider {
        do {
            return try await ProviderResolver.resolve(choice.providerID, settings: settings, secrets: secrets)
        } catch let failure as RewriteFailure {
            throw InterviewSetupFailure.provider(failure)
        }
    }

    /// La voix et le nom de son fournisseur, par la résolution unique (`VoiceChoice.resolve(in:secrets:)` : la route, puis la clé
    /// pour une voix de fournisseur seulement ; aucune invite du trousseau pour un repli). La fabrique reçoit la forme normalisée.
    /// Une `RewriteFailure` de la résolution retombe sur le système ; l'annulation remonte. Le repli garde langue et genre, sans
    /// identifiant ; une voix de fournisseur a la voix du système en secours (`FallbackSpeechSynthesizer`).
    @MainActor
    private static func resolveVoice(
        _ choice: VoiceChoice, settings: AppSettings, secrets: SecretAccess,
        makeVoice: @Sendable (VoiceChoice, ResolvedProvider?) -> any SpeechSynthesizer
    ) async throws -> (voice: any SpeechSynthesizer, providerName: String?) {
        let choice = choice.normalized
        let systemChoice = VoiceChoice(
            providerID: nil, model: nil, identifier: nil, language: choice.language, gender: choice.gender, extra: [:])
        let resolved: ResolvedVoice
        do {
            resolved = try await choice.resolve(in: settings, secrets: secrets)
        } catch is RewriteFailure {
            return (makeVoice(systemChoice, nil), nil)
        }
        switch resolved {
        case .system(_, _, because: nil):
            return (makeVoice(choice, nil), nil)
        case .system:
            return (makeVoice(systemChoice, nil), nil)
        case .provider(let provider, _):
            let voice = FallbackSpeechSynthesizer(
                primary: makeVoice(choice, provider), fallback: makeVoice(systemChoice, nil))
            return (voice, provider.name)
        }
    }
}

/// Ce que la préparation rend : la configuration avec laquelle la conversation est fabriquée (le vocabulaire effectif, selon la règle
/// de la dictée, `EffectiveVocabulary`), et l'avis à montrer quand une partie du vocabulaire ne sert pas.
public struct InterviewPreparation: Sendable {
    public var setup: InterviewSetup
    /// Une phrase de `InterviewText` (vocabulaire), `nil` quand il n'y a rien à dire.
    public var notice: String?

    public init(setup: InterviewSetup, notice: String? = nil) {
        self.setup = setup
        self.notice = notice
    }
}

/// Ce que le contrôleur de l'entretien demande au monde extérieur : préparer le moteur de transcription, construire la conversation.
/// La cible `Supervox` le construit avec les vrais moteurs (et le son réel) ; tout le reste (tests, outil de rendu, constructeurs
/// par défaut) reçoit `unavailable`. `SupervoxApp` ne dépend pas des moteurs.
public struct InterviewEnvironment: Sendable {
    /// Télécharge, si besoin, les modèles de `setup.transcription`, puis charge le moteur de transcription (`setup.engine`, variante
    /// WhisperKit de `setup.transcription`) et le détecteur de voix de l'entretien, au silence de fin de tour `setup.turnSilence`
    /// (un exemplaire distinct de celui de la dictée, que le préchargement du lancement ne prépare pas). Sans cela, le premier tour
    /// paierait le chargement. Applique au vocabulaire la règle de la dictée (`EffectiveVocabulary`) et rend la configuration avec
    /// laquelle fabriquer la conversation. Lève si un modèle ne peut pas être obtenu ; une tâche annulée s'arrête. N'ouvre ni micro
    /// ni son.
    public var prepare: @Sendable (InterviewSetup) async throws -> InterviewPreparation
    /// Construit la conversation, une fois la porte de préchargement passée. Ne démarre ni micro ni son : c'est `start()`.
    public var makeConversation: @Sendable (InterviewSetup) async throws -> any ConversationEngine
    /// Fabrique une voix pour `InterviewSetup.resolve`. Contrat : avec `nil`, la voix **du système** pour ce choix ; avec un
    /// fournisseur résolu, la voix **de ce fournisseur**. Fabriquer ne synthétise rien.
    public var makeVoice: @Sendable (VoiceChoice, ResolvedProvider?) -> any SpeechSynthesizer
    /// Le silence de fin de tour que le détecteur de voix applique en pratique (secondes) quand on lui demande celui-ci : il ne
    /// décide qu'à la fin d'un bloc de 0,256 s. L'onglet Entretien l'affiche à côté de la valeur réglée. Le détecteur n'est pas
    /// connu de `SupervoxApp` : la cible `Supervox` donne la vraie formule ; tout le reste garde l'identité.
    public var effectiveTurnSilence: @Sendable (Double) -> Double

    public init(
        prepare: @escaping @Sendable (InterviewSetup) async throws -> InterviewPreparation,
        makeConversation: @escaping @Sendable (InterviewSetup) async throws -> any ConversationEngine,
        makeVoice: @escaping @Sendable (VoiceChoice, ResolvedProvider?) -> any SpeechSynthesizer,
        effectiveTurnSilence: @escaping @Sendable (Double) -> Double = { $0 }
    ) {
        self.prepare = prepare
        self.makeConversation = makeConversation
        self.makeVoice = makeVoice
        self.effectiveTurnSilence = effectiveTurnSilence
    }

    /// Ce que lèvent les fermetures de `unavailable` : aucun entretien n'est branché dans ce processus.
    public struct Unavailable: Error, Equatable, Sendable {}

    /// Aucun entretien branché : préparer et construire lèvent, la voix fabriquée lève à la première phrase. Le défaut de tout ce qui
    /// n'est pas l'application elle-même ; le panneau dit alors « L'entretien n'a pas pu démarrer : relancez Supervox. ».
    public static let unavailable = InterviewEnvironment(
        prepare: { _ in throw Unavailable() }, makeConversation: { _ in throw Unavailable() },
        makeVoice: { _, _ in UnavailableVoice() })

    /// La voix de `unavailable` : jamais utilisée (rien ne se construit), elle lève si on la sollicitait.
    private struct UnavailableVoice: SpeechSynthesizer {
        func synthesize(_ text: String) async throws -> Speech { throw Unavailable() }
    }
}
