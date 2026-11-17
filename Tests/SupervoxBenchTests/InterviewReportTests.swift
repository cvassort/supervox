import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxBench

// Le signal de chaque réplique et la mise en forme du rapport de `interview`. Aucun réseau : le modèle est un double.

/// Un modèle dont la n-ième requête rend les événements du n-ième tableau, ou lève l'erreur donnée.
private final class FixedEventsModel: LanguageModel {
    enum Reply {
        case events([CompletionEvent])
        case fail(any Error)
    }

    private let replies: [Reply]
    private let next = Mutex(0)

    init(_ replies: [Reply]) { self.replies = replies }

    func complete(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        let index = next.withLock { next -> Int in
            defer { next += 1 }
            return next
        }
        // Une requête de plus que prévu est une panne du double, pas un plantage du processus de test.
        let reply = replies.indices.contains(index) ? replies[index] : .fail(EndpointError.malformedResponse)
        return AsyncThrowingStream { continuation in
            switch reply {
            case .events(let events):
                for event in events { continuation.yield(event) }
                continuation.finish()
            case .fail(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}

private let anyRequest = CompletionRequest(model: "modele-exemple-rapide", instruction: "consigne", input: "entrée", maxTokens: 10)

private func drain(_ stream: AsyncThrowingStream<CompletionEvent, Error>) async throws -> [CompletionEvent] {
    var events: [CompletionEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

@Suite(.timeLimit(.minutes(1))) struct InterviewSignalTests {
    @Test func theSignalOfEveryRequestIsReadFromTheRawTextAndTheStreamIsPassedOnUnchanged() async throws {
        let sources: [[CompletionEvent]] = [
            // Un marqueur coupé entre deux morceaux.
            [.text("[PRO"), .text("POSER]\nPuis-je "), .text("conclure ?"), .stop(.complete)],
            // Un bloc de raisonnement qui précède le marqueur, fermé dans un autre morceau que celui qui l'ouvre.
            [.reasoning("avant"), .text("<think>je réfléchis"), .text(" longuement</think>\n[CONCLURE]"), .text("\nMerci."), .stop(.complete)],
            // Aucun texte : la requête n'a pas de signal.
            [.stop(.refused)],
            // Un texte sans marqueur : la suite, par défaut.
            [.text("Sans marqueur ?"), .stop(.complete)],
        ]
        let recorder = SignalRecordingModel(FixedEventsModel(sources.map { .events($0) }))

        var received: [[CompletionEvent]] = []
        for _ in sources { received.append(try await drain(recorder.complete(anyRequest))) }

        #expect(received == sources, "le flux doit arriver tel qu'il est parti")
        #expect(recorder.recorded == [.propose, .conclude, nil, .continue])
    }

    @Test func anErrorOfTheModelIsPassedOnAndTheRequestHasNoSignal() async throws {
        let recorder = SignalRecordingModel(FixedEventsModel([.fail(EndpointError.streamInterrupted)]))
        await #expect(throws: EndpointError.streamInterrupted) { try await drain(recorder.complete(anyRequest)) }
        #expect(recorder.recorded == [nil])
    }

    @Test func aReasoningBlockNeverClosedGivesNoVisibleText() {
        #expect(SignalRecordingModel.withoutReasoningBlock("<think>je réfléchis encore") == "")
        #expect(SignalRecordingModel.withoutReasoningBlock("  <thinking>a</thinking>\n[SUITE]\nQuoi ?") == "[SUITE]\nQuoi ?")
        #expect(SignalRecordingModel.withoutReasoningBlock("[SUITE]\nQuoi ?") == "[SUITE]\nQuoi ?")
    }
}

@Suite(.timeLimit(.minutes(1))) struct InterviewRedactionTests {
    private let config = EndpointConfig(baseURL: URL(string: "https://exemple.invalid/v1")!, apiKey: "cle-exemple-secrete")

    @Test func aModelNameIsRemovedAsAWholeWordOnlyAndTheKeyAndTheAddressAlways() {
        let redact = interviewRedactor(config, names: ["rapide", "modele-fort-exemple"])
        // Mot entier, casse ignorée ; jamais au milieu d'un mot ordinaire ni collé à un chiffre ou à une lettre.
        #expect(redact("rapidement et rapide. Rapide, xrapide, rapide2, modele-fort-exemple2 puis modele-fort-exemple")
                == "rapidement et <modèle>. <modèle>, xrapide, rapide2, modele-fort-exemple2 puis <modèle>")
        // La clé et l'adresse partent où qu'elles soient, y compris collées à un mot.
        #expect(redact("clé cle-exemple-secrete sur https://exemple.invalid/v1 ou exemple.invalid") == "clé *** sur <endpoint> ou <endpoint>")
        #expect(redact("xcle-exemple-secretex") == "x***x")
    }

    @Test func aNameWithRegularExpressionCharactersIsTakenLiterally() {
        let redact = interviewRedactor(config, names: ["modele.v2+(a|b)"])
        #expect(redact("modele.v2+(a|b) et modeleXv2+(a|b)") == "<modèle> et modeleXv2+(a|b)")
    }

    @Test func theLongestNameIsRemovedFirst() {
        let redact = interviewRedactor(config, names: ["voix", "modele-voix-exemple"])
        #expect(redact("modele-voix-exemple et voix") == "<modèle> et <modèle>")
    }
}

@Suite(.timeLimit(.minutes(1))) struct InterviewReportFormatTests {
    @Test func aFenceIsLongerThanAnyRunOfBackticksInsideIt() {
        #expect(InterviewReport.fenced("texte") == "```\ntexte\n```\n")
        #expect(InterviewReport.fenced("a ``` b") == "````\na ``` b\n````\n")
        #expect(InterviewReport.fenced("``````") == "```````\n``````\n```````\n")
    }
}
