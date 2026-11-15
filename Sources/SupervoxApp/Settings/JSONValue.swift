import Foundation

/// Une valeur JSON quelconque : ce que le fichier de réglages porte et que cette version ne connaît pas (champs d'une version
/// plus récente, options d'un mode d'un fichier plus ancien) est lu sous cette forme et réécrit tel quel.
///
/// Les nombres sont lus en `Double` : un entier plus grand que 2^53 perdrait des chiffres. Aucun réglage connu n'en approche.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // `null` d'abord ; un booléen avant un nombre (`JSONDecoder` ne lit pas `1` comme booléen, mais l'ordre le dit).
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Une clé quelconque d'un objet JSON : un conteneur à clés libres lit et écrit aussi ce que le type ne connaît pas.
struct JSONKey: CodingKey, Hashable {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Les champs d'un objet que la version courante ne connaît pas : lus par un conteneur à clés libres, réécrits tels quels.
/// Une clé connue n'y entre jamais (elle est exclue à la lecture, et à l'écriture : un champ connu n'est jamais écrit deux fois).
struct UnknownFields: Equatable, Sendable {
    private(set) var values: [String: JSONValue]

    init(_ values: [String: JSONValue] = [:]) { self.values = values }

    /// Toutes les clés du conteneur sauf `known`.
    init(reading container: KeyedDecodingContainer<JSONKey>, excluding known: Set<String>) throws {
        var values: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            values[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.values = values
    }

    /// Réécrit ces champs, sauf ceux dont la clé est connue (déjà écrits par le type lui-même).
    func write(to container: inout KeyedEncodingContainer<JSONKey>, excluding known: Set<String>) throws {
        for (name, value) in values where !known.contains(name) {
            try container.encode(value, forKey: JSONKey(name))
        }
    }
}
