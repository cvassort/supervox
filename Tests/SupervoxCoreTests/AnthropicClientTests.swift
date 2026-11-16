import Foundation
import Testing
@testable import SupervoxCore

/// Un flux Anthropic fait à la main : chaque événement est une paire (nom, objet JSON).
private func sse(_ events: [(name: String, json: String)]) -> String {
    events.map { "event: \($0.name)\ndata: \($0.json)\n\n" }.joined()
}

private func textDelta(_ text: String) -> (name: String, json: String) {
    ("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(text)\"}}")
}

private func messageDelta(_ reason: String) -> (name: String, json: String) {
    ("message_delta", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(reason)\"},\"usage\":{\"output_tokens\":3}}")
}

private let messageStop: (name: String, json: String) = ("message_stop", "{\"type\":\"message_stop\"}")
private let messageStart: (name: String, json: String) = (
    "message_start", "{\"type\":\"message_start\",\"message\":{\"id\":\"requete-exemple\",\"type\":\"message\",\"content\":[]}}")

private func anthropicStub(_ reply: StubURLProtocol.Reply, baseURL: String = "https://example.com", apiKey: String = "k",
                           requestTimeout: TimeInterval = OpenAICompatibleClient.defaultRequestTimeout)
    -> (client: AnthropicClient, stub: StubURLProtocol.StubSession)
{
    let stub = StubURLProtocol.makeSession(reply: reply)
    let config = EndpointConfig(baseURL: URL(string: baseURL)!, apiKey: apiKey)
    return (AnthropicClient(config: config, session: stub.session, requestTimeout: requestTimeout), stub)
}

private func anthropic(body: String, status: Int = 200, apiKey: String = "k") -> AnthropicClient {
    anthropicStub(.response(status: status, body: Data(body.utf8)), apiKey: apiKey).client
}

private func anthropic(fixture: String, status: Int = 200, apiKey: String = "k") -> AnthropicClient {
    anthropicStub(.response(status: status, body: fixtureData(fixture)), apiKey: apiKey).client
}

private func anthropic(chunking body: Data, chunkSize: Int) -> AnthropicClient {
    let chunks = stride(from: 0, to: body.count, by: chunkSize).map { Data(body[$0..<min($0 + chunkSize, body.count)]) }
    return anthropicStub(.stream(status: 200, chunks: chunks, end: .finish)).client
}

@Suite("AnthropicClientTests", .serialized)
struct AnthropicClientTests {
    // MARK: Requête

    @Test(arguments: [
        ("https://example.com", "/v1/messages"),
        ("https://example.com/", "/v1/messages"),
        ("https://example.com/v1", "/v1/messages"),
        ("https://example.com/v1/", "/v1/messages"),
        ("https://example.com/prefixe", "/prefixe/v1/messages"),
        ("https://example.com/prefixe/v1/", "/prefixe/v1/messages"),
    ])
    func theRequestGoesToV1MessagesWhateverTheBaseSpelling(base: String, path: String) async throws {
        let (client, stub) = anthropicStub(.response(status: 200, body: fixtureData("messages-anthropic-text.sse")), baseURL: base)
        _ = await collectEvents(client.complete(sampleRequest))
        let request = try #require(stub.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == path)
        #expect(request.url?.host == "example.com")
    }

    /// Des identifiants écrits dans l'adresse ne partent pas avec la requête (la liste des modèles les retire déjà) : la clé ne
    /// voyage que dans l'en-tête prévu.
    @Test func credentialsInTheBaseURLAreNotSentWithTheCompletion() async throws {
        let (client, stub) = anthropicStub(.response(status: 200, body: fixtureData("messages-anthropic-text.sse")),
                                           baseURL: "https://utilisateur:motdepasse@example.com/prefixe")
        _ = await collectEvents(client.complete(sampleRequest))
        let url = try #require(stub.lastRequest?.url)
        #expect(url.user == nil && url.password == nil)
        #expect(url.absoluteString == "https://example.com/prefixe/v1/messages")
    }

    @Test func headersAndBodyAreExactlyTheAnnouncedOnes() async throws {
        let (client, stub) = anthropicStub(.response(status: 200, body: fixtureData("messages-anthropic-text.sse")),
                                           apiKey: "cle-secrete-0123")
        _ = await collectEvents(client.complete(sampleRequest))
        let request = try #require(stub.lastRequest)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "cle-secrete-0123")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == ModelLister.anthropicVersion)
        #expect(ModelLister.anthropicVersion == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == OpenAICompatibleClient.defaultRequestTimeout)

        let object = try #require(try JSONSerialization.jsonObject(with: stub.lastBody) as? [String: Any])
        #expect(Set(object.keys) == ["model", "max_tokens", "system", "messages", "stream"])
        let expected: NSDictionary = [
            "model": "modele-exemple", "max_tokens": 50, "system": "Consigne.",
            "messages": [["role": "user", "content": "Texte à traiter."]], "stream": true,
        ]
        #expect(object as NSDictionary == expected)
    }

    /// Règle 1 : `system` = consigne, `messages` = l'historique dans l'ordre, puis `input`.
    @Test func theHistoryGoesBeforeTheInputInOrderAndTheInstructionStaysTheSystem() async throws {
        let (client, stub) = anthropicStub(.response(status: 200, body: fixtureData("messages-anthropic-text.sse")))
        let request = CompletionRequest(
            model: "modele-exemple", instruction: "Consigne.", input: "Dernier message.", maxTokens: 50,
            history: [CompletionTurn(role: .assistant, text: "Première question ?"),
                      CompletionTurn(role: .user, text: "Première réponse."),
                      CompletionTurn(role: .assistant, text: "Seconde question ?")])
        _ = await collectEvents(client.complete(request))

        let object = try #require(try JSONSerialization.jsonObject(with: stub.lastBody) as? [String: Any])
        let expected: NSDictionary = [
            "model": "modele-exemple", "max_tokens": 50, "system": "Consigne.",
            "messages": [["role": "assistant", "content": "Première question ?"],
                         ["role": "user", "content": "Première réponse."],
                         ["role": "assistant", "content": "Seconde question ?"],
                         ["role": "user", "content": "Dernier message."]],
            "stream": true,
        ]
        #expect(object as NSDictionary == expected)
    }

    /// Règle 1 : sans historique, le corps est celui de l'étape 5 (un seul message, mêmes clés).
    @Test func anEmptyHistoryLeavesTheBodyOfStepFiveUnchanged() async throws {
        let (client, stub) = anthropicStub(.response(status: 200, body: fixtureData("messages-anthropic-text.sse")))
        _ = await collectEvents(client.complete(CompletionRequest(
            model: "modele-exemple", instruction: "Consigne.", input: "Texte à traiter.", maxTokens: 50, history: [])))

        let object = try #require(try JSONSerialization.jsonObject(with: stub.lastBody) as? [String: Any])
        #expect(Set(object.keys) == ["model", "max_tokens", "system", "messages", "stream"])
        #expect(object["messages"] as? [[String: String]] == [["role": "user", "content": "Texte à traiter."]])
    }

    @Test func theKeyIsNeverInTheAddressNorTheBody() async throws {
        let (client, stub) = anthropicStub(.response(status: 200, body: fixtureData("messages-anthropic-text.sse")),
                                           apiKey: "cle-secrete-0123")
        _ = await collectEvents(client.complete(sampleRequest))
        #expect(try #require(stub.lastRequest?.url?.absoluteString).contains("cle-secrete-0123") == false)
        #expect(String(decoding: stub.lastBody, as: UTF8.self).contains("cle-secrete-0123") == false)
    }

    @Test func theRequestTimeoutIsCarriedByTheRequest() async throws {
        let (client, stub) = anthropicStub(.response(status: 200, body: fixtureData("messages-anthropic-text.sse")), requestTimeout: 12)
        _ = await collectEvents(client.complete(sampleRequest))
        #expect(stub.lastRequest?.timeoutInterval == 12)
    }

    // MARK: Lecture

    @Test func theTextFixtureGivesItsTextsThenTheStop() async {
        let r = await collectEvents(anthropic(fixture: "messages-anthropic-text.sse").complete(sampleRequest))
        #expect(r.events == [.text("Bonjour"), .text(", tout"), .text(" le monde."), .stop(.complete)])
        #expect(r.error == nil)
    }

    @Test func thinkingDeltasAreReasoningAndEmptyOnesAreNotDelivered() async {
        let r = await collectEvents(anthropic(fixture: "messages-anthropic-thinking.sse").complete(sampleRequest))
        #expect(r.events == [
            .reasoning("Je"), .reasoning(" réfléchis"), .reasoning(" d'abord."),
            .text("Bonjour"), .text(", tout le monde."), .stop(.complete),
        ])
        #expect(r.error == nil)
    }

    @Test func anEmptyTextDeltaIsNotDelivered() async {
        let body = sse([messageStart, textDelta(""), textDelta("Bon"), messageDelta("end_turn"), messageStop])
        let r = await collectEvents(anthropic(body: body).complete(sampleRequest))
        #expect(r.events == [.text("Bon"), .stop(.complete)])
    }

    @Test(arguments: ["messages-anthropic-text.sse", "messages-anthropic-thinking.sse"], [1, 2, 7, 64])
    func theReadingDoesNotDependOnHowTheNetworkSlicesTheBody(fixture: String, chunkSize: Int) async {
        let whole = await collectEvents(anthropic(fixture: fixture).complete(sampleRequest))
        let sliced = await collectEvents(anthropic(chunking: fixtureData(fixture), chunkSize: chunkSize).complete(sampleRequest))
        #expect(!whole.events.isEmpty)
        #expect(sliced.events == whole.events)
        #expect(sliced.error == nil)
    }

    /// Tout ce qui n'est ni du texte ni de la réflexion est ignoré : signature, ping, début et fin de bloc, delta d'un
    /// autre type, ligne `event:` seule, commentaire, événement inconnu, `stop_reason` nul.
    @Test func everythingElseIsIgnored() async {
        let body = ": commentaire\n\n" + sse([
            messageStart,
            ("content_block_start", "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"),
            ("ping", "{\"type\":\"ping\"}"),
            ("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"abc\"}}"),
            ("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}"),
            ("evenement_inconnu", "{\"type\":\"evenement_inconnu\",\"text\":\"ne pas livrer\"}"),
            textDelta("Bon"),
            ("content_block_stop", "{\"type\":\"content_block_stop\",\"index\":0}"),
            ("message_delta", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":null},\"usage\":{\"output_tokens\":1}}"),
            messageDelta("end_turn"),
            messageStop,
        ]) + "event: sans_donnees\n\n"
        let r = await collectEvents(anthropic(body: body).complete(sampleRequest))
        #expect(r.events == [.text("Bon"), .stop(.complete)])
        #expect(r.error == nil)
    }

    // MARK: Raisons d'arrêt

    @Test(arguments: [
        ("end_turn", CompletionStop.complete), ("stop_sequence", .complete),
        ("max_tokens", .truncated), ("model_context_window_exceeded", .truncated),
        ("refusal", .refused),
        ("tool_use", .other), ("pause_turn", .other), ("inconnue", .other),
    ])
    func stopReasonsMapToStops(reason: String, stop: CompletionStop) async {
        let body = sse([messageStart, textDelta("Bon"), messageDelta(reason), messageStop])
        let r = await collectEvents(anthropic(body: body).complete(sampleRequest))
        #expect(r.events == [.text("Bon"), .stop(stop)])
        #expect(r.error == nil)
    }

    @Test func theMaxTokensFixtureEndsWithATruncatedStop() async {
        let r = await collectEvents(anthropic(fixture: "messages-anthropic-max-tokens.sse").complete(sampleRequest))
        #expect(r.events == [.text("Une réponse"), .text(" coupée"), .stop(.truncated)])
        #expect(r.error == nil)
    }

    @Test func aStreamWithoutStopReasonDeliversNoStop() async {
        let body = sse([messageStart, textDelta("Bon"), messageStop])
        let r = await collectEvents(anthropic(body: body).complete(sampleRequest))
        #expect(r.events == [.text("Bon")])
        #expect(r.error == nil)
    }

    // MARK: Fin du flux

    @Test func messageStopEndsTheStreamAndNothingAfterItIsDelivered() async {
        let late = ("error", "{\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"tard\"}}")
        let body = sse([messageStart, textDelta("Bon"), messageDelta("end_turn"), messageStop, textDelta("jamais"), late])
        let r = await collectEvents(anthropic(body: body).complete(sampleRequest))
        #expect(r.events == [.text("Bon"), .stop(.complete)])
        #expect(r.error == nil)
    }

    @Test func aStreamEndingWithoutMessageStopIsInterruptedAfterTheTextAlreadySent() async {
        let body = sse([messageStart, textDelta("Bon"), textDelta("jour"), messageDelta("end_turn")])
        let r = await collectEvents(anthropic(body: body).complete(sampleRequest))
        #expect(r.events == [.text("Bon"), .text("jour")])
        #expect(r.error as? EndpointError == .streamInterrupted)
    }

    /// Sans aucun texte ni réflexion, une réponse coupée ou refusée garde sa raison : `.stop` seul, fin normale (un refus
    /// avant toute sortie, ou une réflexion non affichée qui a épuisé `max_tokens`).
    @Test(arguments: [
        ("max_tokens", CompletionStop.truncated), ("model_context_window_exceeded", .truncated), ("refusal", .refused),
    ])
    func aTruncatedOrRefusedAnswerWithoutAnyTextKeepsItsStop(reason: String, stop: CompletionStop) async {
        let body = sse([messageStart, messageDelta(reason), messageStop])
        let r = await collectEvents(anthropic(body: body).complete(sampleRequest))
        #expect(r.events == [.stop(stop)])
        #expect(r.error == nil)
    }

    /// Les autres raisons sans texte ne sont pas une réponse : `.malformedResponse`, sans `.stop`.
    @Test(arguments: ["end_turn", "stop_sequence", "tool_use", "pause_turn", "inconnue"])
    func anyOtherEndWithoutAnyTextIsAMalformedResponse(reason: String) async {
        let body = sse([messageStart, messageDelta(reason), messageStop])
        let r = await collectEvents(anthropic(body: body).complete(sampleRequest))
        #expect(r.events.isEmpty)
        #expect(r.error as? EndpointError == .malformedResponse)
    }

    @Test func messageStopWithoutAnyTextNorStopReasonIsAMalformedResponse() async {
        let r = await collectEvents(anthropic(body: sse([messageStart, messageStop])).complete(sampleRequest))
        #expect(r.events.isEmpty)
        #expect(r.error as? EndpointError == .malformedResponse)
    }

    /// Le `.stop` ne vient qu'à `message_stop` : une raison d'arrêt déjà lue (`message_delta`) puis un événement `error`
    /// ne livre aucun `.stop` (la raison d'un flux qui finit mal n'a pas de sens), seulement le texte et l'erreur.
    @Test func noStopIsDeliveredWhenAMessageDeltaIsFollowedByAnErrorEvent() async {
        let error = ("error", "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}")
        let body = sse([messageStart, textDelta("Bon"), messageDelta("end_turn"), error])
        let r = await collectEvents(anthropic(body: body).complete(sampleRequest))
        #expect(r.events == [.text("Bon")])
        #expect(r.error as? CompletionError == .provider(type: "overloaded_error"))
    }

    @Test func anErrorEventEndsTheStreamAfterTheTextAlreadySent() async {
        let r = await collectEvents(anthropic(fixture: "messages-anthropic-error-event.sse").complete(sampleRequest))
        #expect(r.events == [.text("Bon"), .text("jour")])
        #expect(r.error as? CompletionError == .provider(type: "overloaded_error"))
    }

    @Test func aNonStreamBodyIsMalformedAndAnEmptyOneIsInterrupted() async {
        let json = await collectEvents(anthropic(body: "{\"id\":\"requete-exemple\",\"content\":[]}").complete(sampleRequest))
        #expect(json.events.isEmpty)
        #expect(json.error as? EndpointError == .malformedResponse)
        let empty = await collectEvents(anthropic(body: "").complete(sampleRequest))
        #expect(empty.events.isEmpty)
        #expect(empty.error as? EndpointError == .streamInterrupted)
    }

    // MARK: Erreurs HTTP et réseau

    @Test(arguments: [("messages-anthropic-401.json", 401), ("messages-anthropic-529.json", 529)])
    func httpErrorsCarryTheirStatusAndBody(fixture: String, status: Int) async {
        // Une clé d'une lettre serait masquée partout dans le corps : on prend une clé qui n'y figure pas.
        let r = await collectEvents(anthropic(fixture: fixture, status: status, apiKey: "cle-test-0123").complete(sampleRequest))
        #expect(r.events.isEmpty)
        #expect(r.error as? EndpointError == .http(status: status, body: fixtureString(fixture)))
    }

    @Test func silenceIsStalled() async {
        let r = await collectEvents(anthropicStub(.failure(.timedOut)).client.complete(sampleRequest))
        #expect(r.error as? CompletionError == .stalled)
    }

    @Test func otherNetworkFailuresAreTransportErrorsAndCancellationStaysCancellation() async {
        let a = await collectEvents(anthropicStub(.failure(.notConnectedToInternet)).client.complete(sampleRequest))
        guard case .transport? = a.error as? EndpointError else {
            Issue.record("attendu .transport, reçu \(String(describing: a.error))"); return
        }
        let b = await collectEvents(anthropicStub(.failure(.cancelled)).client.complete(sampleRequest))
        #expect(b.error is CancellationError)
    }

    @Test func baseURLWithoutSchemeFailsBeforeAnyRequest() async {
        let (client, stub) = anthropicStub(.response(status: 200, body: Data()), baseURL: "exemple.test")
        let r = await collectEvents(client.complete(sampleRequest))
        guard case .transport? = r.error as? EndpointError else {
            Issue.record("attendu .transport, reçu \(String(describing: r.error))"); return
        }
        #expect(stub.requestCount == 0)
    }

    // MARK: Masquage de la clé

    private static let key = "cle-de-test-0123"

    @Test func httpErrorBodiesNeverContainTheKeyEvenAcrossTheCut() async {
        let echoed = "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key \(Self.key)\"}}"
        let a = await collectEvents(anthropic(body: echoed, status: 401, apiKey: Self.key).complete(sampleRequest))
        #expect(a.error as? EndpointError == .http(
            status: 401, body: echoed.replacingOccurrences(of: Self.key, with: "***")))

        let straddling = String(repeating: "x", count: 497) + Self.key + String(repeating: "y", count: 100)
        let b = await collectEvents(anthropic(body: straddling, status: 500, apiKey: Self.key).complete(sampleRequest))
        #expect(b.error as? EndpointError == .http(status: 500, body: String(repeating: "x", count: 497) + "***"))
    }

    @Test func transportMessagesNeverContainTheKeyEvenAcrossTheCut() async {
        let text = String(repeating: "x", count: 497) + Self.key + String(repeating: "y", count: 100)
        let echoing = NSError(domain: "exemple", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        let (client, _) = anthropicStub(.failureWith(echoing), apiKey: Self.key)
        let r = await collectEvents(client.complete(sampleRequest))
        guard case .transport(let message)? = r.error as? EndpointError else {
            Issue.record("attendu .transport, reçu \(String(describing: r.error))"); return
        }
        #expect(message == String(repeating: "x", count: 497) + "***")
    }

    /// Le type d'une erreur du fournisseur vient du serveur : même lui ne peut pas faire sortir la clé.
    @Test func aProviderErrorTypeNeverContainsTheKey() async {
        let event = ("error", "{\"type\":\"error\",\"error\":{\"type\":\"\(Self.key)\",\"message\":\"x\"}}")
        let body = sse([messageStart, textDelta("Bon"), event])
        let r = await collectEvents(anthropic(body: body, apiKey: Self.key).complete(sampleRequest))
        #expect(r.error as? CompletionError == .provider(type: "***"))
    }

    @Test func anErrorEventWithoutATypeIsAProviderErrorOfUnknownType() async {
        let body = sse([messageStart, textDelta("Bon"), ("error", "{\"type\":\"error\"}")])
        let r = await collectEvents(anthropic(body: body).complete(sampleRequest))
        #expect(r.error as? CompletionError == .provider(type: "inconnu"))
    }
}
