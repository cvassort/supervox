import Foundation

/// Un modèle local que l'application peut télécharger ou supprimer (moteur de transcription, détecteur de voix).
public struct LocalModel: Equatable, Identifiable, Sendable {
    /// Où en est le modèle sur ce Mac.
    public enum State: Equatable, Sendable {
        case absent
        /// Un dossier est là mais des fichiers attendus manquent (téléchargement interrompu, fichier supprimé).
        case incomplete
        /// Téléchargement en cours. La fraction (entre 0 et 1) n'est donnée que si la bibliothèque qui télécharge la
        /// fournit elle-même ; `nil` : en cours, sans mesure d'avancement.
        case downloading(Double?)
        case ready
        /// Dernier téléchargement en échec ; le texte dit pourquoi, en français.
        case failed(String)
    }

    public let id: String
    public let title: String
    public let detail: String
    public var state: State
    /// Une ligne de plus sur cet état, quand il y a quelque chose à dire que `state` ne dit pas (Parakeet prêt, dont le
    /// petit modèle de vocabulaire n'est pas encore là). `nil` : rien à ajouter.
    public var note: String?

    public init(id: String, title: String, detail: String, state: State, note: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
        self.note = note
    }
}

/// Identifiants des modèles du catalogue. Le préfixe `whisper:` précède le nom d'une variante WhisperKit.
public enum LocalModelID {
    public static let parakeet = "parakeet"
    public static let voiceDetector = "vad"
    /// Le petit modèle qui reconnaît le vocabulaire de l'utilisateur pour Parakeet. Il n'est pas une ligne de la liste (il
    /// fait partie de Parakeet pour l'utilisateur) : le catalogue sait le télécharger, le supprimer et dire son état.
    public static let parakeetVocabulary = "parakeet-vocabulary"
    private static let whisperPrefix = "whisper:"

    public static func whisper(_ variant: String) -> String { whisperPrefix + variant }

    /// La variante WhisperKit d'un identifiant de modèle, `nil` pour tout autre modèle.
    public static func whisperVariant(of id: String) -> String? {
        id.hasPrefix(whisperPrefix) ? String(id.dropFirst(whisperPrefix.count)) : nil
    }
}

/// Les modèles locaux tels que l'écran de réglages les voit. La réalisation vit dans `SupervoxEngines`
/// (`LocalModelCatalog`) ; le protocole est ici pour que `SupervoxApp` et `SupervoxEngines` le partagent sans dépendre
/// l'un de l'autre.
public protocol ModelCatalog: Sendable {
    /// Les modèles proposés, avec leur état courant sur le disque.
    func models() async -> [LocalModel]
    /// Télécharge le modèle ; `progress` reçoit la fraction faite (0 à 1) quand la bibliothèque la fournit (jamais une
    /// fraction inventée : sans elle, `progress` n'est pas appelée). Lève en cas d'échec.
    func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws
    /// Supprime le modèle du disque. Sans effet s'il est absent.
    func delete(_ id: String) async throws
    /// Nombre de jetons de l'amorce que le moteur construirait pour `vocabulary` avec ce modèle Whisper ; `nil` si le
    /// modèle (son tokenizer) n'est pas sur le disque, donc impossible à compter sans le télécharger.
    func promptTokenCount(_ vocabulary: [String], whisperModel: String) async -> Int?
    /// Fait en sorte que le modèle soit sur le disque : le télécharge, ou attend le téléchargement déjà en cours (celui de
    /// la fenêtre de réglages comme celui d'une dictée), sans en lancer un second. Même état, même progression que
    /// `download`, et le modèle apparaît « en cours » dans `models()` pendant ce temps.
    func ensureDownloaded(_ id: String) async throws
    /// L'état d'un modèle, y compris de ceux que la liste ne montre pas (`LocalModelID.parakeetVocabulary`). `nil` si le
    /// catalogue ne connaît pas ce modèle.
    func state(of id: String) async -> LocalModel.State?
}

extension ModelCatalog {
    /// Pour un catalogue qui ne suit pas ses téléchargements : un téléchargement ordinaire.
    public func ensureDownloaded(_ id: String) async throws {
        try await download(id) { _ in }
    }

    public func state(of id: String) async -> LocalModel.State? {
        await models().first { $0.id == id }?.state
    }
}
