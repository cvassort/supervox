import Foundation
import Testing

@testable import SupervoxApp

/// Dossier temporaire unique ; l'appelant le supprime avec `defer { removeDirectory(directory) }`. Jamais le vrai dossier de
/// réglages.
private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("supervox-settings-v3-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeDirectory(_ directory: URL) { try? FileManager.default.removeItem(at: directory) }

private func names(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

/// 2023-11-14 22:13:20 UTC.
private let fixedClock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }
private let asideName = "settings.json.illisible-20231114T221320Z"

private let providerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

/// Le passage du fichier de la version 2 (étape 5) à la version 3 (étape 6) : lecture sans perte, première écriture, fichier d'une
/// version future, fichier illisible, et champs inconnus des types imbriqués.
@Suite struct SettingsMigrationV3Tests {
    // MARK: - Un fichier de la version 2

    /// Un fichier de la version 2 TAPÉ À LA MAIN, à la forme (clés triées, indentation) de ce que l'étape 5 écrit ; il n'est pas
    /// produit par l'encodeur de l'étape 5 (la fixture de l'étape 4, dans `SettingsStoreTests`, l'est). Fournisseur d'exemple, les
    /// quatre modes de base, `fastModel` et `strongModel` choisis, et chaque champ à une valeur qui n'est pas son défaut (pour
    /// qu'une perte se voie).
    private static let versionTwoFile = #"""
    {
      "fastModel" : {
        "model" : "modele-exemple-rapide",
        "providerID" : "00000000-0000-0000-0000-0000000000A1"
      },
      "hotKey" : {
        "keyCode" : 40,
        "modifiers" : 768
      },
      "hotKeyBehavior" : "hold",
      "lastModeID" : "prompt",
      "modes" : [
        {
          "id" : "dictee-brute",
          "name" : "Dictée brute",
          "reviewBeforePaste" : true
        },
        {
          "engine" : "parakeet",
          "hotKey" : {
            "keyCode" : 12,
            "modifiers" : 6144
          },
          "id" : "dictee-nettoyee",
          "name" : "Dictée nettoyée"
        },
        {
          "id" : "prompt",
          "instruction" : "Consigne d'exemple.",
          "model" : {
            "model" : "modele-exemple-fort",
            "providerID" : "00000000-0000-0000-0000-0000000000A1"
          },
          "name" : "Prompt",
          "reviewBeforePaste" : false
        },
        {
          "id" : "entretien",
          "name" : "Entretien"
        }
      ],
      "providers" : [
        {
          "baseURL" : "https:\/\/example.com\/v1",
          "id" : "00000000-0000-0000-0000-0000000000A1",
          "kind" : "openAICompatible",
          "models" : [
            "modele-exemple-rapide",
            "modele-exemple-fort"
          ],
          "name" : "Fournisseur d'exemple"
        }
      ],
      "strongModel" : {
        "model" : "modele-exemple-fort",
        "providerID" : "00000000-0000-0000-0000-0000000000A1"
      },
      "systemConflictShown" : {
        "keyCode" : 49,
        "modifiers" : 256
      },
      "transcription" : {
        "engine" : "parakeet",
        "language" : "en",
        "vocabulary" : [
          "Kubernetes",
          "Docker"
        ],
        "whisperModel" : "small"
      },
      "version" : 2
    }
    """#

    private let newKeys = ["interview", "voice", "history"]

    @Test func aVersionTwoFileIsReadWithoutLossAndTheThreeNewFieldsTakeTheirDefaults() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        try Data(Self.versionTwoFile.utf8).write(to: file)

        let result = SettingsStore(file: file, now: fixedClock).load()
        #expect(result.notice == nil)
        #expect(result.saveRefusal == nil)
        #expect(!result.isFirstLaunch)
        #expect(try names(in: directory) == ["settings.json"])
        #expect(try Data(contentsOf: file) == Data(Self.versionTwoFile.utf8))

        let settings = result.settings
        let fast = ModelChoice(providerID: providerID, model: "modele-exemple-rapide")
        let strong = ModelChoice(providerID: providerID, model: "modele-exemple-fort")
        #expect(settings.version == 3)
        #expect(settings.providers == [
            Provider(
                id: providerID, name: "Fournisseur d'exemple", baseURL: "https://example.com/v1", kind: .openAICompatible,
                models: ["modele-exemple-rapide", "modele-exemple-fort"])
        ])
        #expect(settings.hotKey == HotKey(keyCode: 40, modifiers: [.command, .shift]))
        #expect(settings.hotKeyBehavior == .hold)
        #expect(settings.lastModeID == "prompt")
        #expect(settings.systemConflictShown == HotKey(keyCode: 49, modifiers: [.command]))
        #expect(settings.transcription == TranscriptionSettings(
            engine: .parakeet, whisperModel: "small", language: "en", vocabulary: ["Kubernetes", "Docker"]))
        #expect(settings.fastModel == fast)
        #expect(settings.strongModel == strong)
        #expect(settings.modes.map(\.id) == ModeChip.fixed.map(\.id))
        #expect(settings.modes[0].reviewBeforePaste == true)
        #expect(settings.modes[1].engine == .parakeet)
        #expect(settings.modes[1].hotKey == HotKey(keyCode: 12, modifiers: [.control, .option]))
        #expect(settings.modes[2].instruction == "Consigne d'exemple.")
        #expect(settings.modes[2].model == strong)
        #expect(settings.modes[2].reviewBeforePaste == false)
        #expect(settings.modes[3].reviewBeforePaste == nil)

        #expect(settings.interview == .defaults)
        #expect(settings.voice == .system)
        #expect(settings.history == .defaults)
    }

    /// La première écriture est de la version 3 et rend au mot près tous les champs de la version 2 : mêmes clés, mêmes valeurs,
    /// à la même place. Seuls `version` et les trois champs neufs diffèrent.
    @Test func theFirstSaveWritesVersionThreeAndReturnsEveryVersionTwoFieldWordForWord() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file, now: fixedClock)
        try Data(Self.versionTwoFile.utf8).write(to: file)

        let loaded = store.load().settings
        try store.save(loaded)

        var written = try jsonObject(Data(contentsOf: file))
        #expect(written["version"] as? Int == 3)
        for key in newKeys { #expect(written[key] is [String: Any], "\(key) absent du fichier écrit") }
        for key in newKeys { written[key] = nil }
        written["version"] = nil
        var expected = try jsonObject(Data(Self.versionTwoFile.utf8))
        expected["version"] = nil
        #expect(Set(written.keys) == Set(expected.keys))
        #expect((written as NSDictionary).isEqual(to: expected), "\(written) \(expected)")

        // Relu : les mêmes réglages, sans avis, sans copie mise de côté.
        let reloaded = store.load()
        #expect(reloaded.settings == loaded)
        #expect(reloaded.notice == nil)
        #expect(try names(in: directory) == ["settings.json"])
    }

    /// Les trois champs neufs s'écrivent avec leurs défauts, puis se relisent ; un choix fait ensuite survit à la relecture.
    @Test func theNewFieldsAreWrittenWithTheirDefaultsAndAChoiceMadeAfterwardsSurvives() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file, now: fixedClock)
        try Data(Self.versionTwoFile.utf8).write(to: file)

        var settings = store.load().settings
        try store.save(settings)
        let first = try jsonObject(Data(contentsOf: file))
        let history = try #require(first["history"] as? [String: Any])
        #expect(history["retentionDays"] as? Int == 30)
        let interview = try #require(first["interview"] as? [String: Any])
        #expect(interview["maxQuestions"] as? Int == 8)

        settings.interview.maxQuestions = 5
        settings.interview.template = "Un gabarit d'exemple."
        settings.voice = VoiceChoice(
            providerID: providerID, model: "modele-exemple-voix", identifier: "voix-exemple", gender: .neutral)
        settings.history.retentionDays = 90
        try store.save(settings)

        let reloaded = store.load().settings
        #expect(reloaded.interview.maxQuestions == 5)
        #expect(reloaded.interview.template == "Un gabarit d'exemple.")
        #expect(reloaded.voice.identifier == "voix-exemple")
        #expect(reloaded.voice.gender == .neutral)
        #expect(reloaded.voice.providerID == providerID)
        #expect(reloaded.history.retentionDays == 90)
        #expect(reloaded == settings)
    }

    /// Les valeurs hors borne d'un fichier sont bornées dès `load()` : un consommateur qui lit `settings.interview` ou
    /// `settings.history` sans rien appeler ne voit jamais une question maximale nulle, ni une durée de conservation négative
    /// (qui ferait supprimer tout l'historique) ou énorme.
    @Test(arguments: [
        (#"{"version": 3, "interview": {"maxQuestions": 0}, "history": {"retentionDays": -5}}"#, 1, 30),
        (#"{"version": 3, "interview": {"maxQuestions": 99}, "history": {"retentionDays": 9223372036854775807}}"#, 20, 3650),
        (#"{"version": 3, "interview": {"maxQuestions": 7}, "history": {"retentionDays": 0}}"#, 7, 0),
    ])
    func outOfRangeValuesAreBoundedByLoad(json: String, questions: Int, days: Int) throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file, now: fixedClock)
        try Data(json.utf8).write(to: file)

        let loaded = store.load()
        #expect(loaded.notice == nil)
        #expect(loaded.settings.interview.maxQuestions == questions)
        #expect(loaded.settings.history.retentionDays == days)
        try store.save(loaded.settings)
        let written = try jsonObject(Data(contentsOf: file))
        #expect((written["interview"] as? [String: Any])?["maxQuestions"] as? Int == questions)
        #expect((written["history"] as? [String: Any])?["retentionDays"] as? Int == days)
    }

    // MARK: - Fichier futur et fichier illisible

    /// Un fichier de la version 4 : lu autant que possible (ce que la version 3 en connaît), jamais écrasé.
    @Test func aVersionFourFileIsReadAsFarAsPossibleAndNeverOverwritten() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let original = Data(
            #"{"version": 4, "lastModeID": "prompt", "interview": {"maxQuestions": 3, "futur": 1}, "champ-du-futur": true}"#.utf8)
        try original.write(to: file)
        let store = SettingsStore(file: file, now: fixedClock)

        let result = store.load()
        #expect(result.saveRefusal == .newerVersionKept(fileName: "settings.json", version: 4))
        #expect(result.notice?.contains("plus récente") == true)
        #expect(result.settings.lastModeID == "prompt")
        #expect(result.settings.interview.maxQuestions == 3)
        #expect(result.settings.version == AppSettings.current)
        #expect(throws: SettingsError.newerVersionKept(fileName: "settings.json", version: 4)) {
            try store.save(result.settings)
        }
        #expect(try Data(contentsOf: file) == original)
        #expect(try names(in: directory) == ["settings.json"])
    }

    /// Un fichier de la version 4 d'une forme que la version 3 ne lit pas : réglages par défaut, fichier ni déplacé ni écrasé.
    @Test func aVersionFourFileOfAnotherShapeIsNeitherMovedNorOverwritten() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let original = Data(#"{"version": 4, "interview": "une autre forme", "history": 12}"#.utf8)
        try original.write(to: file)
        let store = SettingsStore(file: file, now: fixedClock)

        let result = store.load()
        #expect(result.settings.interview == .defaults)
        #expect(result.saveRefusal == .newerVersionKept(fileName: "settings.json", version: 4))
        #expect(throws: SettingsError.newerVersionKept(fileName: "settings.json", version: 4)) {
            try store.save(.defaults)
        }
        #expect(try Data(contentsOf: file) == original)
        #expect(try names(in: directory) == ["settings.json"])
    }

    /// Un bloc neuf (`interview`, `voice`, `history`) qui n'est pas un objet prend ses défauts : tout champ neuf est optionnel au
    /// décodage. Le reste du fichier (fournisseur, modes, raccourcis) est lu normalement, rien n'est mis de côté ni avisé, et le
    /// fichier n'est pas touché à la lecture.
    @Test(arguments: [
        #""interview": "une autre forme""#, #""voice": ["une", "autre", "forme"]"#, #""history": 12"#,
        #""interview": 3, "voice": null, "history": [1]"#,
    ])
    func aNewBlockThatIsNotAnObjectTakesItsDefaultsAndTheRestOfTheFileIsRead(block: String) throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file, now: fixedClock)
        let original = Data(
            """
            {"version": 3, \(block), "lastModeID": "prompt", "hotKey": {"keyCode": 40, "modifiers": 768},
             "providers": [{"id": "00000000-0000-0000-0000-0000000000A1", "name": "Fournisseur d'exemple",
                            "baseURL": "https://example.com/v1", "kind": "anthropic", "models": ["modele-exemple-fort"]}],
             "modes": [{"id": "dictee-brute", "name": "Dictée brute"}, {"id": "perso-1", "name": "Courriel", "instruction": "Écris."},
                       {"id": "entretien", "name": "Entretien"}]}
            """.utf8)
        try original.write(to: file)

        let result = store.load()
        #expect(result.notice == nil)
        #expect(result.saveRefusal == nil)
        #expect(try names(in: directory) == ["settings.json"])
        #expect(try Data(contentsOf: file) == original)
        let settings = result.settings
        #expect(settings.lastModeID == "prompt")
        #expect(settings.hotKey == HotKey(keyCode: 40, modifiers: [.command, .shift]))
        #expect(settings.providers.map(\.name) == ["Fournisseur d'exemple"])
        #expect(settings.mode("perso-1")?.instruction == "Écris.")
        #expect(settings.interview == .defaults)
        #expect(settings.voice == .system)
        #expect(settings.history == .defaults)

        // La première écriture remet des objets à la place.
        try store.save(settings)
        let written = try jsonObject(Data(contentsOf: file))
        for key in newKeys { #expect(written[key] is [String: Any], "\(key)") }
    }

    /// Ce qui reste illisible (comportement de l'étape 5) : un champ ancien d'une autre forme.
    @Test func aVersionThreeFileWithAnOldFieldOfAnotherShapeIsStillSetAside() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let original = Data(#"{"version": 3, "providers": "une autre forme", "history": 12}"#.utf8)
        try original.write(to: file)

        let result = SettingsStore(file: file, now: fixedClock).load()
        #expect(result.settings == .defaults)
        #expect(result.saveRefusal == nil)
        #expect(try #require(result.notice).contains(asideName))
        #expect(try names(in: directory) == [asideName])
        #expect(try Data(contentsOf: directory.appendingPathComponent(asideName)) == original)
    }

    // MARK: - Champs inconnus des types imbriqués (règle 3)

    /// Un fichier de la version 3 avec un champ inconnu dans chacun des sept types imbriqués, à chaque endroit où le type
    /// apparaît (le raccourci des réglages, d'un mode, `systemConflictShown` ; le choix de modèle des réglages et d'un mode),
    /// chacun d'une forme différente. Les champs connus sont tous présents : l'arbre écrit doit lui ressembler à l'identique.
    private static let versionThreeFileWithUnknownFields = #"""
    {
      "fastModel" : {
        "futur-modele" : { "a" : [ 1, null ] },
        "model" : "modele-exemple-rapide",
        "providerID" : "00000000-0000-0000-0000-0000000000A1"
      },
      "history" : {
        "futur-historique" : [ "a", 2 ],
        "retentionDays" : 90
      },
      "hotKey" : {
        "futur-touche" : { "x" : "y" },
        "keyCode" : 40,
        "modifiers" : 768
      },
      "hotKeyBehavior" : "hold",
      "interview" : {
        "futur-entretien" : 2.5,
        "interruptLevel" : -25,
        "interruptMinDuration" : 0.4,
        "maxQuestions" : 5,
        "template" : "Un gabarit d'exemple.",
        "turnSilence" : 0.9
      },
      "lastModeID" : "prompt",
      "modes" : [
        {
          "hotKey" : {
            "futur-touche-mode" : [ true ],
            "keyCode" : 12,
            "modifiers" : 6144
          },
          "id" : "dictee-brute",
          "name" : "Dictée brute"
        },
        {
          "id" : "prompt",
          "instruction" : "Consigne d'exemple.",
          "model" : {
            "futur-modele-mode" : "z",
            "model" : "modele-exemple-fort",
            "providerID" : "00000000-0000-0000-0000-0000000000A1"
          },
          "name" : "Prompt"
        },
        {
          "id" : "entretien",
          "name" : "Entretien"
        }
      ],
      "providers" : [
        {
          "baseURL" : "https:\/\/example.com\/v1",
          "couleur" : "bleu",
          "futur-fournisseur" : { "n" : null },
          "id" : "00000000-0000-0000-0000-0000000000A1",
          "kind" : "openAICompatible",
          "models" : [ "modele-exemple-rapide" ],
          "name" : "Fournisseur d'exemple"
        }
      ],
      "strongModel" : {
        "futur-modele-fort" : false,
        "model" : "modele-exemple-fort",
        "providerID" : "00000000-0000-0000-0000-0000000000A1"
      },
      "systemConflictShown" : {
        "futur-conflit" : 7,
        "keyCode" : 49,
        "modifiers" : 256
      },
      "transcription" : {
        "engine" : "parakeet",
        "futur-transcription" : [ [ 1 ], [ 2 ] ],
        "language" : "en",
        "vocabulary" : [ "Kubernetes" ],
        "whisperModel" : "small"
      },
      "version" : 3,
      "voice" : {
        "extra" : { "parametre-exemple" : "valeur-exemple" },
        "futur-voix" : "texte",
        "gender" : "autre-valeur",
        "identifier" : "voix-exemple",
        "language" : "fr-FR",
        "model" : "modele-exemple-voix",
        "providerID" : "00000000-0000-0000-0000-0000000000A1"
      }
    }
    """#

    /// Lecture puis écriture, après une modification de champs connus faite en place : tout champ inconnu revient à la même place
    /// dans l'arbre, avec sa valeur d'origine ; les champs modifiés portent leur valeur neuve ; rien n'est ajouté ni perdu.
    @Test func anUnknownFieldOfAnyNestedTypeComesBackAtTheSamePlaceInTheTree() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file, now: fixedClock)
        try Data(Self.versionThreeFileWithUnknownFields.utf8).write(to: file)

        let result = store.load()
        #expect(result.notice == nil)
        #expect(result.saveRefusal == nil)
        var settings = result.settings
        // Des modifications en place, sur des types qui portent un champ inconnu : celui-ci doit suivre la valeur modifiée.
        settings.lastModeID = "dictee-brute"
        settings.hotKey.keyCode = 41
        settings.transcription.language = "fr"
        settings.providers[0].name = "Autre fournisseur d'exemple"
        settings.strongModel?.model = "modele-exemple-rapide"
        settings.interview.maxQuestions = 6
        settings.voice.identifier = "autre-voix-exemple"
        settings.history.retentionDays = 7
        try store.save(settings)

        var expected = try jsonObject(Data(Self.versionThreeFileWithUnknownFields.utf8))
        func edit(_ path: [String], _ value: Any) {
            func set(_ node: inout [String: Any], _ path: ArraySlice<String>) {
                let key = path.first!
                if path.count == 1 {
                    node[key] = value
                } else {
                    var child = node[key] as! [String: Any]
                    set(&child, path.dropFirst())
                    node[key] = child
                }
            }
            set(&expected, path[...])
        }
        edit(["lastModeID"], "dictee-brute")
        edit(["hotKey", "keyCode"], 41)
        edit(["transcription", "language"], "fr")
        var providers = try #require(expected["providers"] as? [[String: Any]])
        providers[0]["name"] = "Autre fournisseur d'exemple"
        expected["providers"] = providers
        edit(["strongModel", "model"], "modele-exemple-rapide")
        edit(["interview", "maxQuestions"], 6)
        edit(["voice", "identifier"], "autre-voix-exemple")
        edit(["history", "retentionDays"], 7)

        let written = try jsonObject(Data(contentsOf: file))
        #expect((written as NSDictionary).isEqual(to: expected), "\(written)\n\(expected)")

        // Les endroits un par un, pour que l'échec dise lequel manque.
        func has(_ node: Any?, _ key: String) -> Bool { (node as? [String: Any])?[key] != nil }
        let modes = try #require(written["modes"] as? [[String: Any]])
        #expect(has((written["providers"] as? [[String: Any]])?.first, "couleur"))
        #expect(has((written["providers"] as? [[String: Any]])?.first, "futur-fournisseur"))
        #expect(has(written["hotKey"], "futur-touche"))
        #expect(has(written["systemConflictShown"], "futur-conflit"))
        #expect(has(written["transcription"], "futur-transcription"))
        #expect(has(written["strongModel"], "futur-modele-fort"))
        #expect(has(written["fastModel"], "futur-modele"))
        #expect(has(modes[0]["hotKey"], "futur-touche-mode"))
        #expect(has(modes[1]["model"], "futur-modele-mode"))
        #expect(has(written["interview"], "futur-entretien"))
        #expect(has(written["voice"], "futur-voix"))
        #expect(has(written["history"], "futur-historique"))
    }

    /// Le champ de genre inconnu traverse aussi le fichier : réécrit à l'identique, pas remplacé ni supprimé.
    @Test func anUnknownGenderSurvivesTheFile() throws {
        let directory = try makeDirectory()
        defer { removeDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file, now: fixedClock)
        try Data(Self.versionThreeFileWithUnknownFields.utf8).write(to: file)

        let settings = store.load().settings
        #expect(settings.voice.gender == .other("autre-valeur"))
        try store.save(settings)
        let written = try jsonObject(Data(contentsOf: file))
        #expect((written["voice"] as? [String: Any])?["gender"] as? String == "autre-valeur")
    }

    // MARK: - L'égalité ignore les champs inconnus (règle 3)

    @Test func twoHotKeysOfTheSameKeyAndModifiersAreEqualWhateverUnknownFieldTheyCarry() throws {
        let plain = HotKey(keyCode: 49, modifiers: [.control, .option])
        let one = try decode(HotKey.self, #"{"keyCode": 49, "modifiers": 6144, "futur": {"a": 1}}"#)
        let other = try decode(HotKey.self, #"{"keyCode": 49, "modifiers": 6144, "autre-futur": [2]}"#)
        #expect(one == other)
        #expect(one == plain)
        #expect(plain == other)
        #expect(one != HotKey(keyCode: 50, modifiers: [.control, .option]))
        #expect(one != HotKey(keyCode: 49, modifiers: [.control]))
    }

    /// La comparaison que fait `AppController` ne voit pas le champ inconnu : le raccourci déjà signalé
    /// (`systemConflictShown`) reste reconnu comme tel.
    @Test func theComparisonsOfTheAppDoNotSeeAnUnknownFieldOfAHotKey() throws {
        let shown = try decode(HotKey.self, #"{"keyCode": 49, "modifiers": 256, "futur": 1}"#)
        let settings = AppSettings(
            version: 3, providers: [], hotKey: .standard, hotKeyBehavior: .toggle, lastModeID: "prompt",
            systemConflictShown: shown)
        #expect(settings.systemConflictShown == HotKey(keyCode: 49, modifiers: [.command]))
        #expect(settings.systemConflictShown != HotKey(keyCode: 49, modifiers: [.command, .shift]))
        // Deux jeux de réglages qui ne diffèrent que par un champ inconnu d'un type imbriqué sont égaux.
        var plain = settings
        plain.systemConflictShown = HotKey(keyCode: 49, modifiers: [.command])
        #expect(plain == settings)
    }

    @Test func twoProvidersAreEqualWhateverUnknownFieldTheyCarryButNotWhenAKnownFieldDiffers() throws {
        let base = #"{"id": "00000000-0000-0000-0000-0000000000A1", "name": "Fournisseur d'exemple", "baseURL": "https://example.com/v1", "kind": "anthropic", "models": ["modele-exemple-rapide"]"#
        let one = try decode(Provider.self, base + #", "couleur": "bleu"}"#)
        let other = try decode(Provider.self, base + #", "couleur": "rouge", "autre": [1]}"#)
        let plain = Provider(
            id: providerID, name: "Fournisseur d'exemple", baseURL: "https://example.com/v1", kind: .anthropic,
            models: ["modele-exemple-rapide"])
        #expect(one == other)
        #expect(one == plain)
        var variants = [Provider](repeating: plain, count: 5)
        variants[0].id = UUID()
        variants[1].name = "Autre"
        variants[2].baseURL = "https://example.com/v2"
        variants[3].kind = .openAICompatible
        variants[4].models = []
        for (index, variant) in variants.enumerated() { #expect(variant != one, "champ \(index)") }
    }

    @Test func twoModelChoicesAreEqualWhateverUnknownFieldTheyCarryButNotWhenAKnownFieldDiffers() throws {
        let one = try decode(
            ModelChoice.self,
            #"{"providerID": "00000000-0000-0000-0000-0000000000A1", "model": "modele-exemple-fort", "futur": 1}"#)
        #expect(one == ModelChoice(providerID: providerID, model: "modele-exemple-fort"))
        #expect(one != ModelChoice(providerID: providerID, model: "modele-exemple-rapide"))
        #expect(one != ModelChoice(providerID: UUID(), model: "modele-exemple-fort"))
        // Les modes se comparent par leur choix : le champ inconnu d'un `ModelChoice` n'y change rien.
        let mode = Mode(id: "prompt", name: "Prompt", model: one)
        #expect(mode == Mode(id: "prompt", name: "Prompt", model: ModelChoice(providerID: providerID, model: "modele-exemple-fort")))
    }

    @Test func twoTranscriptionSettingsAreEqualWhateverUnknownFieldTheyCarryButNotWhenAKnownFieldDiffers() throws {
        let one = try decode(
            TranscriptionSettings.self,
            #"{"engine": "parakeet", "whisperModel": "small", "language": "en", "vocabulary": ["Kubernetes"], "futur": {"a": 1}}"#)
        let plain = TranscriptionSettings(
            engine: .parakeet, whisperModel: "small", language: "en", vocabulary: ["Kubernetes"])
        #expect(one == plain)
        var variants = [TranscriptionSettings](repeating: plain, count: 4)
        variants[0].engine = .whisperKit
        variants[1].whisperModel = "base"
        variants[2].language = "fr"
        variants[3].vocabulary = []
        for (index, variant) in variants.enumerated() { #expect(variant != one, "champ \(index)") }
    }

    // MARK: - Ce qui ne change pas

    /// Les champs connus des types devenus tolérants restent ceux d'avant : un raccourci sans touche, un fournisseur sans adresse
    /// ou un choix de modèle sans modèle n'a pas de sens, le fichier est alors illisible (comme à l'étape 5).
    @Test func theRequiredFieldsOfTheNestedTypesAreStillRequired() {
        #expect(throws: DecodingError.self) { try decode(HotKey.self, #"{"modifiers": 256}"#) }
        #expect(throws: DecodingError.self) { try decode(HotKey.self, #"{"keyCode": 49}"#) }
        #expect(throws: DecodingError.self) { try decode(ModelChoice.self, #"{"model": "modele-exemple"}"#) }
        #expect(throws: DecodingError.self) {
            try decode(ModelChoice.self, #"{"providerID": "00000000-0000-0000-0000-0000000000A1"}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode(Provider.self, #"{"id": "00000000-0000-0000-0000-0000000000A1", "name": "x", "kind": "anthropic"}"#)
        }
    }
}
