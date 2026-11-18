import Foundation
import SupervoxApp
import SupervoxCore
import SupervoxEngines

/// L'environnement réel de l'entretien : les moteurs de la dictée (un seul cache, une seule porte de préchargement), le son et les
/// voix reçus en fabriques. Aucune fabrique n'a de défaut : seul `main.swift` construit le son réel (`LiveAudioIO`) et la voix du
/// système, les tests passent un son scripté et des voix doubles (amendement A de la tâche 9).
struct LiveInterview: Sendable {
    /// Ce dont une conversation est faite, une fois la porte de préchargement passée.
    struct Parts: Sendable {
        let audio: any AudioIO
        let detector: any StreamingVoiceDetector
        let transcriber: any Transcriber
        let setup: InterviewSetup
    }

    let engines: LiveDictationEngines
    /// Le son d'un entretien (micro et haut-parleur) : un neuf par conversation. Fabriquer n'ouvre rien : c'est `start()`.
    let makeAudio: @Sendable () -> any AudioIO
    /// La voix du système pour cette langue, désignée par `identifier` (`nil` : la meilleure voix de la langue). Fabriquer ne dit
    /// rien.
    let makeSystemVoice: @Sendable (_ language: String, _ identifier: String?) -> any SpeechSynthesizer
    /// La voix d'un fournisseur résolu (adresse et clé) pour ce modèle et cet identifiant. Fabriquer n'envoie rien.
    let makeProviderVoice: @Sendable (ResolvedProvider, ProviderVoice) -> any SpeechSynthesizer
    /// Assemble la conversation (en production : `LiveInterview.session`). Injecté pour que les tests voient les pièces reçues.
    let assemble: @Sendable (Parts) -> any ConversationEngine
    /// Les voix du système installées (en production : `SystemVoices.installed`, nommée par `main.swift` seul).
    let systemVoices: @Sendable () -> [SystemVoiceInfo]
    /// Le lecteur de sortie seule de l'écoute d'une voix (en production : le vrai, construit par `main.swift` seul). Fabriquer ne
    /// joue rien.
    let makePlayer: @Sendable () -> any ClipPlayer

    /// La conversation réelle : la façade du moteur (jamais `ConversationChain` directement).
    static let session: @Sendable (Parts) -> any ConversationEngine = { parts in
        ConversationSession(
            audio: parts.audio, detector: parts.detector, transcriber: parts.transcriber, fastModel: parts.setup.fastModel,
            strongModel: parts.setup.strongModel, voice: parts.setup.voice, config: parts.setup.config)
    }

    var environment: InterviewEnvironment {
        InterviewEnvironment(
            prepare: { [self] setup in try await prepare(setup) },
            makeConversation: { [self] setup in try await makeConversation(setup) },
            makeVoice: { [self] choice, provider in makeVoice(choice, provider) },
            // La formule du détecteur de voix réel : l'onglet Entretien montre ce que le réglage donne en pratique.
            effectiveTurnSilence: { FluidStreamingVoiceDetector.effectiveSilence($0) },
            systemVoices: systemVoices, makePlayer: makePlayer)
    }

    /// Télécharge ce qui manque aux réglages de transcription de l'entretien (par le catalogue, après la porte de préchargement),
    /// applique au vocabulaire la règle de la dictée (`EffectiveVocabulary`, avec le même compte de jetons), puis charge le
    /// détecteur de l'entretien, à son silence de fin de tour, et le moteur de transcription. Le préchargement du lancement ne
    /// prépare que le détecteur de la dictée : sans ceci, le premier tour paierait le chargement. N'ouvre aucun son.
    func prepare(_ setup: InterviewSetup) async throws -> InterviewPreparation {
        let downloaded = try await engines.downloadModels(for: setup.transcription)
        var prepared = InterviewPreparation(setup: setup)
        let dictation = engines.environment
        if let vocabulary = await EffectiveVocabulary.resolve(
            for: setup.transcription, vocabularyModelUnavailable: downloaded.vocabularyModelUnavailable, activity: .interview,
            limit: dictation.promptTokenLimit, count: dictation.promptTokenCount)
        {
            // Le moteur de conversation transcrit avec `config.vocabulary` : sans terme, Parakeet ne va rien chercher hors du
            // catalogue, et WhisperKit ne reçoit jamais une amorce qu'il refuserait.
            prepared.setup.config.vocabulary = vocabulary.terms
            prepared.setup.transcription.vocabulary = vocabulary.terms
            prepared.notice = vocabulary.notice
        }
        // Le réseau de FluidAudio est rétabli : aucun préchargement ne tourne plus quand la porte s'ouvre.
        await engines.gate.waitUntilFinished()
        try Task.checkCancellation()
        try await engines.cache.detector(minSilence: setup.turnSilence).prepare()
        try Task.checkCancellation()
        try await engines.cache.engines(for: prepared.setup.transcription).final.prepare()
        return prepared
    }

    /// Attend la porte de préchargement (comme une session de dictée), puis assemble la conversation avec le détecteur de
    /// l'entretien et le moteur final de ses réglages : les mêmes exemplaires que `prepare` a chargés. Ne démarre rien.
    func makeConversation(_ setup: InterviewSetup) async throws -> any ConversationEngine {
        await engines.gate.waitUntilFinished()
        try Task.checkCancellation()
        let parts = Parts(
            audio: makeAudio(), detector: engines.cache.detector(minSilence: setup.turnSilence),
            transcriber: engines.cache.engines(for: setup.transcription).final, setup: setup)
        return assemble(parts)
    }

    /// Contrat de `InterviewEnvironment.makeVoice` : sans fournisseur, la voix **du système** dans la langue du choix, désignée par
    /// son identifiant quand le choix est une voix du système ; avec un fournisseur résolu, la voix **de ce fournisseur** (modèle,
    /// identifiant et paramètres du choix). Un fournisseur au format Anthropic n'a pas de synthèse (`InterviewSetup.resolve` ne le
    /// donne jamais) : la voix du système, plutôt qu'une voix muette. Tout repli d'une voix de fournisseur, et tout choix donné avec
    /// un fournisseur sans faire une voix de fournisseur, prend la meilleure voix de la langue : l'identifiant d'un fournisseur ne
    /// désigne pas une voix du système.
    func makeVoice(_ choice: VoiceChoice, _ provider: ResolvedProvider?) -> any SpeechSynthesizer {
        // La voix d'un fournisseur ne se construit que par `VoiceChoice.providerVoice` (forme normalisée) : rien de non normalisé ne
        // part chez lui, quel que soit l'appelant. Un fournisseur donné avec un choix qui ne fait pas une voix de fournisseur
        // (sans fournisseur, modèle ou identifiant blanc) donne la voix du système, jamais une voix au modèle vide.
        guard let provider, provider.kind == .openAICompatible, let voice = choice.providerVoice else {
            let choice = choice.normalized
            let isSystemVoice = provider == nil && choice.providerID == nil
            return makeSystemVoice(choice.language, isSystemVoice ? choice.identifier : nil)
        }
        return makeProviderVoice(provider, voice)
    }

    /// La voix d'un fournisseur au format OpenAI : sa route `audio/speech`.
    static let providerVoice: @Sendable (ResolvedProvider, ProviderVoice) -> any SpeechSynthesizer = { provider, voice in
        ProviderSpeechSynthesizer(endpoint: OpenAICompatibleClient(config: provider.config), voice: voice)
    }
}
