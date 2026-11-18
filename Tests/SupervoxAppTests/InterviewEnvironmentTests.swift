import Testing

@testable import SupervoxApp

/// `InterviewEnvironment.effectiveTurnSilence` : ce que l'onglet Entretien affiche du silence « en pratique ». `SupervoxApp` ne
/// connaît pas le détecteur de voix : la fonction lui vient de l'environnement, et l'identité tient lieu de repli.
@Suite(.timeLimit(.minutes(1))) struct InterviewEnvironmentTests {
    /// Sans entretien branché, le silence en pratique est le silence demandé, sur toute la plage de l'interface.
    @Test func theUnavailableEnvironmentGivesTheRequestedSilenceBack() {
        for requested in [0.3, 0.5, 0.7, 1.4, 2.0] {
            #expect(InterviewEnvironment.unavailable.effectiveTurnSilence(requested) == requested)
        }
    }

    /// Un environnement construit sans le dire garde l'identité (les appelants existants compilent sans changement) ; celui qui la
    /// donne garde sa fonction.
    @Test func theInitializerKeepsTheGivenFunctionAndDefaultsToTheIdentity() {
        let voice = InterviewEnvironment.unavailable.makeVoice
        let plain = InterviewEnvironment(
            prepare: { _ in }, makeConversation: { _ in throw InterviewEnvironment.Unavailable() }, makeVoice: voice)
        #expect(plain.effectiveTurnSilence(0.7) == 0.7)
        let doubled = InterviewEnvironment(
            prepare: { _ in }, makeConversation: { _ in throw InterviewEnvironment.Unavailable() }, makeVoice: voice,
            effectiveTurnSilence: { $0 * 2 })
        #expect(doubled.effectiveTurnSilence(0.7) == 1.4)
    }
}
