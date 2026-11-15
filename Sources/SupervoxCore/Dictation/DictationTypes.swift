import Foundation

/// Pourquoi une dictée a échoué. `message` est une phrase complète en français, prête à être montrée.
public enum DictationFailure: Error, Equatable, Sendable {
    /// Le micro n'a pas pu démarrer ou s'est arrêté ; le texte dit pourquoi.
    case microphone(String)
    /// Aucune parole n'a été trouvée dans la prise.
    case noSpeech
    /// Un moteur (détection de voix ou transcription) a échoué ; le texte dit pourquoi.
    case engine(String)
    /// Le texte est transcrit, mais le presse-papiers du système a refusé de le recevoir : il n'a été ni collé ni copié.
    case clipboard

    public var message: String {
        switch self {
        case .microphone(let reason): "Le micro ne fonctionne pas : \(Self.trimmed(reason))."
        case .noSpeech: "Aucune parole n'a été entendue."
        case .engine(let reason): "La transcription a échoué : \(Self.trimmed(reason))."
        case .clipboard:
            "Le presse-papiers a refusé le texte : il n'a été ni collé ni copié. Il reste dans « Dernière dictée », ci-dessous : essayez « Copier »."
        }
    }

    /// Sans le point final de la raison : la phrase en met un, pas deux.
    private static func trimmed(_ reason: String) -> String {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "cause inconnue" : text
    }
}

public enum DictationPhase: Equatable, Sendable {
    case idle
    /// Chargement du détecteur et des moteurs ; le micro n'est pas encore ouvert.
    case preparing
    case recording
    /// Fin de prise : le moteur final travaille sur la parole.
    case finalizing
    case finished(String)
    case cancelled
    case failed(DictationFailure)

    /// Une phase terminale ne change plus.
    public var isTerminal: Bool {
        switch self {
        case .finished, .cancelled, .failed: true
        case .idle, .preparing, .recording, .finalizing: false
        }
    }
}

/// L'état de la dictée à un instant, tel qu'il est montré.
public struct DictationSnapshot: Equatable, Sendable {
    public var phase: DictationPhase
    /// Texte provisoire : passages clos figés puis passage ouvert, séparés par une espace.
    public var liveText: String
    /// Niveau du micro, entre 0 et 1 (voir `DictationSession.level(of:)`).
    public var level: Float
    /// Secondes écoulées depuis le début de la prise, selon l'horloge `now` de la session.
    public var elapsed: Double

    public init(phase: DictationPhase = .idle, liveText: String = "", level: Float = 0, elapsed: Double = 0) {
        self.phase = phase
        self.liveText = liveText
        self.level = level
        self.elapsed = elapsed
    }
}

public struct DictationConfig: Sendable {
    /// Code ISO 639-1 transmis aux moteurs (`fr`).
    public var language: String
    public var vocabulary: [String]
    /// Intervalle minimal entre deux passes d'aperçu sur le passage ouvert, en secondes. Choix de conception du plan,
    /// non mesuré.
    public var previewInterval: Double
    /// Durée maximale, en secondes, de la fin du passage ouvert donnée au moteur d'aperçu. Choix de conception du
    /// plan, non mesuré.
    public var previewWindow: Double
    /// Marge, en secondes, ajoutée de chaque côté de la parole avant le moteur final. Raisonnement de granularité, non
    /// mesuré sur des voix réelles : le détecteur décide par blocs de 4096 échantillons à 16 kHz, soit 0,256 s, et le
    /// début qu'il donne peut être décalé d'un bloc ; 0,3 s couvre un bloc de chaque côté.
    public var padding: Double
    /// Durée de prise, en secondes, à laquelle la session se termine d'elle-même. 300 s (5 minutes) : choix du plan.
    public var maxDuration: Double

    public init(language: String, vocabulary: [String] = [], previewInterval: Double = 0.5, previewWindow: Double = 15,
                padding: Double = 0.3, maxDuration: Double = 300) {
        self.language = language
        self.vocabulary = vocabulary
        self.previewInterval = previewInterval
        self.previewWindow = previewWindow
        self.padding = padding
        self.maxDuration = maxDuration
    }
}

/// Ce que l'interface (tâche 6) demande à une session de dictée ; `DictationSession` en est l'implémentation, les tests
/// de l'interface la doublent.
public protocol DictationSessioning: Sendable {
    /// `idle` → `preparing` → `recording`, ou `failed`. Sans effet hors de `idle`.
    func start() async
    /// `recording` → `finalizing` → `finished(texte)` ou `failed`. Pendant `preparing`, la demande est retenue : le micro
    /// n'est pas ouvert et la prise finit en `failed(.noSpeech)` (rien n'a été enregistré). Sans effet dans toute autre
    /// phase, `idle` comprise : un `finish()` qui précède `start()` est perdu, à l'appelant de les enchaîner.
    func finish() async
    /// Toute phase non terminale → `cancelled`. Sans effet sur une phase terminale.
    func cancel() async
    /// Un instantané à chaque changement ; le flux se termine après une phase terminale. Un seul lecteur à la fois (c'est
    /// une propriété d'`AsyncStream`) ; un abonné qui arrive après la fin ne voit rien.
    var snapshots: AsyncStream<DictationSnapshot> { get }
}

/// Le chien de garde du micro : en `recording`, si aucune tranche n'arrive pendant `timeout` secondes, la prise échoue (un
/// casque débranché ou une entrée qui change arrête le moteur audio sans rien dire, et sans lui la prise resterait
/// « Enregistrement » alors que rien n'est plus entendu). Un vrai micro livre des tranches même dans le silence : une prise
/// silencieuse ne le déclenche pas.
///
/// L'horloge est celle de la session (`now`) et l'attente est injectée : aucun test n'attend une durée réelle. Sans chien de
/// garde (le défaut), la session ne surveille rien : c'est le cas du micro scripté des tests et de `supervox-bench live`, qui
/// livrent toutes leurs tranches d'un coup puis se taisent.
public struct MicrophoneWatchdog: Sendable {
    /// Secondes sans tranche, entre deux tranches, au bout desquelles la prise échoue.
    public var timeout: Double
    /// Secondes accordées à la **première** tranche, comptées depuis le retour de `feed.start` : un moteur audio à traitement de
    /// la voix, ou un casque sans fil qui change de profil, peut mettre plus d'une seconde à livrer sa première fenêtre.
    public var firstChunkTimeout: Double
    /// Secondes entre deux vérifications.
    public var pollInterval: Double
    /// Attend ce nombre de secondes, et lève si la tâche est annulée.
    public var sleep: @Sendable (Double) async throws -> Void

    /// `firstChunkTimeout` : `nil` = `timeout`.
    public init(
        timeout: Double, firstChunkTimeout: Double? = nil, pollInterval: Double,
        sleep: @escaping @Sendable (Double) async throws -> Void
    ) {
        self.timeout = timeout
        self.firstChunkTimeout = firstChunkTimeout ?? timeout
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    /// Le réglage de l'application : 3 s pour la première tranche après l'ouverture du micro, puis 1 s entre deux tranches,
    /// vérifié quatre fois par seconde. Choix de conception, non mesuré : une tranche du micro dure bien moins d'une seconde (le
    /// plan en suppose environ 0,1 s), mais l'écart entre l'ouverture du micro et la première tranche n'a été mesuré ni sur un
    /// micro intégré ni sur un casque sans fil, d'où la tolérance de 3 s pour la première.
    public static let system = MicrophoneWatchdog(
        timeout: 1, firstChunkTimeout: 3, pollInterval: 0.25, sleep: { try await Task.sleep(for: .seconds($0)) })
}
