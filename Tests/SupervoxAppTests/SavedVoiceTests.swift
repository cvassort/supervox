import Foundation
import Testing

@testable import SupervoxApp

/// Les voix enregistrées dans les réglages (`AppSettings.voices`, `SavedVoice`) : lecture d'un fichier qui n'en a pas, entrée
/// illisible gardée et réécrite, champs inconnus d'une entrée, fichier non modifié qui reste identique (règles 1 et 2 de la tâche 2).
/// Tout passe par l'encodeur et le décodeur JSON : aucun fichier, aucun dossier.
@Suite(.timeLimit(.minutes(1))) struct SavedVoiceTests {
    static let firstID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0A1")!
    static let secondID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0A2")!
    static let providerID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0B1")!

    /// Une entrée lisible, à la forme exacte que l'encodeur écrit (pour que la comparaison des valeurs JSON soit stricte).
    static let firstEntry = #"{"id":"00000000-0000-0000-0000-00000000C0A1","name":"Voix d'exemple A","voice":{"identifier":"voix.exemple.a","language":"fr-FR","extra":{}}}"#
    static let secondEntry = #"{"id":"00000000-0000-0000-0000-00000000C0A2","name":"Voix d'exemple A","voice":{"providerID":"00000000-0000-0000-0000-00000000C0B1","model":"modele-voix-exemple","identifier":"voix-exemple","language":"fr-FR","extra":{"cle-exemple":"valeur-exemple"}}}"#

    static func value(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    static func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    static func decode(_ value: JSONValue) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(value))
    }

    /// Ce que l'encodeur écrit, relu comme valeur JSON.
    static func written(_ settings: AppSettings) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(JSONValue.self, from: try JSONEncoder().encode(settings))
        guard case .object(let object) = value else { throw Unexpected() }
        return object
    }

    struct Unexpected: Error {}

    static func array(_ value: JSONValue?) throws -> [JSONValue] {
        guard case .array(let items) = value else { throw Unexpected() }
        return items
    }

    static func object(_ value: JSONValue?) throws -> [String: JSONValue] {
        guard case .object(let object) = value else { throw Unexpected() }
        return object
    }

    /// Un fichier tel que l'étape 6 l'écrivait : tout ce que l'encodeur d'aujourd'hui écrit, SANS `voices` (la clé est retirée de
    /// la valeur, quel que soit ce que l'encodeur testé en fait). Chaque champ à une valeur qui n'est pas son défaut.
    static func stepSixFile() throws -> [String: JSONValue] {
        var settings = AppSettings.defaults
        settings.providers = [
            Provider(
                id: providerID, name: "Fournisseur d'exemple", baseURL: "https://example.com/v1", kind: .openAICompatible,
                models: ["modele-exemple"])
        ]
        settings.hotKeyBehavior = .hold
        settings.fastModel = ModelChoice(providerID: providerID, model: "modele-exemple")
        settings.voice = VoiceChoice(
            providerID: providerID, model: "modele-voix-exemple", identifier: "voix-exemple", language: "fr-CA",
            gender: .female, extra: ["cle-exemple": "valeur-exemple"])
        settings.history = HistorySettings(retentionDays: 90)
        var file = try written(settings)
        file["voices"] = nil
        return file
    }

    // MARK: - Règle 1 : lecture

    /// Un fichier de l'étape 6 (sans `voices`) se lit entier : aucune voix, et le reste tel qu'il est écrit.
    @Test func aFileWithoutVoicesReads() throws {
        let file = try Self.stepSixFile()
        let settings = try Self.decode(.object(file))
        #expect(settings.voices.isEmpty)
        #expect(settings.voice.identifier == "voix-exemple", "le reste du fichier est lu")
        #expect(settings.history.retentionDays == 90)

        let minimal = try Self.decode(#"{"version":3}"#)
        #expect(minimal.voices.isEmpty)
    }

    /// Ce qui rend une entrée illisible : `id`, `name` ou `voice` absent ou d'une autre forme, ou une entrée qui n'est pas un objet.
    static let unreadableEntries: [String] = [
        #"{"id":"pas-un-uuid","name":"Voix d'exemple A","voice":{"language":"fr-FR"}}"#,
        #"{"name":"Voix d'exemple A","voice":{"language":"fr-FR"}}"#,
        #"{"id":"00000000-0000-0000-0000-00000000C0A9","name":"Voix d'exemple A","voice":"voix.exemple.a"}"#,
        #"{"id":"00000000-0000-0000-0000-00000000C0A9","name":"Voix d'exemple A"}"#,
        #"{"id":"00000000-0000-0000-0000-00000000C0A9","name":7,"voice":{"language":"fr-FR"}}"#,
        #"{"id":"00000000-0000-0000-0000-00000000C0A9","voice":{"language":"fr-FR"}}"#,
        #"{"id":"00000000-0000-0000-0000-00000000C0A9","name":"Voix d'exemple A","voice":null}"#,
        "42", #""voix.exemple.a""#, "null", "[]", "true",
    ]

    /// Une entrée illisible au milieu de deux lisibles : les deux autres sont lues, et l'illisible revient, valeur JSON égale, APRÈS
    /// les lisibles dans le fichier réécrit.
    @Test(arguments: unreadableEntries)
    func anUnreadableEntryIsKeptAndRewritten(entry: String) throws {
        let json = #"{"version":3,"voices":["# + Self.firstEntry + "," + entry + "," + Self.secondEntry + "]}"
        let settings = try Self.decode(json)
        #expect(settings.voices.map(\.id) == [Self.firstID, Self.secondID], "les entrées lisibles sont lues")
        #expect(settings.voices.last?.voice.extra == ["cle-exemple": "valeur-exemple"])

        let rewritten = try Self.array(try Self.written(settings)["voices"])
        #expect(rewritten.count == 3)
        #expect(rewritten.last == (try Self.value(entry)), "l'entrée illisible revient telle quelle, après les lisibles")
        #expect(Array(rewritten.prefix(2)) == [try Self.value(Self.firstEntry), try Self.value(Self.secondEntry)])
    }

    /// Plusieurs entrées illisibles : toutes gardées, dans leur ordre, après les lisibles ; une relecture du fichier réécrit les
    /// garde encore (rien ne se perd en deux tours).
    @Test func severalUnreadableEntriesKeepTheirOrderOverTwoRewrites() throws {
        let bad1 = Self.unreadableEntries[0]
        let bad2 = Self.unreadableEntries[2]
        let json = #"{"version":3,"voices":["# + bad1 + "," + Self.firstEntry + "," + bad2 + "]}"
        let once = try Self.decode(json)
        let firstRewrite = try Self.written(once)
        let twice = try Self.decode(.object(firstRewrite))
        let secondRewrite = try Self.written(twice)
        let expected = [try Self.value(Self.firstEntry), try Self.value(bad1), try Self.value(bad2)]
        #expect(try Self.array(firstRewrite["voices"]) == expected)
        #expect(try Self.array(secondRewrite["voices"]) == expected)
        #expect(twice.voices.map(\.id) == [Self.firstID])
    }

    /// Décision 1 des amendements : un `voices` qui n'est pas un tableau se lit sans voix, sans faire perdre le reste du fichier ; la
    /// valeur fautive n'est pas gardée (réécrite `[]`, puisque la clé était présente).
    @Test(arguments: [#""texte""#, "42", #"{"id":"00000000-0000-0000-0000-00000000C0A1"}"#, "null"])
    func aVoicesValueOfAnotherShapeReadsEmpty(voices: String) throws {
        var file = try Self.stepSixFile()
        file["voices"] = try Self.value(voices)
        let settings = try Self.decode(.object(file))
        #expect(settings.voices.isEmpty)
        #expect(settings.history.retentionDays == 90, "le reste du fichier est lu")
        #expect(try Self.written(settings)["voices"] == .array([]))
    }

    /// Un champ inconnu d'une entrée (et de sa voix) est gardé, y compris après une modification de l'entrée en place.
    @Test func unknownFieldsOfAnEntrySurvive() throws {
        let entry = #"{"id":"00000000-0000-0000-0000-00000000C0A1","name":"Voix d'exemple A","couleur":"bleu","rang":{"a":1},"voice":{"identifier":"voix.exemple.a","language":"fr-FR","extra":{},"nuance":"douce"}}"#
        var settings = try Self.decode(#"{"version":3,"voices":["# + entry + "]}")
        try #require(settings.voices.count == 1)
        #expect(try Self.array(try Self.written(settings)["voices"]) == [try Self.value(entry)])

        settings.voices[0].name = "Voix d'exemple A (copie)"
        let rewritten = try Self.object(try Self.array(try Self.written(settings)["voices"]).first)
        #expect(rewritten["couleur"] == .string("bleu"))
        #expect(rewritten["rang"] == (try Self.value(#"{"a":1}"#)))
        #expect(try Self.object(rewritten["voice"])["nuance"] == .string("douce"))
        #expect(rewritten["name"] == .string("Voix d'exemple A (copie)"))
    }

    // MARK: - Décision 3 : l'égalité

    /// Une entrée illisible gardée compte dans l'égalité des réglages (comme un champ inconnu du premier niveau, que l'égalité
    /// synthétisée d'`AppSettings` compare) ; un champ inconnu d'une `SavedVoice` ne compte pas (champs connus seulement, comme les
    /// autres types imbriqués) ; la présence d'un `voices` vide à la lecture ne compte pas (c'est la forme du fichier).
    @Test func whatCountsInEquality() throws {
        let clean = try Self.decode(#"{"version":3,"voices":["# + Self.firstEntry + "]}")
        let withUnreadable = try Self.decode(#"{"version":3,"voices":["# + Self.firstEntry + ",42]}")
        #expect(clean.voices == withUnreadable.voices)
        #expect(clean != withUnreadable, "l'entrée illisible gardée compte")

        let plain = try Self.decode(#"{"version":3}"#)
        let unknownTop = try Self.decode(#"{"version":3,"champ-inconnu":1}"#)
        #expect(plain != unknownTop, "témoin : un champ inconnu du premier niveau compte déjà")

        let withUnknownField = try Self.decode(
            #"{"version":3,"voices":[{"id":"00000000-0000-0000-0000-00000000C0A1","name":"Voix d'exemple A","couleur":"bleu","voice":{"identifier":"voix.exemple.a","language":"fr-FR","extra":{}}}]}"#)
        #expect(withUnknownField.voices == clean.voices)
        #expect(withUnknownField == clean, "un champ inconnu d'une entrée ne compte pas")

        let emptyPresent = try Self.decode(#"{"version":3,"voices":[]}"#)
        #expect(emptyPresent == plain, "un voices vide présent à la lecture ne compte pas")

        // Écrites puis relues, des voix sont égales à celles écrites.
        var settings = AppSettings.defaults
        settings.voices = clean.voices
        #expect(try Self.decode(.object(try Self.written(settings))) == settings)
    }

    // MARK: - Règle 2 : écriture

    /// `voices` n'est écrit que s'il n'est pas vide ou s'il était présent à la lecture : un fichier relu puis réécrit sans
    /// changement reste identique (valeur JSON), dans chacun des trois cas.
    @Test func anUntouchedFileStaysIdentical() throws {
        let stepSix = try Self.stepSixFile()
        var emptyPresent = stepSix
        emptyPresent["voices"] = .array([])
        var withVoices = stepSix
        withVoices["voices"] = .array([try Self.value(Self.firstEntry), try Self.value(Self.secondEntry)])

        for (name, file) in [("étape 6, sans voices", stepSix), ("voices vide", emptyPresent), ("deux voix", withVoices)] {
            let rewritten = try Self.written(try Self.decode(.object(file)))
            #expect(rewritten == file, "\(name)")
        }
        #expect(try Self.written(try Self.decode(.object(stepSix)))["voices"] == nil, "aucune clé ajoutée à un fichier de l'étape 6")
        #expect(try Self.written(.defaults)["voices"] == nil, "les réglages par défaut n'écrivent pas de voices")
    }

    /// Une liste présente à la lecture, vidée ensuite, s'écrit `[]` (la clé ne disparaît pas) ; une liste remplie en mémoire s'écrit.
    @Test func aListPresentAtReadingIsWrittenEvenEmptied() throws {
        var file = try Self.stepSixFile()
        file["voices"] = .array([try Self.value(Self.firstEntry)])
        var settings = try Self.decode(.object(file))
        settings.voices = []
        #expect(try Self.written(settings)["voices"] == .array([]))

        var fresh = try Self.decode(.object(try Self.stepSixFile()))
        fresh.voices = [SavedVoice(id: Self.firstID, name: "Voix d'exemple A", voice: VoiceChoice(identifier: "voix.exemple.a"))]
        #expect(try Self.written(fresh)["voices"] == .array([try Self.value(Self.firstEntry)]))
    }
}
