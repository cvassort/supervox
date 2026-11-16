import Foundation

/// Une demande de complétion : une consigne et un texte à traiter. Sans historique ni outils.
public struct CompletionRequest: Equatable, Sendable {
    public var model: String
    /// Part comme consigne système.
    public var instruction: String
    /// Part comme seul message de l'utilisateur.
    public var input: String
    public var maxTokens: Int

    public init(model: String, instruction: String, input: String, maxTokens: Int) {
        self.model = model
        self.instruction = instruction
        self.input = input
        self.maxTokens = maxTokens
    }
}

/// Pourquoi le modèle s'est arrêté, ramené à un vocabulaire commun aux deux types d'endpoint.
public enum CompletionStop: Equatable, Sendable {
    /// Fin naturelle de la réponse (`stop`, `end_turn`, `stop_sequence`).
    case complete
    /// Réponse coupée par une limite (`length`, `max_tokens`, `model_context_window_exceeded`).
    case truncated
    /// Le modèle a refusé (`content_filter`, `refusal`).
    case refused
    /// Toute autre raison, connue ou non (appel d'outil, pause, valeur inconnue).
    case other
}

public enum CompletionEvent: Equatable, Sendable {
    /// Morceau de la réponse. Jamais vide.
    case text(String)
    /// Morceau de la réflexion du modèle. Jamais vide.
    case reasoning(String)
    /// La raison d'arrêt annoncée par le serveur : au plus une fois, toujours le dernier événement s'il vient.
    case stop(CompletionStop)
}

public enum CompletionError: Error, Equatable, Sendable {
    /// Rien n'est arrivé pendant le délai d'inactivité de la requête (`URLError.timedOut`). `chatStream` rend la même
    /// panne en `EndpointError.transport`.
    case stalled
    /// Événement `error` d'un flux Anthropic ; `type` est le `error.type` lu (vocabulaire de l'API, jamais montré tel
    /// quel à l'écran), `"inconnu"` s'il manque, et la clé d'API en est retirée.
    case provider(type: String)
}

/// Un modèle de langage qui répond en flux.
///
/// Contrat de fin et d'annulation de `OpenAICompatibleClient.chatStream`, à quoi s'ajoute la raison d'arrêt : le flux
/// se termine normalement seulement quand le serveur a dit que la réponse est finie et qu'au moins un morceau de texte
/// ou de réflexion est arrivé (sans morceau, seule une raison `truncated` ou `refused` suffit : le flux livre alors
/// `.stop` seul) ; toute autre fin est une erreur (`EndpointError`, `CompletionError`), jamais une fin
/// silencieuse. La requête part dès l'appel de `complete`. L'arrêt de la lecture (boucle quittée, tâche annulée) annule
/// la requête ; une tâche consommatrice annulée voit sa boucle se terminer sans erreur : tester `Task.isCancelled`.
/// `.stop` vient au plus une fois et en dernier ; il n'est jamais livré avant une erreur.
public protocol LanguageModel: Sendable {
    func complete(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error>
}
