import Foundation
import SupervoxCore

/// Les phrases de l'onglet Voix et de l'écoute d'une voix : fixes, en français, en phrases complètes, passées par `InterviewText.fr`
/// (espaces insécables). Aucune ne reprend le texte d'une erreur.
public enum VoicesText {
    // MARK: - Phrase d'essai (règle 10)

    /// La phrase que dit une voix qu'on écoute, par langue primaire. Une autre langue prend l'anglais.
    public static let samplePhrases: [String: String] = [
        "fr": InterviewText.fr("Bonjour, je suis la voix que Supervox prendra pour vous parler."),
        "en": "Hello, I am the voice Supervox will use to speak to you.",
        "es": "Hola, soy la voz que Supervox usará para hablarte.",
        "de": "Hallo, ich bin die Stimme, mit der Supervox zu Ihnen sprechen wird.",
        "it": "Ciao, sono la voce che Supervox userà per parlarti.",
    ]

    /// La phrase d'essai de cette langue : sa langue primaire (avant `-` ou `_`, sans casse), sinon l'anglais.
    public static func samplePhrase(for language: String) -> String {
        let primary = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        return samplePhrases[primary] ?? samplePhrases["en"] ?? ""
    }

    // MARK: - Pannes de l'écoute

    /// La phrase d'une panne de l'écoute ; pour `.provider(f)`, la phrase fixe de `f` (`RewriteFailure.message`).
    public static func failure(_ failure: VoicePreview.Failure) -> String {
        switch failure {
        case .notInstalled:
            InterviewText.fr("Cette voix n'est pas installée sur cet ordinateur : choisissez-en une autre.")
        case .unusable(let reason):
            Self.reason(reason)
        case .provider(let failure):
            failure.message
        case .silent:
            InterviewText.fr("La voix n'a rendu aucun son : il n'y a rien à faire entendre.")
        case .timedOut:
            InterviewText.fr(
                "La voix n'a pas répondu en \(Int(VoicePreview.limitSeconds)) secondes : réessayez dans un moment.")
        case .playback:
            InterviewText.fr("Le son n'a pas pu être joué : vérifiez la sortie audio, puis réessayez.")
        case .unavailable:
            InterviewText.fr("L'écoute n'est pas disponible : relancez Supervox.")
        }
    }

    /// Pourquoi une voix de fournisseur ne peut pas parler (règle 3).
    public static func reason(_ reason: SystemReason) -> String {
        switch reason {
        case .providerRemoved:
            InterviewText.fr("Le fournisseur de cette voix a été supprimé : choisissez-en un autre en modifiant la voix.")
        case .providerCannotSpeak:
            InterviewText.fr("Ce fournisseur ne sait pas parler : il n'a pas de synthèse de la voix.")
        case .incomplete:
            InterviewText.fr("Le modèle ou l'identifiant de cette voix manque : complétez-les en modifiant la voix.")
        }
    }
}
