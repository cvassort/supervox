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
                == "Parlez : Supervox attend la fin de votre phrase. Appuyez sur Conclure quand vous avez tout dit.")
        #expect(InterviewText.hint(.speaking) == "Parlez pour couper la parole à Supervox.")
        #expect(InterviewText.hint(.thinking) == "Parlez pour ajouter quelque chose : Supervox reprendra avec.")
        #expect(InterviewText.hint(.preparing).isEmpty)
        #expect(InterviewText.hint(.concluding).isEmpty)
    }

    @Test func theFooterCancelHintAndTheConcludeTextsAreTheOnesOfTheBrief() {
        #expect(InterviewText.cancelHint == "Échap annule l'entretien sans rien garder.")
        #expect(InterviewText.concludeLabel == "Conclure")
        #expect(InterviewText.concludeHelp == "Rédige le prompt à partir de ce qui a été dit.")
        #expect(InterviewText.holdNote == "En entretien, le raccourci fonctionne toujours en bascule : un appui conclut.")
    }

    @Test func theCounterSaysTheQuestionNumberOfTheMaximum() {
        #expect(InterviewText.questionCounter(1, of: 6) == "Question 1 sur 6")
        #expect(InterviewText.questionCounter(12, of: 12) == "Question 12 sur 12")
    }

    @Test func theNoticesAreTheOnesOfTheBrief() {
        #expect(
            InterviewText.notice(.notUnderstood) == "Rien n'a été compris : répétez, un peu plus près du micro.")
        #expect(
            InterviewText.notice(.voiceFellBack)
                == "La voix choisie ne répond pas : l'entretien continue avec la voix du système.")
        #expect(
            InterviewText.notice(.voiceUnavailable)
                == "La voix ne fonctionne pas : lisez la question à l'écran, puis répondez à voix haute.")
        #expect(
            InterviewText.notice(.proposal)
                == "Supervox propose de conclure : dites-le s'il vous convient, ou continuez à préciser.")
        #expect(
            InterviewText.notice(.lastQuestion)
                == "Dernière question : après votre réponse, Supervox rédige le prompt.")
    }

    @Test("un échec du modèle rapide se dit par la phrase du tour, jamais par le texte de l'erreur")
    func aModelFailureNoticeIsTheTurnFailureSentence() {
        for failure in Self.everyRewriteFailure {
            #expect(InterviewText.notice(.modelFailed(failure)) == InterviewText.turnFailure(failure), "\(failure)")
        }
    }

    // MARK: Les échecs d'un tour

    private static let keySentence =
        "Le fournisseur refuse la clé : vérifiez-la dans Réglages, onglet Fournisseurs, puis relancez l'entretien."
    private static let notFoundSentence =
        "Le modèle rapide n'existe pas chez ce fournisseur : choisissez-en un autre en tête de Réglages, onglet Modes."
    private static let rateSentence =
        "Le fournisseur limite les requêtes : attendez un peu, puis répétez votre réponse."
    private static let otherSentence =
        "Supervox n'a pas pu formuler sa question : répétez votre réponse, ou appuyez sur Conclure."

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
                == "Le texte de vos réponses part chez « Fournisseur d'exemple » ; l'audio du micro reste sur cet ordinateur.")
    }

    @Test func withAProviderVoiceThePrivacyLineAddsWhereTheTextOfSupervoxGoes() {
        #expect(
            InterviewText.privacy(provider: "Fournisseur d'exemple", voiceProvider: "Voix d'exemple")
                == "Le texte de vos réponses part chez « Fournisseur d'exemple » ; l'audio du micro reste sur cet ordinateur. Le texte que dit Supervox part chez « Voix d'exemple ».")
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
            #expect(sentence.count <= DictationText.detailLimit, "\(sentence.count) caractères : \(sentence)")
        }
    }

    @Test("règle 1 : allSentences contient toutes les phrases que le code peut produire (une phrase oubliée échapperait au test)")
    func allSentencesHoldsEverythingTheTextTableCanSay() {
        let sentences = Set(InterviewText.allSentences)
        let forty = String(repeating: "x", count: 40)
        var expected: [String] = []
        for phase in Self.phases {
            expected.append(InterviewText.title(phase))
            let hint = InterviewText.hint(phase)
            if !hint.isEmpty { expected.append(hint) }
        }
        expected += [
            InterviewText.cancelHint, InterviewText.concludeLabel, InterviewText.concludeHelp, InterviewText.holdNote,
            InterviewText.questionCounter(99, of: 99), InterviewText.supervoxLabel, InterviewText.youLabel,
            InterviewText.privacy(provider: forty, voiceProvider: nil),
            InterviewText.privacy(provider: forty, voiceProvider: forty),
        ]
        expected += Self.everyRewriteFailure.map(InterviewText.turnFailure)
        expected += [
            ConversationNotice.notUnderstood, .voiceFellBack, .voiceUnavailable, .proposal, .lastQuestion,
        ].map(InterviewText.notice)
        expected += InterviewText.knownFailureCodes.flatMap { code in
            [InterviewText.failure(.microphone(code)), InterviewText.failure(.engine(code))]
        }
        expected.append(InterviewText.failure(.engine("code-inconnu")))
        for sentence in expected {
            #expect(sentences.contains(sentence), "absente de allSentences : \(sentence)")
        }
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
        try #require(codes.count >= 10, "le balayage ne voit presque aucun code : \(codes)")
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
                #expect(!sentence.localizedCaseInsensitiveContains(code), "\(code) est montré : \(sentence)")
                #expect(sentence.hasSuffix("."), "\(code) : phrase non terminée")
                #expect(sentence.count <= DictationText.detailLimit, "\(code) : \(sentence.count) caractères")
            }
            let sentence = InterviewText.failure(.engine(code))
            #expect(sentence == InterviewText.failure(.microphone(code)), "\(code) : la phrase dépend du genre")
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
                if !code.isEmpty { #expect(!sentence.contains(code), "le code brut est montré : \(sentence)") }
                #expect(sentence == InterviewText.failure(.engine("autre-code-inconnu")))
                #expect(sentence.count <= DictationText.detailLimit)
            }
        }
    }

    @Test("chaque phrase de panne dit quoi faire")
    func everyFailureSentenceSaysWhatToDo() throws {
        let verbs = ["relancez", "branchez", "choisissez", "vérifiez", "autorisez", "attendez", "fermez", "mettez"]
        for code in try Self.codesOfTheEngine() + ["code-inconnu"] {
            let sentence = InterviewText.failure(.engine(code)).lowercased()
            #expect(verbs.contains { sentence.contains($0) }, "\(code) : aucune consigne dans « \(sentence) »")
        }
    }
}
