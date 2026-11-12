import Foundation
import Testing
@testable import SupervoxCore

@Suite("EndpointConfigTests")
struct EndpointConfigTests {
    @Test func missingKeyFailsBeforeAnyRequest() {
        #expect(throws: EndpointError.missingVariable("SUPERVOX_API_KEY")) {
            try EndpointConfig.fromEnvironment(["SUPERVOX_BASE_URL": "https://exemple.test"])
        }
        #expect(throws: EndpointError.missingVariable("SUPERVOX_BASE_URL")) {
            try EndpointConfig.fromEnvironment(["SUPERVOX_API_KEY": "k"])
        }
    }

    /// Une variable exportée vide (`export SUPERVOX_API_KEY=`) est un oubli, pas une valeur : sans ce refus,
    /// le premier appel partirait avec « Bearer » seul et reviendrait en 401, loin de la cause.
    @Test func emptyOrBlankVariablesCountAsMissing() {
        #expect(throws: EndpointError.missingVariable("SUPERVOX_API_KEY")) {
            try EndpointConfig.fromEnvironment(["SUPERVOX_BASE_URL": "https://exemple.test", "SUPERVOX_API_KEY": ""])
        }
        #expect(throws: EndpointError.missingVariable("SUPERVOX_API_KEY")) {
            try EndpointConfig.fromEnvironment(["SUPERVOX_BASE_URL": "https://exemple.test", "SUPERVOX_API_KEY": " \n"])
        }
        #expect(throws: EndpointError.missingVariable("SUPERVOX_BASE_URL")) {
            try EndpointConfig.fromEnvironment(["SUPERVOX_BASE_URL": "  ", "SUPERVOX_API_KEY": "k"])
        }
    }

    /// Une clé collée avec un retour à la ligne final produirait un en-tête HTTP invalide.
    @Test func surroundingWhitespaceIsTrimmed() throws {
        let cfg = try EndpointConfig.fromEnvironment(["SUPERVOX_BASE_URL": " https://exemple.test/v1\n", "SUPERVOX_API_KEY": "secret-123\n"])
        #expect(cfg.apiKey == "secret-123")
        #expect(cfg.baseURL.absoluteString == "https://exemple.test/v1")
    }

    @Test func errorDescriptionNeverContainsTheKey() throws {
        let cfg = try EndpointConfig.fromEnvironment(["SUPERVOX_BASE_URL": "https://exemple.test", "SUPERVOX_API_KEY": "secret-123"])
        #expect(!String(describing: cfg).contains("secret-123"))
        #expect(String(describing: cfg).contains("https://exemple.test"))
    }

    /// `String(reflecting:)` (affichage des échecs de test) et `dump` passent par le miroir, pas par `description`.
    @Test func reflectionNeverContainsTheKey() throws {
        let cfg = try EndpointConfig.fromEnvironment(["SUPERVOX_BASE_URL": "https://exemple.test", "SUPERVOX_API_KEY": "secret-123"])
        #expect(!String(reflecting: cfg).contains("secret-123"))
        var dumped = ""
        dump(cfg, to: &dumped)
        #expect(!dumped.contains("secret-123"))
        #expect(dumped.contains("https://exemple.test"))
    }
}
