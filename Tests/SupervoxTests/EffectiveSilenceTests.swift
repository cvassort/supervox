import SupervoxEngines
import Testing

/// Le silence que le détecteur de voix demande réellement, pour l'affichage de l'onglet Entretien. La règle vient du code de
/// FluidAudio 0.18.3 (`VadManager+Streaming.swift`, `processStreamingChunk`, code lu) : le compte du silence démarre à la FIN du
/// premier bloc silencieux, et la fin de voix tombe au premier bloc où `processedSamples - silenceStart >= Int(minSilence × 16 000)`.
/// Aucun modèle n'est chargé : ces tests ne touchent que la formule.
@Suite(.timeLimit(.minutes(1))) struct EffectiveSilenceTests {
    /// La règle de la bibliothèque rejouée bloc par bloc, par un chemin indépendant de la formule fermée de `effectiveSilence` :
    /// on avance d'un bloc silencieux à la fois jusqu'à ce que la condition de la bibliothèque soit vraie.
    static func replayed(_ minSilence: Double) -> Double {
        let block = 4096  // `VadManager.chunkSize`, code lu
        let rate = 16000  // `VadManager.sampleRate`, code lu
        let needed = Int(minSilence * Double(rate))
        var processed = 0
        var silenceStart: Int?
        var blocks = 0
        while true {
            processed += block
            blocks += 1
            if silenceStart == nil { silenceStart = processed }
            if let start = silenceStart, processed - start >= needed { break }
        }
        return Double(blocks * block) / Double(rate)
    }

    /// Règle 3 : 0,6 s et 0,7 s demandées donnent la même valeur en pratique, 1,024 s (quatre blocs de 0,256 s).
    @Test func sixAndSevenTenthsBothGiveFourBlocks() {
        #expect(FluidStreamingVoiceDetector.effectiveSilence(0.6) == 1.024)
        #expect(FluidStreamingVoiceDetector.effectiveSilence(0.7) == 1.024)
    }

    /// Amendement : de 0,30 s à 0,51 s demandées, la valeur en pratique est la même (trois blocs, 0,768 s) ; au-delà de 0,512 s,
    /// elle passe à quatre blocs. Le défaut de l'application (0,5 s) est dans le premier palier.
    @Test func theFirstStepSpansThreeTenthsToJustOverFiveTenths() {
        for requested in [0.3, 0.4, 0.5, 0.51] {
            #expect(FluidStreamingVoiceDetector.effectiveSilence(requested) == 0.768, "\(requested) s demandées")
        }
        #expect(FluidStreamingVoiceDetector.effectiveSilence(0.52) == 1.024)
    }

    /// La formule fermée suit la règle de la bibliothèque rejouée bloc par bloc, sur toute la plage de l'interface (0,3 à 2,0 s par
    /// pas de 0,1 s) et sur les bords des paliers.
    @Test func theClosedFormulaFollowsTheLibraryRuleReplayedBlockByBlock() {
        var requested: [Double] = (3...20).map { Double($0) / 10 }
        requested += [0.512, 0.513, 0.768, 0.769, 1.024, 1.025]
        for value in requested {
            #expect(
                FluidStreamingVoiceDetector.effectiveSilence(value) == Self.replayed(value),
                "\(value) s demandées")
        }
    }

    /// La valeur en pratique n'est jamais plus courte que la demande, et ne baisse jamais quand la demande monte.
    @Test func theEffectiveSilenceNeverFallsBelowTheRequestAndNeverDecreases() {
        var previous = 0.0
        for tenths in 3...20 {
            let requested = Double(tenths) / 10
            let effective = FluidStreamingVoiceDetector.effectiveSilence(requested)
            #expect(effective >= requested)
            #expect(effective >= previous)
            previous = effective
        }
    }
    /// Une valeur qui n'est pas un silence (NaN, négative, infinie, énorme) ne fait pas planter la fonction publique : NaN et le négatif
    /// comptent comme zéro (un seul bloc), l'infini et l'énorme sont plafonnés. Avant, `Int(...)` piégeait.
    @Test func aValueThatIsNotASilenceNeitherCrashesNorExceedsTheCap() {
        let oneBlock = FluidStreamingVoiceDetector.effectiveSilence(0)
        #expect(oneBlock == 0.256)
        #expect(FluidStreamingVoiceDetector.effectiveSilence(.nan) == oneBlock)
        #expect(FluidStreamingVoiceDetector.effectiveSilence(-1) == oneBlock)
        #expect(FluidStreamingVoiceDetector.effectiveSilence(-.infinity) == oneBlock)
        let capped = FluidStreamingVoiceDetector.effectiveSilence(FluidStreamingVoiceDetector.silenceCap)
        #expect(capped >= FluidStreamingVoiceDetector.silenceCap)
        #expect(FluidStreamingVoiceDetector.effectiveSilence(.infinity) == capped)
        #expect(FluidStreamingVoiceDetector.effectiveSilence(1e300) == capped)
    }
}
