import Foundation

/// Pourquoi une réécriture par le modèle a échoué. `message` est une phrase fixe, complète, en français : jamais le corps
/// d'une erreur du serveur, jamais le texte d'une panne, jamais le texte dicté.
public enum RewriteFailure: Error, Equatable, Sendable {
    /// Le mode n'a pas de modèle.
    case noModel
    /// Le fournisseur du mode n'existe plus dans les réglages.
    case providerMissing
    /// Aucune clé enregistrée pour ce fournisseur (nom du fournisseur).
    case noKey(provider: String)
    /// Le trousseau n'a pas rendu la clé.
    case keychain
    case unauthorized(Int)
    case notFound
    case rejected(Int)
    case rateLimited
    case server(Int)
    case unreachable
    case redirected
    case interrupted
    /// Rien reçu pendant ce nombre de secondes (le délai d'inactivité du client).
    case stalled(Int)
    case providerError
    case truncated
    case refused
    case empty
    /// Réponse non terminée au bout de ce nombre de secondes (le délai total).
    case timedOut(Int)
    case malformed

    public var message: String {
        switch self {
        case .noModel:
            "Aucun modèle n'est choisi pour ce mode : choisissez-en un dans Réglages, onglet Modes."
        case .providerMissing:
            "Le fournisseur choisi pour ce mode n'existe plus : choisissez un autre modèle dans Réglages, onglet Modes."
        case .noKey(let provider):
            "Aucune clé n'est enregistrée pour « \(provider) » : saisissez-la dans Réglages, onglet Fournisseurs (si votre serveur n'en demande pas, saisissez une clé quelconque)."
        case .keychain:
            "Le trousseau n'a pas donné la clé du fournisseur : autorisez Supervox dans l'invite du trousseau, puis réessayez."
        case .unauthorized(let status):
            "La clé a été refusée par le serveur (HTTP \(status)) : vérifiez-la dans Réglages, onglet Fournisseurs."
        case .notFound:
            "Le serveur ne connaît pas ce modèle ou cette adresse (HTTP 404) : vérifiez le modèle du mode et l'adresse du fournisseur."
        case .rejected(let status):
            "Le serveur a refusé la demande (HTTP \(status)) : le modèle choisi n'accepte peut-être pas une réponse aussi longue ; essayez un autre modèle."
        case .rateLimited:
            "Le serveur limite les demandes (HTTP 429) : réessayez dans un moment."
        case .server(let status):
            "Le serveur a rencontré une erreur (HTTP \(status)) : réessayez plus tard."
        case .unreachable:
            "Le serveur est injoignable : vérifiez la connexion et l'adresse du fournisseur."
        case .redirected:
            "Le serveur renvoie vers une autre adresse : la clé ne lui a pas été envoyée. Saisissez l'adresse finale dans Réglages, onglet Fournisseurs."
        case .interrupted:
            "La réponse du modèle a été interrompue."
        case .stalled(let seconds):
            "Le modèle n'a rien envoyé pendant \(seconds) secondes : il réfléchit peut-être longuement ; réessayez, ou choisissez un modèle plus rapide."
        case .providerError:
            "Le fournisseur a signalé une erreur pendant la réponse : réessayez dans un moment."
        case .truncated:
            "La réponse du modèle a été coupée avant la fin."
        case .refused:
            "Le modèle a refusé de traiter ce texte."
        case .empty:
            "Le modèle n'a rendu aucun texte."
        case .timedOut(let seconds):
            "Le modèle n'a pas répondu en \(seconds) secondes."
        case .malformed:
            "La réponse du serveur n'a pas la forme attendue : vérifiez le type du fournisseur (compatible OpenAI ou Anthropic)."
        }
    }

    /// L'échec que montre une erreur du client. Jamais le texte de l'erreur : seul son genre (et un code HTTP) compte.
    /// Toute erreur inconnue est une réponse mal formée. L'annulation n'est pas une panne : l'appelant la traite avant.
    public static func from(_ error: any Error) -> RewriteFailure {
        switch error {
        case let failure as RewriteFailure:
            return failure
        case let endpoint as EndpointError:
            switch endpoint {
            case .http(let status, _):
                switch status {
                case 401, 403: return .unauthorized(status)
                case 404: return .notFound
                case 429: return .rateLimited
                case 400..<500: return .rejected(status)
                case 500...: return .server(status)
                default: return .malformed   // 1xx, 2xx, 3xx : un statut qui n'est pas une panne de requête
                }
            case .transport: return .unreachable
            case .streamInterrupted: return .interrupted
            case .crossOriginRedirect: return .redirected
            case .malformedResponse, .missingVariable: return .malformed
            }
        case let completion as CompletionError:
            switch completion {
            case .stalled: return .stalled(Int(OpenAICompatibleClient.defaultRequestTimeout.rounded()))
            case .provider: return .providerError
            }
        default:
            return .malformed
        }
    }
}

/// Les bornes d'une réécriture. `sleep` est injectée pour que les tests pilotent le délai.
public struct RewritePolicy: Sendable {
    /// Plafond de jetons de la réponse.
    public var maxTokens: Int
    /// Délai total, en secondes, de la requête à la fin de la réponse.
    public var timeout: Double
    public var sleep: @Sendable (Double) async throws -> Void

    public init(maxTokens: Int, timeout: Double,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.maxTokens = maxTokens
        self.timeout = timeout
        self.sleep = sleep
    }

    /// 16 000 jetons et 120 secondes : choix de conception, non mesurés.
    public static let standard = RewritePolicy(maxTokens: 16_000, timeout: 120)
}

public enum Rewriter {
    /// Réécrit `input` selon `instruction` avec `model`, et rend le texte de la réponse entier, rogné. Le raisonnement du
    /// modèle est écarté, comme un bloc `<think>…</think>` (ou `<thinking>`) en tête de réponse ; `onText` reçoit le texte
    /// visible cumulé à chaque morceau (jamais vide, et rien tant qu'un bloc de tête n'est pas fermé). Lève `RewriteFailure`,
    /// ou `CancellationError` quand la tâche appelante est annulée.
    public static func run(
        _ client: any LanguageModel, model: String, instruction: String, input: String, policy: RewritePolicy,
        onText: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let request = CompletionRequest(model: model, instruction: instruction, input: input, maxTokens: policy.maxTokens)
        let collected: Collected
        do {
            collected = try await Deadline.run(seconds: policy.timeout, sleep: policy.sleep) {
                try await collect(client, request, onText: onText)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is DeadlineExceeded {
            throw RewriteFailure.timedOut(Int(policy.timeout.rounded()))
        } catch {
            throw RewriteFailure.from(error)
        }
        return try conclude(collected)
    }

    /// Le verdict sur une réponse lue jusqu'au bout. Un appelant annulé n'en reçoit jamais un succès : `Deadline` a pu poser le
    /// résultat avant l'annulation, et l'appelant reprend après. La raison d'arrêt passe avant le texte : une réponse coupée ou
    /// refusée sans aucun texte n'est pas « vide ».
    static func conclude(_ collected: Collected) throws -> String {
        try Task.checkCancellation()
        switch collected.stop {
        case .truncated: throw RewriteFailure.truncated
        case .refused: throw RewriteFailure.refused
        case .complete, .other, nil: break
        }
        guard !collected.text.isEmpty else { throw RewriteFailure.empty }
        return collected.text
    }

    struct Collected: Sendable {
        var text: String
        var stop: CompletionStop?
    }

    /// Lit le flux jusqu'au bout. Une tâche annulée voit sa boucle se terminer sans erreur (contrat de `LanguageModel`) :
    /// cette fin n'est pas un succès, elle lève `CancellationError`.
    static func collect(_ client: any LanguageModel, _ request: CompletionRequest,
                        onText: @Sendable (String) -> Void) async throws -> Collected {
        var raw = ""
        var stop: CompletionStop?
        var shown = ""
        for try await event in client.complete(request) {
            try Task.checkCancellation()
            switch event {
            case .text(let chunk):
                raw += chunk
                if let visible = ResponseText.visible(in: raw, isComplete: false), !visible.isEmpty {
                    shown = visible
                    onText(visible)
                }
            case .reasoning:
                break
            case .stop(let reason):
                stop = reason
            }
        }
        try Task.checkCancellation()
        let text = ResponseText.visible(in: raw, isComplete: true) ?? ""
        // Une réponse qui finit sur un début de balise retenu (`<thi`) : le texte rendu n'a pas encore été montré.
        if !text.isEmpty, text != shown { onText(text) }
        return Collected(text: text, stop: stop)
    }
}

/// Le texte visible d'une réponse : sans le bloc de raisonnement `<think>…</think>` (ou `<thinking>…</thinking>`) qui la
/// précède, rogné. Fonction du texte reçu jusque-là : une balise coupée entre deux morceaux ne coûte rien. Lue par scalaires
/// Unicode : une marque combinante collée à `>` n'empêche pas la balise de se fermer.
enum ResponseText {
    private static let blocks = [(open: "<think>", close: "</think>"), (open: "<thinking>", close: "</thinking>")]

    /// `nil` tant que ce qui est à montrer peut encore changer de sens : réponse qui peut commencer par un bloc de
    /// raisonnement (début de balise, ou bloc ouvert non fermé), ou texte qui n'est pour l'instant qu'un début de balise
    /// (`<thi`, y compris après un bloc fermé). `isComplete` : la réponse est finie, ce qui reste est tout ce qu'il y a (un
    /// début de balise est alors du texte, un bloc jamais fermé n'en donne aucun). Un second bloc de suite n'est pas retiré.
    static func visible(in raw: String, isComplete: Bool) -> String? {
        var rest = raw.unicodeScalars.drop(while: { $0.properties.isWhitespace })
        for block in blocks where rest.starts(with: block.open.unicodeScalars) {
            let body = rest.dropFirst(block.open.unicodeScalars.count)
            guard let close = body.firstRange(of: block.close.unicodeScalars) else { return isComplete ? "" : nil }
            rest = body[close.upperBound...].drop(while: { $0.properties.isWhitespace })
            break
        }
        if !isComplete, blocks.contains(where: { $0.open.unicodeScalars.starts(with: rest) }) { return nil }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
