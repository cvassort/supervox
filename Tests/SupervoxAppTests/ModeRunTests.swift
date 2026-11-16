import Foundation
import SupervoxCore
import Testing

@testable import SupervoxApp

@Suite struct ModeRunTests {
    @Test func rawDictationAndAPersonalModeWithoutAnInstructionDictateWithoutTheModel() {
        #expect(ModeRun.from(Mode(id: ModeChip.rawID, name: "Dictée brute")) == .raw(engine: nil))
        #expect(ModeRun.from(Mode(id: "perso-un", name: "Brut", instruction: "")) == .raw(engine: nil))
        #expect(ModeRun.from(Mode(id: "perso-un", name: "Brut", instruction: " \n ")) == .raw(engine: nil))
    }

    @Test func aModesEngineIsCarriedWithItsRun() {
        #expect(ModeRun.from(Mode(id: ModeChip.rawID, name: "Dictée brute", engine: .parakeet)) == .raw(engine: .parakeet))
        let model = ModelChoice(providerID: UUID(), model: "modele-exemple")
        let mode = Mode(id: "perso-un", name: "Résumé", instruction: "Résume.", model: model, engine: .parakeet)
        #expect(ModeRun.from(mode) == .rewrite(instruction: "Résume.", model: model, engine: .parakeet))
    }

    @Test func aBaseModeWithoutAnInstructionUsesItsOriginalOne() throws {
        let cleaned = Mode(id: ModeChip.cleanedID, name: "Dictée nettoyée")
        let origin = try #require(ModeDefaults.instruction(for: ModeChip.cleanedID))
        #expect(ModeRun.from(cleaned) == .rewrite(instruction: origin, model: nil, engine: nil))
        #expect(ModeRun.from(Mode(id: ModeChip.promptID, name: "Prompt")) != .later)
    }

    @Test func theInterviewAndAnAbsentModeDoNotDictateYet() {
        #expect(ModeRun.from(Mode(id: ModeChip.interviewID, name: "Entretien")) == .later)
        #expect(ModeRun.from(Mode(id: ModeChip.interviewID, name: "Entretien", instruction: "Fais ceci.")) == .later)
        #expect(ModeRun.from(nil) == .later)
    }

    @Test func theLegacyDefaultKeepsStepFourBehaviour() {
        #expect(ModeRun.legacy(ModeChip.rawID) == .raw(engine: nil))
        for id in [ModeChip.cleanedID, ModeChip.promptID, ModeChip.interviewID, "perso-un"] {
            #expect(ModeRun.legacy(id) == .later)
        }
    }
}
