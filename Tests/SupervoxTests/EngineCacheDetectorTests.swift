import Foundation
import Synchronization
import SupervoxApp
import SupervoxCore
import SupervoxEngines
import Testing

@testable import Supervox

/// Le détecteur de voix de l'entretien dans `EngineCache` : une seule case, reconstruite quand le silence minimal change, vidée
/// quand le modèle du détecteur est supprimé ; celui de la dictée n'est jamais touché. Aucun moteur réel n'est chargé : la
/// fabrique est un double qui note chaque demande et ne garde de ses détecteurs que des références faibles.
@Suite(.timeLimit(.minutes(1))) struct EngineCacheDetectorTests {
    /// Les demandes faites à la fabrique, dans l'ordre, et les détecteurs rendus (références faibles : « lâché » se vérifie).
    final class Ledger: Sendable {
        private final class WeakDetector {
            weak var value: DoubleDetector?
        }
        private let state = Mutex<(requests: [Double], made: [WeakDetector])>(([], []))

        var requests: [Double] { state.withLock { $0.requests } }
        var madeCount: Int { state.withLock { $0.made.count } }

        /// Le détecteur rendu à la demande numéro `index` (0 pour la construction du cache), s'il vit encore.
        func isAlive(_ index: Int) -> Bool { state.withLock { $0.made.indices.contains(index) && $0.made[index].value != nil } }

        func make(_ minSilence: Double) -> DoubleDetector {
            let detector = DoubleDetector()
            let weak = WeakDetector()
            weak.value = detector
            state.withLock {
                $0.requests.append(minSilence)
                $0.made.append(weak)
            }
            return detector
        }
    }

    private static func cache(_ ledger: Ledger) -> EngineCache {
        let engines = DoubleEngines()
        let factory = EngineFactory(
            parakeet: { engines.parakeet }, detector: { ledger.make($0) }, whisper: { model, _ in engines.whisper(model) },
            whisperLoadsOffline: { _, _ in true }, setOffline: { _ in })
        return EngineCache(modelsRoot: URL(fileURLWithPath: "/tmp/supervox-test-modeles"), factory: factory)
    }

    private static let settings = TranscriptionSettings(engine: .parakeet, whisperModel: "small", language: "fr", vocabulary: [])

    @Test("le détecteur de la dictée est construit au silence d'avant l'entretien (0,6 s) et servi tel quel")
    func theDictationDetectorKeepsItsSilence() {
        let ledger = Ledger()
        let cache = Self.cache(ledger)

        let detector = cache.engines(for: Self.settings).detector

        #expect(ledger.requests == [EngineCache.dictationMinSilence])
        #expect(EngineCache.dictationMinSilence == 0.6)
        #expect((detector as AnyObject) === (cache.engines(for: Self.settings).detector as AnyObject))
    }

    @Test("la même valeur rend le même exemplaire, sans nouvelle fabrication")
    func theSameValueGivesTheSameDetector() {
        let ledger = Ledger()
        let cache = Self.cache(ledger)

        let first = cache.detector(minSilence: 0.8)
        let second = cache.detector(minSilence: 0.8)

        #expect((first as AnyObject) === (second as AnyObject))
        #expect(ledger.requests == [EngineCache.dictationMinSilence, 0.8])
    }

    @Test("une valeur changée donne un nouvel exemplaire, et l'ancien est lâché ; revenir à l'ancienne valeur en refabrique un")
    func aChangedValueReplacesTheDetectorAndReleasesTheOldOne() {
        let ledger = Ledger()
        let cache = Self.cache(ledger)
        var first: (any LoadableDetector)? = cache.detector(minSilence: 0.8)
        #expect(ledger.isAlive(1))

        var second: (any LoadableDetector)? = cache.detector(minSilence: 1.1)
        #expect((first as AnyObject?) !== (second as AnyObject?), "un exemplaire neuf")
        first = nil
        #expect(!ledger.isAlive(1), "l'ancien exemplaire n'est plus tenu par le cache")
        #expect(ledger.isAlive(2))

        let third = cache.detector(minSilence: 0.8)
        #expect((third as AnyObject) !== (second as AnyObject?))
        second = nil
        #expect(ledger.requests == [EngineCache.dictationMinSilence, 0.8, 1.1, 0.8], "une seule case, jamais une par valeur")
        #expect(!ledger.isAlive(2), "la valeur 1,1 n'est pas gardée à côté de 0,8")
    }

    @Test("supprimer le modèle du détecteur vide la case de l'entretien, et le détecteur suivant est neuf")
    func evictingTheVoiceDetectorModelEmptiesTheInterviewCase() {
        let ledger = Ledger()
        let cache = Self.cache(ledger)
        _ = cache.detector(minSilence: 0.8)
        #expect(ledger.isAlive(1), "le cache tient le détecteur de l'entretien")

        cache.evict(modelID: LocalModelID.voiceDetector)

        #expect(!ledger.isAlive(1), "la case est vidée par l'éviction, avant toute nouvelle demande")
        _ = cache.detector(minSilence: 0.8)
        #expect(ledger.requests.last == 0.8)
        #expect(ledger.madeCount == 4, "construction du cache, entretien, dictée refaite à l'éviction, entretien refait")
    }

    @Test("supprimer un autre modèle laisse le détecteur de l'entretien")
    func evictingAnotherModelKeepsTheInterviewDetector() {
        let ledger = Ledger()
        let cache = Self.cache(ledger)
        let before = cache.detector(minSilence: 0.8)

        cache.evict(modelID: LocalModelID.parakeet)
        cache.evict(modelID: LocalModelID.whisper("small"))

        #expect((cache.detector(minSilence: 0.8) as AnyObject) === (before as AnyObject))
    }

    @Test("l'entretien ne touche jamais au détecteur de la dictée, même à la même valeur de silence")
    func theInterviewNeverTouchesTheDictationDetector() {
        let ledger = Ledger()
        let cache = Self.cache(ledger)
        let dictation = cache.engines(for: Self.settings).detector

        let sameValue = cache.detector(minSilence: EngineCache.dictationMinSilence)
        _ = cache.detector(minSilence: 0.4)
        _ = cache.detector(minSilence: 1.5)

        #expect((cache.engines(for: Self.settings).detector as AnyObject) === (dictation as AnyObject))
        #expect((sameValue as AnyObject) !== (dictation as AnyObject), "deux cases, même à valeur égale")
        #expect(ledger.isAlive(0))
    }

    @Test("la fabrique réelle transmet le silence minimal, et celui de la dictée est le défaut d'avant (0,6 s)")
    func theRealFactoryForwardsTheSilence() async {
        let made = EngineFactory.real.detector(1.25)
        #expect((made as? FluidStreamingVoiceDetector) != nil)
        #expect(await (made as? FluidStreamingVoiceDetector)?.minSilence == 1.25)
        #expect(await FluidStreamingVoiceDetector().minSilence == EngineCache.dictationMinSilence)
    }
}
