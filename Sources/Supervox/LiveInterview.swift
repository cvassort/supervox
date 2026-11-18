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
    /// La voix du système pour cette langue. Fabriquer ne dit rien.
    let makeSystemVoice: @Sendable (_ language: String) -> any SpeechSynthesizer
    /// La voix d'un fournisseur résolu (adresse et clé) pour ce modèle et cet identifiant. Fabriquer n'envoie rien.
    let makeProviderVoice: @Sendable (ResolvedProvider, ProviderVoice) -> any SpeechSynthesizer
    /// Assemble la conversation (en production : `LiveInterview.session`). Injecté pour que les tests voient les pièces reçues.
    let assemble: @Sendable (Parts) -> any ConversationEngine

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
            effectiveTurnSilence: { FluidStreamingVoiceDetector.effectiveSilence($0) })
    }

    /// Télécharge ce qui manque aux réglages de transcription de l'entretien (par le catalogue, après la porte de préchargement),
    /// puis charge le détecteur de l'entretien, à son silence de fin de tour, et le moteur de transcription. Le préchargement du
    /// lancement ne prépare que le détecteur de la dictée : sans ceci, le premier tour paierait le chargement. N'ouvre aucun son.
    func prepare(_ setup: InterviewSetup) async throws {
        _ = try await engines.downloadModels(for: setup.transcription)
        // Le réseau de FluidAudio est rétabli : aucun préchargement ne tourne plus quand la porte s'ouvre.
        await engines.gate.waitUntilFinished()
        try Task.checkCancellation()
        try await engines.cache.detector(minSilence: setup.turnSilence).prepare()
        try Task.checkCancellation()
        try await engines.cache.engines(for: setup.transcription).final.prepare()
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

    /// Contrat de `InterviewEnvironment.makeVoice` : sans fournisseur, la voix **du système** dans la langue du choix ; avec un
    /// fournisseur résolu, la voix **de ce fournisseur** (modèle, identifiant et paramètres du choix). Un fournisseur au format
    /// Anthropic n'a pas de synthèse (`InterviewSetup.resolve` ne le donne jamais) : la voix du système, plutôt qu'une voix muette.
    func makeVoice(_ choice: VoiceChoice, _ provider: ResolvedProvider?) -> any SpeechSynthesizer {
        guard let provider, provider.kind == .openAICompatible else { return makeSystemVoice(choice.language) }
        return makeProviderVoice(
            provider, ProviderVoice(model: choice.model ?? "", identifier: choice.identifier ?? "", extra: choice.extra))
    }

    /// La voix d'un fournisseur au format OpenAI : sa route `audio/speech`.
    static let providerVoice: @Sendable (ResolvedProvider, ProviderVoice) -> any SpeechSynthesizer = { provider, voice in
        ProviderSpeechSynthesizer(endpoint: OpenAICompatibleClient(config: provider.config), voice: voice)
    }
}
