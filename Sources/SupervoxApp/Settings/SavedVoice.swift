import Foundation

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
