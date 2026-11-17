import Foundation
import SupervoxCore
import Testing

@testable import SupervoxApp

// Les phrases de l'entretien, mot pour mot (tâche 8 du plan « entretien »). Les littéraux de ce fichier sont l'oracle : ils sont
// recopiés du cahier des charges, jamais lus dans `InterviewText`.

@Suite struct InterviewTextTests {
    // MARK: Les phrases du cahier des charges

    @Test func theTitlesAreTheOnesOfTheBrief() {
        #expect(InterviewText.title(.preparing) == "Préparation de l'entretien…")
        #expect(InterviewText.title(.listening) == "À vous")
        #expect(InterviewText.title(.thinking) == "Réflexion…")
        #expect(InterviewText.title(.speaking) == "Supervox parle")
        #expect(InterviewText.title(.concluding) == "Rédaction du prompt…")
    }

    @Test func theHintsAreTheOnesOfTheBriefAndPreparationAndConclusionHaveNone() {
        #expect(
            InterviewText.hint(.listening)
                == "Parlez\u{00A0}: Supervox attend la fin de votre phrase. Appuyez sur Conclure quand vous avez tout dit.")
        #expect(InterviewText.hint(.speaking) == "Parlez pour couper la parole à Supervox.")
        #expect(InterviewText.hint(.thinking) == "Parlez pour ajouter quelque chose\u{00A0}: Supervox reprendra avec.")
        #expect(InterviewText.hint(.preparing).isEmpty)
        #expect(InterviewText.hint(.concluding).isEmpty)
    }

    @Test func theFooterCancelHintAndTheConcludeTextsAreTheOnesOfTheBrief() {
        #expect(InterviewText.cancelHint == "Échap annule l'entretien sans rien garder.")
        #expect(InterviewText.concludeLabel == "Conclure")
        #expect(InterviewText.concludeHelp == "Rédige le prompt à partir de ce qui a été dit.")
        #expect(InterviewText.holdNote == "En entretien, le raccourci fonctionne toujours en bascule\u{00A0}: un appui conclut.")
    }

    @Test func theCounterSaysTheQuestionNumberOfTheMaximum() {
        #expect(InterviewText.questionCounter(1, of: 6) == "Question 1 sur 6")
        #expect(InterviewText.questionCounter(12, of: 12) == "Question 12 sur 12")
    }

    @Test func theNoticesAreTheOnesOfTheBrief() {
        #expect(
            InterviewText.notice(.notUnderstood) == "Rien n'a été compris\u{00A0}: répétez, un peu plus près du micro.")
        #expect(
            InterviewText.notice(.voiceFellBack)
                == "La voix choisie ne répond pas\u{00A0}: l'entretien continue avec la voix du système.")
        #expect(
            InterviewText.notice(.voiceUnavailable)
                == "La voix ne fonctionne pas\u{00A0}: lisez la question à l'écran, puis répondez à voix haute.")
        #expect(
            InterviewText.notice(.proposal)
                == "Supervox propose de conclure\u{00A0}: dites-le s'il vous convient, ou continuez à préciser.")
        #expect(
            InterviewText.notice(.lastQuestion)
                == "Dernière question\u{00A0}: après votre réponse, Supervox rédige le prompt.")
        #expect(
            InterviewText.notice(.lastWordsLost)
                == "Votre dernière phrase n'a pas pu être transcrite\u{00A0}: le prompt est rédigé sans elle.")
    }

    @Test("un échec du modèle rapide se dit par la phrase du tour, jamais par le texte de l'erreur")
    func aModelFailureNoticeIsTheTurnFailureSentence() {
        for failure in Self.everyRewriteFailure {
            #expect(InterviewText.notice(.modelFailed(failure)) == InterviewText.turnFailure(failure), "\(failure)")
        }
    }

    // MARK: Les échecs d'un tour

    private static let keySentence =
        "Le fournisseur refuse la clé\u{00A0}: vérifiez-la dans Réglages, onglet Fournisseurs, puis relancez l'entretien."
    private static let notFoundSentence =
        "Le modèle rapide n'existe pas chez ce fournisseur\u{00A0}: choisissez-en un autre en tête de Réglages, onglet Modes."
    private static let rateSentence =
        "Le fournisseur limite les requêtes\u{00A0}: attendez un peu, puis répétez votre réponse."
    private static let otherSentence =
        "Supervox n'a pas pu formuler sa question\u{00A0}: répétez votre réponse, ou appuyez sur Conclure."

    /// Un échantillon de chaque cas de `RewriteFailure`. Exhaustif par construction : un cas ajouté à l'énumération casse la
    /// compilation de ce `switch`, qui oblige à choisir la phrase attendue.
    private static let everyRewriteFailure: [RewriteFailure] = [
        .noModel, .providerMissing, .noKey(provider: "Fournisseur d'exemple"), .keychain, .unauthorized(401), .notFound,
        .rejected(422), .rateLimited, .server(503), .unreachable, .redirected, .interrupted, .stalled(30), .providerError,
        .truncated, .refused, .empty, .timedOut(30), .malformed,
    ]

    private static func expectedTurnFailure(_ failure: RewriteFailure) -> String {
        switch failure {
        case .unauthorized, .noKey, .keychain: keySentence
        case .notFound: notFoundSentence
        case .rateLimited: rateSentence
        case .noModel, .providerMissing, .rejected, .server, .unreachable, .redirected, .interrupted, .stalled, .providerError,
            .truncated, .refused, .empty, .timedOut, .malformed:
            otherSentence
        }
    }

    @Test("chaque cas de RewriteFailure a la phrase attendue par le cahier des charges")
    func everyRewriteFailureHasTheExpectedSentence() {
        #expect(Set(Self.everyRewriteFailure.map(Self.kind)).count == Self.everyRewriteFailure.count, "un genre est répété")
        for failure in Self.everyRewriteFailure {
            #expect(InterviewText.turnFailure(failure) == Self.expectedTurnFailure(failure), "\(failure)")
        }
    }

    /// Un genre par cas : l'échantillon couvre toute l'énumération (le `switch` n'a pas de `default`).
    private static func kind(_ failure: RewriteFailure) -> Int {
        switch failure {
        case .noModel: 0
        case .providerMissing: 1
        case .noKey: 2
        case .keychain: 3
        case .unauthorized: 4
        case .notFound: 5
        case .rejected: 6
        case .rateLimited: 7
        case .server: 8
        case .unreachable: 9
        case .redirected: 10
        case .interrupted: 11
        case .stalled: 12
        case .providerError: 13
        case .truncated: 14
        case .refused: 15
        case .empty: 16
        case .timedOut: 17
        case .malformed: 18
        }
    }

    @Test("une phrase d'échec du tour ne porte ni le nom du fournisseur ni un code HTTP")
    func aTurnFailureSentenceCarriesNeitherTheProviderNorAStatus() {
        let name = "Fournisseur d'exemple"
        for failure in [RewriteFailure.noKey(provider: name), .unauthorized(401), .rejected(422), .server(503), .stalled(30)] {
            let sentence = InterviewText.turnFailure(failure)
            #expect(!sentence.contains(name) && !sentence.contains("401") && !sentence.contains("HTTP"), "\(failure)")
        }
    }

    // MARK: La vie privée

    @Test func thePrivacyLineNamesTheProviderOfTheTextAndKeepsTheAudioOnTheComputer() {
        #expect(
            InterviewText.privacy(provider: "Fournisseur d'exemple", voiceProvider: nil)
                == "Le texte de vos réponses part chez «\u{00A0}Fournisseur d'exemple\u{00A0}»\u{00A0}; l'audio du micro reste sur cet ordinateur.")
    }

    @Test func withAProviderVoiceThePrivacyLineAddsWhereTheTextOfSupervoxGoes() {
        #expect(
            InterviewText.privacy(provider: "Fournisseur d'exemple", voiceProvider: "Voix d'exemple")
                == "Le texte de vos réponses part chez «\u{00A0}Fournisseur d'exemple\u{00A0}»\u{00A0}; l'audio du micro reste sur cet ordinateur. Le texte que dit Supervox part chez «\u{00A0}Voix d'exemple\u{00A0}».")
    }

    @Test("un nom de fournisseur démesuré est rogné comme partout : la ligne tient dans la limite")
    func aHugeProviderNameIsCutSoThePrivacyLineStillFits() {
        let huge = String(repeating: "Fournisseur ", count: 20)
        let line = InterviewText.privacy(provider: huge, voiceProvider: huge)
        #expect(line.count <= DictationText.detailLimit, "\(line.count) caractères")
        #expect(line.contains(Provider.shortName(huge)))
        #expect(!line.contains(huge))
    }

    // MARK: Règle 1 : la longueur

    @Test("règle 1 : chaque phrase de l'entretien tient dans DictationText.detailLimit, noms de 40 caractères")
    func everySentenceFitsTheDetailLimit() {
        #expect(!InterviewText.allSentences.isEmpty)
        for sentence in InterviewText.allSentences {
            #expect(sentence.count <= DictationText.detailLimit, "\(sentence.count) caractères\u{00A0}: \(sentence)")
        }
    }

    @Test("règle 1 : allSentences contient les phrases que ces appels produisent")
    func allSentencesHoldsWhatTheseCallsProduce() {
        let sentences = Set(InterviewText.allSentences)
        let forty = String(repeating: "x", count: 40)
        var expected: [String] = []
        for phase in Self.phases {
            for textOnly in [false, true] {
                expected.append(InterviewText.title(phase, textOnly: textOnly))
                let hint = InterviewText.hint(phase, textOnly: textOnly)
                if !hint.isEmpty { expected.append(hint) }
            }
        }
        expected += [
            InterviewText.cancelHint, InterviewText.concludeLabel, InterviewText.concludeHelp, InterviewText.holdNote,
            InterviewText.questionCounter(99, of: 99), InterviewText.supervoxLabel, InterviewText.youLabel,
            InterviewText.modeLockedHint,
            InterviewText.privacy(provider: forty, voiceProvider: nil),
            InterviewText.privacy(provider: forty, voiceProvider: forty),
        ]
        expected += Self.everyRewriteFailure.map(InterviewText.turnFailure)
        expected += [
            ConversationNotice.notUnderstood, .voiceFellBack, .voiceUnavailable, .proposal, .lastQuestion, .lastWordsLost,
        ].map(InterviewText.notice)
        expected += InterviewText.knownFailureCodes.flatMap { code in
            [InterviewText.failure(.microphone(code)), InterviewText.failure(.engine(code))]
        }
        expected.append(InterviewText.failure(.engine("code-inconnu")))
        for sentence in expected {
            #expect(sentences.contains(sentence), "absente de allSentences\u{00A0}: \(sentence)")
        }
    }

    /// Le test précédent recalcule ses attendus avec les mêmes fonctions : une phrase ajoutée hors de ces appels (un nouveau
    /// `static let`, une nouvelle fonction) lui échapperait. Celui-ci lit les sources : chaque déclaration publique ou interne de
    /// `InterviewText.swift` doit être nommée dans le corps de `allSentences`, ou figurer dans la liste de celles qui ne sont pas
    /// des phrases. Limite : il vérifie des noms, pas que tout le domaine d'une fonction est parcouru (les cas d'une énumération le
    /// sont par les `switch` exhaustifs du code et par les tests ci-dessus).
    @Test("règle 1 : toute phrase déclarée dans InterviewText est nommée dans allSentences")
    func everyDeclaredSentenceIsNamedInAllSentences() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SupervoxApp/Interview/InterviewText.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let marker = try #require(source.range(of: "static var allSentences"), "allSentences a disparu")
        let body = String(source[marker.upperBound...])
        let declared = try source.matches(of: Regex(#"(?m)^\s*(?:public )?static (?:let|var|func) (\w+)"#)).map { String($0.output[1].substring ?? "") }
        // Ce qui n'est pas une phrase : la table elle-même, la liste des codes, le typographe.
        let notSentences: Set<String> = ["allSentences", "knownFailureCodes", "failureSentences", "generalFailure", "fr"]
        let sentences = declared.filter { !notSentences.contains($0) }
        try #require(sentences.count >= 12, "le balayage ne voit presque aucune phrase : \(sentences)")
        for name in Set(sentences) {
            #expect(body.contains("\(name)"), "\(name) n'est pas nommé dans allSentences")
        }
    }

    @Test("typographie : aucune phrase n'a d'espace ordinaire avant « : ; ? ! », après « « » ni avant « » », comme DictationText")
    func noSentenceLeavesARegularSpaceBeforeHighPunctuation() {
        for sentence in InterviewText.allSentences {
            for mark in [":", ";", "?", "!", "»"] {
                #expect(!sentence.contains(" " + mark), "espace ordinaire avant \(mark) : \(sentence)")
            }
            #expect(!sentence.contains("« "), "espace ordinaire après « : \(sentence)")
        }
        // La règle s'applique aussi quand elle a quelque chose à faire : au moins une phrase porte une espace insécable.
        #expect(InterviewText.allSentences.contains { $0.contains("\u{00A0}") })
    }

    @Test("M8 : sans voix la phase de parole devient « Supervox répond » et dit de lire, jamais de couper la parole")
    func withoutAVoiceTheSpeakingPhaseSaysToReadTheAnswer() {
        #expect(InterviewText.title(.speaking, textOnly: true) == "Supervox répond")
        #expect(InterviewText.hint(.speaking, textOnly: true) == "Lisez la réponse à l'écran, puis parlez.")
        #expect(!InterviewText.hint(.speaking, textOnly: true).contains("couper"))
        // Les autres phases ne changent pas.
        for phase in Self.phases where phase != .speaking {
            #expect(InterviewText.title(phase, textOnly: true) == InterviewText.title(phase), "\(phase)")
            #expect(InterviewText.hint(phase, textOnly: true) == InterviewText.hint(phase), "\(phase)")
        }
        #expect(InterviewText.title(.speaking, textOnly: false) == "Supervox parle")
    }

    @Test("M6 : les pastilles verrouillées disent pourquoi")
    func theLockedChipsHint() {
        #expect(InterviewText.modeLockedHint == "Indisponible pendant un entretien.")
    }

    static let phases: [InterviewPhase] = [.preparing, .listening, .thinking, .speaking, .concluding]

    // MARK: Les pannes de l'entretien

    /// Les codes de `ConversationFailure.Code`, lus dans le fichier du moteur : l'énumération n'est pas itérable, et une liste
    /// recopiée à la main resterait juste en silence quand un code s'ajoute.
    private static func codesOfTheEngine() throws -> [String] {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SupervoxCore/Conversation/ConversationEngine.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(text.range(of: "public enum Code {"), "le bloc Code a disparu du moteur")
        let rest = text[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }"), "la fin du bloc Code est introuvable")
        let codes = try rest[..<end.lowerBound].matches(of: Regex(#"public static let \w+ = "(\w+)""#)).map { String($0.output[1].substring ?? "") }
        try #require(codes.count >= 10, "le balayage ne voit presque aucun code\u{00A0}: \(codes)")
        return codes
    }

    @Test("chaque code de ConversationFailure.Code a sa phrase propre, et aucune ne montre le code")
    func everyFailureCodeHasItsOwnSentenceWithoutTheCode() throws {
        let codes = try Self.codesOfTheEngine()
        let general = InterviewText.failure(.engine("code-inconnu"))
        var seen: [String: String] = [:]
        for code in codes {
            for failure in [ConversationFailure.microphone(code), .engine(code)] {
                let sentence = InterviewText.failure(failure)
                #expect(sentence != general, "\(code) retombe sur la phrase générale")
                #expect(!sentence.localizedCaseInsensitiveContains(code), "\(code) est montré\u{00A0}: \(sentence)")
                #expect(sentence.hasSuffix("."), "\(code)\u{00A0}: phrase non terminée")
                #expect(sentence.count <= DictationText.detailLimit, "\(code)\u{00A0}: \(sentence.count) caractères")
            }
            let sentence = InterviewText.failure(.engine(code))
            #expect(sentence == InterviewText.failure(.microphone(code)), "\(code)\u{00A0}: la phrase dépend du genre")
            if let other = seen[sentence] { Issue.record("\(code) et \(other) ont la même phrase") }
            seen[sentence] = code
        }
        #expect(Set(InterviewText.knownFailureCodes) == Set(codes), "la table de phrases et le moteur ne parlent pas des mêmes codes")
    }

    @Test("un code inconnu a une phrase générale qui ne montre jamais le code brut")
    func anUnknownCodeGetsTheGeneralSentenceWithoutTheRawCode() {
        for code in ["codeQuiNExistePas", "", "Erreur 42 (adresse https://example.com/cle)"] {
            for failure in [ConversationFailure.microphone(code), .engine(code)] {
                let sentence = InterviewText.failure(failure)
                #expect(!sentence.isEmpty)
                if !code.isEmpty { #expect(!sentence.contains(code), "le code brut est montré\u{00A0}: \(sentence)") }
                #expect(sentence == InterviewText.failure(.engine("autre-code-inconnu")))
                #expect(sentence.count <= DictationText.detailLimit)
            }
        }
    }

    /// Ce que chaque phrase doit dire : la consigne qui correspond à sa cause (tous les morceaux, en minuscules). Écrite ici, à la
    /// main, depuis les commentaires de `AudioCaptureError`, de `TranscriberError` et de `ConversationFailure.Code`.
    private static let expectedAdvice: [String: [String]] = [
        "microphoneAccessDenied": ["autorisez", "micro"],
        "noInputDevice": ["aucun micro", "branchez"],
        "alreadyRunning": ["déjà utilisé", "terminez"],
        "engineFailed": ["moteur audio", "autre application"],
        "notRunning": ["moteur audio", "pas démarré"],
        "silent": ["aucun son", "branché"],
        "unusableSampleRate": ["fréquence", "autre entrée audio"],
        "conversionFailed": ["converti", "autre entrée audio"],
        "detectorFailed": ["détecteur de voix", "onglet transcription"],
        "transcriptionUnsupportedSampleRate": ["fréquence", "autre entrée audio"],
        "transcriptionNotPrepared": ["pas prêt", "onglet transcription", "téléchargé"],
        "transcriptionUnsupportedLocale": ["langue", "onglet transcription"],
        "transcriptionVocabularyUnavailable": ["réduisez ou videz le vocabulaire", "onglet transcription"],
        "transcriptionFailed": ["transcription a échoué", "onglet transcription"],
        "transcriptionTimedOut": ["à temps", "onglet transcription"],
        "unexpected": ["inattendue", "relancez"],
    ]

    @Test("M12 : chaque phrase de panne porte la consigne de sa cause, et aucune ne cite un chemin de Réglages Système non vérifié")
    func everyFailureSentenceCarriesTheAdviceOfItsCause() throws {
        let codes = try Self.codesOfTheEngine()
        #expect(Set(codes) == Set(Self.expectedAdvice.keys), "la table attendue ne couvre pas les codes du moteur")
        for code in codes {
            let sentence = InterviewText.failure(.engine(code)).lowercased()
            let pieces = try #require(Self.expectedAdvice[code])
            for piece in pieces {
                #expect(sentence.contains(piece), "\(code) : « \(piece) » absent de « \(sentence) »")
            }
            #expect(!sentence.contains("réglages système, son"), "\(code) cite un chemin non vérifié")
            #expect(!sentence.contains("> "), "\(code) cite un chemin de réglages")
        }
        // Le vocabulaire trop long est une panne qui se répétera : la phrase commence par la consigne, pas par « relancez ».
        #expect(InterviewText.failure(.engine("transcriptionVocabularyUnavailable")).hasPrefix("Réduisez ou videz le vocabulaire personnel"))
        // Une fréquence inutilisable n'affirme aucune cause : elle propose d'essayer une autre entrée.
        for code in ["unusableSampleRate", "transcriptionUnsupportedSampleRate", "conversionFailed"] {
            let sentence = InterviewText.failure(.engine(code))
            #expect(sentence.contains("relancez l'entretien") && sentence.contains("si cela se répète"), "\(code)")
        }
    }
}
