import Foundation

/// La façade de l'entretien : ce que l'appelant garde, et rien d'autre. Elle construit elle-même son moteur (`ConversationChain`,
/// dont les `init` sont internes) à partir des dépendances : aucun appelant ne peut l'envelopper autour d'un moteur qu'il tiendrait
/// aussi, ni deux façades autour du même moteur (revue de la tâche 6, m-6). Elle annule l'entretien quand elle est libérée sans
/// `cancel()` : le micro est alors arrêté et le flux finit sur `.finished(.cancelled)`.
///
/// L'acteur ne peut pas le faire lui-même : ses tâches (la conversation, la fin) le retiennent tant que l'entretien tourne, un
/// `deinit` sur lui ne s'exécuterait jamais. Le filet de l'acteur reste : un lecteur qui abandonne le flux annule aussi l'entretien.
///
/// Usage : `start()` une fois, lire le flux jusqu'à `.finished` ; `conclude()` pour demander le prompt, `cancel()` pour tout arrêter
/// sans prompt (rend la main quand l'entretien est arrêté).
public final class ConversationSession: ConversationEngine {
    let chain: ConversationChain

    /// Les mêmes dépendances que le moteur : son, détecteur de voix, transcription, modèles rapide et fort, voix, configuration,
    /// chien de garde du micro, horloge et attentes (injectables pour les tests ; par défaut, l'horloge et le sommeil du système).
    public init(audio: any AudioIO, detector: any StreamingVoiceDetector, transcriber: any Transcriber,
                fastModel: any LanguageModel, strongModel: any LanguageModel, voice: any SpeechSynthesizer,
                config: ConversationConfig, watchdog: MicrophoneWatchdog = .system,
                now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                transcriptionSleep: (@Sendable (Double) async throws -> Void)? = nil) {
        chain = ConversationChain(
            audio: audio, detector: detector, transcriber: transcriber, fastModel: fastModel, strongModel: strongModel,
            voice: voice, config: config, watchdog: watchdog, now: now, sleep: sleep, transcriptionSleep: transcriptionSleep)
    }

    /// Pour les tests : le rééchantillonneur et l'observation des événements, comme l'`init` interne du moteur.
    init(audio: any AudioIO, detector: any StreamingVoiceDetector, transcriber: any Transcriber,
         fastModel: any LanguageModel, strongModel: any LanguageModel, voice: any SpeechSynthesizer,
         config: ConversationConfig, watchdog: MicrophoneWatchdog, now: @escaping @Sendable () -> Double,
         sleep: @escaping @Sendable (Double) async throws -> Void,
         transcriptionSleep: @escaping @Sendable (Double) async throws -> Void,
         makeResampler: (@Sendable (Double, Double) -> StreamingResampler?)?,
         eventTap: (@Sendable (ConversationEvent) -> Void)?) {
        chain = ConversationChain(
            audio: audio, detector: detector, transcriber: transcriber, fastModel: fastModel, strongModel: strongModel,
            voice: voice, config: config, watchdog: watchdog, now: now, sleep: sleep, transcriptionSleep: transcriptionSleep,
            makeResampler: makeResampler, eventTap: eventTap)
    }

    public func start() async -> AsyncStream<ConversationEvent> { await chain.start() }
    public func conclude() async { await chain.conclude() }
    public func cancel() async { await chain.cancel() }

    deinit {
        let chain = chain
        Task { await chain.cancel() }
    }
}
