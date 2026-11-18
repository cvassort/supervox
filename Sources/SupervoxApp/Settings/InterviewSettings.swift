import Foundation

/// Lit un champ sans que son absence, un `null` ou une autre forme fasse échouer le type entier : `nil` dans ces trois cas, et
/// l'appelant prend alors le défaut de CE champ (les autres champs restent lus). Règle de la version 3 pour les champs neufs.
extension KeyedDecodingContainer where K == JSONKey {
    fileprivate func lenient<Value: Decodable>(_ type: Value.Type, _ name: String) -> Value? {
        try? decodeIfPresent(type, forKey: JSONKey(name))
    }
}

/// Réglages de l'entretien vocal, enregistrés dans `settings.json` sous `interview` (version 3). Chaque champ absent ou d'une
/// autre forme prend son défaut ; un champ que cette version ne connaît pas est gardé et réécrit tel quel (`UnknownFields`).
///
/// Une valeur hors borne est ramenée dans sa borne dès la lecture (le décodage applique `normalized`), pour qu'aucun
/// consommateur ne puisse oublier la borne ; un gabarit blanc se lit `nil`. `normalized` reste pour les valeurs que l'interface
/// pose ensuite.
public struct InterviewSettings: Codable, Equatable, Sendable {
    /// Nombre maximal de questions posées. Défaut 8 : choix non mesuré.
    public var maxQuestions: Int
    /// Gabarit du compte rendu. `nil` : le gabarit d'origine.
    public var template: String?
    /// Silence qui marque la fin d'un tour de parole, en secondes. Défaut 0,5 s : décision du contrôleur après lecture du détecteur
    /// (code lu : 0,5 s demandées donnent 3 blocs, soit 0,768 s, contre 1,024 s pour 0,6 comme pour 0,7).
    public var turnSilence: Double
    /// Durée minimale d'une voix qui coupe la parole de l'assistant, en secondes. Défaut 0,30 s : choix non mesuré.
    public var interruptMinDuration: Double
    /// Niveau minimal d'une voix qui coupe la parole de l'assistant, en dB. Défaut −30 dB : choix non mesuré.
    public var interruptLevel: Double
    /// Ce que cette version ne connaît pas, réécrit tel quel.
    var unknown = UnknownFields()

    public init(
        maxQuestions: Int = 8, template: String? = nil, turnSilence: Double = 0.5, interruptMinDuration: Double = 0.30,
        interruptLevel: Double = -30
    ) {
        self.maxQuestions = maxQuestions
        self.template = template
        self.turnSilence = turnSilence
        self.interruptMinDuration = interruptMinDuration
        self.interruptLevel = interruptLevel
    }

    public static let defaults = InterviewSettings()

    /// Bornes : choix non mesurés.
    public static let maxQuestionsRange: ClosedRange<Int> = 1...20
    public static let turnSilenceRange: ClosedRange<Double> = 0.3...2.0
    public static let interruptMinDurationRange: ClosedRange<Double> = 0.1...1.0
    public static let interruptLevelRange: ClosedRange<Double> = -50...(-10)

    /// Les mêmes réglages, chaque valeur ramenée dans sa borne, et un gabarit blanc rendu `nil` (le gabarit d'origine). Un nombre
    /// qui n'en est pas un (NaN) prend le défaut du champ. Part de `self` : les champs inconnus restent. Un gabarit qui dit
    /// quelque chose n'est pas modifié, marges comprises.
    public var normalized: InterviewSettings {
        var result = self
        result.maxQuestions = min(max(maxQuestions, Self.maxQuestionsRange.lowerBound), Self.maxQuestionsRange.upperBound)
        result.turnSilence = Self.clamped(turnSilence, Self.turnSilenceRange, fallback: Self.defaults.turnSilence)
        result.interruptMinDuration = Self.clamped(
            interruptMinDuration, Self.interruptMinDurationRange, fallback: Self.defaults.interruptMinDuration)
        result.interruptLevel = Self.clamped(
            interruptLevel, Self.interruptLevelRange, fallback: Self.defaults.interruptLevel)
        if let template, template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.template = nil }
        return result
    }

    private static func clamped(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isNaN ? fallback : min(max(value, range.lowerBound), range.upperBound)
    }

    /// Les champs connus seulement : un champ inconnu ne change pas l'égalité.
    public static func == (lhs: InterviewSettings, rhs: InterviewSettings) -> Bool {
        lhs.maxQuestions == rhs.maxQuestions && lhs.template == rhs.template && lhs.turnSilence == rhs.turnSilence
            && lhs.interruptMinDuration == rhs.interruptMinDuration && lhs.interruptLevel == rhs.interruptLevel
    }

    private enum CodingKeys: String, CaseIterable {
        case maxQuestions, template, turnSilence, interruptMinDuration, interruptLevel
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        let defaults = Self.defaults
        maxQuestions = container.lenient(Int.self, CodingKeys.maxQuestions.rawValue) ?? defaults.maxQuestions
        template = container.lenient(String.self, CodingKeys.template.rawValue)
        turnSilence = container.lenient(Double.self, CodingKeys.turnSilence.rawValue) ?? defaults.turnSilence
        interruptMinDuration =
            container.lenient(Double.self, CodingKeys.interruptMinDuration.rawValue) ?? defaults.interruptMinDuration
        interruptLevel = container.lenient(Double.self, CodingKeys.interruptLevel.rawValue) ?? defaults.interruptLevel
        unknown = try UnknownFields(reading: container, excluding: Self.knownKeys)
        self = normalized
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JSONKey.self)
        try container.encode(maxQuestions, forKey: JSONKey(CodingKeys.maxQuestions.rawValue))
        try container.encodeIfPresent(template, forKey: JSONKey(CodingKeys.template.rawValue))
        try container.encode(turnSilence, forKey: JSONKey(CodingKeys.turnSilence.rawValue))
        try container.encode(interruptMinDuration, forKey: JSONKey(CodingKeys.interruptMinDuration.rawValue))
        try container.encode(interruptLevel, forKey: JSONKey(CodingKeys.interruptLevel.rawValue))
        try unknown.write(to: &container, excluding: Self.knownKeys)
    }
}

/// Le genre d'une voix. Une valeur que cette version ne connaît pas est gardée telle quelle (`other`) et réécrite à l'identique,
/// au lieu d'être remplacée ou perdue. Un `other` qui porte l'un des trois noms connus ne se distingue pas du cas connu : le
/// décodage et `init(name:)` le ramènent au cas connu, et l'égalité compare les noms écrits (`other("female") == female`), de sorte
/// qu'une valeur relue est toujours égale à celle qui a été écrite.
public enum VoiceGender: Codable, Equatable, Sendable {
    case female
    case male
    case neutral
    case other(String)

    private var name: String {
        switch self {
        case .female: "female"
        case .male: "male"
        case .neutral: "neutral"
        case .other(let name): name
        }
    }

    /// Le cas que ce nom désigne : un des trois connus (nom exact : « Female » reste `other`), sinon
    /// `other`.
    public init(name: String) {
        switch name {
        case "female": self = .female
        case "male": self = .male
        case "neutral": self = .neutral
        default: self = .other(name)
        }
    }

    /// Une valeur qui n'est pas un texte lève une erreur ; `VoiceChoice` la lit comme « pas de genre ».
    public init(from decoder: any Decoder) throws {
        self.init(name: try decoder.singleValueContainer().decode(String.self))
    }

    /// Le nom écrit seulement : `other("female")` est `female`.
    public static func == (lhs: VoiceGender, rhs: VoiceGender) -> Bool { lhs.name == rhs.name }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

/// La voix de l'assistant, enregistrée dans `settings.json` sous `voice` (version 3). Aucun écran ne la modifie à l'étape 6.
///
/// `providerID` `nil` : une voix du système. `identifier` `nil` : la meilleure voix du système pour `language`. `extra` : des
/// paramètres libres envoyés tels quels au fournisseur (design 6.5). Un champ absent ou d'une autre forme prend son défaut (un
/// fournisseur illisible donne donc la voix du système) ; un champ inconnu est gardé et réécrit tel quel.
public struct VoiceChoice: Codable, Equatable, Sendable {
    public var providerID: UUID?
    public var model: String?
    public var identifier: String?
    public var language: String
    public var gender: VoiceGender?
    public var extra: [String: String]
    /// Ce que cette version ne connaît pas, réécrit tel quel.
    var unknown = UnknownFields()

    public init(
        providerID: UUID? = nil, model: String? = nil, identifier: String? = nil, language: String = "fr-FR",
        gender: VoiceGender? = nil, extra: [String: String] = [:]
    ) {
        self.providerID = providerID
        self.model = model
        self.identifier = identifier
        self.language = language
        self.gender = gender
        self.extra = extra
    }

    /// La voix du système, meilleure voix pour le français.
    public static let system = VoiceChoice()

    /// La voix vient d'un fournisseur (sinon, du système).
    public var usesProvider: Bool { providerID != nil }

    /// Les clés que la requête de synthèse pose elle-même (`OpenAICompatibleClient.speech`, code lu) : un paramètre libre ne les
    /// porte jamais.
    public static let reservedExtraKeys: Set<String> = ["model", "input", "voice", "response_format"]
    /// Nombre maximal de paramètres libres envoyés au fournisseur : 16, choix non mesuré.
    public static let maxExtraEntries = 16

    /// La forme sous laquelle la voix sert : modèle et identifiant rognés (vides : `nil`) ; langue vide ou blanche : `fr-FR` ; clés
    /// d'`extra` rognées, les clés vides et les clés réservées (`reservedExtraKeys`, comparées après rognage, casse comprise)
    /// retirées, puis au plus `maxExtraEntries` entrées, les premières dans l'ordre des clés. Deux clés qui se rejoignent une fois
    /// rognées : celle qui l'était déjà l'emporte, sinon la première dans l'ordre des clés d'origine. Les valeurs ne sont pas
    /// touchées ; le fournisseur, le genre et les champs inconnus restent. Idempotente. C'est la seule forme qui part chez un
    /// fournisseur (`InterviewSetup.resolve`, `route(in:)`).
    public var normalized: VoiceChoice {
        func trimmed(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        var result = self
        result.model = trimmed(model)
        result.identifier = trimmed(identifier)
        if trimmed(language) == nil { result.language = Self.system.language }
        // Tri par (clé rognée, clé déjà propre d'abord, clé d'origine) : l'ordre ne dépend pas du parcours du dictionnaire.
        let entries = extra
            .map { (key: $0.key.trimmingCharacters(in: .whitespacesAndNewlines), original: $0.key, value: $0.value) }
            .filter { !$0.key.isEmpty && !Self.reservedExtraKeys.contains($0.key) }
            .sorted { lhs, rhs in
                if lhs.key != rhs.key { return lhs.key < rhs.key }
                let lhsClean = lhs.key == lhs.original
                let rhsClean = rhs.key == rhs.original
                if lhsClean != rhsClean { return lhsClean }
                return lhs.original < rhs.original
            }
        var kept: [String: String] = [:]
        for entry in entries where kept[entry.key] == nil {
            guard kept.count < Self.maxExtraEntries else { break }
            kept[entry.key] = entry.value
        }
        result.extra = kept
        return result
    }

    /// Les champs connus seulement : un champ inconnu ne change pas l'égalité.
    public static func == (lhs: VoiceChoice, rhs: VoiceChoice) -> Bool {
        lhs.providerID == rhs.providerID && lhs.model == rhs.model && lhs.identifier == rhs.identifier
            && lhs.language == rhs.language && lhs.gender == rhs.gender && lhs.extra == rhs.extra
    }

    private enum CodingKeys: String, CaseIterable {
        case providerID, model, identifier, language, gender, extra
    }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        providerID = container.lenient(UUID.self, CodingKeys.providerID.rawValue)
        model = container.lenient(String.self, CodingKeys.model.rawValue)
        identifier = container.lenient(String.self, CodingKeys.identifier.rawValue)
        // Une langue vide ou blanche ne dit rien : lue comme absente.
        language = container.lenient(String.self, CodingKeys.language.rawValue)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? Self.system.language
        gender = container.lenient(VoiceGender.self, CodingKeys.gender.rawValue)
        // Entrée par entrée : une valeur qui n'est pas un texte ne fait pas perdre les autres paramètres.
        extra = (container.lenient([String: JSONValue].self, CodingKeys.extra.rawValue) ?? [:])
            .compactMapValues { value in
                if case .string(let text) = value { text } else { nil }
            }
        unknown = try UnknownFields(reading: container, excluding: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JSONKey.self)
        try container.encodeIfPresent(providerID, forKey: JSONKey(CodingKeys.providerID.rawValue))
        try container.encodeIfPresent(model, forKey: JSONKey(CodingKeys.model.rawValue))
        try container.encodeIfPresent(identifier, forKey: JSONKey(CodingKeys.identifier.rawValue))
        try container.encode(language, forKey: JSONKey(CodingKeys.language.rawValue))
        try container.encodeIfPresent(gender, forKey: JSONKey(CodingKeys.gender.rawValue))
        try container.encode(extra, forKey: JSONKey(CodingKeys.extra.rawValue))
        try unknown.write(to: &container, excluding: Self.knownKeys)
    }
}

/// Une voix enregistrée dans les réglages (`AppSettings.voices`) : un nom choisi par la personne et la voix qu'il désigne.
///
/// `id`, `name` et `voice` sont obligatoires : une entrée dont l'un manque ou a une autre forme (un `voice` qui n'est pas un objet)
/// ne se lit pas, et `AppSettings` la garde à part, telle quelle. Dans `voice`, chaque champ reste tolérant (`VoiceChoice`). Un
/// champ inconnu de l'entrée est gardé et réécrit tel quel ; l'égalité ne compare que les champs connus.
public struct SavedVoice: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var voice: VoiceChoice
    /// Ce que cette version ne connaît pas, réécrit tel quel.
    var unknown = UnknownFields()

    public init(id: UUID, name: String, voice: VoiceChoice) {
        self.id = id
        self.name = name
        self.voice = voice
    }

    /// Les champs connus seulement : un champ inconnu ne change pas l'égalité.
    public static func == (lhs: SavedVoice, rhs: SavedVoice) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.voice == rhs.voice
    }

    private enum CodingKeys: String, CaseIterable { case id, name, voice }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        id = try container.decode(UUID.self, forKey: JSONKey(CodingKeys.id.rawValue))
        name = try container.decode(String.self, forKey: JSONKey(CodingKeys.name.rawValue))
        voice = try container.decode(VoiceChoice.self, forKey: JSONKey(CodingKeys.voice.rawValue))
        unknown = try UnknownFields(reading: container, excluding: Self.knownKeys)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JSONKey.self)
        try container.encode(id, forKey: JSONKey(CodingKeys.id.rawValue))
        try container.encode(name, forKey: JSONKey(CodingKeys.name.rawValue))
        try container.encode(voice, forKey: JSONKey(CodingKeys.voice.rawValue))
        try unknown.write(to: &container, excluding: Self.knownKeys)
    }
}

/// Durée de conservation de l'historique des entretiens, enregistrée dans `settings.json` sous `history` (version 3). Un champ
/// absent ou d'une autre forme prend le défaut ; un champ inconnu est gardé et réécrit tel quel.
public struct HistorySettings: Codable, Equatable, Sendable {
    /// Nombre de jours de conservation. 0 : ne rien garder. Défaut 30 : choix non mesuré. Lu borné (`normalized`) : jamais
    /// négatif, jamais au-delà de `maxRetentionDays`.
    public var retentionDays: Int
    /// Ce que cette version ne connaît pas, réécrit tel quel.
    var unknown = UnknownFields()

    public init(retentionDays: Int = 30) {
        self.retentionDays = retentionDays
    }

    public static let defaults = HistorySettings()

    /// Les durées que l'interface propose, en jours : choix non mesuré.
    public static let choices: [Int] = [0, 7, 30, 90, 365]

    /// Plafond de `retentionDays`, en jours (dix ans) : choix non mesuré. Un nombre énorme ferait déborder un calcul de date.
    public static let maxRetentionDays = 3650

    /// La durée ramenée dans sa borne : une valeur négative prend le défaut (30 jours, jamais 0 : « ne rien garder » effacerait
    /// l'historique de la personne), une valeur au-delà du plafond va au plafond. Part de `self` : les champs inconnus restent.
    public var normalized: HistorySettings {
        var result = self
        if retentionDays < 0 {
            result.retentionDays = Self.defaults.retentionDays
        } else {
            result.retentionDays = min(retentionDays, Self.maxRetentionDays)
        }
        return result
    }

    /// Le champ connu seulement : un champ inconnu ne change pas l'égalité.
    public static func == (lhs: HistorySettings, rhs: HistorySettings) -> Bool {
        lhs.retentionDays == rhs.retentionDays
    }

    private enum CodingKeys: String, CaseIterable { case retentionDays }

    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: JSONKey.self)
        retentionDays = container.lenient(Int.self, CodingKeys.retentionDays.rawValue) ?? Self.defaults.retentionDays
        unknown = try UnknownFields(reading: container, excluding: Self.knownKeys)
        self = normalized
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JSONKey.self)
        try container.encode(retentionDays, forKey: JSONKey(CodingKeys.retentionDays.rawValue))
        try unknown.write(to: &container, excluding: Self.knownKeys)
    }
}
