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
        let reply = replies[index]
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

@Suite struct InterviewReportFormatTests {
    @Test func aFenceIsLongerThanAnyRunOfBackticksInsideIt() {
        #expect(InterviewReport.fenced("texte") == "```\ntexte\n```\n")
        #expect(InterviewReport.fenced("a ``` b") == "````\na ``` b\n````\n")
        #expect(InterviewReport.fenced("``````") == "```````\n``````\n```````\n")
    }
}
