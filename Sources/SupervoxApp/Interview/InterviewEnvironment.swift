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
    /// Le fournisseur du modèle rapide, tel que l'utilisateur l'a nommé : celui qui reçoit le texte des réponses de la personne
    /// (`InterviewText.privacy` le rogne). Le modèle fort peut venir d'un autre fournisseur, qui reçoit alors la conversation à la
    /// conclusion : cette ligne ne le dit pas.
    public var providerName: String
    /// Le fournisseur de la voix quand elle en vient (le texte que dit Supervox part chez lui) ; `nil` quand c'est la voix du système,
    /// y compris quand la voix choisie n'a pas pu être résolue.
    public var voiceProviderName: String?

    public init(
        engine: TranscriptionEngine, fastModel: any LanguageModel, strongModel: any LanguageModel,
        voice: any SpeechSynthesizer, config: ConversationConfig, turnSilence: Double, providerName: String,
        voiceProviderName: String?
    ) {
        self.engine = engine
        self.fastModel = fastModel
        self.strongModel = strongModel
        self.voice = voice
        self.config = config
        self.turnSilence = turnSilence
        self.providerName = providerName
        self.voiceProviderName = voiceProviderName
    }

    /// Résout un entretien : les deux modèles (chacun par `ProviderResolver`, la clé lue hors du fil principal), la configuration et
    /// la voix. Rien n'est lu dans le trousseau tant que les deux modèles ne sont pas choisis.
    ///
    /// - Parameters:
    ///   - engine: le moteur du mode Entretien ; `nil` : `TranscriptionEngine.interviewDefault`.
    ///   - makeModel: fabrique le client d'un modèle (injectée : les tests n'ouvrent aucune connexion).
    ///   - makeVoice: fabrique une voix. Avec `nil`, la voix du système, pour le choix donné (`providerID`, `model` et `identifier`
    ///     à `nil` quand c'est un repli : l'identifiant d'une voix de fournisseur ne veut rien dire pour le système). Avec un
    ///     fournisseur résolu, la voix de ce fournisseur pour le choix donné.
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
            turnSilence: interview.turnSilence, providerName: fast.name, voiceProviderName: voiceProviderName)
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

    /// La voix et le nom de son fournisseur. Un fournisseur au format Anthropic n'a pas de synthèse : il est écarté avant toute lecture
    /// de sa clé (aucune invite du trousseau pour rien). Une voix de fournisseur sans modèle ou sans identifiant ne dit pas quoi
    /// demander : écartée aussi. Seule une `RewriteFailure` de la résolution retombe sur le système ; l'annulation remonte.
    @MainActor
    private static func resolveVoice(
        _ choice: VoiceChoice, settings: AppSettings, secrets: SecretAccess,
        makeVoice: @Sendable (VoiceChoice, ResolvedProvider?) -> any SpeechSynthesizer
    ) async throws -> (voice: any SpeechSynthesizer, providerName: String?) {
        guard let providerID = choice.providerID else { return (makeVoice(choice, nil), nil) }
        let systemChoice = VoiceChoice(
            providerID: nil, model: nil, identifier: nil, language: choice.language, gender: choice.gender, extra: [:])
        guard let resolved = try await resolveVoiceProvider(providerID, choice: choice, settings: settings, secrets: secrets)
        else { return (makeVoice(systemChoice, nil), nil) }
        let voice = FallbackSpeechSynthesizer(
            primary: makeVoice(choice, resolved), fallback: makeVoice(systemChoice, nil))
        return (voice, resolved.name)
    }

    @MainActor
    private static func resolveVoiceProvider(
        _ providerID: UUID, choice: VoiceChoice, settings: AppSettings, secrets: SecretAccess
    ) async throws -> ResolvedProvider? {
        guard let provider = settings.providers.first(where: { $0.id == providerID }) else { return nil }
        switch provider.kind {
        case .anthropic: return nil
        case .openAICompatible: break
        }
        func isBlank(_ text: String?) -> Bool { text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true }
        guard !isBlank(choice.model), !isBlank(choice.identifier) else { return nil }
        do {
            return try await ProviderResolver.resolve(providerID, settings: settings, secrets: secrets)
        } catch is RewriteFailure {
            return nil
        }
    }
}

/// Ce que le contrôleur de l'entretien demande au monde extérieur : préparer le moteur de transcription, construire la conversation.
/// La cible `Supervox` le construit avec les vrais moteurs (et le son réel) ; tout le reste (tests, outil de rendu, constructeurs
/// par défaut) reçoit `unavailable`. `SupervoxApp` ne dépend pas des moteurs.
public struct InterviewEnvironment: Sendable {
    /// Télécharge, si besoin, et charge le moteur de transcription et le détecteur de voix, comme la dictée. Lève si le modèle ne peut
    /// pas être obtenu ; une tâche annulée s'arrête.
    public var prepare: @Sendable (TranscriptionEngine) async throws -> Void
    /// Construit la conversation, une fois la porte de préchargement passée. Ne démarre ni micro ni son : c'est `start()`.
    public var makeConversation: @Sendable (InterviewSetup) async throws -> any ConversationEngine

    public init(
        prepare: @escaping @Sendable (TranscriptionEngine) async throws -> Void,
        makeConversation: @escaping @Sendable (InterviewSetup) async throws -> any ConversationEngine
    ) {
        self.prepare = prepare
        self.makeConversation = makeConversation
    }

    /// Ce que lèvent les deux fermetures de `unavailable` : aucun entretien n'est branché dans ce processus.
    public struct Unavailable: Error, Equatable, Sendable {}

    /// Aucun entretien branché : les deux fermetures lèvent. Le défaut de tout ce qui n'est pas l'application elle-même ; le panneau
    /// dit alors « L'entretien n'a pas pu démarrer : relancez Supervox. ».
    public static let unavailable = InterviewEnvironment(
        prepare: { _ in throw Unavailable() }, makeConversation: { _ in throw Unavailable() })
}
