import Foundation
import SupervoxCore

/// Ce que le pilote a vu d'un entretien.
struct InterviewTrace: Equatable {
    /// Un tour poussé, avec les durées (secondes) entre la fin de sa voix et trois instants de la réplique.
    struct Turn: Equatable {
        /// Le rang du tour, à partir de 1 (celui du fichier WAV dans la ligne de commande).
        var number: Int
        /// L'entretien a rendu le texte du tour (`.turnEnded`).
        var heard = false
        /// Aucun événement n'a répondu à ce tour dans le délai (`reactionTimeout`) : le fichier n'a sans doute aucune voix.
        var noReaction = false
        var toFirstText: Double?
        var toFirstSentence: Double?
        var toPlayed: Double?
    }

    var turns: [Turn] = []
    /// Les questions posées, au sens du moteur (une question coupée avant d'être entendue ne compte pas).
    var questions = 0
    /// Ce qui avait été entendu de la réplique, à chaque interruption (vide si elle avait été coupée avant la première phrase).
    var interruptions: [String] = []
    var notices: [ConversationNotice] = []
    var concludeSent = false
    /// La fin de l'entretien ; `nil` si le flux s'est arrêté sans l'annoncer.
    var end: ConversationEnd?
}

/// Mène un entretien : pousse les tours du `WavTurnFeed` au rythme des événements de l'entretien, demande la conclusion après le
/// dernier, et note ce qui arrive.
///
/// - **Quand pousser.** Le premier tour, quand l'entretien écoute pour la première fois. Chacun des suivants, au `.state(.listening)`
///   qui suit la fin de la réplique (`.speakingEnded`) ou son remplacement par un avis (`.notice(.notUnderstood)`,
///   `.notice(.modelFailed)`, qui ramènent à l'écoute sans `.speakingEnded`). Jamais sur `.speakingEnded` seul : une réplique de
///   conclusion émet `.speakingEnded` puis `.state(.concluding)`, et le moteur ne reprend pas l'écoute.
/// - **Interruption** (`interruptAfter`) : le tour suivant est poussé `interruptAfter` secondes (attente injectée) après
///   `.speakingStarted`, pendant que la réplique est jouée. Si la réplique finit avant, il est poussé comme sans interruption. Un
///   `.interrupted` n'est pas la fin d'une réplique à attendre : le tour qui l'a causée est déjà en route.
/// - **Conclure.** Quand le prochain tour aurait dû être poussé et qu'il n'y en a plus : `conclude()`, une fois, et seulement si
///   `.state(.concluding)` n'a pas déjà été vu. Jamais juste après le dernier tour : le moteur relit ses drapeaux de fin avant chaque
///   entrée, les tranches encore en file ne seraient pas lues.
/// - **Un tour sans réaction.** Un fichier sans voix ne fait jamais répondre le moteur : au bout de `reactionTimeout` secondes
///   (attente injectée) le tour est noté « sans réaction » et le suivant part.
///
/// Les dates sont lues quand la boucle reçoit l'événement (un instant après son émission) ; « fin de tour » est la date où le
/// `WavTurnFeed` a fini de pousser la voix du tour (`WavTurnFeed.voiceEnd(of:)`), avant le silence qui la suit.
enum InterviewDriver {
    private enum Input: Sendable {
        case event(ConversationEvent)
        case interruptDue(token: Int)
        case reactionTimeout(token: Int)
    }

    private enum Phase {
        /// Rien n'est encore poussé.
        case starting
        /// Un tour est poussé ; le moteur n'en a pas encore rendu le texte.
        case awaitingTurnEnded
        /// Le texte du tour est rendu ; la réplique est attendue.
        case awaitingReplyEnd
        /// La réplique est finie : le prochain `.state(.listening)` pousse le tour suivant (ou conclut).
        case replyDone
    }

    /// - Parameters:
    ///   - reactionTimeout: secondes sans réaction du moteur à un tour poussé avant de le dire « sans réaction ». L'appelant le dérive
    ///     de la limite de temps de transcription du moteur (`InterviewCommand.reactionTimeout(for:)`) : plus court, un moteur lent mais
    ///     dans son droit verrait le tour suivant partir pendant qu'il transcrit encore le précédent.
    ///   - observe: appelé avec chaque événement **après** que le pilote l'a traité (pour les tests).
    ///   - progress: une ligne de français par fait notable (tour poussé, conclusion demandée) ; jamais une valeur d'environnement.
    static func run(
        engine: any ConversationEngine, feed: WavTurnFeed, interruptAfter: Double?, reactionTimeout: Double,
        wait: @escaping @Sendable (Double) async -> Void, now: @escaping @Sendable () -> Double,
        observe: (@Sendable (ConversationEvent) -> Void)? = nil, progress: @Sendable (String) -> Void = { _ in }
    ) async -> InterviewTrace {
        let (inputs, sink) = AsyncStream<Input>.makeStream()
        let events = await engine.start()
        let pump = Task {
            for await event in events { sink.yield(.event(event)) }
            sink.finish()
        }
        defer { pump.cancel() }

        var trace = InterviewTrace()
        var phase = Phase.starting
        var nextTurn = 0
        var concluding = false
        /// Le tour poussé dont le texte n'est pas encore rendu.
        var pendingTurn: Int?
        /// Le tour dont on mesure la réplique : celui dont le texte vient d'être rendu.
        var timingTurn: Int?
        var asked = 0
        var replyCounted = false
        var timer: Task<Void, Never>?
        var token = 0

        func cancelTimer() {
            token += 1
            timer?.cancel()
            timer = nil
        }

        func arm(after seconds: Double, _ input: @escaping @Sendable (Int) -> Input) {
            cancelTimer()
            let mine = token
            timer = Task {
                await wait(seconds)
                if !Task.isCancelled { sink.yield(input(mine)) }
            }
        }

        func pushNext() {
            cancelTimer()
            let index = nextTurn
            nextTurn += 1
            feed.pushTurn(index)
            trace.turns.append(InterviewTrace.Turn(number: index + 1))
            pendingTurn = index
            timingTurn = nil
            phase = .awaitingTurnEnded
            progress("Tour \(index + 1) sur \(feed.turnCount) poussé.")
            arm(after: reactionTimeout) { .reactionTimeout(token: $0) }
        }

        /// Le moment de pousser le tour suivant : ou de conclure, s'il n'y en a plus.
        func advance() async {
            guard !concluding else { return }
            if nextTurn < feed.turnCount {
                pushNext()
            } else if !trace.concludeSent {
                trace.concludeSent = true
                cancelTimer()
                progress("Tous les tours sont poussés : conclusion demandée.")
                await engine.conclude()
            }
        }

        func elapsed(_ turn: Int?) -> Double? {
            guard let turn, let end = feed.voiceEnd(of: turn) else { return nil }
            return now() - end
        }

        loop: for await input in inputs {
            switch input {
            case .interruptDue(let due):
                if due == token, phase == .awaitingReplyEnd { await advance() }
            case .reactionTimeout(let due):
                if due == token, phase == .awaitingTurnEnded, let turn = pendingTurn {
                    trace.turns[turn].noReaction = true
                    pendingTurn = nil
                    phase = .replyDone
                    await advance()
                }
            case .event(let event):
                switch event {
                case .state(.listening):
                    if phase == .starting || phase == .replyDone { await advance() }
                case .state(.concluding):
                    concluding = true
                    cancelTimer()
                case .state(.thinking):
                    replyCounted = false
                case .turnEnded:
                    if let turn = pendingTurn {
                        trace.turns[turn].heard = true
                        timingTurn = turn
                        pendingTurn = nil
                        if phase == .awaitingTurnEnded {
                            cancelTimer()
                            phase = .awaitingReplyEnd
                        }
                    }
                case .replyText:
                    if let turn = timingTurn, trace.turns[turn].toFirstText == nil { trace.turns[turn].toFirstText = elapsed(turn) }
                case .speakingStarted(let question):
                    if let turn = timingTurn, trace.turns[turn].toFirstSentence == nil {
                        trace.turns[turn].toFirstSentence = elapsed(turn)
                    }
                    replyCounted = question > asked
                    if replyCounted { asked = question }
                    if let seconds = interruptAfter, phase == .awaitingReplyEnd, !concluding, nextTurn < feed.turnCount {
                        arm(after: seconds) { .interruptDue(token: $0) }
                    }
                case .sentencePlayed:
                    if let turn = timingTurn, trace.turns[turn].toPlayed == nil { trace.turns[turn].toPlayed = elapsed(turn) }
                case .speakingEnded(let heard):
                    if replyCounted, heard.isEmpty { asked -= 1 }
                    replyCounted = false
                    if phase == .awaitingReplyEnd {
                        cancelTimer()
                        phase = .replyDone
                    }
                case .interrupted(let heard):
                    trace.interruptions.append(heard)
                    if replyCounted, heard.isEmpty { asked -= 1 }
                    replyCounted = false
                    if phase == .awaitingReplyEnd {
                        cancelTimer()
                        phase = .replyDone
                    }
                case .notice(let notice):
                    trace.notices.append(notice)
                    switch notice {
                    case .notUnderstood:
                        if phase == .awaitingTurnEnded, pendingTurn != nil {
                            cancelTimer()
                            pendingTurn = nil
                            phase = .replyDone
                        }
                    case .modelFailed:
                        if phase == .awaitingReplyEnd {
                            cancelTimer()
                            phase = .replyDone
                        }
                    default:
                        break
                    }
                case .finished(let end):
                    trace.end = end
                    observe?(event)
                    break loop
                case .level, .partialTranscript, .state:
                    break
                }
                observe?(event)
            }
        }
        cancelTimer()
        trace.questions = asked
        // Le flux s'est arrêté sans `.finished` (lecteur annulé, moteur disparu) : plus rien ne doit rester en route.
        if trace.end == nil { await engine.cancel() }
        return trace
    }
}
