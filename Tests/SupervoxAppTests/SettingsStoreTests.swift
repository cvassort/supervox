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
        lastModeID: "reformulation")
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
        #expect(defaults.version == 1)
        #expect(AppSettings.current == 1)
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
        let original = Data(#"{"version": 2, "providers": "une autre forme"}"#.utf8)
        try original.write(to: file)
        let store = SettingsStore(file: file, now: fixedClock)

        let result = store.load()
        #expect(result.settings == .defaults)
        let notice = try #require(result.notice)
        #expect(notice.contains("plus récente"))
        #expect(try names(in: directory) == ["settings.json"])
        #expect(throws: SettingsError.newerVersionKept(fileName: "settings.json", version: 2)) {
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

    /// Un champ inconnu (écrit par une version future qui a gardé le même numéro, ou à la main) est ignoré.
    @Test func unknownFieldsAreIgnoredAndTheFileIsKept() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        let id = UUID()
        try Data(#"""
        {"version": 1, "providers": [{"id": "\#(id.uuidString)", "name": "Local", "baseURL": "http://localhost:1",
          "kind": "anthropic", "models": ["m"], "couleur": "bleu"}],
         "hotKey": {"keyCode": 49, "modifiers": 6144}, "hotKeyBehavior": "toggle", "lastModeID": "prompt",
         "langue": "fr", "moteur": {"nom": "x"}}
        """#.utf8).write(to: file)

        let result = SettingsStore(file: file, now: fixedClock).load()
        #expect(result.notice == nil)
        #expect(result.settings.lastModeID == "prompt")
        #expect(result.settings.providers.map(\.models) == [["m"]])
        #expect(try names(in: directory) == ["settings.json"])
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
}
