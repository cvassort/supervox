import Foundation
import Synchronization
@testable import SupervoxCore

/// Rejoue un statut et un corps (ou une erreur réseau) et garde la dernière requête reçue, corps compris.
/// Remplace un serveur local : les réponses rejouées sont des enregistrements réels (voir `Fixtures/endpoint`).
///
/// L'état est statique et partagé : toute suite qui s'en sert doit être `.serialized`, et deux suites qui s'en
/// servent peuvent se marcher dessus, car `.serialized` n'ordonne que les tests d'une même suite.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case response(status: Int, body: Data)
        case failure(URLError.Code)
    }

    private struct State {
        var reply: Reply = .response(status: 200, body: Data())
        var lastRequest: URLRequest?
        var lastBody = Data()
    }

    private static let state = Mutex(State())

    static var lastRequest: URLRequest? { state.withLock { $0.lastRequest } }
    static var lastBody: Data { state.withLock { $0.lastBody } }

    static func reset(reply: Reply) {
        state.withLock { $0 = State(reply: reply) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // Dans un URLProtocol, le corps d'une requête arrive par `httpBodyStream`, pas par `httpBody`.
        let body = Self.readBody(of: request)
        let reply = Self.state.withLock { state -> Reply in
            state.lastRequest = request
            state.lastBody = body
            return state.reply
        }
        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private static func readBody(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func client(reply: StubURLProtocol.Reply, baseURL: String, apiKey: String) -> OpenAICompatibleClient {
    StubURLProtocol.reset(reply: reply)
    let config = EndpointConfig(baseURL: URL(string: baseURL)!, apiKey: apiKey)
    return OpenAICompatibleClient(config: config, session: stubbedSession())
}

/// Client dont le « serveur » répond `status` avec le contenu du fichier enregistré `fixture`.
func stubbedClient(status: Int, fixture: String, baseURL: String = "https://exemple.test", apiKey: String = "k") -> OpenAICompatibleClient {
    client(reply: .response(status: status, body: fixtureData(fixture)), baseURL: baseURL, apiKey: apiKey)
}

/// Client dont le « serveur » répond `status` avec le corps `body`.
func stubbedClient(status: Int, body: String, baseURL: String = "https://exemple.test", apiKey: String = "k") -> OpenAICompatibleClient {
    client(reply: .response(status: status, body: Data(body.utf8)), baseURL: baseURL, apiKey: apiKey)
}

/// Client dont la requête échoue au niveau réseau, sans réponse HTTP.
func stubbedClient(failure code: URLError.Code, baseURL: String = "https://exemple.test") -> OpenAICompatibleClient {
    client(reply: .failure(code), baseURL: baseURL, apiKey: "k")
}

/// Contenu d'un fichier de `Fixtures/endpoint`. Un fichier absent fait échouer le test : jamais de corps vide silencieux.
func fixtureData(_ name: String) -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/endpoint"),
          let data = try? Data(contentsOf: url), !data.isEmpty
    else { fatalError("fixture absente ou vide : \(name)") }
    return data
}

func fixtureString(_ name: String) -> String { String(decoding: fixtureData(name), as: UTF8.self) }
