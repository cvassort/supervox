import Foundation
import SupervoxCore
import WhisperKit

/// Whisper par WhisperKit (Core ML). La transcription est locale. Le chargement l'est aussi quand le dossier de la variante
/// est présent et « Prêt » (voir `configuration`) ; sinon WhisperKit télécharge le modèle, et son tokenizer si le fichier
/// manque sur le disque.
///
/// Vocabulaire : les termes, joints par des virgules, deviennent l'amorce du décodeur (`promptTokens`, encodés comme
/// le fait la ligne de commande de WhisperKit). La langue est imposée (`fr`), sans détection.
public actor WhisperKitTranscriber: Transcriber {
    public nonisolated let name = "whisperkit"
    public nonisolated var acceptsVocabulary: Bool { true }
    public nonisolated var measurementConditions: String {
        "modèle chargé, et préchauffé avant chaque passe hors chrono : un passage sur 2 s de bruit sans amorce, puis, "
            + "pour la passe +vocab, un second avec l'amorce de la passe. Durée mesurée : transcription complète de la "
            + "phrase (encodeur et décodeur, langue imposée, horodatage par défaut de la bibliothèque) ; passe +vocab : "
            + "en plus, l'encodage de l'amorce par le tokenizer, refait à chaque phrase, et le préremplissage de l'amorce."
    }

    /// Jetons d'amorce que WhisperKit garde : au-delà, il ne conserve que les derniers (TextDecoder, `suffix`).
    public static let promptTokenLimit = Constants.maxTokenContext / 2 - 1

    /// Charge (ou télécharge, puis charge) WhisperKit pour ce modèle dans ce dossier. Injecté par les tests, qui ne
    /// chargent aucun vrai modèle.
    typealias Loader = @Sendable (_ model: String, _ downloadBase: URL?) async throws -> sending WhisperKit

    private let model: String
    private let downloadBase: URL?
    private let loader: Loader
    /// Un seul chargement à la fois : `prepare()` est appelé par toutes les sessions qui partagent ce moteur.
    private let loading = SingleFlight()
    private var kit: WhisperKit?

    /// `model` : variante du dépôt de modèles WhisperKit (ex. `large-v3-v20240930_turbo`). `downloadBase` : dossier où le
    /// modèle (et son tokenizer) sont cherchés et, s'ils manquent, téléchargés ; `nil` : le dossier de WhisperKit par
    /// défaut, `Documents/huggingface` (le banc d'essai). L'application passe le dossier de ses modèles, jamais Documents.
    public init(model: String, downloadBase: URL? = nil) {
        self.init(model: model, downloadBase: downloadBase, loader: Self.defaultLoader)
    }

    init(model: String, downloadBase: URL?, loader: @escaping Loader) {
        self.model = model
        self.downloadBase = downloadBase
        self.loader = loader
    }

    /// Le vrai chargement. N'est lancé que par `prepare()`, jamais à la construction.
    private static let defaultLoader: Loader = { model, downloadBase in
        let kit = try await WhisperKit(configuration(model: model, downloadBase: downloadBase))
        guard kit.modelState == .loaded else {
            throw TranscriberError.engine("modèle WhisperKit \(model) non chargé (état : \(kit.modelState))")
        }
        return kit
    }

    /// Ce que `prepare` passe à WhisperKit. `load: true` : sans lui, WhisperKit charge le modèle au premier `transcribe`,
    /// donc dans la mesure.
    ///
    /// - Dossier de la variante présent et « Prêt » pour le catalogue (`LocalModelCatalog.readyWhisperFolder`) : le modèle
    ///   est chargé depuis ce dossier (`modelFolder`), `download: false` (WhisperKit n'interroge pas le dépôt de modèles) et
    ///   le dossier du tokenizer est donné (`tokenizerFolder`). Sans `modelFolder`, WhisperKit interroge toujours le dépôt
    ///   avant de charger, même modèle présent, et échoue hors ligne.
    /// - Dossier absent ou incomplet (par exemple une variante saisie à la main, inconnue du catalogue) ou pas de dossier de
    ///   base : WhisperKit peut télécharger.
    ///
    /// Le tokenizer ne passe par le réseau que si son fichier manque dans `tokenizerFolder` ou ne se lit pas : WhisperKit
    /// le cherche d'abord sur le disque et ne se rabat sur le dépôt qu'ensuite (`ModelUtilities.loadTokenizer`).
    static func configuration(model: String, downloadBase: URL?) -> WhisperKitConfig {
        guard let downloadBase, let folder = LocalModelCatalog.readyWhisperFolder(for: model, in: downloadBase) else {
            return WhisperKitConfig(model: model, downloadBase: downloadBase, load: true)
        }
        return WhisperKitConfig(
            model: model, downloadBase: downloadBase, modelFolder: folder.path, tokenizerFolder: downloadBase,
            load: true, download: false)
    }

    /// Vrai quand le modèle est chargé en mémoire (un `prepare()` a réussi).
    public var isPrepared: Bool { kit != nil }

    /// Vrai si ce modèle se charge sans aucun accès au réseau : son dossier est « Prêt » et son tokenizer **se charge réellement**
    /// depuis le disque. Un fichier de tokenizer qui existe mais ne se lit pas (JSON invalide, fichier tronqué) ne suffit pas :
    /// WhisperKit se rabattrait alors sur le dépôt en ligne, quel que soit `download` (`ModelUtilities.loadTokenizer`,
    /// `WhisperKit/Utilities/ModelUtilities.swift:56-77`). Le préchargement du lancement ne tourne que dans ce cas : il ne
    /// télécharge jamais. Ne lit que le disque.
    ///
    /// `tokenizerLoads` : essaie de charger le tokenizer d'un dossier (le même chargement local que WhisperKit, `AutoTokenizer…
    /// from(modelFolder:)`) ; injectable pour les tests.
    public static func canLoadWithoutNetwork(
        model: String, downloadBase: URL,
        tokenizerLoads: @Sendable (URL) async -> Bool = WhisperKitTranscriber.tokenizerLoadsFromDisk
    ) async -> Bool {
        guard LocalModelCatalog.readyWhisperFolder(for: model, in: downloadBase) != nil,
            let variant = tokenizerVariant(of: model)
        else { return false }
        let tokenizer = LocalModelCatalog.tokenizerFile(for: variant, in: downloadBase)
        let folder = tokenizer.deletingLastPathComponent()
        // `tokenizer.json` et `tokenizer_config.json` : la lecture locale de WhisperKit exige les deux.
        guard [tokenizer, folder.appendingPathComponent("tokenizer_config.json")]
            .allSatisfy({ FileManager.default.fileExists(atPath: $0.path) })
        else { return false }
        return await tokenizerLoads(folder)
    }

    /// Le chargement local du tokenizer, tel que WhisperKit le fait avant tout repli sur le réseau (`ModelUtilities.swift:60`) :
    /// lecture des fichiers du dossier, aucun accès au réseau.
    @Sendable public static func tokenizerLoadsFromDisk(_ folder: URL) async -> Bool {
        (try? await AutoTokenizerWrapper.from(modelFolder: folder)) != nil
    }

    /// Un acteur accepte un autre appel à chaque `await` : sans `loading`, un second `prepare()` arrivé pendant le premier
    /// verrait `kit == nil` et lancerait un second chargement (ou téléchargement) du même dossier. Les appels qui arrivent
    /// pendant un chargement attendent le même ; un chargement qui échoue peut être retenté.
    public func prepare() async throws {
        if kit != nil { return }
        try await loading.run { [self] in try await load() }
    }

    private func load() async throws {
        if kit != nil { return }
        kit = try await loader(model, downloadBase)
    }

    /// Mesuré : sur du silence, le décodeur s'arrête tout de suite et la 1re phrase restait ~0,1 s plus lente ; sans
    /// passage avec amorce, la 1re phrase de la passe +vocab restait ~0,07 s plus lente.
    public func warmUp(vocabulary: [String]) async throws {
        guard let kit else { throw TranscriberError.notPrepared(name) }
        _ = try await run(kit, samples: warmUpClip().samples, language: "fr", vocabulary: [])
        if !vocabulary.isEmpty {
            _ = try await run(kit, samples: warmUpClip().samples, language: "fr", vocabulary: vocabulary)
        }
    }

    public func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        try TranscriberError.check16kHz(clip)
        guard let kit else { throw TranscriberError.notPrepared(name) }
        return try await run(kit, samples: clip.samples, language: language, vocabulary: vocabulary)
    }

    /// Amorce encodée. Refuse au-delà de `promptTokenLimit` plutôt que de laisser WhisperKit tronquer en silence.
    static func promptTokens(_ vocabulary: [String], tokenizer: any WhisperTokenizer) throws -> [Int] {
        let prompt = " " + vocabulary.joined(separator: ", ")
        let tokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        guard tokens.count <= promptTokenLimit else {
            throw TranscriberError.vocabularyUnavailable("\(tokens.count) jetons d'amorce, \(promptTokenLimit) au plus")
        }
        return tokens
    }

    /// La variante de tokenizer d'un nom de modèle : la plus spécifique contenue dans le nom (« large-v3-v20240930_turbo »
    /// → large-v3). `nil` si elle ne se déduit pas du nom.
    static func tokenizerVariant(of model: String) -> ModelVariant? {
        let candidates = ModelVariant.allCases.filter { model.contains($0.description) }
        return candidates.max(by: { $0.description.count < $1.description.count })
    }

    /// Nombre de jetons de l'amorce pour `vocabulary`, avec le tokenizer du modèle `model`, sans charger le modèle
    /// (seul le tokenizer est lu, ou téléchargé s'il manque, dans `tokenizerFolder` ; `nil` : `Documents/huggingface`).
    /// `nil` si la variante du modèle ne se déduit pas de son nom.
    public static func promptTokenCount(_ vocabulary: [String], model: String, tokenizerFolder: URL? = nil) async throws -> Int? {
        guard let variant = tokenizerVariant(of: model) else { return nil }
        let tokenizer = try await ModelUtilities.loadTokenizer(for: variant, tokenizerFolder: tokenizerFolder)
        let prompt = " " + vocabulary.joined(separator: ", ")
        return tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }.count
    }

    private func run(_ kit: WhisperKit, samples: [Float], language: String, vocabulary: [String]) async throws -> String {
        var options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true    // sinon le texte porte <|fr|>, <|0.00|>… comptés comme mots insérés
            // Horodatage laissé au défaut de la bibliothèque (activé) : même texte que sans sur le corpus de contrôle,
            // ~0,03 s de plus par phrase, et c'est lui qui découpe un enregistrement de plus de 30 s en fenêtres.
        )
        if !vocabulary.isEmpty {
            guard let tokenizer = kit.tokenizer else { throw TranscriberError.vocabularyUnavailable("tokenizer WhisperKit absent") }
            options.promptTokens = try Self.promptTokens(vocabulary, tokenizer: tokenizer)
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
