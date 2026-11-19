import Foundation

/// Une voix enregistrée dans les réglages (`AppSettings.voices`) : un nom choisi par la personne et la voix qu'il désigne.
///
/// `id`, `name` et `voice` sont obligatoires : une entrée dont l'un manque ou a une autre forme (un `voice` qui n'est pas un objet,
/// ou dont un champ connu a une forme que `VoiceChoice` ne sait pas lire) ne se lit pas, et `AppSettings` la garde à part, telle
/// quelle. Un champ inconnu de l'entrée ou de sa voix est gardé et réécrit tel quel ; l'égalité ne compare que les champs connus.
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
        let voiceKey = JSONKey(CodingKeys.voice.rawValue)
        guard Self.isFullyReadable(try container.decode([String: JSONValue].self, forKey: voiceKey)) else {
            throw DecodingError.dataCorruptedError(
                forKey: voiceKey, in: container, debugDescription: "un champ connu de la voix a une autre forme")
        }
        voice = try container.decode(VoiceChoice.self, forKey: voiceKey)
        unknown = try UnknownFields(reading: container, excluding: Self.knownKeys)
    }

    /// Vrai si chaque champ CONNU de la voix a une forme que `VoiceChoice` sait lire : `providerID` un UUID écrit en texte, `model`,
    /// `identifier`, `language` et `gender` des textes, `extra` un objet de textes ; `null` vaut absence. Lue tolérante, une voix
    /// d'une autre forme prendrait le défaut du champ et le perdrait à la réécriture : dans une liste que la personne construit,
    /// l'entrée est plutôt gardée telle quelle (`AppSettings.voices`). La voix en vigueur (`settings.voice`) garde sa lecture
    /// tolérante (règle de la version 3).
    private static func isFullyReadable(_ voice: [String: JSONValue]) -> Bool {
        func isTextOrAbsent(_ value: JSONValue?) -> Bool {
            switch value {
            case nil, .null?, .string?: true
            default: false
            }
        }
        if case .string(let text)? = voice["providerID"], UUID(uuidString: text) == nil { return false }
        guard isTextOrAbsent(voice["providerID"]), isTextOrAbsent(voice["model"]), isTextOrAbsent(voice["identifier"]),
            isTextOrAbsent(voice["language"]), isTextOrAbsent(voice["gender"])
        else { return false }
        switch voice["extra"] {
        case nil, .null?: return true
        case .object(let entries)?: return entries.values.allSatisfy { if case .string = $0 { true } else { false } }
        default: return false
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JSONKey.self)
        try container.encode(id, forKey: JSONKey(CodingKeys.id.rawValue))
        try container.encode(name, forKey: JSONKey(CodingKeys.name.rawValue))
        try container.encode(voice, forKey: JSONKey(CodingKeys.voice.rawValue))
        try unknown.write(to: &container, excluding: Self.knownKeys)
    }
}
