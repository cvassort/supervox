import Foundation
import SupervoxCore

/// Ce que le téléchargement des modèles d'une dictée a laissé de côté sans empêcher la dictée.
public struct ModelDownloadOutcome: Equatable, Sendable {
    /// Le petit modèle de vocabulaire n'a pas pu être téléchargé alors que le modèle de transcription est là : la dictée a
    /// lieu quand même, sans vocabulaire.
    public var vocabularyModelUnavailable: Bool

    public init(vocabularyModelUnavailable: Bool = false) {
        self.vocabularyModelUnavailable = vocabularyModelUnavailable
    }

    public static let complete = ModelDownloadOutcome()
}

/// Ce que le contrôleur de dictée demande au monde extérieur : fabriquer une session, savoir si un modèle manque, compter
/// l'amorce du vocabulaire. La cible `Supervox` le construit avec les moteurs réels ; les tests et l'outil de rendu en
/// donnent un double. `SupervoxApp` ne dépend pas des moteurs.
public struct DictationEnvironment: Sendable {
    /// Une session neuve pour ces réglages. Une erreur levée ici n'ouvre aucun micro : le contrôleur la dit.
    public var makeSession: @Sendable (TranscriptionSettings) async throws -> any DictationSessioning
    /// Vrai si un modèle dont la dictée a besoin (moteur choisi, aperçu, détecteur de voix, et le petit modèle de vocabulaire
    /// si le vocabulaire n'est pas vide) n'est pas prêt sur le disque : il sera téléchargé avant la préparation.
    public var needsModelDownload: @Sendable (TranscriptionSettings) async -> Bool
    /// Télécharge ces modèles par le catalogue des modèles (même état et même progression que depuis les réglages, et
    /// jamais un second téléchargement du même modèle) : rend quand ils sont tous là, lève si l'un échoue, sauf le petit
    /// modèle de vocabulaire (la dictée s'en passe : voir `ModelDownloadOutcome`). Une tâche annulée s'arrête avant le
    /// modèle suivant de la liste (celui qui est en cours finit, partagé, visible dans les réglages).
    public var downloadModels: @Sendable (TranscriptionSettings) async throws -> ModelDownloadOutcome
    /// Nombre de jetons de l'amorce du vocabulaire pour ce modèle Whisper ; `nil` si son tokenizer n'est pas sur le disque
    /// (`ModelCatalog.promptTokenCount`).
    public var promptTokenCount: @Sendable (_ vocabulary: [String], _ whisperModel: String) async -> Int?
    /// Jetons d'amorce que Whisper garde (`WhisperKitTranscriber.promptTokenLimit`).
    public var promptTokenLimit: Int
    /// Vrai si les moteurs de ces réglages (détecteur, aperçu, moteur final) sont déjà chargés en mémoire : la préparation
    /// de la dictée est alors instantanée et le panneau ne montre pas « Chargement du modèle… ».
    public var enginesLoaded: @Sendable (TranscriptionSettings) async -> Bool
    /// Au lancement : prépare en tâche de fond les moteurs de ces réglages, **seulement** si tous leurs modèles sont déjà sur
    /// le disque. Ne télécharge jamais ; un échec est silencieux (la dictée refera la préparation et dira l'erreur).
    public var preload: @Sendable (TranscriptionSettings) async -> Void

    public init(
        makeSession: @escaping @Sendable (TranscriptionSettings) async throws -> any DictationSessioning,
        needsModelDownload: @escaping @Sendable (TranscriptionSettings) async -> Bool,
        downloadModels: @escaping @Sendable (TranscriptionSettings) async throws -> ModelDownloadOutcome,
        promptTokenCount: @escaping @Sendable ([String], String) async -> Int?,
        promptTokenLimit: Int,
        enginesLoaded: @escaping @Sendable (TranscriptionSettings) async -> Bool = { _ in true },
        preload: @escaping @Sendable (TranscriptionSettings) async -> Void = { _ in }
    ) {
        self.makeSession = makeSession
        self.needsModelDownload = needsModelDownload
        self.downloadModels = downloadModels
        self.promptTokenCount = promptTokenCount
        self.promptTokenLimit = promptTokenLimit
        self.enginesLoaded = enginesLoaded
        self.preload = preload
    }

    /// Aucun moteur : la dictée dit qu'elle n'est pas disponible. Sert aux fenêtres et aux tests qui ne dictent pas.
    public static let unavailable = DictationEnvironment(
        makeSession: { _ in throw DictationUnavailable() },
        needsModelDownload: { _ in false },
        downloadModels: { _ in .complete },
        promptTokenCount: { _, _ in nil },
        promptTokenLimit: 0)
}

/// La dictée n'a pas de moteur dans ce contexte.
struct DictationUnavailable: Error {}

/// Le panneau, tel que le contrôleur de dictée le pilote. Le contrôleur ne sait pas si c'est la vraie fenêtre.
@MainActor
public protocol PanelOpening: AnyObject {
    var isOpen: Bool { get }
    func open()
    func close()
    /// Ce que le panneau peut faire de la frappe ; sans effet panneau fermé.
    func setKeyboard(_ keyboard: PanelKeyboard)
}

/// Ce que la vue du panneau montre d'une dictée.
public struct DictationViewState: Equatable, Sendable {
    public var stage: DictationStage
    /// Texte provisoire, tel que la session le donne.
    public var liveText: String
    /// Les 48 derniers niveaux du micro, entre 0 et 1, du plus ancien au plus récent.
    public var levels: [Float]
    /// Secondes écoulées depuis le début de la prise.
    public var elapsed: Double
    /// Une ligne à montrer sous l'état : mention de téléchargement, avis sur le vocabulaire, raison d'un échec ou d'une copie.
    public var notice: String?
    /// Le texte de la dernière dictée réussie, que le collage ait réussi ou non : copie de `DictationController.lastTranscript`,
    /// posée à chaque changement de la vue. En mémoire seulement.
    public var lastTranscript: String?

    public init(
        stage: DictationStage = .idle, liveText: String = "", levels: [Float] = [], elapsed: Double = 0,
        notice: String? = nil, lastTranscript: String? = nil
    ) {
        self.stage = stage
        self.liveText = liveText
        self.levels = levels
        self.elapsed = elapsed
        self.notice = notice
        self.lastTranscript = lastTranscript
    }

    /// Nombre de niveaux gardés.
    public static let levelCount = 48
}
