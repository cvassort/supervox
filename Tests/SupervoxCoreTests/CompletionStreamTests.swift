import Foundation
import Testing
@testable import SupervoxCore

/// Tout ce que le flux a livré, puis l'erreur qui l'a terminé (nil si fin normale).
func collectEvents(_ stream: AsyncThrowingStream<CompletionEvent, Error>) async -> (events: [CompletionEvent], error: (any Error)?) {
    var events: [CompletionEvent] = []
    do {
        for try await event in stream { events.append(event) }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

/// Attend qu'une condition devienne vraie, au plus `seconds` secondes : un test en échec ne bloque jamais la suite.
func waitUntil(seconds: Double = 10, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

let sampleRequest = CompletionRequest(model: "modele-exemple", instruction: "Consigne.", input: "Texte à traiter.", maxTokens: 50)

/// Un flux d'événements compatible OpenAI : une ligne `data:` par objet, puis `[DONE]` si demandé.
private func openAIStream(_ deltas: [String], finish: String? = nil, done: Bool = true) -> String {
    var lines = deltas.map { delta in
        "data: {\"choices\":[{\"index\":0,\"delta\":\(delta),\"finish_reason\":null}]}\n\n"
    }
    if let finish {
        lines.append("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"\(finish)\"}]}\n\n")
    }
    if done { lines.append("data: [DONE]\n\n") }
    return lines.joined()
}

@Suite("CompletionStreamTests", .serialized)
struct CompletionStreamTests {
    // MARK: Requête

    @Test func theBodyIsExactlyTheAnnouncedOne() async throws {
        let client = stubbedClient(status: 200, fixture: "chat-stream-content.sse", baseURL: "https://example.com", apiKey: "cle-test")
        _ = await collectEvents(client.complete(sampleRequest))

        let request = try #require(StubURLProtocol.lastRequest(of: client))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://example.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cle-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        let body = try #require(try JSONSerialization.jsonObject(with: StubURLProtocol.lastBody(of: client)) as? NSDictionary)
        let expected: NSDictionary = [
            "model": "modele-exemple",
            "messages": [["role": "system", "content": "Consigne."], ["role": "user", "content": "Texte à traiter."]],
            "max_tokens": 50,
            "stream": true,
        ]
        #expect(body == expected)
    }

    /// Règle 1 : `messages` = consigne, puis l'historique dans l'ordre, puis `input` (qui reste le dernier message).
    @Test func theHistoryGoesBetweenTheInstructionAndTheInputInOrder() async throws {
        let client = stubbedClient(status: 200, fixture: "chat-stream-content.sse")
        let request = CompletionRequest(
            model: "modele-exemple", instruction: "Consigne.", input: "Dernier message.", maxTokens: 50,
            history: [CompletionTurn(role: .user, text: "Première réponse."),
                      CompletionTurn(role: .assistant, text: "Seconde question ?"),
                      CompletionTurn(role: .user, text: "Seconde réponse."),
                      CompletionTurn(role: .assistant, text: "Troisième question ?")])
        _ = await collectEvents(client.complete(request))

        let body = try #require(try JSONSerialization.jsonObject(with: StubURLProtocol.lastBody(of: client)) as? NSDictionary)
        let expected: NSDictionary = [
            "model": "modele-exemple",
            "messages": [["role": "system", "content": "Consigne."],
                         ["role": "user", "content": "Première réponse."],
                         ["role": "assistant", "content": "Seconde question ?"],
                         ["role": "user", "content": "Seconde réponse."],
                         ["role": "assistant", "content": "Troisième question ?"],
                         ["role": "user", "content": "Dernier message."]],
            "max_tokens": 50,
            "stream": true,
        ]
        #expect(body == expected)
    }

    /// Règle 1 : sans historique, le corps est celui de l'étape 5 (deux messages, mêmes clés).
    @Test func anEmptyHistoryLeavesTheBodyOfStepFiveUnchanged() async throws {
        let client = stubbedClient(status: 200, fixture: "chat-stream-content.sse")
        let request = CompletionRequest(model: "modele-exemple", instruction: "Consigne.", input: "Texte à traiter.", maxTokens: 50, history: [])
        _ = await collectEvents(client.complete(request))

        let body = try #require(try JSONSerialization.jsonObject(with: StubURLProtocol.lastBody(of: client)) as? [String: Any])
        #expect(Set(body.keys) == ["model", "messages", "max_tokens", "stream"])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "Consigne."], ["role": "user", "content": "Texte à traiter."]])
        #expect(CompletionRequest(model: "m", instruction: "i", input: "t", maxTokens: 1).history.isEmpty)
    }

    @Test func everyRequestCarriesTheClientTimeout() async {
        let client = stubbedClient(status: 200, fixture: "chat-stream-content.sse", requestTimeout: 12)
        _ = await collectEvents(client.complete(sampleRequest))
        #expect(StubURLProtocol.lastRequest(of: client)?.timeoutInterval == 12)
    }

    // MARK: Lecture des enregistrements

    @Test func theRecordedContentGivesItsTextsThenTheStop() async {
        let r = await collectEvents(stubbedClient(status: 200, fixture: "chat-stream-content.sse").complete(sampleRequest))
        #expect(r.events == [.text("un"), .text(", deux, trois,"), .text(" quatre, cinq"), .stop(.complete)])
        #expect(r.error == nil)
    }

    /// L'enregistrement dit `length` sur le dernier morceau de réflexion, puis `stop` sur un morceau vide : la première
    /// raison compte (la seconde est un artefact du serveur), sinon une réponse coupée passerait pour complète.
    @Test func theRecordedReasoningGivesItsReasoningThenTheFirstStopReason() async {
        let r = await collectEvents(stubbedClient(status: 200, fixture: "chat-stream-reasoning.sse").complete(sampleRequest))
        #expect(r.events.count == 14)
        #expect(r.events.last == .stop(.truncated))
        #expect(r.events.first == .reasoning("Here"))
        #expect(r.events.dropLast().allSatisfy { if case .reasoning = $0 { true } else { false } })
        #expect(r.error == nil)
    }

    @Test func reasoningComesBeforeTheAnswerAndTheStopComesLast() async {
        let r = await collectEvents(stubbedClient(status: 200, fixture: "completion-openai-reasoning-then-content.sse").complete(sampleRequest))
        #expect(r.events == [
            .reasoning("Je"), .reasoning("' réfléchis"), .reasoning(" d'abord"), .reasoning("\n\n1. Reprendre"),
            .reasoning("\n2. Répondre"), .text("Bonjour"), .text(", tout"), .text(" le monde."), .stop(.complete),
        ])
        #expect(r.error == nil)
    }

    @Test func aTruncatedAnswerEndsWithATruncatedStop() async {
        let r = await collectEvents(stubbedClient(status: 200, fixture: "completion-openai-length.sse").complete(sampleRequest))
        #expect(r.events == [.text("Un"), .text("e réponse"), .text(" coupée"), .stop(.truncated)])
        #expect(r.error == nil)
    }

    // MARK: Raisons d'arrêt

    @Test(arguments: [
        ("stop", CompletionStop.complete), ("length", .truncated), ("content_filter", .refused),
        ("tool_calls", .other), ("function_call", .other), ("inconnue", .other),
    ])
    func finishReasonsMapToStops(reason: String, stop: CompletionStop) async {
        let body = openAIStream(["{\"content\":\"Bon\"}"], finish: reason)
        let r = await collectEvents(stubbedClient(status: 200, body: body).complete(sampleRequest))
        #expect(r.events == [.text("Bon"), .stop(stop)])
        #expect(r.error == nil)
    }

    @Test func aStreamEndingWithDoneButNoFinishReasonDeliversNoStop() async {
        let body = openAIStream(["{\"content\":\"Bon\"}", "{\"content\":\"jour\"}"])
        let r = await collectEvents(stubbedClient(status: 200, body: body).complete(sampleRequest))
        #expect(r.events == [.text("Bon"), .text("jour")])
        #expect(r.error == nil)
    }

    @Test func theStopIsDeliveredOnceEvenWhenTheServerRepeatsTheFinishReason() async {
        // L'enregistrement répète `finish_reason: stop` dans trois morceaux.
        let r = await collectEvents(stubbedClient(status: 200, fixture: "chat-stream-content.sse").complete(sampleRequest))
        #expect(r.events.filter { if case .stop = $0 { true } else { false } }.count == 1)
        #expect(r.events.last == .stop(.complete))
    }

    /// Un `.stop` n'est jamais suivi de rien, et jamais livré avant une erreur : la raison d'arrêt d'un flux qui
    /// finit mal n'a pas de sens.
    @Test func noStopIsDeliveredWhenTheStreamEndsInAnError() async {
        let error = "data: {\"error\":{\"message\":\"surcharge\"}}\n\n"
        let withError = openAIStream(["{\"content\":\"Bon\"}"], finish: "stop", done: false) + error + "data: [DONE]\n\n"
        let a = await collectEvents(stubbedClient(status: 200, body: withError).complete(sampleRequest))
        #expect(a.events == [.text("Bon")])
        #expect(a.error is EndpointError)

        let cut = openAIStream(["{\"content\":\"Bon\"}"], finish: "stop", done: false)
        let b = await collectEvents(stubbedClient(status: 200, body: cut).complete(sampleRequest))
        #expect(b.events == [.text("Bon")])
        #expect(b.error as? EndpointError == .streamInterrupted)
    }

    /// Sans aucun texte ni réflexion, une réponse coupée ou refusée garde sa raison : `.stop` seul, fin normale. Le
    /// consommateur dit alors « coupée » ou « refusée », pas « mal formée ».
    @Test(arguments: [("length", CompletionStop.truncated), ("content_filter", .refused)])
    func aTruncatedOrRefusedAnswerWithoutAnyTextKeepsItsStop(reason: String, stop: CompletionStop) async {
        let r = await collectEvents(stubbedClient(status: 200, body: openAIStream([], finish: reason)).complete(sampleRequest))
        #expect(r.events == [.stop(stop)])
        #expect(r.error == nil)
    }

    /// Les autres raisons (ou aucune) sans texte ne sont pas une réponse : `.malformedResponse`, sans `.stop`.
    @Test(arguments: ["stop", "tool_calls", "inconnue", ""])
    func anyOtherEndWithoutAnyTextIsAMalformedResponseWithoutStop(reason: String) async {
        let body = openAIStream([], finish: reason.isEmpty ? nil : reason)
        let r = await collectEvents(stubbedClient(status: 200, body: body).complete(sampleRequest))
        #expect(r.events.isEmpty)
        #expect(r.error as? EndpointError == .malformedResponse)
    }

    /// `chatStream` ne change pas : il ne livre pas de raison d'arrêt, donc une fin sans texte reste mal formée.
    @Test func chatStreamStillRefusesATruncatedEndWithoutAnyText() async {
        var caught: (any Error)?
        do {
            for try await _ in stubbedClient(status: 200, body: openAIStream([], finish: "length")).chatStream(model: "m", messages: [], maxTokens: 5) {}
        } catch { caught = error }
        #expect(caught as? EndpointError == .malformedResponse)
    }

    // MARK: Découpage du réseau

    @Test(arguments: [1, 2, 7, 64])
    func theReadingDoesNotDependOnHowTheNetworkSlicesTheBody(chunkSize: Int) async {
        let body = fixtureData("completion-openai-reasoning-then-content.sse")
        let r = await collectEvents(stubbedClient(status: 200, body: body, chunkSize: chunkSize).complete(sampleRequest))
        #expect(r.events.count == 9)
        #expect(r.events.first == .reasoning("Je"))
        #expect(r.events.last == .stop(.complete))
        #expect(r.error == nil)
    }

    // MARK: Erreurs

    @Test func silenceIsStalledForCompleteAndTransportForChatStream() async {
        let r = await collectEvents(stubbedClient(failure: .timedOut).complete(sampleRequest))
        #expect(r.events.isEmpty)
        #expect(r.error as? CompletionError == .stalled)

        var chatError: (any Error)?
        do { for try await _ in stubbedClient(failure: .timedOut).chatStream(model: "m", messages: [], maxTokens: 5) {} } catch { chatError = error }
        guard case .transport? = chatError as? EndpointError else {
            Issue.record("attendu .transport, reçu \(String(describing: chatError))"); return
        }
    }

    @Test func otherNetworkFailuresStayTransportErrors() async {
        let r = await collectEvents(stubbedClient(failure: .notConnectedToInternet).complete(sampleRequest))
        guard case .transport? = r.error as? EndpointError else {
            Issue.record("attendu .transport, reçu \(String(describing: r.error))"); return
        }
        let c = await collectEvents(stubbedClient(failure: .cancelled).complete(sampleRequest))
        #expect(c.error is CancellationError)
    }

    @Test func baseURLWithoutSchemeFailsBeforeAnyRequest() async {
        let client = stubbedClient(status: 200, body: "data: [DONE]\n\n", baseURL: "exemple.test")
        let r = await collectEvents(client.complete(sampleRequest))
        guard case .transport? = r.error as? EndpointError else {
            Issue.record("attendu .transport, reçu \(String(describing: r.error))"); return
        }
        #expect(StubURLProtocol.requestCount(of: client) == 0)
    }

    // MARK: Masquage de la clé

    private static let key = "cle-de-test-0123"

    @Test func httpErrorBodiesNeverContainTheKeyEvenAcrossTheCut() async {
        let echoed = "{\"error\":\"Incorrect API key provided: \(Self.key)\"}"
        let a = await collectEvents(stubbedClient(status: 401, body: echoed, apiKey: Self.key).complete(sampleRequest))
        #expect(a.error as? EndpointError == .http(status: 401, body: "{\"error\":\"Incorrect API key provided: ***\"}"))

        let straddling = String(repeating: "x", count: 497) + Self.key + String(repeating: "y", count: 100)
        let b = await collectEvents(stubbedClient(status: 500, body: straddling, apiKey: Self.key).complete(sampleRequest))
        #expect(b.error as? EndpointError == .http(status: 500, body: String(repeating: "x", count: 497) + "***"))
    }

    /// Un message de panne réseau qui répète la clé (un proxy, un système qui recopie l'adresse) ne la montre pas non
    /// plus, coupure à 500 caractères comprise. Égalité exacte : sans masquage, le texte coupé garde `cle` (trois
    /// premiers caractères de la clé) et un simple « ne contient pas la clé » passerait quand même.
    private static var echoingFailure: NSError {
        let text = String(repeating: "x", count: 497) + key + String(repeating: "y", count: 100)
        return NSError(domain: "exemple", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private static let maskedTransportText = String(repeating: "x", count: 497) + "***"

    @Test func completeTransportMessagesNeverContainTheKeyEvenAcrossTheCut() async {
        let r = await collectEvents(stubbedClient(reply: .failureWith(Self.echoingFailure), apiKey: Self.key).complete(sampleRequest))
        #expect(r.error as? EndpointError == .transport(Self.maskedTransportText))
    }

    @Test func chatStreamTransportMessagesNeverContainTheKeyEvenAcrossTheCut() async {
        var caught: (any Error)?
        do {
            for try await _ in stubbedClient(reply: .failureWith(Self.echoingFailure), apiKey: Self.key)
                .chatStream(model: "m", messages: [], maxTokens: 5) {}
        } catch { caught = error }
        #expect(caught as? EndpointError == .transport(Self.maskedTransportText))
    }

    // MARK: Contrat

    @Test func theClientIsUsableThroughTheProtocol() async {
        let model: any LanguageModel = stubbedClient(status: 200, fixture: "chat-stream-content.sse")
        let r = await collectEvents(model.complete(sampleRequest))
        #expect(r.events.last == .stop(.complete))
    }
}
