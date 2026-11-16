import Foundation
import SupervoxCore

/// Un travail de mise en forme : la consigne et le texte tels que `RewritePrompt` les compose, et le modèle du mode.
public struct RewriteJob: Equatable, Sendable {
    /// Part comme consigne système (`RewritePrompt.format`).
    public var instruction: String
    /// Part comme seul message de l'utilisateur ; contient le texte dicté, délimité.
    public var input: String
    /// `nil` : le modèle fort des réglages.
    public var model: ModelChoice?

    public init(instruction: String, input: String, model: ModelChoice?) {
        self.instruction = instruction
        self.input = input
        self.model = model
    }
}

public enum RewriteOutcome: Equatable, Sendable {
    /// Le texte mis en forme, entier et rogné.
    case rewritten(String)
    /// La panne : la phrase qui la dit est `RewriteFailure.message`.
    case failed(RewriteFailure)
    /// La tâche appelante a été annulée : ce n'est pas une panne.
    case cancelled
}

/// Ce que le contrôleur de dictée demande au monde extérieur pour mettre un texte en forme : le modèle de langage, la clé, les
/// réglages. Les tests en donnent un double ; `LiveRewriter` en fabrique le vrai.
public struct RewriteEnvironment: Sendable {
    /// Met `job` en forme. `onText` reçoit le texte visible cumulé à mesure qu'il arrive, toujours avant que cette fonction
    /// rende la main (un texte reçu plus tard serait un défaut de l'environnement : le contrôleur l'ignore).
    public var rewrite: @MainActor (RewriteJob, _ onText: @escaping @MainActor (String) -> Void) async -> RewriteOutcome
    /// Le nom du fournisseur qui recevra le texte, `nil` s'il n'y en a pas (aucun modèle, fournisseur disparu).
    public var providerName: @MainActor (ModelChoice?) -> String?

    public init(
        rewrite: @escaping @MainActor (RewriteJob, _ onText: @escaping @MainActor (String) -> Void) async -> RewriteOutcome,
        providerName: @escaping @MainActor (ModelChoice?) -> String?
    ) {
        self.rewrite = rewrite
        self.providerName = providerName
    }

    /// Aucun modèle de langage dans ce contexte : toute mise en forme échoue faute de modèle.
    public static let unavailable = RewriteEnvironment(
        rewrite: { _, _ in .failed(.noModel) }, providerName: { _ in nil })
}
