import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxApp

/// La règle du vocabulaire, une seule pour la dictée et l'entretien (I-1 de la revue 9b) : ce qui part au moteur, et l'avis qui le
/// dit. Les phrases de la dictée sont relues mot pour mot : les extraire ne les a pas changées.
@Suite(.timeLimit(.minutes(1))) struct EffectiveVocabularyTests {
    /// Compte les appels, 10 jetons par terme.
    final class Counter: Sendable {
        private let calls = Mutex(0)
        var count: Int { calls.withLock { $0 } }
        func tokens(_ terms: [String], _ model: String) -> Int? {
            calls.withLock { $0 += 1 }
            return terms.count * 10
        }
    }

    static func settings(_ engine: TranscriptionEngine, _ vocabulary: [String]) -> TranscriptionSettings {
        TranscriptionSettings(engine: engine, whisperModel: "small", language: "fr", vocabulary: vocabulary)
    }

    func resolve(
        _ settings: TranscriptionSettings, unavailable: Bool = false, activity: EffectiveVocabulary.Activity = .dictation,
        limit: Int = 25, counter: Counter
    ) async -> EffectiveVocabulary? {
        await EffectiveVocabulary.resolve(
            for: settings, vocabularyModelUnavailable: unavailable, activity: activity, limit: limit,
            count: { counter.tokens($0, $1) })
    }

    // MARK: - La règle

    @Test("Parakeet avec son petit modèle : la liste part telle quelle, rien n'est compté")
    func parakeetKeepsTheListUntouched() async {
        let counter = Counter()
        #expect(await resolve(Self.settings(.parakeet, ["a", "b", "c"]), counter: counter) == nil)
        #expect(counter.count == 0)
    }

    @Test("petit modèle absent : aucun terme, sous les deux moteurs, et rien n'est compté")
    func withoutTheVocabularyModelNothingIsSent() async {
        for engine in [TranscriptionEngine.parakeet, .whisperKit] {
            let counter = Counter()
            let result = await resolve(Self.settings(engine, ["a"]), unavailable: true, counter: counter)
            #expect(result == EffectiveVocabulary(terms: [], notice: DictationController.vocabularyModelNotice))
            #expect(counter.count == 0)
        }
    }

    @Test("WhisperKit : une liste qui tient part entière, sans avis ; une liste vide n'est pas comptée")
    func whisperKitKeepsAListThatFits() async {
        let counter = Counter()
        #expect(await resolve(Self.settings(.whisperKit, ["a", "b"]), counter: counter) == EffectiveVocabulary(terms: ["a", "b"], notice: nil))
        let empty = Counter()
        #expect(await resolve(Self.settings(.whisperKit, []), counter: empty) == nil)
        #expect(empty.count == 0)
    }

    @Test("WhisperKit : une liste trop longue garde ses premiers termes, avec l'avis de l'activité")
    func whisperKitTrimsATooLongList() async {
        let settings = Self.settings(.whisperKit, ["a", "b", "c", "d", "e"])
        let dictation = await resolve(settings, counter: Counter())
        #expect(dictation == EffectiveVocabulary(terms: ["a", "b"], notice: EffectiveVocabulary.trimmedNotice(kept: 2, of: 5, .dictation)))
        let interview = await resolve(settings, activity: .interview, counter: Counter())
        #expect(interview == EffectiveVocabulary(terms: ["a", "b"], notice: InterviewText.vocabularyTrimmed(kept: 2, of: 5)))
    }

    @Test("WhisperKit : une longueur impossible à compter n'envoie aucun terme")
    func whisperKitDropsAnUncountableList() async {
        let result = await EffectiveVocabulary.resolve(
            for: Self.settings(.whisperKit, ["a"]), vocabularyModelUnavailable: false, activity: .interview, limit: 25,
            count: { _, _ in nil })
        #expect(result == EffectiveVocabulary(terms: [], notice: InterviewText.vocabularyUncountable))
    }

    // MARK: - Les phrases

    @Test("les phrases de la dictée sont celles d'avant l'extraction, mot pour mot")
    func theDictationSentencesAreUnchanged() {
        #expect(
            DictationController.uncountableNotice
                == "Le vocabulaire n'a pas servi à cette dictée : sa longueur n'a pas pu être vérifiée avec ce modèle.")
        #expect(
            DictationController.vocabularyModelNotice
                == "Le vocabulaire n'a pas servi à cette dictée : le petit modèle qui le reconnaît n'a pas pu être téléchargé. Il sera retenté à la prochaine dictée.")
        let ending = " à cette dictée. Raccourcissez la liste dans Réglages, onglet Transcription."
        #expect(EffectiveVocabulary.trimmedNotice(kept: 0, of: 4, .dictation) == "Vocabulaire trop long pour ce modèle : aucun terme n'a pu servir" + ending)
        #expect(EffectiveVocabulary.trimmedNotice(kept: 1, of: 4, .dictation) == "Vocabulaire trop long pour ce modèle : seul le premier terme sur 4 sert" + ending)
        #expect(EffectiveVocabulary.trimmedNotice(kept: 3, of: 4, .dictation) == "Vocabulaire trop long pour ce modèle : seuls les 3 premiers termes sur 4 servent" + ending)
    }

    @Test("celles de l'entretien nomment l'entretien, avec les espaces insécables de l'entretien")
    func theInterviewSentencesNameTheInterview() {
        let nbsp = "\u{00A0}"
        #expect(
            InterviewText.vocabularyUncountable
                == "Le vocabulaire n'a pas servi à cet entretien\(nbsp): sa longueur n'a pas pu être vérifiée avec ce modèle.")
        #expect(
            InterviewText.vocabularyModelUnavailable
                == "Le vocabulaire n'a pas servi à cet entretien\(nbsp): le petit modèle qui le reconnaît n'a pas pu être téléchargé. Il sera retenté au prochain entretien.")
        #expect(
            InterviewText.vocabularyTrimmed(kept: 3, of: 4)
                == "Vocabulaire trop long pour ce modèle\(nbsp): seuls les 3 premiers termes sur 4 servent à cet entretien. Raccourcissez la liste dans Réglages, onglet Transcription.")
    }
}
