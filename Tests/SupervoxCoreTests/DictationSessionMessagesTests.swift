import Foundation
import Testing
@testable import SupervoxCore

/// Ce que la personne lit quand une dictée échoue : jamais le texte brut d'une erreur système (qui peut porter l'adresse
/// d'un service), toujours une phrase française.
@Suite(.timeLimit(.minutes(1)))
struct DictationSessionMessagesTests {
    private func failureOf(finalReply: ScriptedTranscriber.Reply) async -> DictationFailure? {
        let final = ScriptedTranscriber(reply: { _ in finalReply })
        let rig = makeRig(chunks: [rampChunk(0..<2000)], events: [0: .speechStart(sample: 0)], final: final)
        await rig.session.start()
        await rig.session.finish()
        guard case .failed(let failure) = await rig.outcome() else { return nil }
        return failure
    }

    @Test func anUnknownSystemErrorNeverShowsItsRawTextNorTheServiceAddress() async {
        let address = "https://service.example.invalid/v1/audio"
        let error = URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: address)!])

        let failure = await failureOf(finalReply: .fail(error))

        guard let failure else {
            Issue.record("la prise aurait dû échouer")
            return
        }
        for text in [failure.message, String(describing: failure)] {
            #expect(!text.contains("example.invalid"), "\(text)")
            #expect(!text.contains("http"), "\(text)")
            #expect(!text.contains("Error Domain"), "\(text)")
            #expect(!text.contains("NSURLError"), "\(text)")
        }
        #expect(failure.message.hasPrefix("La transcription a échoué"))
        #expect(failure.message.hasSuffix("."))
    }

    /// Une erreur d'une bibliothèque tierce qui porte son propre texte (`LocalizedError`, ici un type du test) : son texte n'est
    /// jamais montré, la raison est la phrase de repli (B1, revue finale : remplace le choix du 14/11).
    @Test func aForeignLocalizedErrorNeverShowsItsText() async {
        struct ForeignError: LocalizedError {
            var errorDescription: String? { "texte étranger" }
        }
        let failure = await failureOf(finalReply: .fail(ForeignError()))
        #expect(failure == .engine("erreur inattendue"))
        #expect(failure?.message.contains("texte étranger") == false)
    }

    /// Réécrit sur le protocole (B1, revue finale ; était `aLocalizedErrorKeepsItsOwnMessage`) : une erreur de la maison
    /// (`SupervoxError`, qui n'est pas une `LocalizedError`) garde sa raison.
    @Test func aHouseErrorKeepsItsReason() async {
        struct HouseFailure: SupervoxError {
            var reason: String { "le service ne répond pas" }
        }
        let failure = await failureOf(finalReply: .fail(HouseFailure()))
        #expect(failure == .engine("le service ne répond pas"))
    }

    @Test func aTranscriberErrorKeepsItsMessage() async {
        let failure = await failureOf(finalReply: .fail(TranscriberError.notPrepared("whisperkit")))
        #expect(failure == .engine("moteur whisperkit non préparé : prepare() doit réussir avant transcribe()"))
    }
}
