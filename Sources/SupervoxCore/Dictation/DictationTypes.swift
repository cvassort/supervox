import Foundation

/// Pourquoi une dictée a échoué. `message` est une phrase complète en français, prête à être montrée.
public enum DictationFailure: Error, Equatable, Sendable {
    /// Le micro n'a pas pu démarrer ou s'est arrêté ; le texte dit pourquoi.
    case microphone(String)
    /// Aucune parole n'a été trouvée dans la prise.
    case noSpeech
    /// Un moteur (détection de voix ou transcription) a échoué ; le texte dit pourquoi.
    case engine(String)

    public var message: String {
        switch self {
        case .microphone(let reason): "Le micro ne fonctionne pas : \(Self.trimmed(reason))."
        case .noSpeech: "Aucune parole n'a été entendue."
        case .engine(let reason): "La transcription a échoué : \(Self.trimmed(reason))."
        }
    }

    /// Sans le point final de la raison : la phrase en met un, pas deux.
    private static func trimmed(_ reason: String) -> String {
        var text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
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
    /// Marge, en secondes, ajoutée de chaque côté de la parole avant le moteur final. 0,3 s : un bloc du détecteur
    /// dure 0,256 s (4096 échantillons à 16 kHz) et le début détecté peut se tromper d'un bloc
    /// (`task-2-report.md`, mesuré sur voix de synthèse).
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
    /// `recording` → `finalizing` → `finished(texte)` ou `failed`. Sans effet hors de `recording`.
    func finish() async
    /// Toute phase non terminale → `cancelled`. Sans effet sur une phase terminale.
    func cancel() async
    /// Un instantané à chaque changement ; le flux se termine après une phase terminale.
    var snapshots: AsyncStream<DictationSnapshot> { get }
}
