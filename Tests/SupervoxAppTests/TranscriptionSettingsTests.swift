import Foundation
import Testing

@testable import SupervoxApp

/// Les réglages de transcription dans `settings.json` : défauts, décodage tolérant, moteur inconnu.
@Suite struct TranscriptionSettingsTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervox-transcription-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    /// La variante mesurée à l'étape 1 (`docs/bench/2026-11-13-resultats.md`, `TranscribeCommand.swift`).
    @Test func defaultsAreTheMeasuredWhisperVariantInFrench() {
        let defaults = TranscriptionSettings.defaults
        #expect(defaults.engine == .whisperKit)
        #expect(defaults.whisperModel == "large-v3-v20240930_turbo")
        #expect(defaults.language == "fr")
        #expect(defaults.vocabulary == [])
        #expect(AppSettings.defaults.transcription == defaults)
    }

    @Test func aSettingsFileWithoutTranscriptionReadsTheDefaultsAndIsNotSetAside() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try Data(#"{"version":1,"lastModeID":"prompt"}"#.utf8).write(to: file)

        let load = SettingsStore(file: file).load()

        #expect(load.settings.transcription == .defaults)
        #expect(load.settings.lastModeID == "prompt")
        #expect(load.notice == nil)
        #expect(load.saveRefusal == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["settings.json"])
    }

    @Test func anUnknownEngineReadsAsWhisperKit() throws {
        let settings = try decode(#"{"version":1,"transcription":{"engine":"moteur-futur","language":"en"}}"#)
        #expect(settings.transcription.engine == .whisperKit)
        // Le reste du bloc est repris tel quel.
        #expect(settings.transcription.language == "en")
    }

    /// m11 : le moteur est un type, pas une chaîne ; ses deux valeurs s'écrivent comme à l'étape 4.
    @Test func theEngineKeepsItsFileSpellingAndItsTitle() throws {
        #expect(TranscriptionEngine.allCases == [.whisperKit, .parakeet])
        #expect(TranscriptionEngine.whisperKit.rawValue == "whisperkit")
        #expect(TranscriptionEngine.parakeet.rawValue == "parakeet")
        #expect(TranscriptionEngine.whisperKit.title == "WhisperKit")
        #expect(TranscriptionEngine.parakeet.title == "Parakeet")
        for engine in TranscriptionEngine.allCases {
            let written = try JSONEncoder().encode(TranscriptionSettings(
                engine: engine, whisperModel: "small", language: "fr", vocabulary: []))
            let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
            #expect(object["engine"] as? String == engine.rawValue)
            #expect(try JSONDecoder().decode(TranscriptionSettings.self, from: written).engine == engine)
        }
    }

    @Test(arguments: ["whisperkit", "parakeet"])
    func aKnownEngineReadsAndWritesIdentically(name: String) throws {
        let read = try decode(#"{"version":1,"transcription":{"engine":"\#(name)"}}"#)
        let written = try JSONEncoder().encode(read.transcription)
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["engine"] as? String == name)
    }

    /// Une valeur inconnue du moteur se lit `.whisperKit` jusque dans le type lui-même (hors de `TranscriptionSettings`).
    @Test func anUnknownEngineValueReadsAsWhisperKitAtTheTypeLevel() throws {
        #expect(try JSONDecoder().decode(TranscriptionEngine.self, from: Data(#""moteur-futur""#.utf8)) == .whisperKit)
        #expect(try JSONDecoder().decode(TranscriptionEngine.self, from: Data(#""""#.utf8)) == .whisperKit)
    }

    @Test func parakeetIsKept() throws {
        let settings = try decode(#"{"version":1,"transcription":{"engine":"parakeet"}}"#)
        #expect(settings.transcription.engine == .parakeet)
        // Un bloc qui ne dit que le moteur : tout le reste prend ses défauts.
        #expect(settings.transcription.vocabulary == [])
        #expect(settings.transcription.whisperModel == TranscriptionSettings.defaults.whisperModel)
        #expect(settings.transcription.language == "fr")
    }

    @Test func missingTranscriptionFieldsTakeTheirDefaultsAndUnknownOnesAreIgnored() throws {
        let settings = try decode(#"{"version":1,"transcription":{"vocabulary":["Kubernetes"],"autre":1}}"#)
        #expect(settings.transcription.vocabulary == ["Kubernetes"])
        #expect(settings.transcription.engine == .whisperKit)
        #expect(settings.transcription.whisperModel == TranscriptionSettings.defaults.whisperModel)
        #expect(settings.transcription.language == "fr")
    }

    @Test func transcriptionSurvivesASaveAndALoad() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
        var settings = AppSettings.defaults
        settings.transcription = TranscriptionSettings(
            engine: .parakeet, whisperModel: "small", language: "en", vocabulary: ["Docker", "Sentry"])
        try store.save(settings)

        #expect(store.load().settings.transcription == settings.transcription)
    }
}
