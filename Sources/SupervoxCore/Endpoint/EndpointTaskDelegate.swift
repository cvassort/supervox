import Foundation
import Synchronization

/// Origine d'une adresse : schéma et hôte en minuscules, port explicite ou port par défaut du schéma.
struct EndpointOrigin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL?) {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let defaultPort: Int? = switch scheme {
        case "https": 443
        case "http": 80
        default: nil
        }
        guard let port = components.port ?? defaultPort else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
    }
}

/// Délégué propre à une tâche qui porte une clé.
///
/// Redirections : une redirection vers la même origine que la requête d'origine est suivie, avec les en-têtes de clé
/// de la requête d'origine (mesuré : CFNetwork retire `Authorization` d'une requête redirigée, même vers la même
/// origine). Une redirection vers une autre origine n'est pas suivie : rien ne part vers elle, et `refusedRedirect`
/// le dit à l'appelant, qui lève `EndpointError.crossOriginRedirect`.
///
/// Mesures : relève la connexion qui a porté la requête (`URLSessionTaskMetrics`, dernière transaction).
final class EndpointTaskDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    /// En-têtes qui portent une clé : recopiés sur une redirection de même origine.
    static let keyHeaders = ["Authorization", "x-api-key"]

    private struct State {
        var refusedRedirect = false
        var connection: ConnectionInfo?
    }

    private let state = Mutex(State())

    var refusedRedirect: Bool { state.withLock { $0.refusedRedirect } }
    var connection: ConnectionInfo? { state.withLock { $0.connection } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let original = task.originalRequest, let from = EndpointOrigin(original.url),
              let to = EndpointOrigin(request.url), from == to
        else {
            state.withLock { $0.refusedRedirect = true }
            return nil
        }
        var next = request
        for name in Self.keyHeaders where next.value(forHTTPHeaderField: name) == nil {
            if let value = original.value(forHTTPHeaderField: name) { next.setValue(value, forHTTPHeaderField: name) }
        }
        return next
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last else { return }
        let info = ConnectionInfo(networkProtocol: last.networkProtocolName, reused: last.isReusedConnection)
        state.withLock { $0.connection = info }
    }
}
