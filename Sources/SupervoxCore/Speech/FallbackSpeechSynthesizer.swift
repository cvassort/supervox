import Foundation
import Synchronization

/// La voix choisie, et la voix de secours qui la remplace dès qu'elle échoue.
///
/// Une phrase que la voix choisie rate (elle lève, ou ne rend rien en `timeout` secondes) est dite par la voix de secours
/// (`fellBack` vrai), et la requête de la voix choisie est annulée. **Ensuite, la voix choisie n'est plus appelée** de tout
/// l'entretien : une voix qui vient de manquer une phrase ferait attendre `timeout` secondes à chacune des suivantes. Si la
/// voix de secours échoue aussi, son erreur est celle qu'on lève.
///
/// Un texte blanc lève `SpeechError.empty` sans appeler aucune voix et sans toucher à cet état : ce n'est la panne d'aucune voix.
///
/// L'annulation de l'appelant n'est jamais un échec : elle lève `CancellationError`, sans repli, et la voix choisie reste
/// en place.
public final class FallbackSpeechSynthesizer: SpeechSynthesizer {
    private let primary: any SpeechSynthesizer
    private let fallback: any SpeechSynthesizer
    private let timeout: Double
    private let sleep: @Sendable (Double) async throws -> Void
    private let primaryFailed = Mutex(false)

    /// - Parameter timeout: secondes par phrase laissées à la voix choisie. 4 s : choix non mesuré (design §4 : 0,23 à
    ///   1,3 s mesurés pour une phrase, trois essais).
    public init(primary: any SpeechSynthesizer, fallback: any SpeechSynthesizer, timeout: Double = 4,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.primary = primary
        self.fallback = fallback
        self.timeout = timeout
        self.sleep = sleep
    }

    public func synthesize(_ text: String) async throws -> Speech {
        try Task.checkCancellation()
        // Avant toute chose : une phrase blanche n'est pas une panne de la voix choisie, qui ne doit pas être écartée pour elle.
        guard !text.isBlankForSpeech else { throw SpeechError.empty }
        if !primaryFailed.withLock({ $0 }) {
            do {
                let primary = primary
                return try await Deadline.run(seconds: timeout, sleep: sleep) { try await primary.synthesize(text) }
            } catch {
                // Une erreur levée parce que l'appelant annule (quelle qu'elle soit) n'est pas une panne de la voix choisie.
                if Task.isCancelled { throw CancellationError() }
                primaryFailed.withLock { $0 = true }
            }
        }
        var speech: Speech
        do { speech = try await fallback.synthesize(text) } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        speech.fellBack = true
        return speech
    }
}
