import Foundation
import Testing

@testable import SupervoxApp

/// Dossier temporaire unique ; l'appelant le supprime avec `defer { removeTemporaryDirectory(directory) }`.
private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("supervox-settings-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeTemporaryDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

private func names(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

/// Toutes les clés de tous les objets d'un JSON, à n'importe quelle profondeur.
private func allKeys(in json: Any) -> Set<String> {
    if let object = json as? [String: Any] {
        return object.reduce(into: Set(object.keys)) { $0.formUnion(allKeys(in: $1.value)) }
    }
    if let array = json as? [Any] {
        return array.reduce(into: Set<String>()) { $0.formUnion(allKeys(in: $1)) }
    }
    return []
}

/// Noms de clés qui évoquent un secret : recherche par sous-chaîne, sans tenir compte de la casse,
/// avec une exemption explicite pour les noms légitimes qui contiennent « key ».
private func suspiciousKeys(in keys: Set<String>) -> Set<String> {
    let exempt: Set<String> = ["keycode", "hotkey", "hotkeybehavior"]
    let fragments = ["key", "secret", "token", "password"]
    return keys.filter { key in
        let lowered = key.lowercased()
        return !exempt.contains(lowered) && fragments.contains { lowered.contains($0) }
    }
}

/// 2023-11-14 22:13:20 UTC.
private let fixedInstant = Date(timeIntervalSince1970: 1_700_000_000)
private let fixedClock: @Sendable () -> Date = { fixedInstant }
private let asideStem = "settings.json.illisible-20231114T221320Z"

private func sampleSettings() -> AppSettings {
    AppSettings(
        version: AppSettings.current,
        providers: [
            Provider(
                id: UUID(), name: "Local", baseURL: "http://localhost:1234/v1",
                kind: .openAICompatible, models: ["modele-a", "modele-b"]),
            Provider(
                id: UUID(), name: "Distant", baseURL: "https://api.example.com",
                kind: .anthropic, models: []),
        ],
        hotKey: HotKey(keyCode: 40, modifiers: [.command, .shift]),
        hotKeyBehavior: .hold,
        lastModeID: "reformulation",
        modes: Mode.base + [
            Mode(
                id: "perso-1", name: "Courriel", instruction: "Écris un courriel.",
                model: ModelChoice(providerID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, model: "modele-exemple"),
                engine: .parakeet, hotKey: HotKey(keyCode: 12, modifiers: [.control, .option]), reviewBeforePaste: true)
        ],
        strongModel: ModelChoice(providerID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, model: "modele-exemple"),
        fastModel: ModelChoice(providerID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, model: "modele-rapide"))
}

@Suite struct SettingsStoreTests {
    @Test func missingFileGivesDefaultsWithoutNotice() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let result = SettingsStore(file: file).load()
        #expect(result == SettingsLoad(settings: .defaults, notice: nil, isFirstLaunch: true))
        #expect(try names(in: directory).isEmpty)
    }

    /// I3 : seul un fichier absent fait un premier lancement ; un fichier présent, même abîmé ou illisible, non.
    @Test func onlyAMissingFileIsAFirstLaunch() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file)
        #expect(store.load().isFirstLaunch)

        try store.save(.defaults)
        #expect(!store.load().isFirstLaunch)

        try Data("pas du json".utf8).write(to: file)
        #expect(!store.load().isFirstLaunch)  // abîmé : mis de côté, mais ce n'est pas un premier lancement
    }

    @Test func defaultsMatchTheSpecification() {
        let defaults = AppSettings.defaults
        #expect(defaults.version == 2)
        #expect(AppSettings.current == 2)
        #expect(defaults.providers.isEmpty)
        #expect(defaults.hotKey == HotKey(keyCode: 49, modifiers: [.control, .option]))
        #expect(defaults.hotKeyBehavior == .toggle)
        #expect(defaults.lastModeID == "dictee-brute")
    }

    @Test func saveThenLoadRoundTrips() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
        let settings = sampleSettings()
        try store.save(settings)
        let result = store.load()
        #expect(result.settings == settings)
        #expect(result.notice == nil)
        #expect(result.settings != .defaults)
    }

    // L'écriture atomique repose sur `Data.write(options: .atomic)` (Foundation) ; elle n'est pas
    // testée, car retirer `.atomic` laisse ce test vert. Ce test prouve seulement la création du
    // dossier parent et l'absence de fichier temporaire après écriture.
    @Test func saveCreatesTheFolderAndLeavesNoTemporaryFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let folder = directory.appendingPathComponent("Supervox", isDirectory: true)
        let file = folder.appendingPathComponent("settings.json")
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        let store = SettingsStore(file: file)
        try store.save(sampleSettings())
        #expect(try names(in: folder) == ["settings.json"])

        // Une seconde écriture remplace le fichier sans laisser de temporaire.
        try store.save(.defaults)
        #expect(try names(in: folder) == ["settings.json"])
        #expect(store.load().settings == .defaults)
    }

    @Test func corruptFileIsKeptAsideAndDefaultsAreUsed() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let original = Data("{pas du json".utf8)
        try original.write(to: file)
        let store = SettingsStore(file: file, now: fixedClock)

        let result = store.load()
        #expect(result.settings == .defaults)
        let notice = try #require(result.notice)
        #expect(notice.contains(asideStem))

        let aside = directory.appendingPathComponent(asideStem)
        #expect(try Data(contentsOf: aside) == original)
        // Déplacé, pas copié : l'ancien emplacement est libre.
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let saved = sampleSettings()
        try store.save(saved)
        #expect(try Data(contentsOf: aside) == original)
        #expect(store.load().settings == saved)
    }

    @Test func twoCorruptFilesInTheSameInstantKeepDistinctCopies() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file, now: fixedClock)
        let first = Data("{premier".utf8)
        let second = Data("{second".utf8)

        try first.write(to: file)
        let firstNotice = try #require(store.load().notice)
        try second.write(to: file)
        let secondNotice = try #require(store.load().notice)

        #expect(firstNotice != secondNotice)
        let copies = try names(in: directory)
        #expect(copies.count == 2)
        #expect(copies.allSatisfy { $0.hasPrefix(asideStem) })
        let contents = try copies.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
        #expect(Set(contents) == [first, second])
    }

    /// Un fichier d'une version future est lu avec ce que cette version connaît, gardé à sa place, et jamais
    /// écrasé : la version qui l'a écrit le retrouvera intact.
    @Test func newerVersionIsReadAsFarAsPossibleAndNeverOverwritten() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let original = Data(#"{"version": 99, "providers": [], "hotKey": {"keyCode": 40, "modifiers": 768}, "hotKeyBehavior": "toggle", "lastModeID": "mode-du-futur", "moteurDuFutur": "x"}"#.utf8)
        try original.write(to: file)
        let store = SettingsStore(file: file, now: fixedClock)

        let result = store.load()
        #expect(result.settings.lastModeID == "mode-du-futur")
        #expect(result.settings.hotKey == HotKey(keyCode: 40, modifiers: [.command, .shift]))
        // En mémoire, ce sont des réglages de la version courante.
        #expect(result.settings.version == AppSettings.current)
        let notice = try #require(result.notice)
        #expect(notice.contains("99"))
        #expect(notice.contains("plus récente"))
        #expect(notice.contains("rien n'y sera écrit"))
        #expect(try names(in: directory) == ["settings.json"])

        #expect(throws: SettingsError.newerVersionKept(fileName: "settings.json", version: 99)) {
            try store.save(.defaults)
        }
        #expect(try Data(contentsOf: file) == original)
        #expect(try names(in: directory) == ["settings.json"])
    }

    /// Même une version future que cette application ne sait pas lire n'est ni déplacée ni écrasée.
    @Test func unreadableNewerVersionIsNeitherMovedNorOverwritten() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let original = Data(#"{"version": 3, "providers": "une autre forme"}"#.utf8)
        try original.write(to: file)
        let store = SettingsStore(file: file, now: fixedClock)

        let result = store.load()
        #expect(result.settings == .defaults)
        let notice = try #require(result.notice)
        #expect(notice.contains("plus récente"))
        #expect(try names(in: directory) == ["settings.json"])
        #expect(throws: SettingsError.newerVersionKept(fileName: "settings.json", version: 3)) {
            try store.save(sampleSettings())
        }
        #expect(try Data(contentsOf: file) == original)
    }

    /// Un fichier de version 1 écrit avant l'ajout d'un champ : le champ absent prend sa valeur par défaut, le
    /// fichier n'est pas mis de côté. Simulé en retirant des champs qui existent aujourd'hui.
    @Test func versionOneFileWithoutALaterFieldReadsWithItsDefault() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let id = UUID()
        try Data(#"""
        {"version": 1, "hotKey": {"keyCode": 40, "modifiers": 768},
         "providers": [{"id": "\#(id.uuidString)", "name": "Local", "baseURL": "http://localhost:1", "kind": "openAICompatible"}]}
        """#.utf8).write(to: file)
        let store = SettingsStore(file: file, now: fixedClock)

        let result = store.load()
        #expect(result.notice == nil)
        #expect(result.settings.hotKey == HotKey(keyCode: 40, modifiers: [.command, .shift]))
        #expect(result.settings.hotKeyBehavior == AppSettings.defaults.hotKeyBehavior)
        #expect(result.settings.lastModeID == AppSettings.defaults.lastModeID)
        #expect(result.settings.providers == [Provider(id: id, name: "Local", baseURL: "http://localhost:1", kind: .openAICompatible, models: [])])
        #expect(try names(in: directory) == ["settings.json"])
        // Et l'application peut l'enregistrer : il est de sa version.
        try store.save(result.settings)
        #expect(store.load().settings == result.settings)
    }

    /// m-d : un cas d'énumération inconnu à la version courante n'est pas remplacé en silence : tout le fichier est
    /// mis de côté, avec un avis. C'est pourquoi un nouveau cas exige une nouvelle `version` (règle d'`AppSettings`).
    @Test(arguments: [
        #"{"version": 1, "providers": [{"id": "6F9619FF-8B86-D011-B42D-00CF4FC964FF", "name": "x", "baseURL": "http://localhost:1", "kind": "typeDuFutur"}]}"#,
        #"{"version": 1, "hotKeyBehavior": "comportementDuFutur"}"#,
    ])
    func unknownEnumCaseAtTheCurrentVersionSetsTheFileAside(json: String) throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        try Data(json.utf8).write(to: file)
        let store = SettingsStore(file: file, now: fixedClock)

        let result = store.load()
        #expect(result.settings == .defaults)
        let notice = try #require(result.notice)
        #expect(notice.contains("mis de côté"))
        let names = try names(in: directory)
        #expect(!names.contains("settings.json"))
        let aside = try #require(names.first { $0.hasPrefix("settings.json.illisible-") })
        #expect(try Data(contentsOf: directory.appendingPathComponent(aside)) == Data(json.utf8))
    }

    /// Le même cas inconnu dans un fichier d'une version plus récente : fichier gardé intact, réglages par défaut.
    @Test func unknownEnumCaseInANewerFileKeepsItAndUsesDefaults() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let original = Data(#"{"version": 3, "hotKeyBehavior": "comportementDuFutur", "lastModeID": "mode-du-futur"}"#.utf8)
        try original.write(to: file)
        let store = SettingsStore(file: file, now: fixedClock)

        let result = store.load()
        #expect(result.settings == .defaults)
        #expect(result.notice?.contains("plus récente") == true)
        #expect(try names(in: directory) == ["settings.json"])
        #expect(try Data(contentsOf: file) == original)
    }

    /// M7 : un champ inconnu du premier niveau (écrit par une version future qui a gardé le même numéro, ou à la main) est lu,
    /// gardé, et réécrit à l'identique ; le fichier n'est pas mis de côté. Pour un fournisseur, le champ inconnu est perdu :
    /// voir la fin du test.
    @Test func unknownFieldsAreKeptAndWrittenBack() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let id = UUID()
        try Data(#"""
        {"version": 2, "providers": [{"id": "\#(id.uuidString)", "name": "Local", "baseURL": "http://localhost:1",
          "kind": "anthropic", "models": ["m"], "couleur": "bleu"}],
         "hotKey": {"keyCode": 49, "modifiers": 6144}, "hotKeyBehavior": "toggle", "lastModeID": "prompt",
         "langue": "fr", "moteur": {"nom": "x"}}
        """#.utf8).write(to: file)
        let store = SettingsStore(file: file, now: fixedClock)

        let result = store.load()
        #expect(result.notice == nil)
        #expect(result.settings.lastModeID == "prompt")
        #expect(result.settings.providers.map(\.models) == [["m"]])
        #expect(try names(in: directory) == ["settings.json"])

        try store.save(result.settings)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(written["langue"] as? String == "fr")
        #expect((written["moteur"] as? NSDictionary)?.isEqual(to: ["nom": "x"]) == true)

        // Limite connue, fixée ici pour qu'elle reste visible (I2) : seuls `AppSettings` et `Mode` gardent leurs champs
        // inconnus. Ceux d'un fournisseur (`couleur`), de `HotKey`, de `TranscriptionSettings` et de `ModelChoice` sont perdus
        // à la réécriture ; ajouter un champ à l'un de ces types exige donc d'augmenter `AppSettings.current`, ou d'étendre la
        // garde (`UnknownFields`) à ce type. Si ce test tombe parce que la garde a été étendue, mettre le commentaire de
        // `AppSettings` à jour avec elle.
        let providers = try #require(written["providers"] as? [[String: Any]])
        #expect(providers.count == 1)
        #expect(providers[0]["couleur"] == nil)
        #expect(providers[0]["name"] as? String == "Local")
    }

    /// I1 : un moteur que cette version ne connaît pas se lit `whisperkit` (règle 6), et l'enregistrement suivant l'écrit
    /// ainsi, sans avis, dans l'onglet Transcription comme dans chaque mode qui l'avait choisi (où il devient un choix explicite
    /// de WhisperKit). Un nouveau moteur exige donc d'augmenter `AppSettings.current` : à la version suivante, un fichier plus
    /// ancien que l'application qui l'écrit est protégé (gardé intact, non enregistrable) au lieu d'être réécrit. Ce test fixe la
    /// conséquence de ne pas le faire.
    @Test func anUnknownEngineInAVersionTwoFileIsRewrittenAsWhisperKitOnTheNextSave() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        try Data(
            #"""
            {"version": 2, "lastModeID": "dictee-brute", "transcription": {"engine": "moteur-futur", "language": "en"},
             "modes": [{"id": "dictee-brute", "name": "Dictée brute"},
                       {"id": "perso-1", "name": "Courriel", "instruction": "Écris.", "engine": "moteur-futur"},
                       {"id": "entretien", "name": "Entretien"}]}
            """#.utf8
        ).write(to: file)
        let store = SettingsStore(file: file, now: fixedClock)

        var settings = store.load().settings
        #expect(settings.transcription.engine == .whisperKit)
        #expect(settings.mode("perso-1")?.engine == .whisperKit)
        settings.lastModeID = ModeChip.promptID
        try store.save(settings)

        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect((written["transcription"] as? [String: Any])?["engine"] as? String == "whisperkit")
        #expect((written["transcription"] as? [String: Any])?["language"] as? String == "en")
        let modes = try #require(written["modes"] as? [[String: Any]])
        #expect(modes[1]["engine"] as? String == "whisperkit")
        #expect(modes[0]["engine"] == nil)
    }

    /// m1 : une erreur de lecture (ici un fichier sans droit de lecture) n'est pas un fichier abîmé : il reste à
    /// sa place, intact, les réglages par défaut servent en mémoire, et rien ne l'écrase.
    @Test func readErrorKeepsTheFileInPlaceAndSaysSo() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file, now: fixedClock)
        try store.save(sampleSettings())
        let original = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        let result = store.load()
        #expect(result.settings == .defaults)
        let notice = try #require(result.notice)
        #expect(notice.contains("n'a pas pu être lu"))
        #expect(notice.contains("reste en place"))
        #expect(try names(in: directory) == ["settings.json"])
        #expect(throws: SettingsError.unreadableFileKept(fileName: "settings.json")) {
            try store.save(.defaults)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
    }

    /// m-e : après une mise de côté, le fichier manque, mais ce n'est pas un nouvel utilisateur : pas de premier
    /// lancement tant qu'une copie mise de côté existe.
    @Test func setAsideCopyMeansNoFirstLaunch() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file, now: fixedClock)
        try Data("pas du json".utf8).write(to: file)

        let first = store.load()
        #expect(!first.isFirstLaunch)
        #expect(first.notice?.contains("settings.json.illisible-") == true)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let next = store.load()
        #expect(!next.isFirstLaunch)
        #expect(next.saveRefusal == nil)
    }

    /// R1 : une lecture qui a échoué rend le fichier non enregistrable pour toute la session, même si l'erreur cesse
    /// ensuite ; le magasin le dit dans `SettingsLoad`. Un fichier lisible et un fichier absent restent enregistrables.
    @Test func failedReadMakesTheFileUnsavableForTheSession() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file, now: fixedClock)
        #expect(store.load().saveRefusal == nil)  // absent
        try store.save(sampleSettings())
        #expect(store.load().saveRefusal == nil)  // lisible

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        let result = store.load()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(result.saveRefusal == .unreadableFileKept(fileName: "settings.json"))
    }

    @Test func newerVersionIsUnsavableForTheSession() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        try Data(#"{"version": 7}"#.utf8).write(to: file)
        #expect(SettingsStore(file: file).load().saveRefusal == .newerVersionKept(fileName: "settings.json", version: 7))
    }

    @Test func settingsFileNeverContainsASecretField() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        try SettingsStore(file: file).save(sampleSettings())
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        let keys = allKeys(in: json)

        // Le parcours atteint bien les objets imbriqués dans les tableaux.
        #expect(keys.isSuperset(of: ["providers", "baseURL", "models", "hotKey", "keyCode"]))
        #expect(suspiciousKeys(in: keys).isEmpty)
    }

    @Test func secretKeyFilterFlagsSuspiciousNamesAndSparesLegitimateOnes() {
        let secrets: Set<String> = ["apiKey", "api_key", "accessToken", "clientSecret", "PASSWORD", "key"]
        let legitimate: Set<String> = [
            "keyCode", "hotKey", "hotKeyBehavior", "providers", "baseURL", "models", "lastModeID",
        ]
        #expect(suspiciousKeys(in: secrets.union(legitimate)) == secrets)
        #expect(suspiciousKeys(in: legitimate).isEmpty)
    }

    @Test(arguments: [0, -1])
    func nonPositiveVersionIsTreatedAsUnknownAndKeptAside(version: Int) throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        var old = AppSettings.defaults
        old.version = version
        let original = try JSONEncoder().encode(old)
        try original.write(to: file)
        let store = SettingsStore(file: file, now: fixedClock)

        let result = store.load()
        #expect(result.settings == .defaults)
        let notice = try #require(result.notice)
        #expect(notice.contains("inconnue"))
        #expect(notice.contains(asideStem))
        #expect(try Data(contentsOf: directory.appendingPathComponent(asideStem)) == original)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func failedMoveLeavesTheFileInPlaceAndSaveRefusesToOverwriteIt() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let original = Data("{pas du json".utf8)
        try original.write(to: file)
        struct MoveFailure: Error {}
        let store = SettingsStore(file: file, now: fixedClock, moveItem: { _, _ in throw MoveFailure() })

        let result = store.load()
        #expect(result.settings == .defaults)
        let notice = try #require(result.notice)
        #expect(notice.contains("reste en place"))
        #expect(notice.contains("settings.json"))

        #expect(throws: SettingsError.unreadableFileKept(fileName: "settings.json")) {
            try store.save(sampleSettings())
        }
        #expect(try Data(contentsOf: file) == original)
        #expect(try names(in: directory) == ["settings.json"])
    }

    @Test func saveRefusesToOverwriteAnUnreadableOrNewerFileEvenWithoutLoading() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file)
        var future = AppSettings.defaults
        future.version = 99
        let cases: [(Data, SettingsError)] = [
            (Data("{pas du json".utf8), .unreadableFileKept(fileName: "settings.json")),
            (try JSONEncoder().encode(future), .newerVersionKept(fileName: "settings.json", version: 99)),
        ]

        for (original, refusal) in cases {
            try original.write(to: file)
            #expect(throws: refusal) {
                try store.save(sampleSettings())
            }
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func unreadableFileErrorNamesTheFileWithoutItsFolder() {
        let message = SettingsError.unreadableFileKept(fileName: "settings.json").localizedDescription
        #expect(message.contains("settings.json"))
        #expect(!message.contains("/"))
        let newer = SettingsError.newerVersionKept(fileName: "settings.json", version: 7).localizedDescription
        #expect(newer.contains("settings.json") && newer.contains("7") && newer.contains("plus récente"))
        #expect(!newer.contains("/"))
    }

    @Test func defaultFileIsInApplicationSupport() throws {
        let file = try SettingsStore.defaultFile()
        #expect(file.pathComponents.suffix(3) == ["Application Support", "Supervox", "settings.json"])
    }

    // MARK: - Migration : un fichier de l'étape 4 (version 1, `modeOptions`)

    /// Un fichier au format de l'étape 4, tous champs remplis. PAS tapé à la main : produit par l'encodeur de l'étape 4
    /// (`SettingsStore.save` d'un `AppSettings` de l'étape 4 construit avec chacun de ces champs), avant la modification
    /// d'`AppSettings`, et collé tel quel (y compris l'entrée `mode-inconnu`, que l'encodeur produit aussi).
    private static let stepFourFile = #"""
    {
      "hotKey" : {
        "keyCode" : 49,
        "modifiers" : 6144
      },
      "hotKeyBehavior" : "hold",
      "lastModeID" : "prompt",
      "modeOptions" : {
        "dictee-brute" : {
          "reviewBeforePaste" : true
        },
        "entretien" : {
          "reviewBeforePaste" : false
        },
        "mode-inconnu" : {
          "reviewBeforePaste" : true
        },
        "prompt" : {
          "reviewBeforePaste" : false
        }
      },
      "providers" : [
        {
          "baseURL" : "https:\/\/api.example.com\/v1",
          "id" : "00000000-0000-0000-0000-0000000000A1",
          "kind" : "openAICompatible",
          "models" : [
            "modele-exemple",
            "modele-b"
          ],
          "name" : "Exemple"
        }
      ],
      "systemConflictShown" : {
        "keyCode" : 40,
        "modifiers" : 768
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
      "version" : 1
    }
    """#

    /// Ce que la migration doit rendre : les quatre modes de base, avec le choix de relecture repris de `modeOptions` (`true`
    /// pour Dictée brute, rien pour Dictée nettoyée, `false` pour Prompt, `false` gardé pour Entretien sans effet).
    private static var migratedModes: [Mode] {
        var modes = Mode.base
        modes[0].reviewBeforePaste = true
        modes[2].reviewBeforePaste = false
        modes[3].reviewBeforePaste = false
        return modes
    }

    private static let providerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    @Test func aStepFourFileIsMigratedToTheBaseModesWithTheChoicesTaken() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(Self.stepFourFile.utf8))
        #expect(decoded.providers == [
            Provider(
                id: Self.providerID, name: "Exemple", baseURL: "https://api.example.com/v1", kind: .openAICompatible,
                models: ["modele-exemple", "modele-b"])
        ])
        #expect(decoded.hotKey == .standard)
        #expect(decoded.hotKeyBehavior == .hold)
        #expect(decoded.lastModeID == "prompt")
        #expect(decoded.systemConflictShown == HotKey(keyCode: 40, modifiers: [.command, .shift]))
        #expect(decoded.transcription == TranscriptionSettings(
            engine: .parakeet, whisperModel: "small", language: "en", vocabulary: ["Kubernetes", "Docker"]))
        #expect(decoded.modes == Self.migratedModes)
        #expect(decoded.modes.map(\.reviewBeforePaste) == [true, nil, false, false])
        #expect(decoded.reviewsBeforePaste(ModeChip.rawID))
        #expect(!decoded.reviewsBeforePaste(ModeChip.cleanedID))
        #expect(!decoded.reviewsBeforePaste(ModeChip.promptID))
        // Entretien : `false` est gardé dans le mode, sans effet.
        #expect(decoded.reviewsBeforePaste(ModeChip.interviewID))
        #expect(decoded.strongModel == nil)
        #expect(decoded.fastModel == nil)
    }

    @Test func theStoreReadsAStepFourFileWithoutANoticeOrASetAsideCopy() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        try Data(Self.stepFourFile.utf8).write(to: file)

        let result = SettingsStore(file: file, now: fixedClock).load()
        #expect(result.notice == nil)
        #expect(result.saveRefusal == nil)
        #expect(!result.isFirstLaunch)
        #expect(result.settings.modes == Self.migratedModes)
        #expect(result.settings.transcription.engine == .parakeet)
        #expect(result.settings.providers.map(\.name) == ["Exemple"])
        #expect(result.settings.version == AppSettings.current)
        #expect(result.settings.strongModel == nil)
        #expect(result.settings.fastModel == nil)
        #expect(try names(in: directory) == ["settings.json"])
        #expect(try Data(contentsOf: file) == Data(Self.stepFourFile.utf8))
    }

    /// Enregistré puis relu : égal ; et le JSON écrit est en version 2, garde toutes les clés d'origine avec leurs valeurs
    /// (`modeOptions` compris, avec son entrée `mode-inconnu`) et ajoute `modes`.
    @Test func aStepFourFileSurvivesASaveWithAllItsKeysAndValues() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file, now: fixedClock)
        try Data(Self.stepFourFile.utf8).write(to: file)

        let loaded = store.load().settings
        try store.save(loaded)
        let reloaded = store.load()
        #expect(reloaded.settings == loaded)
        #expect(reloaded.notice == nil)
        #expect(try names(in: directory) == ["settings.json"])

        let original = try #require(
            try JSONSerialization.jsonObject(with: Data(Self.stepFourFile.utf8)) as? [String: Any])
        var written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(written["version"] as? Int == 2)
        let modes = try #require(written["modes"] as? [[String: Any]])
        #expect(modes.compactMap { $0["id"] as? String } == ModeChip.fixed.map(\.id))
        written["modes"] = nil
        written["version"] = nil
        var expected = original
        expected["version"] = nil
        #expect(Set(written.keys) == Set(expected.keys))
        #expect((written as NSDictionary).isEqual(to: expected), "\(written) \(expected)")
        let modeOptions = try #require(written["modeOptions"] as? [String: Any])
        #expect(Set(modeOptions.keys) == ["dictee-brute", "entretien", "mode-inconnu", "prompt"])
    }

    /// Le `modeOptions` d'origine reste dans le fichier pour toujours : il ne sert qu'une fois. Un choix fait depuis ne doit pas
    /// être défait, au chargement suivant, par ce reste.
    @Test func aChoiceMadeAfterTheMigrationIsNotUndoneByTheLeftoverModeOptions() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file, now: fixedClock)
        try Data(Self.stepFourFile.utf8).write(to: file)

        var settings = store.load().settings
        #expect(settings.reviewsBeforePaste(ModeChip.rawID))
        let index = try #require(settings.modes.firstIndex { $0.id == ModeChip.rawID })
        settings.modes[index].reviewBeforePaste = false
        try store.save(settings)

        let reloaded = store.load().settings
        #expect(!reloaded.reviewsBeforePaste(ModeChip.rawID))
        #expect(reloaded.mode(ModeChip.rawID)?.reviewBeforePaste == false)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let leftover = try #require(written["modeOptions"] as? [String: [String: Bool]])
        #expect(leftover["dictee-brute"] == ["reviewBeforePaste": true])
    }

    @Test func savingStampsTheCurrentVersionOnAnOlderSettingsValue() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        var older = AppSettings.defaults
        older.version = 1
        try SettingsStore(file: file).save(older)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(written["version"] as? Int == AppSettings.current)
    }

    // MARK: - Champs inconnus gardés et réécrits (M7, m6)

    /// Un fichier de la version courante avec des champs inconnus de toute forme, au premier niveau et dans un mode.
    private static let futureFields = #"""
    {"version": 2,
     "hotKey": {"keyCode": 49, "modifiers": 6144}, "hotKeyBehavior": "toggle", "lastModeID": "dictee-brute",
     "futur-objet": {"a": [1, {"b": null}], "c": "d"}, "futur-tableau": [1, "deux", false, null],
     "futur-nombre": 2.5, "futur-entier": 6144, "futur-booleen": true, "futur-faux": false, "futur-nul": null,
     "modes": [
       {"id": "dictee-brute", "name": "Dictée brute", "futur-objet": {"x": [1, 2]}, "futur-tableau": ["a", true],
        "futur-nombre": -0.5, "futur-booleen": true, "futur-nul": null},
       {"id": "perso-1", "name": "Courriel", "instruction": "Écris.", "futur-texte": "t", "futur-faux": false},
       {"id": "entretien", "name": "Entretien"}]}
    """#

    /// Une modification quelconque (`lastModeID`) réécrit tout ce que cette version ne connaît pas, tel quel.
    @Test func unknownFieldsOfTheFileAndOfAModeAreWrittenBackAfterAnyChange() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file, now: fixedClock)
        try Data(Self.futureFields.utf8).write(to: file)

        var settings = store.load().settings
        settings.lastModeID = ModeChip.promptID
        try store.save(settings)

        let original = try #require(
            try JSONSerialization.jsonObject(with: Data(Self.futureFields.utf8)) as? [String: Any])
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(written["lastModeID"] as? String == ModeChip.promptID)
        // Chaque champ inconnu du premier niveau, avec sa valeur.
        for key in original.keys where key.hasPrefix("futur-") {
            #expect((written[key] as? NSObject)?.isEqual(original[key]) == true || (written[key] is NSNull && original[key] is NSNull), "\(key)")
        }
        #expect(written["futur-nul"] is NSNull)
        #expect(written["futur-booleen"] as? Bool == true)
        #expect(written["futur-faux"] as? Bool == false)
        #expect(written["futur-entier"] as? Int == 6144)
        // Et dans les modes.
        let originalModes = try #require(original["modes"] as? [[String: Any]])
        let writtenModes = try #require(written["modes"] as? [[String: Any]])
        #expect(writtenModes.count == originalModes.count)
        #expect((writtenModes as NSArray).isEqual(to: originalModes), "\(writtenModes) \(originalModes)")
        #expect(writtenModes[0]["futur-nul"] is NSNull)
        // Un second tour ne change plus rien.
        let again = store.load().settings
        #expect(again == settings)
    }

    // MARK: - Version (règle 3)

    @Test func aVersionTwoFileWithoutModesReadsWithTheBaseModes() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        try Data(#"{"version": 2, "lastModeID": "prompt"}"#.utf8).write(to: file)

        let result = SettingsStore(file: file, now: fixedClock).load()
        #expect(result.notice == nil)
        #expect(result.saveRefusal == nil)
        #expect(result.settings.modes == Mode.base)
        #expect(result.settings.lastModeID == "prompt")
        #expect(try names(in: directory) == ["settings.json"])
    }

    /// Un fichier en version 3 : lu autant que possible, gardé intact et non enregistrable.
    @Test func aVersionThreeFileStaysIntactAndUnsavable() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let original = Data(#"{"version": 3, "lastModeID": "prompt", "modes": [{"id": "dictee-brute", "name": "B", "futur": 1}]}"#.utf8)
        try original.write(to: file)
        let store = SettingsStore(file: file, now: fixedClock)

        let result = store.load()
        #expect(result.saveRefusal == .newerVersionKept(fileName: "settings.json", version: 3))
        #expect(result.notice?.contains("plus récente") == true)
        #expect(result.settings.lastModeID == "prompt")
        #expect(result.settings.version == AppSettings.current)
        #expect(throws: SettingsError.newerVersionKept(fileName: "settings.json", version: 3)) {
            try store.save(result.settings)
        }
        #expect(try Data(contentsOf: file) == original)
        #expect(try names(in: directory) == ["settings.json"])
    }

    // MARK: - Modes illisibles et modes toujours présents

    /// Un mode sans `name` rend le fichier illisible : politique existante, il est mis de côté, intact.
    @Test func aModeWithoutANameSetsTheFileAside() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let json = #"{"version": 2, "modes": [{"id": "perso-1"}]}"#
        try Data(json.utf8).write(to: file)

        let result = SettingsStore(file: file, now: fixedClock).load()
        #expect(result.settings == .defaults)
        #expect(result.notice?.contains("mis de côté") == true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: directory.appendingPathComponent(asideStem)) == Data(json.utf8))
    }

    @Test func savedModesComeBackWithRawAndInterviewEvenIfTheFileLostThem() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        try Data(#"{"version": 2, "modes": [{"id": "prompt", "name": "Prompt"}]}"#.utf8).write(to: file)
        let result = SettingsStore(file: file, now: fixedClock).load()
        #expect(result.settings.modes.map(\.id) == [ModeChip.rawID, ModeChip.promptID, ModeChip.interviewID])
    }
}
