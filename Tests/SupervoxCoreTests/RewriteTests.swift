import Foundation
import os
import Testing
@testable import SupervoxCore

// Réécriture bornée : le modèle est un double qui rejoue des événements ; la limite de temps est injectée (`TickSleeper`).
// Aucun test n'attend une durée réelle.

/// Les textes que reçoit `onText`, dans l'ordre.
private final class Texts: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [String]())
    func add(_ text: String) { state.withLock { $0.append(text) } }
    var all: [String] { state.withLock { $0 } }
}

private func policy(_ sleeper: TickSleeper = TickSleeper(), maxTokens: Int = 16_000, timeout: Double = 120) -> RewritePolicy {
    RewritePolicy(maxTokens: maxTokens, timeout: timeout, sleep: { try await sleeper.sleep($0) })
}

private func rewrite(_ model: ScriptedModel, policy: RewritePolicy = policy(), texts: Texts = Texts()) async throws -> String {
    try await Rewriter.run(model, model: "modele-exemple", instruction: "consigne", input: "entrée", policy: policy,
                           onText: { texts.add($0) })
}

/// L'échec rendu par `Rewriter.run`, ou `nil` si elle a abouti ou levé autre chose.
private func failure(of model: ScriptedModel, policy: RewritePolicy = policy()) async -> RewriteFailure? {
    do {
        _ = try await rewrite(model, policy: policy)
        return nil
    } catch let failure as RewriteFailure {
        return failure
    } catch {
        return nil
    }
}

@Suite(.timeLimit(.minutes(1)))
struct RewriteTests {
    // MARK: Requête (règle 9)

    @Test func theClientGetsTheModelTheInstructionTheInputAndTheTokenCeilingOfThePolicy() async throws {
        let model = ScriptedModel([.text("ok"), .stop(.complete), .finish])
        _ = try await Rewriter.run(model, model: "modele-exemple", instruction: "la consigne", input: "l'entrée",
                                   policy: policy(maxTokens: 777), onText: { _ in })

        #expect(model.requests == [CompletionRequest(model: "modele-exemple", instruction: "la consigne", input: "l'entrée", maxTokens: 777)])
    }

    /// Règle 1 : `Rewriter.run` transmet `history` tel quel au client, et sans historique la demande est celle d'avant.
    @Test func theHistoryIsPassedToTheClientAsIsAndIsEmptyByDefault() async throws {
        let history = [CompletionTurn(role: .user, text: "Refactorer."), CompletionTurn(role: .assistant, text: "Pourquoi ?")]
        let model = ScriptedModel([.text("ok"), .stop(.complete), .finish])
        _ = try await Rewriter.run(model, model: "modele-exemple", instruction: "la consigne", input: "l'entrée", history: history,
                                   policy: policy(maxTokens: 777), onText: { _ in })
        #expect(model.requests == [CompletionRequest(model: "modele-exemple", instruction: "la consigne", input: "l'entrée",
                                                     maxTokens: 777, history: history)])
        #expect(model.requests[0].history == history)

        let without = ScriptedModel([.text("ok"), .stop(.complete), .finish])
        _ = try await rewrite(without)
        #expect(without.requests[0].history.isEmpty)
    }

    @Test func theStandardPolicyIsSixteenThousandTokensAndTwoMinutes() {
        #expect(RewritePolicy.standard.maxTokens == 16_000)
        #expect(RewritePolicy.standard.timeout == 120)
    }

    // MARK: Seul le texte de réponse est gardé (règle 4)

    @Test func onlyTheResponseTextIsKeptAndOnTextGetsTheAccumulatedVisibleText() async throws {
        let texts = Texts()
        let model = ScriptedModel([
            .reasoning("je réfléchis"), .text("Bon"), .reasoning("encore"), .text("jour "), .text("le monde.\n"), .stop(.complete), .finish,
        ])

        let result = try await rewrite(model, texts: texts)

        #expect(result == "Bonjour le monde.")
        // Un appel par morceau de texte ; le raisonnement n'en provoque aucun et n'apparaît nulle part.
        #expect(texts.all == ["Bon", "Bonjour", "Bonjour le monde."])
        #expect(!texts.all.joined().contains("réfléchis") && !result.contains("encore"))
    }

    @Test func aLeadingThinkBlockIsRemovedAndNothingIsShownBeforeItIsClosed() async throws {
        let texts = Texts()
        let model = ScriptedModel([
            .text("<thi"), .text("nk>il faut d'abord"), .text(" regarder</th"), .text("ink>\n\nBon"), .text("jour"), .finish,
        ])

        let result = try await rewrite(model, texts: texts)

        #expect(result == "Bonjour")
        #expect(texts.all == ["Bon", "Bonjour"])
    }

    @Test func aLeadingThinkingBlockInOneChunkIsRemoved() async throws {
        let texts = Texts()
        let result = try await rewrite(ScriptedModel([.text("<thinking>plan</thinking>Texte final"), .finish]), texts: texts)
        #expect(result == "Texte final")
        #expect(texts.all == ["Texte final"])
    }

    @Test func aLeadingThinkBlockAfterWhitespaceIsRemoved() async throws {
        let result = try await rewrite(ScriptedModel([.text("\n <think>x</think>\nRéponse"), .finish]))
        #expect(result == "Réponse")
    }

    @Test func aThinkBlockClosedByTheOtherTagIsNotClosed() async throws {
        // `<think>` se ferme par `</think>`, pas par `</thinking>` : le bloc reste ouvert, il n'y a donc aucun texte.
        let model = ScriptedModel([.text("<think>a</thinking>b"), .stop(.complete), .finish])
        #expect(await failure(of: model) == .empty)
    }

    @Test func aSimilarTagInTheMiddleOfTheTextIsKept() async throws {
        let text = "Voici <think>une balise</think> au milieu, et <thinking>une autre</thinking>."
        let texts = Texts()
        let result = try await rewrite(ScriptedModel([.text("Voici <thi"), .text(String(text.dropFirst(10))), .finish]), texts: texts)
        #expect(result == text)
    }

    @Test func aTextThatOnlyLooksLikeTheStartOfAThinkTagIsShownAsSoonAsItIsKnownNotToBeOne() async throws {
        let texts = Texts()
        let result = try await rewrite(ScriptedModel([.text("<thin"), .text("g>c'est du texte"), .finish]), texts: texts)
        #expect(result == "<thing>c'est du texte")
        #expect(texts.all == ["<thing>c'est du texte"])
    }

    @Test func aResponseThatEndsOnAnIncompleteTagPrefixKeepsIt() async throws {
        let result = try await rewrite(ScriptedModel([.text("<thi"), .stop(.complete), .finish]))
        #expect(result == "<thi")
    }

    @Test func aThinkBlockThatIsNeverClosedGivesNoText() async {
        #expect(await failure(of: ScriptedModel([.text("<think>je n'en finis pas"), .stop(.complete), .finish])) == .empty)
    }

    @Test func aThinkBlockWithNothingAfterItGivesNoText() async {
        #expect(await failure(of: ScriptedModel([.text("<think>x</think>\n"), .stop(.complete), .finish])) == .empty)
    }

    @Test func aThinkTagInTheReasoningStreamIsNotTheResponse() async throws {
        let result = try await rewrite(ScriptedModel([.reasoning("<think>"), .text("Réponse"), .reasoning("</think>"), .finish]))
        #expect(result == "Réponse")
    }

    /// Un début de balise après un bloc fermé n'est montré qu'une fois fixé : `onText` ne reçoit jamais `<thi` puis un texte qui
    /// ne le prolonge pas. Le second bloc reste dans le texte rendu (le brief ne retire qu'un bloc de tête).
    @Test func aStartOfASecondThinkBlockIsNeverShownAndTheSecondBlockIsKept() async throws {
        let texts = Texts()
        let model = ScriptedModel([.text("<think>a</think>"), .text("<thi"), .text("nk>b</think>Réponse"), .finish])

        let result = try await rewrite(model, texts: texts)

        #expect(result == "<think>b</think>Réponse")
        #expect(texts.all == ["<think>b</think>Réponse"])
    }

    /// La réponse finit sur ce début de balise : `onText` reçoit alors, à la fin, le texte rendu (le dernier appel est le résultat).
    @Test func aResponseThatEndsOnAPendingTagPrefixGivesItToOnTextAtTheEnd() async throws {
        let texts = Texts()
        let result = try await rewrite(ScriptedModel([.text("<think>a</think>"), .text("<thi"), .stop(.complete), .finish]), texts: texts)
        #expect(result == "<thi")
        #expect(texts.all == ["<thi"])
    }

    @Test func theLastTextGivenToOnTextIsTheResult() async throws {
        let texts = Texts()
        let result = try await rewrite(ScriptedModel([.text("Bon"), .text("jour "), .finish]), texts: texts)
        #expect(texts.all.last == result)
    }

    /// Les balises se lisent par scalaires : une marque combinante collée à `>` ne change pas leur sens.
    @Test func aCombiningMarkAfterTheClosingTagDoesNotMakeTheResponseEmpty() async throws {
        #expect(try await rewrite(ScriptedModel([.text("<think>a</think>\u{0301}Réponse"), .finish])) == "\u{0301}Réponse")
        #expect(try await rewrite(ScriptedModel([.text("<think>\u{0301}a</think>Réponse"), .finish])) == "Réponse")
        #expect(try await rewrite(ScriptedModel([.text("<thinking>a</thinking>\u{0301}Réponse"), .finish])) == "\u{0301}Réponse")
    }

    // MARK: Fins (règle 5)

    @Test(arguments: [CompletionStop.complete, .other])
    func aStopReasonThatIsNotATruncationNorARefusalIsASuccess(stop: CompletionStop) async throws {
        #expect(try await rewrite(ScriptedModel([.text(" Texte "), .stop(stop), .finish])) == "Texte")
    }

    @Test func aStreamWithoutAStopReasonIsASuccessWhenThereIsText() async throws {
        #expect(try await rewrite(ScriptedModel([.text("Texte"), .finish])) == "Texte")
    }

    @Test func aTruncatedResponseIsTruncatedEvenWithText() async {
        #expect(await failure(of: ScriptedModel([.text("Début de la répo"), .stop(.truncated), .finish])) == .truncated)
    }

    @Test func aRefusedResponseIsRefusedEvenWithText() async {
        #expect(await failure(of: ScriptedModel([.text("Je ne peux pas"), .stop(.refused), .finish])) == .refused)
    }

    /// Une réponse coupée ou refusée sans aucun texte : le flux ne livre que `.stop`. Ce n'est pas une réponse vide.
    @Test func aStreamOfOnlyATruncatedStopIsTruncatedNotEmpty() async {
        #expect(await failure(of: ScriptedModel([.stop(.truncated), .finish])) == .truncated)
    }

    @Test func aStreamOfOnlyARefusedStopIsRefusedNotEmpty() async {
        #expect(await failure(of: ScriptedModel([.stop(.refused), .finish])) == .refused)
    }

    @Test func aTruncationAfterOnlyReasoningIsTruncatedNotEmpty() async {
        #expect(await failure(of: ScriptedModel([.reasoning("je réfléchis"), .stop(.truncated), .finish])) == .truncated)
    }

    @Test func aBlankOrReasoningOnlyResponseIsEmpty() async {
        #expect(await failure(of: ScriptedModel([.text(" \n\t"), .stop(.complete), .finish])) == .empty)
        #expect(await failure(of: ScriptedModel([.reasoning("je réfléchis"), .reasoning(" encore"), .stop(.complete), .finish])) == .empty)
        #expect(await failure(of: ScriptedModel([.reasoning("je réfléchis"), .finish])) == .empty)
    }

    @Test func nothingIsShownForAResponseThatEndsEmpty() async {
        let texts = Texts()
        _ = try? await rewrite(ScriptedModel([.reasoning("x"), .text("  "), .stop(.complete), .finish]), texts: texts)
        #expect(texts.all.isEmpty)
    }

    // MARK: Erreurs (règle 6)

    private static let failures: [(error: any Error, expected: RewriteFailure)] = [
        (EndpointError.http(status: 401, body: ""), .unauthorized(401)),
        (EndpointError.http(status: 403, body: ""), .unauthorized(403)),
        (EndpointError.http(status: 404, body: ""), .notFound),
        (EndpointError.http(status: 429, body: ""), .rateLimited),
        (EndpointError.http(status: 400, body: ""), .rejected(400)),
        (EndpointError.http(status: 402, body: ""), .rejected(402)),
        (EndpointError.http(status: 413, body: ""), .rejected(413)),
        (EndpointError.http(status: 499, body: ""), .rejected(499)),
        (EndpointError.http(status: 500, body: ""), .server(500)),
        (EndpointError.http(status: 503, body: ""), .server(503)),
        (EndpointError.http(status: 599, body: ""), .server(599)),
        (EndpointError.http(status: 100, body: ""), .malformed),
        (EndpointError.http(status: 200, body: ""), .malformed),
        (EndpointError.http(status: 204, body: ""), .malformed),
        (EndpointError.http(status: 302, body: ""), .malformed),
        (EndpointError.http(status: 399, body: ""), .malformed),
        (EndpointError.transport("panne"), .unreachable),
        (EndpointError.streamInterrupted, .interrupted),
        (EndpointError.crossOriginRedirect, .redirected),
        (EndpointError.malformedResponse, .malformed),
        (EndpointError.missingVariable("X"), .malformed),
        (CompletionError.stalled, .stalled(30)),
        (CompletionError.provider(type: "overloaded_error"), .providerError),
        (TestFailure("autre panne"), .malformed),
        (URLError(.badServerResponse), .malformed),
    ]

    @Test(arguments: failures.indices)
    func anErrorOfTheStreamBecomesItsFixedFailure(index: Int) async {
        let (error, expected) = Self.failures[index]
        #expect(await failure(of: ScriptedModel([.fail(error)])) == expected, "\(error)")
        #expect(RewriteFailure.from(error) == expected, "\(error)")
    }

    @Test func anErrorAfterSomeTextIsStillAFailureAndNeverAPartialResult() async {
        let model = ScriptedModel([.text("Début"), .fail(EndpointError.streamInterrupted)])
        #expect(await failure(of: model) == .interrupted)
    }

    @Test func theStalledDelayIsTheOneOfTheClient() {
        #expect(RewriteFailure.from(CompletionError.stalled) == .stalled(Int(OpenAICompatibleClient.defaultRequestTimeout)))
    }

    @Test func aFailureThatIsAlreadyOneIsKept() {
        #expect(RewriteFailure.from(RewriteFailure.empty) == .empty)
        #expect(RewriteFailure.from(RewriteFailure.timedOut(7)) == .timedOut(7))
    }

    /// Un corps d'erreur qui répète le texte dicté et une adresse, une panne de transport qui cite une adresse : rien de
    /// cela ne paraît dans une phrase.
    @Test func noMessageCarriesTheBodyOfAnErrorNorTheTextOfAFailure() async {
        let dictated = "ma phrase dictée très personnelle"
        let address = "https://example.com/v1/chat/completions"
        let errors: [any Error] = [
            EndpointError.http(status: 400, body: "texte reçu : \(dictated) sur \(address)"),
            EndpointError.http(status: 401, body: "\(dictated) \(address)"),
            EndpointError.http(status: 404, body: "\(dictated) \(address)"),
            EndpointError.http(status: 500, body: "\(dictated) \(address)"),
            EndpointError.http(status: 200, body: "\(dictated) \(address)"),
            EndpointError.transport("\(dictated) \(address)"),
            EndpointError.missingVariable("\(dictated) \(address)"),
            CompletionError.provider(type: "\(dictated) \(address)"),
            TestFailure("\(dictated) \(address)"),
        ]
        for error in errors {
            let failure = await failure(of: ScriptedModel([.fail(error)]))
            let message = failure?.message ?? ""
            #expect(failure != nil)
            #expect(!message.contains(dictated) && !message.contains("example.com") && !message.contains("https"), "\(message)")
        }
    }

    @Test func everyFailureHasItsFixedSentence() {
        let table: [(RewriteFailure, String)] = [
            (.noModel, "Aucun modèle n'est choisi pour ce mode : choisissez-en un dans Réglages, onglet Modes."),
            (.providerMissing, "Le fournisseur choisi pour ce mode n'existe plus : choisissez un autre modèle dans Réglages, onglet Modes."),
            (.noKey(provider: "Mon fournisseur"), "Aucune clé n'est enregistrée pour « Mon fournisseur » : saisissez-la dans Réglages, onglet Fournisseurs (si votre serveur n'en demande pas, saisissez une clé quelconque)."),
            (.keychain, "Le trousseau n'a pas donné la clé du fournisseur : autorisez Supervox dans l'invite du trousseau, puis réessayez."),
            (.unauthorized(401), "La clé a été refusée par le serveur (HTTP 401) : vérifiez-la dans Réglages, onglet Fournisseurs."),
            (.unauthorized(403), "La clé a été refusée par le serveur (HTTP 403) : vérifiez-la dans Réglages, onglet Fournisseurs."),
            (.notFound, "Le serveur ne connaît pas ce modèle ou cette adresse (HTTP 404) : vérifiez le modèle du mode et l'adresse du fournisseur."),
            (.rejected(413), "Le serveur a refusé la demande (HTTP 413) : le modèle choisi n'accepte peut-être pas une réponse aussi longue ; essayez un autre modèle."),
            (.rateLimited, "Le serveur limite les demandes (HTTP 429) : réessayez dans un moment."),
            (.server(503), "Le serveur a rencontré une erreur (HTTP 503) : réessayez plus tard."),
            (.unreachable, "Le serveur est injoignable : vérifiez la connexion et l'adresse du fournisseur."),
            (.redirected, "Le serveur renvoie vers une autre adresse : la clé ne lui a pas été envoyée. Saisissez l'adresse finale dans Réglages, onglet Fournisseurs."),
            (.interrupted, "La réponse du modèle a été interrompue."),
            (.stalled(30), "Le modèle n'a rien envoyé pendant 30 secondes : il réfléchit peut-être longuement ; réessayez, ou choisissez un modèle plus rapide."),
            (.providerError, "Le fournisseur a signalé une erreur pendant la réponse : réessayez dans un moment."),
            (.truncated, "La réponse du modèle a été coupée avant la fin."),
            (.refused, "Le modèle a refusé de traiter ce texte."),
            (.empty, "Le modèle n'a rendu aucun texte."),
            (.timedOut(120), "Le modèle n'a pas répondu en 120 secondes."),
            (.malformed, "La réponse du serveur n'a pas la forme attendue : vérifiez le type du fournisseur (compatible OpenAI ou Anthropic)."),
        ]
        for (failure, sentence) in table { #expect(failure.message == sentence, "\(failure)") }
    }

    // MARK: Délai total (règle 7)

    @Test func theTimerReturningBeforeTheEndOfTheStreamIsATimeoutAndCancelsTheModelStream() async {
        let sleeper = TickSleeper()
        let texts = Texts()
        let model = ScriptedModel([.text("Début")])   // le flux reste ouvert
        let task = Task { try await rewrite(model, policy: policy(sleeper), texts: texts) }
        await model.started.wait()
        await sleeper.waitForSleeps(1)

        sleeper.tick()

        let result = await task.result
        #expect(result.failureValue as? RewriteFailure == .timedOut(120))
        await model.terminated.wait()
        #expect(model.wasCancelled)
        #expect(sleeper.requested == [120])
        #expect(RewriteFailure.timedOut(120).message == "Le modèle n'a pas répondu en 120 secondes.")
    }

    @Test func aTimeoutReportsTheDelayOfThePolicy() async {
        let sleeper = TickSleeper()
        let model = ScriptedModel()
        let task = Task { try await rewrite(model, policy: policy(sleeper, timeout: 45)) }
        await model.started.wait()
        await sleeper.waitForSleeps(1)
        sleeper.tick()
        #expect((await task.result).failureValue as? RewriteFailure == .timedOut(45))
        #expect(sleeper.requested == [45])
    }

    @Test func aStreamThatEndsBeforeTheTimerIsNotTouchedByATimerThatReturnsAfterwards() async throws {
        let sleeper = TickSleeper()
        let model = ScriptedModel([.text("Texte"), .stop(.complete), .finish])

        let result = try await rewrite(model, policy: policy(sleeper))
        sleeper.tick()   // le délai rend après la fin : trop tard

        #expect(result == "Texte")
        #expect(!model.wasCancelled)
        #expect(await eventually { sleeper.cancelled == 1 })   // la minuterie est abandonnée avec la fin du flux
    }

    // MARK: Annulation (règle 8)

    @Test func aCancelledCallerGetsCancellationErrorNeverARewriteFailureAndTheModelStreamIsCancelled() async {
        let model = ScriptedModel([.text("Début")])   // flux ouvert
        let task = Task { try await rewrite(model) }
        await model.started.wait()

        task.cancel()

        let result = await task.result
        #expect(result.failureValue is CancellationError, "\(result)")
        #expect(!(result.failureValue is RewriteFailure))
        await model.terminated.wait()
        #expect(model.wasCancelled)
    }

    /// Le verdict posé, l'appelant annulé avant de reprendre : un succès ne lui est pas rendu. La reprise d'un appelant ne se
    /// commande pas ; la conclusion, appelée par `run` juste après `Deadline.run`, se teste donc depuis une tâche déjà annulée.
    @Test func aCallerCancelledAfterTheVerdictNeverGetsASuccess() async {
        let go = Gate()
        let task = Task { () async throws -> String in
            await go.wait()   // rend la main tout de suite : la tâche est annulée
            return try Rewriter.conclude(Rewriter.Collected(text: "Texte", stop: .complete))
        }
        task.cancel()
        go.open()

        #expect((await task.result).failureValue is CancellationError)
    }

    /// Le flux d'un modèle dont la lecture est annulée se termine normalement, sans erreur (contrat de `LanguageModel`) :
    /// cette fin n'est pas un succès.
    @Test func aLoopThatEndsNormallyBecauseOfACancellationIsNotASuccess() async {
        let model = ScriptedModel([.text("Début de la réponse"), .stop(.complete)])   // flux ouvert, texte déjà reçu
        let request = CompletionRequest(model: "modele-exemple", instruction: "i", input: "e", maxTokens: 10)
        let task = Task { try await Rewriter.collect(model, request, onText: { _ in }) }
        await model.started.wait()

        task.cancel()

        let result = await task.result
        #expect(result.failureValue is CancellationError, "\(result)")
        #expect(model.wasCancelled)
    }
}
