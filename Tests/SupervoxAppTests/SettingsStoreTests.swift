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
        #expect(result == SettingsLoad(settings: .defaults, notice: nil))
        #expect(try names(in: directory).isEmpty)
    }

    @Test func defaultsMatchTheSpecification() {
        let defaults = AppSettings.defaults
        #expect(defaults.version == 1)
        #expect(AppSettings.current == 1)
        #expect(defaults.providers.isEmpty)
        #expect(defaults.hotKey == HotKey(keyCode: 49, modifiers: [.control, .option]))
        #expect(defaults.hotKey == .standard)
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

    @Test func saveIsAtomicAndCreatesTheFolder() throws {
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

    @Test func newerVersionIsNotOverwritten() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeTemporaryDirectory(directory) }
        let file = directory.appendingPathComponent("settings.json")
        // Un fichier de forme lisible mais d'une version future : il ne doit pas être repris tel quel.
        var future = AppSettings.defaults
        future.version = 99
        future.lastModeID = "mode-du-futur"
        let original = try JSONEncoder().encode(future)
        try original.write(to: file)
        let store = SettingsStore(file: file, now: fixedClock)

        let result = store.load()
        #expect(result.settings == .defaults)
        let notice = try #require(result.notice)
        #expect(notice.contains("99"))
        #expect(notice.contains("inconnue"))
        #expect(notice.contains(asideStem))

        let aside = directory.appendingPathComponent(asideStem)
        #expect(try Data(contentsOf: aside) == original)

        try store.save(.defaults)
        #expect(try Data(contentsOf: aside) == original)
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
        let forbidden: Set<String> = ["key", "apikey", "secret", "token"]
        #expect(keys.filter { forbidden.contains($0.lowercased()) }.isEmpty)
    }

    @Test func defaultFileIsInApplicationSupport() throws {
        let file = try SettingsStore.defaultFile()
        #expect(file.pathComponents.suffix(3) == ["Application Support", "Supervox", "settings.json"])
    }
}
