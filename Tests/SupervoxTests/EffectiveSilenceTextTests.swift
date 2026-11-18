import Foundation
import SupervoxApp
import SupervoxEngines
import Testing

/// Règle 3 composée : la phrase de l'onglet Entretien avec la VRAIE formule du détecteur (le modèle reçoit la fonction réelle, comme
/// `LiveInterview.environment` la lui donne), et le « 0,256 s » de la phrase relié à la longueur de bloc du détecteur. Aucun modèle
/// de voix n'est chargé.
@MainActor @Suite(.timeLimit(.minutes(1))) struct EffectiveSilenceTextTests {
    private func model(turnSilence: Double) -> InterviewSettingsModel {
        var settings = AppSettings.defaults
        settings.interview.turnSilence = turnSilence
        return InterviewSettingsModel(
            read: { settings }, update: { change in change(&settings) },
            effectiveTurnSilence: { FluidStreamingVoiceDetector.effectiveSilence($0) })
    }

    /// 0,7 s demandée : 1,024 s en pratique, dit « 1,02 » ; 0,6 s dit la même chose ; 0,5 s (le défaut) : 0,768 s, dit « 0,77 ».
    @Test func theSentenceSaysTheRealDetectorsValue() {
        let tail = "\u{00A0}: le détecteur de voix compte par tranches de 0,256 s."
        #expect(model(turnSilence: 0.7).effectiveSilenceText == "0,70 s demandées, 1,02 s en pratique" + tail)
        #expect(model(turnSilence: 0.6).effectiveSilenceText == "0,60 s demandées, 1,02 s en pratique" + tail)
        #expect(model(turnSilence: 0.5).effectiveSilenceText == "0,50 s demandées, 0,77 s en pratique" + tail)
    }

    /// La longueur de bloc que la phrase annonce (0,256 s) est celle du détecteur : un bloc silencieux de plus que zéro seconde
    /// demandée (`effectiveSilence(0)`). Si la bibliothèque changeait de taille de bloc, ce test tomberait au lieu de laisser la
    /// phrase mentir.
    @Test func theBlockLengthInTheSentenceIsTheDetectorsBlockLength() {
        let block = FluidStreamingVoiceDetector.effectiveSilence(0)
        let written = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), block)
            .replacingOccurrences(of: ".", with: ",")
        #expect(written == "0,256")
        #expect(model(turnSilence: 0.7).effectiveSilenceText.contains("tranches de \(written) s."))
    }
}
