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

    public init(id: String, title: String, detail: String, state: State) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
    }
}

/// Identifiants des modèles du catalogue. Le préfixe `whisper:` précède le nom d'une variante WhisperKit.
public enum LocalModelID {
    public static let parakeet = "parakeet"
    public static let voiceDetector = "vad"
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
}
