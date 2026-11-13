import Foundation
import Synchronization
import Testing
@testable import SupervoxCore

/// Tout ce que le flux a livré, puis l'erreur qui l'a terminé (nil si fin normale).
private func collect(_ stream: AsyncThrowingStream<ChatDelta, Error>) async -> (deltas: [ChatDelta], error: (any Error)?) {
    var deltas: [ChatDelta] = []
    do {
        for try await d in stream { deltas.append(d) }
        return (deltas, nil)
    } catch {
        return (deltas, error)
    }
}

private func chat(_ client: OpenAICompatibleClient) -> AsyncThrowingStream<ChatDelta, Error> {
    client.chatStream(model: "m", messages: [], maxTokens: 50)
}

// Contenu exact des deux enregistrements (relevé deux fois : `grep -c` sur les lignes `delta":{"reasoning"`
// et analyse JSON des lignes `data:`).
private let recordedContent: [ChatDelta] = [.content("un"), .content(", deux, trois,"), .content(" quatre, cinq")]
private let recordedReasoning: [String] = [
    "Here",
    "'s a thinking process:\n\n1.  **An",
    "alyze User Input:**\n   - **",
    "Language:** French\n   - **Task",
    ":** Count",
    " from one",
    " to five\n   - **Format:** All",
    " in lowercase?",
    " Wait, \"",
    "en toutes lettres\" means \"in",
    " full",
    " words\" (as",
    " opposed",
]

@Suite("ChatStreamTests", .serialized)
struct ChatStreamTests {
    @Test func contentDeltasAreYieldedInOrder() async throws {
        var parts: [ChatDelta] = []
        for try await d in chat(stubbedClient(status: 200, fixture: "chat-stream-content.sse")) { parts.append(d) }
        #expect(parts == recordedContent)
        let text = parts.compactMap { if case .content(let c) = $0 { c } else { nil } }.joined()
        #expect(text == "un, deux, trois, quatre, cinq")
    }

    @Test func reasoningOnlyStreamYieldsNoContent() async throws {
        var parts: [ChatDelta] = []
        for try await d in chat(stubbedClient(status: 200, fixture: "chat-stream-reasoning.sse")) { parts.append(d) }
        #expect(parts == recordedReasoning.map(ChatDelta.reasoning))
        #expect(parts.count == 13)
    }

    @Test func streamCutBeforeDoneThrows() async {
        let cut = "data: {\"choices\":[{\"delta\":{\"content\":\"Bon\"}}]}\n\n"      // pas de [DONE]
        await #expect(throws: EndpointError.streamInterrupted) {
            for try await _ in chat(stubbedClient(status: 200, body: cut)) {}
        }
    }

    @Test func streamIgnoresMalformedLinesAndMapsHTTPError() async throws {
        let body = ": keep-alive\n\ndata: pas du json\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
        var parts: [ChatDelta] = []
        for try await d in chat(stubbedClient(status: 200, body: body)) { parts.append(d) }
        #expect(parts == [.content("ok")])
        await #expect(throws: EndpointError.http(status: 404, body: "introuvable")) {
            for try await _ in chat(stubbedClient(status: 404, body: "introuvable")) {}
        }
    }

    // MARK: Requête

    @Test func requestIsAStreamingChatCompletionWithTheGivenArguments() async throws {
        let client = stubbedClient(status: 200, fixture: "chat-stream-content.sse", baseURL: "https://exemple.test/v1/", apiKey: "cle-de-test-0123")
        let messages = [ChatMessage(role: "system", content: "Réponds en français."), ChatMessage(role: "user", content: "Compte \"jusqu'à\" cinq.")]
        for try await _ in client.chatStream(model: "modele-x", messages: messages, maxTokens: 77) {}

        let request = try #require(StubURLProtocol.lastRequest(of: client))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://exemple.test/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cle-de-test-0123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        let json = try #require(try JSONSerialization.jsonObject(with: StubURLProtocol.lastBody(of: client)) as? [String: Any])
        #expect(Set(json.keys) == ["model", "messages", "max_tokens", "stream"])
        #expect(json["model"] as? String == "modele-x")
        #expect(json["max_tokens"] as? Int == 77)
        #expect(json["stream"] as? Bool == true)
        let sent = try #require(json["messages"] as? [[String: String]])
        #expect(sent == [["role": "system", "content": "Réponds en français."], ["role": "user", "content": "Compte \"jusqu'à\" cinq."]])
    }

    // MARK: Lecture du flux

    /// Le réseau coupe où il veut : au milieu d'une ligne, d'un `\r\n`, d'un caractère. Le résultat ne change pas.
    @Test(arguments: [1, 2, 7, 64, 100_000])
    func recordedStreamsAreReadTheSameWhateverTheChunking(chunkSize: Int) async {
        let content = await collect(chat(stubbedClient(status: 200, body: fixtureData("chat-stream-content.sse"), chunkSize: chunkSize)))
        #expect(content.deltas == recordedContent)
        #expect(content.error == nil)
        let reasoning = await collect(chat(stubbedClient(status: 200, body: fixtureData("chat-stream-reasoning.sse"), chunkSize: chunkSize)))
        #expect(reasoning.deltas == recordedReasoning.map(ChatDelta.reasoning))
        #expect(reasoning.error == nil)
    }

    private func event(_ delta: String) -> String { "{\"choices\":[{\"index\":0,\"delta\":\(delta)}]}" }

    /// `\r\n`, `data:` sans espace, caractères sur plusieurs octets : le tout livré octet par octet, pour que
    /// chaque `\r`, `\n` et chaque caractère soit coupé du suivant.
    @Test(arguments: ["\r\n", "\r", "\n"])
    func lineEndingsAndMissingSpaceAfterColonAreAccepted(eol: String) async {
        let body = ": ping\(eol)\(eol)"
            + "data:\(event("{\"content\":\"é—😀\"}"))\(eol)\(eol)"
            + "data: \(event("{\"reasoning\":\"hm\"}"))\(eol)\(eol)"
            + "data:[DONE]\(eol)\(eol)"
        for chunkSize in [1, 3, 10_000] {
            let r = await collect(chat(stubbedClient(status: 200, body: Data(body.utf8), chunkSize: chunkSize)))
            #expect(r.deltas == [.content("é—😀"), .reasoning("hm")], "eol \(Array(eol.utf8)), morceaux de \(chunkSize)")
            #expect(r.error == nil)
        }
    }

    @Test func lastLinesWithoutFinalNewlineAreStillRead() async {
        let body = "data: \(event("{\"content\":\"a\"}"))\n\ndata: [DONE]"   // ni ligne vide ni \n après [DONE]
        let r = await collect(chat(stubbedClient(status: 200, body: body)))
        #expect(r.deltas == [.content("a")] && r.error == nil)
    }

    @Test func bothReasoningFieldNamesAreAccepted() async {
        let body = [
            "data: \(event("{\"reasoning_content\":\"r1\"}"))",
            "data: \(event("{\"reasoning\":\"r2\"}"))",
            // Les deux champs avec le même texte : un seul morceau, pas un doublon.
            "data: \(event("{\"reasoning_content\":\"r3\",\"reasoning\":\"r3\"}"))",
            // Champ vide ou nul : on prend l'autre.
            "data: \(event("{\"reasoning_content\":\"\",\"reasoning\":\"r4\"}"))",
            "data: \(event("{\"reasoning_content\":null,\"reasoning\":\"r5\"}"))",
            "data: [DONE]", "",
        ].joined(separator: "\n\n")
        let r = await collect(chat(stubbedClient(status: 200, body: body)))
        #expect(r.deltas == ["r1", "r2", "r3", "r4", "r5"].map(ChatDelta.reasoning) && r.error == nil)
    }

    @Test func emptyNullAndMissingTextAreDroppedAndReasoningComesBeforeContentInOneDelta() async {
        let body = [
            "data: \(event("{\"role\":\"assistant\",\"content\":\"\"}"))",
            "data: \(event("{\"content\":null}"))",
            "data: \(event("{}"))",
            "data: \(event("{\"reasoning\":\"pense\",\"content\":\"dit\"}"))",
            "data: [DONE]", "",
        ].joined(separator: "\n\n")
        let r = await collect(chat(stubbedClient(status: 200, body: body)))
        #expect(r.deltas == [.reasoning("pense"), .content("dit")] && r.error == nil)
    }

    /// Ni `choices: []` (chunk d'usage), ni un `finish_reason` n'arrêtent la lecture : seul `[DONE]` le fait.
    /// Le texte qui suit un `finish_reason: "length"` (la passerelle ajoute ensuite un `stop`) est donc livré.
    /// Seul le premier choix est lu : deux choix mêlés donneraient un texte incohérent.
    @Test func usageChunksAndFinishReasonsDoNotStopTheStream() async {
        let body = [
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"a\"},\"finish_reason\":\"length\"}]}",
            "data: {\"choices\":[],\"usage\":{\"total_tokens\":3}}",
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"b\"},\"finish_reason\":\"stop\"},{\"index\":1,\"delta\":{\"content\":\"autre\"}}]}",
            "data: [DONE]", "",
        ].joined(separator: "\n\n")
        let r = await collect(chat(stubbedClient(status: 200, body: body)))
        #expect(r.deltas == [.content("a"), .content("b")] && r.error == nil)
    }

    /// Une réponse venue d'un cache peut arriver d'un seul événement : rôle, texte entier de plusieurs phrases et
    /// `finish_reason` ensemble, puis `[DONE]`. Un seul morceau, le texte intact. (Cas décrit par la consigne ;
    /// il n'est pas dans les fixtures enregistrées : corps fabriqué.)
    @Test func aCachedAnswerArrivingAsOneEventYieldsOneContentDelta() async {
        let text = "Bonjour. Voici la réponse complète ! Elle tient en un seul événement…"
        let body = "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\(text)\"},\"finish_reason\":\"stop\"}]}\n\n"
            + "data: {\"choices\":[],\"usage\":{\"total_tokens\":9}}\n\ndata: [DONE]\n\n"
        let r = await collect(chat(stubbedClient(status: 200, body: body)))
        #expect(r.deltas == [.content(text)] && r.error == nil)
    }

    @Test func nothingAfterDoneIsDelivered() async {
        let body = "data: \(event("{\"content\":\"a\"}"))\n\ndata: [DONE]\n\ndata: \(event("{\"content\":\"fantôme\"}"))\n\n"
        let r = await collect(chat(stubbedClient(status: 200, body: body)))
        #expect(r.deltas == [.content("a")] && r.error == nil)
    }

    // MARK: Fins qui ne sont pas un succès

    @Test(arguments: [
        "data: [DONE]\n\n",
        "data: [1,2]\n\ndata: 42\n\ndata: [DONE]\n\n",     // du JSON, mais pas un objet de chat
        "data: {\"choices\":[{\"delta\":{\"content\":\"\",\"role\":\"assistant\"}}]}\n\ndata: {\"choices\":[],\"usage\":{}}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n",
    ])
    func doneWithoutAnyTextIsNotASuccess(body: String) async {
        let r = await collect(chat(stubbedClient(status: 200, body: body)))
        #expect(r.deltas.isEmpty)
        #expect(r.error as? EndpointError == .malformedResponse)
    }

    @Test func emptyBodyIsAnInterruptedStream() async {
        let r = await collect(chat(stubbedClient(status: 200, body: "")))
        #expect(r.deltas.isEmpty)
        #expect(r.error as? EndpointError == .streamInterrupted)
    }

    @Test func jsonErrorBodyWithStatus200IsReportedWithItsMessage() async {
        let compact = "{\"error\":{\"message\":\"modèle inconnu\",\"type\":\"invalid_request_error\"}}"
        let r1 = await collect(chat(stubbedClient(status: 200, body: compact)))
        #expect(r1.deltas.isEmpty)
        #expect(r1.error as? EndpointError == .http(status: 200, body: compact))

        // Le même objet sur plusieurs lignes, avec fins de ligne `\r\n`.
        let pretty = "{\r\n  \"error\": {\r\n    \"message\": \"modèle inconnu\"\r\n  }\r\n}\r\n"
        let r2 = await collect(chat(stubbedClient(status: 200, body: Data(pretty.utf8), chunkSize: 5)))
        #expect(r2.deltas.isEmpty)
        #expect(r2.error as? EndpointError == .http(status: 200, body: "{\n  \"error\": {\n    \"message\": \"modèle inconnu\"\n  }\n}"))
    }

    /// Un corps 200 qui n'est pas un flux et ne dit pas d'erreur (page HTML d'un mandataire, réponse complète d'un
    /// serveur qui ignore `stream`) n'est pas une réponse exploitable.
    @Test(arguments: [
        "<html><body>Bienvenue</body></html>",
        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Bonjour\"}}]}",
        "{\"error\":null}",
    ])
    func nonStreamBodyWithoutErrorIsMalformed(body: String) async {
        let r = await collect(chat(stubbedClient(status: 200, body: body)))
        #expect(r.deltas.isEmpty)
        #expect(r.error as? EndpointError == .malformedResponse)
    }

    @Test func errorObjectInTheMiddleOfTheStreamEndsItWithAnErrorAfterTheTextAlreadySent() async {
        let payload = "{\"error\":{\"message\":\"surcharge, clé cle-de-test-0123 refusée\"}}"
        let body = "data: \(event("{\"content\":\"Bon\"}"))\n\ndata: \(payload)\n\ndata: \(event("{\"content\":\"jour\"}"))\n\ndata: [DONE]\n\n"
        let r = await collect(chat(stubbedClient(status: 200, body: body, apiKey: "cle-de-test-0123")))
        #expect(r.deltas == [.content("Bon")])
        #expect(r.error as? EndpointError == .http(status: 200, body: payload.replacingOccurrences(of: "cle-de-test-0123", with: "***")))
    }

    @Test func connectionDroppedAfterSomeTextEndsWithATransportError() async {
        let client = hangingClient()
        let received = Mutex<[ChatDelta]>([])
        let consumer = Task { () -> (any Error)? in
            do { for try await d in chat(client) { received.withLock { $0.append(d) } }; return nil } catch { return error }
        }
        #expect(await eventually { received.withLock { $0.count } == 1 })
        StubURLProtocol.dropConnection(of: client, code: .networkConnectionLost)
        let error = await consumer.value
        #expect(received.withLock { $0 } == [.content("Bon")])
        guard case .transport(let message)? = error as? EndpointError else {
            Issue.record("attendu .transport, reçu \(String(describing: error))")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test func failureBeforeAnyResponseIsATransportErrorAndCancellationStaysCancellation() async {
        let r = await collect(chat(stubbedClient(failure: .notConnectedToInternet)))
        #expect(r.deltas.isEmpty)
        guard case .transport? = r.error as? EndpointError else {
            Issue.record("attendu .transport, reçu \(String(describing: r.error))")
            return
        }
        let c = await collect(chat(stubbedClient(failure: .cancelled)))
        #expect(c.error is CancellationError)
    }

    @Test func baseURLWithoutSchemeFailsBeforeAnyRequest() async {
        let client = stubbedClient(status: 200, body: "data: [DONE]\n\n", baseURL: "exemple.test")
        let r = await collect(chat(client))
        guard case .transport? = r.error as? EndpointError else {
            Issue.record("attendu .transport, reçu \(String(describing: r.error))")
            return
        }
        #expect(StubURLProtocol.requestCount(of: client) == 0)
    }

    @Test func aLineBeyondOneMegabyteIsRefusedInsteadOfBufferedForever() async {
        let huge = "data: " + String(repeating: "x", count: (1 << 20) + 10) + "\n\n"
        let r = await collect(chat(stubbedClient(status: 200, body: Data(huge.utf8), chunkSize: 64 * 1024)))
        #expect(r.deltas.isEmpty)
        #expect(r.error as? EndpointError == .malformedResponse)
    }

    // MARK: Erreurs HTTP

    @Test func httpErrorBodyHidesTheKeyAndIsTruncatedTo500Characters() async {
        let echoed = "{\"error\":\"Incorrect API key provided: cle-de-test-0123\"}"
        let e1 = await collect(chat(stubbedClient(status: 401, body: echoed, apiKey: "cle-de-test-0123")))
        #expect(e1.deltas.isEmpty)
        #expect(e1.error as? EndpointError == .http(status: 401, body: "{\"error\":\"Incorrect API key provided: ***\"}"))

        let straddling = String(repeating: "x", count: 497) + "cle-de-test-0123" + String(repeating: "y", count: 100)
        let e2 = await collect(chat(stubbedClient(status: 500, body: straddling, apiKey: "cle-de-test-0123")))
        #expect(e2.error as? EndpointError == .http(status: 500, body: String(repeating: "x", count: 497) + "***"))

        let e3 = await collect(chat(stubbedClient(status: 502, body: String(repeating: "é", count: 600))))
        #expect(e3.error as? EndpointError == .http(status: 502, body: String(repeating: "é", count: 500)))
    }

    // MARK: Annulation

    /// Attend qu'une condition devienne vraie, au plus `seconds` secondes (un test en échec ne doit jamais bloquer la suite).
    private func eventually(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func hangingClient() -> OpenAICompatibleClient {
        let first = Data("data: \(event("{\"content\":\"Bon\"}"))\n\n".utf8)
        return stubbedClient(reply: .stream(status: 200, chunks: [first], end: .hang))
    }

    /// Annuler la tâche qui consomme le flux arrête la requête. À savoir (constaté, imposé par `AsyncThrowingStream`) :
    /// la boucle du consommateur se termine alors SANS erreur, comme une fin normale. Un appelant qui vide ensuite le
    /// découpeur de phrases doit d'abord tester `Task.isCancelled`, sinon il fait dire le reste d'une phrase interrompue.
    @Test func cancellingTheConsumingTaskStopsTheRequest() async {
        let client = hangingClient()
        let received = Mutex<[ChatDelta]>([])
        let consumer = Task { () -> Bool in
            do {
                for try await d in chat(client) { received.withLock { $0.append(d) } }
                return Task.isCancelled    // fin « normale » : le consommateur doit pouvoir voir qu'il est annulé
            } catch { return false }
        }
        #expect(await eventually { received.withLock { $0.count } == 1 })
        #expect(StubURLProtocol.stopLoadingCount(of: client) == 0)    // le serveur se tait mais la requête vit encore
        consumer.cancel()
        #expect(await eventually { StubURLProtocol.stopLoadingCount(of: client) >= 1 })
        #expect(await consumer.value == true)
        #expect(received.withLock { $0 } == [.content("Bon")])
    }

    /// La requête part dès l'appel de `chatStream`, avant toute itération : à savoir pour qui mesure le délai
    /// jusqu'au premier morceau (il commence à l'appel, pas à la première lecture).
    @Test func requestStartsAtCallTimeNotAtFirstIteration() async {
        let client = hangingClient()
        let stream = chat(client)
        #expect(await eventually { StubURLProtocol.requestCount(of: client) == 1 })
        _ = stream
    }

    /// Quitter la boucle (interruption de la parole par l'utilisateur, par exemple) arrête aussi la requête.
    @Test func leavingTheLoopEarlyStopsTheRequest() async throws {
        let client = hangingClient()
        for try await d in chat(client) {
            #expect(d == .content("Bon"))
            break
        }
        #expect(await eventually { StubURLProtocol.stopLoadingCount(of: client) >= 1 })
    }
}
