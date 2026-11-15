import Foundation
import Testing

@testable import SupervoxApp

/// Une valeur JSON quelconque et les champs inconnus d'un objet : ce que cette version ne connaît pas est lu tel quel et
/// réécrit tel quel (M7, m6). Aucun disque.
@Suite struct JSONValueTests {
    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private func encoded(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func eachKindOfValueIsReadAsItsOwnCase() throws {
        #expect(try decode(#""texte""#) == .string("texte"))
        #expect(try decode("12") == .number(12))
        #expect(try decode("-0.5") == .number(-0.5))
        #expect(try decode("true") == .bool(true))
        #expect(try decode("false") == .bool(false))
        #expect(try decode("null") == .null)
        #expect(try decode(#"[1, "a", null]"#) == .array([.number(1), .string("a"), .null]))
        #expect(try decode(#"{"a": {"b": []}}"#) == .object(["a": .object(["b": .array([])])]))
    }

    /// Un booléen reste un booléen et un nombre reste un nombre : `true` ne devient pas `1`, ni `0` `false`.
    @Test func aBooleanIsNeverReadAsANumberNorTheOtherWayRound() throws {
        #expect(try decode("true") != .number(1))
        #expect(try decode("1") != .bool(true))
        #expect(try decode("0") != .bool(false))
        #expect(try decode("false") != .number(0))
    }

    @Test(arguments: [
        #""texte""#, #""""#, "0", "12", "6144", "-3", "1.5", "true", "false", "null", "[]", "{}",
        #"[1,"a",true,null,[2],{"b":false}]"#, #"{"a":null,"b":[],"c":{"d":{"e":1.25}},"f":true,"g":"x"}"#,
    ])
    func everyKindSurvivesARoundTripIdentically(json: String) throws {
        let value = try decode(json)
        #expect(try encoded(value) == json)
        #expect(try decode(encoded(value)) == value)
    }

    /// Les nombres entiers se réécrivent sans partie décimale : `6144` reste `6144` (les modificateurs d'un raccourci).
    @Test func anIntegerIsWrittenWithoutADecimalPart() throws {
        #expect(try encoded(.number(6144)) == "6144")
        #expect(try encoded(.array([.number(0), .number(-1), .number(2.5)])) == "[0,-1,2.5]")
    }

    @Test func aStringKeepsItsCharactersAndEscapes() throws {
        let tricky = "guillemets \" barre \\ saut \n accent é emoji 🙂 tabulation \t"
        let value = JSONValue.string(tricky)
        #expect(try decode(encoded(value)) == value)
    }

    // MARK: - Champs inconnus

    /// Un objet à deux champs connus et des champs inconnus de toutes les formes.
    private struct Host: Codable, Equatable {
        static let known: Set<String> = ["id", "name"]
        var id: String
        var name: String
        var unknown: UnknownFields

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: JSONKey.self)
            id = try container.decode(String.self, forKey: JSONKey("id"))
            name = try container.decode(String.self, forKey: JSONKey("name"))
            unknown = try UnknownFields(reading: container, excluding: Self.known)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: JSONKey.self)
            try container.encode(id, forKey: JSONKey("id"))
            try container.encode(name, forKey: JSONKey("name"))
            try unknown.write(to: &container, excluding: Self.known)
        }
    }

    private static let hostJSON = #"""
    {"id": "a", "name": "Nom", "futur-objet": {"x": [1, {"y": null}]}, "futur-tableau": [1, "deux", false],
     "futur-nombre": 2.5, "futur-booleen": true, "futur-nul": null, "futur-texte": "t"}
    """#

    @Test func unknownKeysAreReadWithoutTheKnownOnes() throws {
        let host = try JSONDecoder().decode(Host.self, from: Data(Self.hostJSON.utf8))
        #expect(Set(host.unknown.values.keys) == [
            "futur-objet", "futur-tableau", "futur-nombre", "futur-booleen", "futur-nul", "futur-texte",
        ])
        #expect(host.unknown.values["id"] == nil)
        #expect(host.unknown.values["name"] == nil)
        #expect(host.unknown.values["futur-nul"] == .null)
        #expect(host.unknown.values["futur-booleen"] == .bool(true))
    }

    /// Un objet, un tableau, un nombre, un booléen et `null` font l'aller-retour à l'identique ; `null` est bien écrit (la clé
    /// reste là), `true` n'est pas écrit `1`.
    @Test func unknownKeysAreWrittenBackAsTheyWereRead() throws {
        let host = try JSONDecoder().decode(Host.self, from: Data(Self.hostJSON.utf8))
        let data = try JSONEncoder().encode(host)
        let written = try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let original = try #require(try JSONSerialization.jsonObject(with: Data(Self.hostJSON.utf8)) as? NSDictionary)
        #expect(written.isEqual(to: original), "\(written) \(original)")
        #expect(written["futur-nul"] is NSNull)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""futur-booleen":true"#) || text.contains(#""futur-booleen" : true"#))
        #expect(try JSONDecoder().decode(Host.self, from: data) == host)
    }

    /// Une clé connue n'entre jamais dans les champs inconnus, même si on essaie de l'y mettre à l'écriture.
    @Test func aKnownKeyNeverEntersTheUnknownFieldsNorIsWrittenFromThem() throws {
        var host = try JSONDecoder().decode(Host.self, from: Data(Self.hostJSON.utf8))
        host.unknown = UnknownFields(["id": .string("intrus"), "autre": .number(1)])
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        #expect(object["id"] as? String == "a")
        #expect(object["autre"] as? Int == 1)
    }

    @Test func anObjectWithoutUnknownKeysWritesNoneAndIsEmpty() throws {
        let host = try JSONDecoder().decode(Host.self, from: Data(#"{"id":"a","name":"n"}"#.utf8))
        #expect(host.unknown.values.isEmpty)
        #expect(host.unknown == UnknownFields())
        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "name"])
    }
}
