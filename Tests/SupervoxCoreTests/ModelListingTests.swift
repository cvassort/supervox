import Foundation
import Synchronization
import Testing
@testable import SupervoxCore

// MARK: - Double HTTP propre à cette suite
//
// `StubURLProtocol` rejoue une seule réponse par client et ne fabrique que des `OpenAICompatibleClient`. La liste
// des modèles a besoin d'une session à injecter dans `ModelLister` et, pour la pagination, d'une réponse différente
// à chaque requête. Ce double reprend le principe d'isolation du stub existant : chaque session porte un identifiant
// (en-tête `X-Stub-Id`, posé par la session et non par le code testé) qui retrouve son propre enregistrement.

private final class ListingStub: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case response(status: Int, body: Data)
        case failure(URLError.Code)
    }

    private struct Entry {
        let respond: @Sendable (Int) -> Reply
        var requests: [URLRequest] = []
    }

    static let idHeader = "X-Stub-Id"
    private static let entries = Mutex<[String: Entry]>([:])

    /// Une session dont le « serveur » répond `respond(n)` à la n-ième requête (à partir de 0).
    static func session(respond: @escaping @Sendable (Int) -> Reply) -> (session: URLSession, id: String) {
        let id = UUID().uuidString
        entries.withLock { $0[id] = Entry(respond: respond) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ListingStub.self]
        configuration.httpAdditionalHeaders = [idHeader: id]
        return (URLSession(configuration: configuration), id)
    }

    static func requests(_ id: String) -> [URLRequest] { entries.withLock { $0[id]?.requests ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.idHeader) else {
            fatalError("requête sans \(Self.idHeader) : la session ne vient pas de ListingStub.session")
        }
        let request = request
        let reply = Self.entries.withLock { entries -> Reply in
            guard var entry = entries[id] else { fatalError("aucun enregistrement pour \(id)") }
            let index = entry.requests.count
            entry.requests.append(request)
            entries[id] = entry
            return entry.respond(index)
        }
        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .response(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

/// Un `ModelLister` branché sur le double, et l'identifiant qui permet de relire les requêtes reçues.
private func makeLister(_ kind: ModelListingKind, baseURL: String = "https://exemple.test", apiKey: String = "cle-secrete-test",
                        requestTimeout: TimeInterval = 15,
                        respond: @escaping @Sendable (Int) -> ListingStub.Reply) -> (lister: ModelLister, id: String) {
    let (session, id) = ListingStub.session(respond: respond)
    let config = EndpointConfig(baseURL: URL(string: baseURL)!, apiKey: apiKey)
    return (ModelLister(config: config, kind: kind, session: session, requestTimeout: requestTimeout), id)
}

private func makeLister(_ kind: ModelListingKind, baseURL: String = "https://exemple.test", apiKey: String = "cle-secrete-test",
                        status: Int = 200, body: Data) -> (lister: ModelLister, id: String) {
    makeLister(kind, baseURL: baseURL, apiKey: apiKey) { _ in .response(status: status, body: body) }
}

private func makeLister(_ kind: ModelListingKind, baseURL: String = "https://exemple.test", apiKey: String = "cle-secrete-test",
                        status: Int = 200, fixture: String) -> (lister: ModelLister, id: String) {
    makeLister(kind, baseURL: baseURL, apiKey: apiKey, status: status, body: fixtureData(fixture))
}

private func makeLister(_ kind: ModelListingKind, baseURL: String = "https://exemple.test", apiKey: String = "cle-secrete-test",
                        status: Int = 200, body: String) -> (lister: ModelLister, id: String) {
    makeLister(kind, baseURL: baseURL, apiKey: apiKey, status: status, body: Data(body.utf8))
}

/// Une page de la route de l'autre type d'API.
private func anthropicPage(_ ids: [String], hasMore: Bool, lastID: String?) -> Data {
    let data = ids.map { "{\"id\":\"\($0)\",\"type\":\"model\"}" }.joined(separator: ",")
    let last = lastID.map { "\"\($0)\"" } ?? "null"
    return Data("{\"data\":[\(data)],\"first_id\":\(ids.first.map { "\"\($0)\"" } ?? "null"),\"has_more\":\(hasMore),\"last_id\":\(last)}".utf8)
}

private func queryItems(_ request: URLRequest?) -> [String: String] {
    guard let url = request?.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

private func thrownError(_ body: () async throws -> some Any) async -> (any Error)? {
    do { _ = try await body(); return nil } catch { return error }
}

// MARK: - Tests

@Suite("ModelListingTests", .serialized)
struct ModelListingTests {
    @Test func listsOpenAICompatibleModels() async throws {
        let (lister, id) = makeLister(.openAICompatible, apiKey: "cle-secrete-test", fixture: "models-openai-200.json")
        let models = try await lister.listModels()
        // La fixture range les modèles dans l'ordre c, a, b : le tri fait partie du contrat.
        #expect(models == ["model-a", "model-b", "model-c"])
        let requests = ListingStub.requests(id)
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://exemple.test/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cle-secrete-test")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == nil)
    }

    @Test func openAICompatibleListIsASinglePage() async throws {
        // La documentation de cette route ne décrit aucune pagination : même si le corps ressemble à une page
        // suivante, on ne fait qu'une requête.
        let body = Data("{\"object\":\"list\",\"data\":[{\"id\":\"model-b\"},{\"id\":\"model-a\"}],\"has_more\":true,\"last_id\":\"model-a\"}".utf8)
        let (lister, id) = makeLister(.openAICompatible, body: body)
        #expect(try await lister.listModels() == ["model-a", "model-b"])
        #expect(ListingStub.requests(id).count == 1)
    }

    @Test func listsAnthropicModels() async throws {
        let (lister, id) = makeLister(.anthropic, apiKey: "cle-secrete-test", fixture: "models-anthropic-200.json")
        let models = try await lister.listModels()
        // La fixture range les modèles dans l'ordre y, z, x.
        #expect(models == ["model-x", "model-y", "model-z"])
        let requests = ListingStub.requests(id)
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/v1/models")
        #expect(request.url?.host == "exemple.test")
        #expect(queryItems(request) == ["limit": "1000"])
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "cle-secrete-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func followsPaginationUntilTheEnd() async throws {
        let (lister, id) = makeLister(.anthropic) { index in
            switch index {
            case 0: .response(status: 200, body: anthropicPage(["model-b", "model-a"], hasMore: true, lastID: "model-a"))
            // `model-a` revient sur la page suivante : un doublon entre pages disparaît de la liste.
            default: .response(status: 200, body: anthropicPage(["model-c", "model-a"], hasMore: false, lastID: "model-a"))
            }
        }
        #expect(try await lister.listModels() == ["model-a", "model-b", "model-c"])
        let requests = ListingStub.requests(id)
        #expect(requests.count == 2)
        #expect(queryItems(requests[0])["after_id"] == nil)
        #expect(queryItems(requests[1])["after_id"] == "model-a")
        #expect(queryItems(requests[1])["limit"] == "1000")
        #expect(requests[1].value(forHTTPHeaderField: "x-api-key") == "cle-secrete-test")
        #expect(requests[1].url?.path == "/v1/models")
    }

    @Test func followsAtMostTwentyPages() async throws {
        // Vingt pages exactement, la dernière sans suite : accepté, vingt requêtes.
        let (twenty, twentyID) = makeLister(.anthropic) { index in
            .response(status: 200, body: anthropicPage(["model-\(index)"], hasMore: index < 19, lastID: "model-\(index)"))
        }
        #expect(try await twenty.listModels().count == 20)
        #expect(ListingStub.requests(twentyID).count == 20)

        // Un serveur qui annonce vingt et une pages (fini, pour qu'un plafond retiré échoue au lieu de boucler) :
        // la vingt et unième n'est jamais demandée et l'appel échoue.
        let (twentyOne, twentyOneID) = makeLister(.anthropic) { index in
            .response(status: 200, body: anthropicPage(["model-\(index)"], hasMore: index < 20, lastID: "model-\(index)"))
        }
        let error = await thrownError { try await twentyOne.listModels() }
        #expect(error as? EndpointError == .malformedResponse)
        #expect(ListingStub.requests(twentyOneID).count == 20)
    }

    @Test func paginationThatDoesNotAdvanceIsMalformed() async throws {
        // `has_more` sans `last_id` : impossible de demander la suite.
        let (noCursor, noCursorID) = makeLister(.anthropic, body: anthropicPage(["model-a"], hasMore: true, lastID: nil))
        #expect(await thrownError { try await noCursor.listModels() } as? EndpointError == .malformedResponse)
        #expect(ListingStub.requests(noCursorID).count == 1)

        // Le même curseur renvoyé deux fois : on s'arrête à la deuxième page au lieu de tourner vingt fois.
        let (stuck, stuckID) = makeLister(.anthropic) { _ in
            .response(status: 200, body: anthropicPage(["model-a"], hasMore: true, lastID: "model-a"))
        }
        #expect(await thrownError { try await stuck.listModels() } as? EndpointError == .malformedResponse)
        #expect(ListingStub.requests(stuckID).count == 2)
    }

    @Test func baseURLWithOrWithoutTrailingV1GivesTheSameRoute() async throws {
        let bases: [(String, String)] = [
            ("https://exemple.test", "/v1/models"),
            ("https://exemple.test/", "/v1/models"),
            ("https://exemple.test/v1", "/v1/models"),
            ("https://exemple.test/v1/", "/v1/models"),
            ("https://exemple.test/passerelle", "/passerelle/v1/models"),
            ("https://exemple.test/passerelle/v1", "/passerelle/v1/models"),
            ("https://exemple.test/passerelle/v1/?x=1#frag", "/passerelle/v1/models"),
        ]
        for kind in [ModelListingKind.openAICompatible, .anthropic] {
            for (base, path) in bases {
                let body = kind == .anthropic ? anthropicPage(["model-a"], hasMore: false, lastID: "model-a")
                                              : Data("{\"data\":[{\"id\":\"model-a\"}]}".utf8)
                let (lister, id) = makeLister(kind, baseURL: base, body: body)
                #expect(try await lister.listModels() == ["model-a"], "\(kind) \(base)")
                let url = try #require(ListingStub.requests(id).first?.url)
                #expect(url.path == path, "\(kind) \(base)")
                #expect(url.host == "exemple.test")
                #expect(url.fragment == nil, "\(kind) \(base)")
                // La requête de la base est ignorée ; celle du type d'API (limit) est la seule.
                #expect(queryItems(ListingStub.requests(id).first)["x"] == nil, "\(kind) \(base)")
            }
        }
    }

    @Test func unusableBaseURLIsATransportError() async throws {
        for base in ["ftp://exemple.test", "exemple.test", "https://"] {
            for kind in [ModelListingKind.openAICompatible, .anthropic] {
                let (lister, id) = makeLister(kind, baseURL: base, fixture: "models-openai-200.json")
                guard case .transport? = await thrownError({ try await lister.listModels() }) as? EndpointError else {
                    Issue.record("\(kind) \(base) : attendu .transport"); continue
                }
                #expect(ListingStub.requests(id).isEmpty, "\(base) : aucune requête ne doit partir")
            }
        }
    }

    @Test func listModelsMapsFailures() async throws {
        for kind in [ModelListingKind.openAICompatible, .anthropic] {
            // 401 : le statut et le corps reçus.
            let (denied, _) = makeLister(kind, status: 401, fixture: "models-401.json")
            #expect(await thrownError { try await denied.listModels() } as? EndpointError
                    == .http(status: 401, body: fixtureString("models-401.json")), "\(kind)")

            // Un autre statut d'erreur passe de la même façon.
            let (broken, _) = makeLister(kind, status: 503, body: "Service Unavailable")
            #expect(await thrownError { try await broken.listModels() } as? EndpointError
                    == .http(status: 503, body: "Service Unavailable"), "\(kind)")

            // Hôte injoignable.
            let (unreachable, _) = makeLister(kind) { _ in .failure(.cannotFindHost) }
            guard case .transport? = await thrownError({ try await unreachable.listModels() }) as? EndpointError else {
                Issue.record("\(kind) : hôte injoignable, attendu .transport"); continue
            }

            // Corps 200 sans la forme attendue.
            let malformed = ["{}", "<html><body>Bienvenue</body></html>", "", "[]", "{\"data\":\"model-a\"}",
                             "{\"data\":[{\"name\":\"model-a\"}]}", "{\"data\":[{\"id\":\"\"}]}", "{\"data\":[{\"id\":7}]}", "{\"data\":[\"model-a\"]}"]
            for body in malformed {
                let (lister, _) = makeLister(kind, body: body)
                #expect(await thrownError { try await lister.listModels() } as? EndpointError == .malformedResponse,
                        "\(kind) corps \(body)")
            }

            // Une liste vide est une réponse valide : « aucun modèle ».
            let (empty, _) = makeLister(kind, body: kind == .anthropic ? "{\"data\":[],\"has_more\":false}" : "{\"data\":[]}")
            #expect(try await empty.listModels() == [], "\(kind)")
        }
    }

    @Test func aFailureOnALaterPageFailsTheWholeCall() async throws {
        let (lister, id) = makeLister(.anthropic) { index in
            index == 0 ? .response(status: 200, body: anthropicPage(["model-a"], hasMore: true, lastID: "model-a"))
                       : .response(status: 500, body: Data("boom".utf8))
        }
        #expect(await thrownError { try await lister.listModels() } as? EndpointError == .http(status: 500, body: "boom"))
        #expect(ListingStub.requests(id).count == 2)
    }

    @Test func errorsNeverContainTheKey() async throws {
        let key = "sk-secret-0123456789"
        for kind in [ModelListingKind.openAICompatible, .anthropic] {
            var errors: [any Error] = []
            // Un serveur qui renvoie la clé dans son message d'erreur.
            let (echo, _) = makeLister(kind, apiKey: key, status: 401,
                                       body: "{\"error\":{\"message\":\"Incorrect key \(key) provided\"}}")
            errors.append(await thrownError { try await echo.listModels() }!)
            // La clé à cheval sur la coupure à 500 caractères : masquée avant la troncature, aucun morceau ne reste.
            let (straddling, _) = makeLister(kind, apiKey: key, status: 401, body: String(repeating: "x", count: 490) + key + String(repeating: "y", count: 100))
            errors.append(await thrownError { try await straddling.listModels() }!)
            // Panne réseau, adresse inutilisable, corps 200 inattendu.
            let (down, _) = makeLister(kind, apiKey: key) { _ in .failure(.notConnectedToInternet) }
            errors.append(await thrownError { try await down.listModels() }!)
            let (badBase, _) = makeLister(kind, baseURL: "ftp://utilisateur:motdepasse@exemple.test", apiKey: key, body: "{}")
            errors.append(await thrownError { try await badBase.listModels() }!)
            let (junk, _) = makeLister(kind, apiKey: key, body: "<html>\(key)</html>")
            errors.append(await thrownError { try await junk.listModels() }!)
            // Adresse de base avec identifiants : ni la clé ni l'adresse complète ne sortent dans l'erreur.
            let (userinfo, _) = makeLister(kind, baseURL: "https://utilisateur:motdepasse@exemple.test/v1", apiKey: key) { _ in
                .failure(.cannotFindHost)
            }
            errors.append(await thrownError { try await userinfo.listModels() }!)

            #expect(errors.count == 6)
            for error in errors {
                for text in ["\(error)", String(describing: error), String(reflecting: error), error.localizedDescription] {
                    #expect(!text.contains(key), "\(kind) : la clé apparaît dans \(text.prefix(80))")
                    #expect(!text.contains("0123456789"), "\(kind) : un morceau de la clé apparaît")
                    #expect(!text.contains("motdepasse"), "\(kind) : un identifiant d'adresse apparaît")
                }
            }
            // Le masque remplace la clé, il ne vide pas le corps.
            #expect(errors[0] as? EndpointError == .http(status: 401, body: "{\"error\":{\"message\":\"Incorrect key *** provided\"}}"))
            guard case .http(_, let body)? = errors[1] as? EndpointError else { Issue.record("attendu .http"); continue }
            #expect(body == String(repeating: "x", count: 490) + "***" + String(repeating: "y", count: 7))
            #expect(!body.contains("sk-secret"))
        }
    }

    @Test func credentialsInTheBaseURLAreNotSentAsBasicAuth() async throws {
        let (lister, id) = makeLister(.openAICompatible, baseURL: "https://utilisateur:motdepasse@exemple.test/v1",
                                      fixture: "models-openai-200.json")
        _ = try await lister.listModels()
        let url = try #require(ListingStub.requests(id).first?.url)
        #expect(url.user == nil && url.password == nil)
        #expect(url.absoluteString == "https://exemple.test/v1/models")
    }

    @Test func requestTimeoutIsAppliedToEveryRequest() async throws {
        let (lister, id) = makeLister(.anthropic, requestTimeout: 7) { index in
            .response(status: 200, body: anthropicPage(["model-\(index)"], hasMore: index == 0, lastID: "model-\(index)"))
        }
        _ = try await lister.listModels()
        let requests = ListingStub.requests(id)
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.timeoutInterval == 7 })
        let (defaulted, defaultedID) = makeLister(.openAICompatible, fixture: "models-openai-200.json")
        _ = try await defaulted.listModels()
        #expect(ListingStub.requests(defaultedID).first?.timeoutInterval == 15)
    }

    @Test func aCancelledCallStaysACancellation() async throws {
        let (lister, _) = makeLister(.openAICompatible) { _ in .failure(.cancelled) }
        let error = await thrownError { try await lister.listModels() }
        #expect(error is CancellationError, "reçu \(String(describing: error))")
    }
}
