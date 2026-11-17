import Foundation
import SupervoxCore
import Testing

@testable import SupervoxApp

// Les phrases du départ, de la relecture et des refus de l'entretien (tâche 9 du plan « entretien »), mot pour mot. Les littéraux de
// ce fichier sont l'oracle : ils sont recopiés du cahier des charges (et de l'amendement D), jamais lus dans `InterviewText`.
// `\u{00A0}` est l'espace insécable que la typographie française met avant « : ; ? ! », après « « » et avant « » ».

@Suite(.timeLimit(.minutes(1))) struct InterviewTextSetupTests {
    // MARK: Les refus au démarrage

    private static let noFast =
        "Aucun modèle rapide n'est choisi\u{00A0}: choisissez-en un en tête de Réglages, onglet Modes, pour mener l'entretien."
    private static let noStrong =
        "Aucun modèle fort n'est choisi\u{00A0}: choisissez-en un en tête de Réglages, onglet Modes, pour rédiger le prompt de l'entretien."
    private static let providerGone =
        "Le fournisseur du modèle de l'entretien n'existe plus\u{00A0}: choisissez un autre modèle en tête de Réglages, onglet Modes."
    private static let keychain =
        "Le trousseau n'a pas donné la clé du fournisseur\u{00A0}: relancez l'entretien et autorisez Supervox si le système le demande."
    private static let badAddress =
        "L'adresse du fournisseur n'est pas valide\u{00A0}: corrigez-la dans Réglages, onglet Fournisseurs."
    private static let couldNotStart = "L'entretien n'a pas pu démarrer\u{00A0}: relancez Supervox."

    private static func noKey(_ name: String) -> String {
        "Aucune clé n'est enregistrée pour «\u{00A0}\(name)\u{00A0}»\u{00A0}: ajoutez-la dans Réglages, onglet Fournisseurs."
    }

    @Test("chaque refus au démarrage a la phrase du cahier des charges, mot pour mot")
    func everySetupRefusalHasItsSentence() {
        let table: [(InterviewSetupFailure, String)] = [
            (.noFastModel, Self.noFast),
            (.noStrongModel, Self.noStrong),
            (.provider(.providerMissing), Self.providerGone),
            (.provider(.noKey(provider: "Fournisseur d'exemple")), Self.noKey("Fournisseur d'exemple")),
            (.provider(.keychain), Self.keychain),
            (.provider(.unreachable), Self.badAddress),
        ]
        for (failure, sentence) in table {
            #expect(InterviewText.setupFailure(failure) == sentence, "\(failure)")
        }
    }

    @Test("« Aucune clé… » nomme le fournisseur concerné, rogné comme partout")
    func theNoKeySentenceNamesTheProvider() {
        for name in ["Fournisseur d'exemple", "Second d'exemple", "Voix d'exemple"] {
            let sentence = InterviewText.setupFailure(.provider(.noKey(provider: name)))
            #expect(sentence == Self.noKey(name))
            #expect(sentence.contains(name))
        }
        let huge = String(repeating: "N", count: 60)
        let long = InterviewText.setupFailure(.provider(.noKey(provider: huge)))
        #expect(long == Self.noKey(Provider.shortName(huge)))
        #expect(!long.contains(huge))
        #expect(long.count <= DictationText.detailLimit)
    }

    /// Les pannes du fournisseur que la résolution ne rend jamais (`ProviderResolver` ne lève que quatre cas) : le type les permet,
    /// elles disent la phrase de départ générale, jamais le texte de l'erreur. Les quatre qui ont leur phrase sont exclues.
    private static let neverResolved: [RewriteFailure] = [
        .noModel, .unauthorized(401), .notFound, .rejected(422), .rateLimited, .server(503), .redirected, .interrupted, .stalled(30),
        .providerError, .truncated, .refused, .empty, .timedOut(30), .malformed,
    ]

    @Test("une panne du fournisseur que la résolution ne rend pas dit « n'a pas pu démarrer », sans rien de l'erreur")
    func anUnexpectedProviderFailureSaysTheGeneralSentence() {
        for failure in Self.neverResolved {
            #expect(InterviewText.setupFailure(.provider(failure)) == Self.couldNotStart, "\(failure)")
        }
    }

    @Test("aucune phrase de refus ne reprend le texte d'une erreur, ni un code HTTP")
    func noSetupSentenceRepeatsTheTextOfAnError() {
        let everyone: [RewriteFailure] = Self.neverResolved + [.providerMissing, .noKey(provider: "Fournisseur d'exemple"), .keychain, .unreachable]
        for failure in everyone {
            let sentence = InterviewText.setupFailure(.provider(failure))
            #expect(!sentence.contains(failure.message), "\(failure) : le message de l'erreur est repris")
            for status in ["401", "422", "503", "HTTP"] { #expect(!sentence.contains(status), "\(failure) : \(status)") }
        }
        #expect(!InterviewText.setupFailure(.noFastModel).contains("HTTP"))
    }

    // MARK: La relecture

    @Test("les phrases de relecture sont celles du cahier des charges, mot pour mot")
    func theReviewSentencesAreTheOnesOfTheBrief() {
        #expect(
            InterviewText.promptReview
                == "Prompt rédigé à partir de l'entretien\u{00A0}: relisez-le, puis collez-le ou copiez-le.")
        #expect(
            InterviewText.promptReviewWithoutLastWords
                == "Prompt rédigé à partir de l'entretien, sans vos derniers mots, qui n'ont pas pu être transcrits\u{00A0}: relisez-le, puis collez-le ou copiez-le.")
        #expect(
            InterviewText.conclusionFailedReview
                == "Le prompt n'a pas pu être rédigé\u{00A0}: le texte ci-dessus est la conversation de l'entretien. Corrigez-la, collez-la ou copiez-la.")
        #expect(
            InterviewText.microphoneStoppedReview
                == "Le micro s'est arrêté pendant l'entretien\u{00A0}: le texte ci-dessus est la conversation jusque-là. Corrigez-la, collez-la ou copiez-la.")
        #expect(
            InterviewText.transcriptionStoppedReview
                == "La transcription s'est arrêtée pendant l'entretien\u{00A0}: le texte ci-dessus est la conversation jusque-là. Corrigez-la, collez-la ou copiez-la.")
    }

    @Test("les phrases sans relecture sont celles du cahier des charges, mot pour mot")
    func theSentencesWithoutAReviewAreTheOnesOfTheBrief() {
        #expect(InterviewText.nothingSaid == "Rien n'a été dit\u{00A0}: il n'y a pas de prompt à rédiger. Relancez l'entretien pour recommencer.")
        #expect(
            InterviewText.microphoneSentNothing
                == "Le micro n'a rien envoyé\u{00A0}: vérifiez qu'il est branché et autorisé, puis relancez l'entretien.")
        #expect(
            InterviewText.transcriptionDidNotStart
                == "La transcription n'a pas démarré\u{00A0}: relancez l'entretien\u{00A0}; si cela se répète, choisissez un autre moteur pour le mode Entretien dans Réglages, onglet Modes.")
        #expect(InterviewText.couldNotStart == Self.couldNotStart)
    }

    // MARK: Le test de longueur

    @Test("toutes ces phrases entrent dans allSentences, que le test de longueur et de typographie mesure")
    func theNewSentencesAreInAllSentences() {
        let sentences = Set(InterviewText.allSentences)
        let expected: [String] = [
            Self.noFast, Self.noStrong, Self.providerGone, Self.keychain, Self.badAddress, Self.couldNotStart,
            Self.noKey(String(repeating: "x", count: Provider.shortNameLimit)),
            "Prompt rédigé à partir de l'entretien\u{00A0}: relisez-le, puis collez-le ou copiez-le.",
            "Prompt rédigé à partir de l'entretien, sans vos derniers mots, qui n'ont pas pu être transcrits\u{00A0}: relisez-le, puis collez-le ou copiez-le.",
            "Le prompt n'a pas pu être rédigé\u{00A0}: le texte ci-dessus est la conversation de l'entretien. Corrigez-la, collez-la ou copiez-la.",
            "Le micro s'est arrêté pendant l'entretien\u{00A0}: le texte ci-dessus est la conversation jusque-là. Corrigez-la, collez-la ou copiez-la.",
            "La transcription s'est arrêtée pendant l'entretien\u{00A0}: le texte ci-dessus est la conversation jusque-là. Corrigez-la, collez-la ou copiez-la.",
            "Rien n'a été dit\u{00A0}: il n'y a pas de prompt à rédiger. Relancez l'entretien pour recommencer.",
            "Le micro n'a rien envoyé\u{00A0}: vérifiez qu'il est branché et autorisé, puis relancez l'entretien.",
            "La transcription n'a pas démarré\u{00A0}: relancez l'entretien\u{00A0}; si cela se répète, choisissez un autre moteur pour le mode Entretien dans Réglages, onglet Modes.",
        ]
        for sentence in expected {
            #expect(sentences.contains(sentence), "absente de allSentences\u{00A0}: \(sentence)")
        }
    }
}
