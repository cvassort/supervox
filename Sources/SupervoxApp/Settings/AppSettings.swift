import Foundation

/// Enregistré dans `settings.json` : un nouveau cas exige une nouvelle `AppSettings.current` (voir sa règle
/// d'évolution).
public enum ProviderKind: String, Codable, Sendable {
    case openAICompatible
    case anthropic
}

/// Un fournisseur de modèles. Aucune clé d'API ici : elles vivent dans le trousseau. Un champ que cette version ne connaît pas
/// est gardé et réécrit tel quel (`UnknownFields`) ; l'égalité ne compare que les champs connus.
public struct Provider: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var kind: ProviderKind
    /// Dernière liste de modèles lue depuis l'endpoint.
    public var models: [String]
    /// Ce que cette version ne connaît pas, réécrit tel quel.
    var unknown = UnknownFields()

    public init(id: UUID, name: String, baseURL: String, kind: ProviderKind, models: [String]) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.kind = kind
        self.models = models
    }

    /// Les champs connus seulement : un champ inconnu ne change pas l'égalité.
    public static func == (lhs: Provider, rhs: Provider) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.baseURL == rhs.baseURL && lhs.kind == rhs.kind
            && lhs.models == rhs.models
    }

    private enum CodingKeys: String, CaseIterable { case id, name, baseURL, kind, models }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    /// Décodage tolérant (voir `AppSettings`) : sans identité, adresse ni type, un fournisseur n'a pas de sens ; la
    /// liste des modèles, elle, se relit en un clic.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        func key(_ key: CodingKeys) -> JSONKey { JSONKey(key.rawValue) }
        id = try container.decode(UUID.self, forKey: key(.id))
        name = try container.decode(String.self, forKey: key(.name))
        baseURL = try container.decode(String.self, forKey: key(.baseURL))
        kind = try container.decode(ProviderKind.self, forKey: key(.kind))
        models = try container.decodeIfPresent([String].self, forKey: key(.models)) ?? []
        unknown = try UnknownFields(reading: container, excluding: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JSONKey.self)
        func key(_ key: CodingKeys) -> JSONKey { JSONKey(key.rawValue) }
        try container.encode(id, forKey: key(.id))
        try container.encode(name, forKey: key(.name))
        try container.encode(baseURL, forKey: key(.baseURL))
        try container.encode(kind, forKey: key(.kind))
        try container.encode(models, forKey: key(.models))
        try unknown.write(to: &container, excluding: Self.knownKeys)
    }
}

extension Provider {
    /// Au-delà de ce nombre de caractères, le nom d'un fournisseur est rogné dans les phrases qui le citent.
    public static let shortNameLimit = 40

    /// Le nom tel qu'une phrase de l'interface le cite : les 40 premiers caractères suivis de « … » s'il est plus long, tel quel
    /// sinon. Les caractères se comptent comme l'utilisateur les voit. Une seule règle pour toutes les phrases (note de vie
    /// privée, lignes de mode) : le nom est une saisie libre, et peut être long.
    public static func shortName(_ name: String) -> String {
        guard name.count > shortNameLimit else { return name }
        return String(name.prefix(shortNameLimit)) + "…"
    }

    public var shortName: String { Self.shortName(name) }
}

/// Enregistré dans `settings.json` : un nouveau cas exige une nouvelle `AppSettings.current` (voir sa règle
/// d'évolution).
public enum HotKeyBehavior: String, Codable, Sendable {
    case toggle
    case hold
}

/// Réglages de l'application, tels qu'ils sont écrits dans `settings.json`.
///
/// Règle d'évolution du format : tout champ ajouté est décodé avec `decodeIfPresent` et une valeur par défaut, pour
/// qu'un fichier écrit avant son ajout se lise encore. `version` ne change que pour un format que l'ancienne application ne
/// saurait pas lire ou réécrire correctement (voir `SettingsStore`).
///
/// Ce que cette version garde, et ce qu'elle perd, à la réécriture d'un fichier :
/// - un champ inconnu de `AppSettings` (premier niveau), de `Mode` et, depuis la version 3, de chaque type imbriqué (`Provider`,
///   `HotKey`, `TranscriptionSettings`, `ModelChoice`, `InterviewSettings`, `VoiceChoice`, `HistorySettings`) est lu, gardé et
///   réécrit tel quel, à la même place dans l'arbre (`UnknownFields`) ; `modeOptions` de la version 1 en fait partie. L'égalité
///   de ces types ne compare que leurs champs connus. Ce qui est gardé l'est d'une lecture à la réécriture de la même valeur :
///   un type reconstruit à neuf (`HotKey(keyCode:modifiers:)` à la place de l'ancien) repart sans champ inconnu ;
/// - un champ connu d'une autre forme dans les types de la version 3 (`InterviewSettings`, `VoiceChoice`, `HistorySettings`)
///   retombe sur son défaut, les autres champs restant lus ; réécrit, il l'est avec ce défaut. Un bloc `interview`, `voice` ou
///   `history` qui n'est pas un objet prend tous ses défauts, sans que le reste du fichier soit mis de côté ;
///   une valeur hors borne de `InterviewSettings` ou de `HistorySettings` est ramenée dans sa borne à la lecture ;
/// - `voices` (les voix enregistrées, sans changement de version) : une entrée illisible est gardée telle quelle et réécrite après
///   les entrées lisibles ; un `voices` qui n'est pas un tableau se lit vide et se réécrit `[]` ; la clé n'est écrite que si la liste
///   n'est pas vide ou si elle était dans le fichier lu (un fichier de l'étape 6 relu puis réécrit reste identique).
///
/// Un nouveau cas d'une énumération enregistrée (`ProviderKind`, `HotKeyBehavior`, `TranscriptionEngine`, ou toute énumération
/// ajoutée plus tard) est un tel format : il exige d'augmenter `current`. Sans cela, une application plus ancienne lit un cas
/// inconnu à sa propre version, ne sait pas décoder le fichier et le met entièrement de côté (fournisseurs compris) ; pour
/// `TranscriptionEngine`, dont le décodage est tolérant, elle le réécrit `whisperkit` sans avis, dans l'onglet Transcription et
/// dans chaque mode (`SettingsStoreTests.anUnknownEngineInAVersionTwoFile…`). Avec une version plus récente, elle garde le
/// fichier intact, n'y écrit rien et prend les réglages par défaut (ou ce qu'elle sait en lire). Ces comportements sont fixés par
/// `SettingsStoreTests` (`unknownEnumCase…`).
///
/// Version 2 : les modes deviennent des données (`modes`). Un fichier de la version 1 n'a pas `modes` : il reçoit `Mode.base`,
/// avec le choix de relecture que `modeOptions` portait. `modeOptions` reste dans le fichier, tel quel, mais ne sert qu'à cette
/// migration, faite une fois : un fichier qui a `modes`, ou qui est déjà en version 2, ne le relit jamais.
///
/// Version 3 : les réglages de l'entretien (`interview`), le choix de voix (`voice`) et la durée de conservation de l'historique
/// (`history`). Un fichier de la version 2 se lit sans perte, les trois champs prennent leurs défauts, et la première écriture
/// le met en version 3. Une application de la version 2 qui ouvre ce fichier le garde intact (version plus récente).
public struct AppSettings: Codable, Equatable, Sendable {
    /// Version du format du fichier que cette application sait lire et écrire.
    public static let current = 3

    public var version: Int
    public var providers: [Provider]
    public var hotKey: HotKey
    public var hotKeyBehavior: HotKeyBehavior
    public var lastModeID: String
    /// Raccourci déjà signalé comme raccourci de macOS activé en ouvrant le panneau au lancement : il ne l'ouvre plus
    /// seul (l'avis reste). `nil` : rien de signalé.
    public var systemConflictShown: HotKey?
    /// Moteur, modèle, langue et vocabulaire de la dictée. Absent d'un fichier plus ancien : les défauts s'appliquent.
    public var transcription: TranscriptionSettings
    /// Les modes, dans l'ordre des pastilles. Dictée brute et Entretien y sont toujours (`Mode.normalized`). Absent d'un
    /// fichier de la version 2 : `Mode.base`.
    public var modes: [Mode]
    /// Le modèle des modes qui n'en choisissent pas un. `nil` : aucun choix fait.
    public var strongModel: ModelChoice?
    /// Le modèle rapide, enregistré dès cette version et employé à l'étape 6. `nil` : aucun choix fait.
    public var fastModel: ModelChoice?
    /// Les réglages de l'entretien vocal. Absent d'un fichier de la version 2 : `InterviewSettings.defaults`.
    public var interview: InterviewSettings
    /// La voix de l'assistant. Absent d'un fichier de la version 2 : la voix du système.
    public var voice: VoiceChoice
    /// La conservation de l'historique des entretiens. Absent d'un fichier de la version 2 : `HistorySettings.defaults`.
    public var history: HistorySettings
    /// Les voix enregistrées, dans l'ordre de l'onglet. Absent d'un fichier plus ancien : aucune.
    public var voices: [SavedVoice]
    /// Ce que le fichier portait sous `voices` sans que cette version sache le lire, et si la clé était là.
    var keptVoices = KeptVoices()
    /// Ce que cette version ne connaît pas, réécrit tel quel.
    var unknown = UnknownFields()

    /// Ce que la lecture de `voices` laisse de côté : les entrées illisibles (`SavedVoice` ne les décode pas), gardées telles quelles
    /// et réécrites après les entrées lisibles ; et la présence de la clé, pour qu'un fichier relu puis réécrit sans changement reste
    /// identique (un `voices` vide n'est écrit que s'il était là).
    ///
    /// Égalité : les entrées illisibles comptent (comme `unknown`, que l'égalité synthétisée d'`AppSettings` compare) ; la présence
    /// de la clé ne compte pas : c'est la forme du fichier, pas une valeur (des réglages écrits puis relus restent égaux).
    struct KeptVoices: Equatable, Sendable {
        var unreadable: [JSONValue] = []
        var keyWasRead = false

        static func == (lhs: KeptVoices, rhs: KeptVoices) -> Bool { lhs.unreadable == rhs.unreadable }
    }

    /// Une entrée de `voices` : une `SavedVoice`, ou, si elle ne se lit pas, sa valeur JSON telle quelle. Les deux lectures se font
    /// sur le même décodeur de l'entrée : la position dans le tableau n'en dépend pas.
    private enum VoiceEntry: Decodable {
        case readable(SavedVoice)
        case unreadable(JSONValue)

        init(from decoder: any Decoder) throws {
            if let voice = try? SavedVoice(from: decoder) {
                self = .readable(voice)
            } else {
                self = .unreadable(try JSONValue(from: decoder))
            }
        }
    }

    public init(
        version: Int, providers: [Provider], hotKey: HotKey,
        hotKeyBehavior: HotKeyBehavior, lastModeID: String, systemConflictShown: HotKey? = nil,
        transcription: TranscriptionSettings = .defaults, modes: [Mode] = Mode.base,
        strongModel: ModelChoice? = nil, fastModel: ModelChoice? = nil, interview: InterviewSettings = .defaults,
        voice: VoiceChoice = .system, history: HistorySettings = .defaults, voices: [SavedVoice] = []
    ) {
        self.version = version
        self.providers = providers
        self.hotKey = hotKey
        self.hotKeyBehavior = hotKeyBehavior
        self.lastModeID = lastModeID
        self.systemConflictShown = systemConflictShown
        self.transcription = transcription
        self.modes = modes
        self.strongModel = strongModel
        self.fastModel = fastModel
        self.interview = interview
        self.voice = voice
        self.history = history
        self.voices = voices
    }

    private enum CodingKeys: String, CaseIterable {
        case version, providers, hotKey, hotKeyBehavior, lastModeID, systemConflictShown, transcription, modes, strongModel,
            fastModel, interview, voice, history, voices
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
    /// Le champ de la version 1 que la migration lit une fois.
    private static let legacyOptionsKey = "modeOptions"

    /// Un champ absent prend sa valeur par défaut ; un champ inconnu est gardé ; seul `version` est obligatoire. Un champ présent
    /// mais d'une autre forme lève une erreur (le fichier est alors illisible), SAUF les trois blocs de la version 3 (`interview`,
    /// `voice`, `history`) : un bloc qui n'est pas un objet prend ses défauts, et dans un bloc, un champ d'une autre forme prend le
    /// sien, sans faire perdre le reste du fichier. Conséquence à connaître : une durée de conservation de la mauvaise forme
    /// (`"retentionDays": "365"`) se lit 30 jours SANS avis ; le dossier de l'historique garde donc la durée confirmée
    /// (`InterviewHistory.confirmedRetention`) pour que la purge au lancement ne s'en serve pas.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        func key(_ key: CodingKeys) -> JSONKey { JSONKey(key.rawValue) }
        let defaults = AppSettings.defaults
        version = try container.decode(Int.self, forKey: key(.version))
        providers = try container.decodeIfPresent([Provider].self, forKey: key(.providers)) ?? defaults.providers
        hotKey = try container.decodeIfPresent(HotKey.self, forKey: key(.hotKey)) ?? defaults.hotKey
        hotKeyBehavior =
            try container.decodeIfPresent(HotKeyBehavior.self, forKey: key(.hotKeyBehavior)) ?? defaults.hotKeyBehavior
        lastModeID = try container.decodeIfPresent(String.self, forKey: key(.lastModeID)) ?? defaults.lastModeID
        systemConflictShown = try container.decodeIfPresent(HotKey.self, forKey: key(.systemConflictShown))
        transcription =
            try container.decodeIfPresent(TranscriptionSettings.self, forKey: key(.transcription))
            ?? defaults.transcription
        strongModel = try container.decodeIfPresent(ModelChoice.self, forKey: key(.strongModel))
        fastModel = try container.decodeIfPresent(ModelChoice.self, forKey: key(.fastModel))
        // Les trois blocs de la version 3 sont optionnels : un bloc qui n'est pas un objet prend ses défauts, sans faire perdre
        // le reste du fichier (fournisseurs, modes, raccourcis).
        interview = (try? container.decodeIfPresent(InterviewSettings.self, forKey: key(.interview))) ?? defaults.interview
        voice = (try? container.decodeIfPresent(VoiceChoice.self, forKey: key(.voice))) ?? defaults.voice
        history = (try? container.decodeIfPresent(HistorySettings.self, forKey: key(.history))) ?? defaults.history
        // `voices` d'une autre forme qu'un tableau : aucune voix, comme un bloc de la version 3 d'une autre forme, et la valeur fautive
        // n'est pas gardée. Dans le tableau, une entrée illisible ne fait perdre ni les autres ni le fichier : elle est gardée.
        let entries = (try? container.decodeIfPresent([VoiceEntry].self, forKey: key(.voices))) ?? nil
        voices = []
        keptVoices.keyWasRead = container.contains(key(.voices))
        for entry in entries ?? [] {
            switch entry {
            case .readable(let voice): voices.append(voice)
            case .unreadable(let value): keptVoices.unreadable.append(value)
            }
        }
        if let modes = try container.decodeIfPresent([Mode].self, forKey: key(.modes)) {
            self.modes = Mode.normalized(modes)
        } else if version < 2 {
            // Un fichier de la version 1, ou avant : les choix de relecture de `modeOptions`, lus entrée par entrée. Une entrée
            // (ou tout le champ) d'une autre forme ne fait pas perdre le fichier pour un champ qui ne sert plus, ni les autres
            // entrées : elle est gardée dans le fichier, et rien n'en est repris.
            let legacy = try? container.nestedContainer(keyedBy: JSONKey.self, forKey: JSONKey(Self.legacyOptionsKey))
            modes = Mode.base.map { mode in
                var mode = mode
                mode.reviewBeforePaste = (try? legacy?.decode(ModeOptions.self, forKey: JSONKey(mode.id)))?.reviewBeforePaste
                return mode
            }
        } else {
            modes = Mode.base
        }
        unknown = try UnknownFields(reading: container, excluding: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JSONKey.self)
        func key(_ key: CodingKeys) -> JSONKey { JSONKey(key.rawValue) }
        try container.encode(version, forKey: key(.version))
        try container.encode(providers, forKey: key(.providers))
        try container.encode(hotKey, forKey: key(.hotKey))
        try container.encode(hotKeyBehavior, forKey: key(.hotKeyBehavior))
        try container.encode(lastModeID, forKey: key(.lastModeID))
        try container.encodeIfPresent(systemConflictShown, forKey: key(.systemConflictShown))
        try container.encode(transcription, forKey: key(.transcription))
        try container.encode(modes, forKey: key(.modes))
        try container.encodeIfPresent(strongModel, forKey: key(.strongModel))
        try container.encodeIfPresent(fastModel, forKey: key(.fastModel))
        try container.encode(interview, forKey: key(.interview))
        try container.encode(voice, forKey: key(.voice))
        try container.encode(history, forKey: key(.history))
        if !voices.isEmpty || !keptVoices.unreadable.isEmpty || keptVoices.keyWasRead {
            var list = container.nestedUnkeyedContainer(forKey: key(.voices))
            try list.encode(contentsOf: voices)
            try list.encode(contentsOf: keptVoices.unreadable)
        }
        try unknown.write(to: &container, excluding: Self.knownKeys)
    }

    public static var defaults: AppSettings {
        AppSettings(
            version: current, providers: [], hotKey: .standard,
            hotKeyBehavior: .toggle, lastModeID: ModeChip.rawID)
    }

    /// Le mode de cet identifiant, `nil` s'il n'y en a pas.
    public func mode(_ id: String) -> Mode? { modes.first { $0.id == id } }

    // MARK: - Relire avant de coller

    /// Les modes dont le texte passe toujours par la relecture : leur choix enregistré, quel qu'il soit, n'y change rien.
    public static let alwaysReviewed: Set<String> = [ModeChip.interviewID]

    /// Le choix d'un mode qui n'en a pas enregistré : relire pour Prompt et Entretien, coller tout de suite pour le reste.
    public static func reviewDefault(_ modeID: String) -> Bool {
        modeID == ModeChip.promptID || modeID == ModeChip.interviewID
    }

    /// Vrai si le texte de ce mode s'affiche pour relecture avant d'être collé. Entretien l'est toujours, même si le fichier
    /// de réglages dit le contraire : la règle est ici, à la lecture, pas dans ce que le fichier porte.
    public func reviewsBeforePaste(_ modeID: String) -> Bool {
        if Self.alwaysReviewed.contains(modeID) { return true }
        return mode(modeID)?.reviewBeforePaste ?? Self.reviewDefault(modeID)
    }
}
