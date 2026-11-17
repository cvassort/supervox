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
        #expect(ModeRun.from(Mode(id: ModeChip.promptID, name: "Prompt")) == .rewrite(
            instruction: try #require(ModeDefaults.instruction(for: ModeChip.promptID)), model: nil, engine: nil))
    }

    @Test("le mode Entretien lance l'entretien avec son moteur, quelle que soit sa consigne ; un mode absent ne démarre rien")
    func theInterviewLaunchesTheInterviewAndAnAbsentModeStartsNothing() {
        #expect(ModeRun.from(Mode(id: ModeChip.interviewID, name: "Entretien")) == .interview(engine: nil))
        #expect(ModeRun.from(Mode(id: ModeChip.interviewID, name: "Entretien", instruction: "Fais ceci.")) == .interview(engine: nil))
        #expect(ModeRun.from(Mode(id: ModeChip.interviewID, name: "Entretien", engine: .whisperKit)) == .interview(engine: .whisperKit))
        #expect(ModeRun.interview(engine: .whisperKit).engine == .whisperKit)
        #expect(ModeRun.from(nil) == .missing)
        #expect(ModeRun.missing.engine == nil)
    }

    @Test("le défaut sans réglages : la dictée brute dicte, l'entretien se lance, tout autre mode ne démarre rien")
    func theLegacyDefault() {
        #expect(ModeRun.legacy(ModeChip.rawID) == .raw(engine: nil))
        #expect(ModeRun.legacy(ModeChip.interviewID) == .interview(engine: nil))
        for id in [ModeChip.cleanedID, ModeChip.promptID, "perso-un"] {
            #expect(ModeRun.legacy(id) == .missing)
        }
    }
}
