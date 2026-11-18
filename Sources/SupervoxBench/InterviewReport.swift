import Foundation
import Synchronization
import SupervoxCore

// MARK: - Le signal de chaque réplique

/// Enveloppe le modèle rapide pour noter le signal (`[SUITE]`, `[PROPOSER]`, `[CONCLURE]`) que chaque requête a reçu. Aucun événement de
/// l'entretien ne le porte : le moteur le retire du texte dit et montré (`ReplyFilter`). Le texte lu ici est celui du modèle, **avant**
/// ce retrait, passé au même `ReplyFilter` que le moteur : la même règle, pas une copie.
///
/// Le flux est transmis tel quel (texte, réflexion, raison d'arrêt, erreur) ; l'arrêt de la lecture annule la requête, comme pour le
/// flux d'origine.
final class SignalRecordingModel: LanguageModel {
    private let inner: any LanguageModel
    /// Une entrée par requête, dans l'ordre : le signal lu, `nil` tant qu'aucun texte n'est arrivé (ou si aucun n'est jamais venu).
    private let signals = Mutex<[ReplySignal?]>([])

    init(_ inner: any LanguageModel) { self.inner = inner }

    /// Le signal de chaque requête faite au modèle rapide, dans l'ordre.
    var recorded: [ReplySignal?] { signals.withLock { $0 } }

    func complete(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        let index = signals.withLock { signals -> Int in
            signals.append(nil)
            return signals.count - 1
        }
        let source = inner.complete(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var filter = ReplyFilter()
                var raw = ""
                do {
                    for try await event in source {
                        if case .text(let chunk) = event {
                            raw += chunk
                            _ = filter.feed(Self.withoutReasoningBlock(raw))
                            signals.withLock { $0[index] = filter.signal }
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Le texte sans le bloc de raisonnement `<think>…</think>` (ou `<thinking>…</thinking>`) qui le précède : la règle de `Rewriter`
    /// (`ResponseText`, interne au cœur), qui donne au moteur le texte qu'il passe au filtre. Un bloc ouvert non fermé ne donne rien
    /// pour l'instant.
    static func withoutReasoningBlock(_ raw: String) -> String {
        var rest = Substring(raw).drop(while: \.isWhitespace)
        for (open, close) in [("<think>", "</think>"), ("<thinking>", "</thinking>")] where rest.hasPrefix(open) {
            guard let end = rest.range(of: close) else { return "" }
            rest = rest[end.upperBound...].drop(while: \.isWhitespace)
            break
        }
        return String(rest)
    }
}

// MARK: - Ce que le rapport ne doit jamais contenir

/// Retire d'un texte la clé, l'adresse (complète et nom d'hôte) et les noms de modèle de la ligne de commande. Tout ce que la commande
/// écrit (rapport, sortie standard, sortie d'erreur) passe par elle : la conversation y est reproduite, et un modèle peut répéter ce
/// qu'on lui a envoyé.
///
/// Un nom de modèle n'est retiré que **mot entier** (ni précédé ni suivi d'une lettre ou d'un chiffre), casse ignorée : un nom court
/// ne doit pas abîmer les mots ordinaires de la conversation ni du prompt.
func interviewRedactor(_ config: EndpointConfig, names: [String]) -> @Sendable (String) -> String {
    let endpoint = endpointRedactor(config)
    let patterns = names.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.map {
        "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: $0) + "(?![\\p{L}\\p{N}])"
    }
    return { text in
        var out = endpoint(text)
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: "<modèle>", options: [.regularExpression, .caseInsensitive])
        }
        return out
    }
}

// MARK: - Le rapport

/// Ce que l'entretien du banc a donné. **Ni clé, ni adresse, ni nom de modèle** : les modèles sont nommés « rapide » et « fort ».
struct InterviewReport: Equatable {
    var launchedAt: Date
    var turnCount: Int
    var turns: [InterviewTrace.Turn]
    var questions: Int
    /// Le signal de chaque requête au modèle rapide, en mots.
    var replySignals: [String]
    /// Ce qui avait été entendu de la réplique, à chaque interruption.
    var interruptions: [String]
    var notices: [String]
    var conversation: Conversation
    var prompt: String?
    var endReason: String
    var maxQuestions: Int
    var turnSilence: Double
    /// Le silence que le banc pousse après la voix de chaque tour (`WavTurnFeed.trailingSilence`), en secondes.
    var trailingSilence: Double
    /// La limite de temps de transcription du moteur et la marge qui s'y ajoute : leur somme est le délai d'un tour sans réaction.
    var transcriptionLimit: Double
    var reactionMargin: Double
    var interruptAfter: Double?
    var voiceDescription: String

    /// Faux sauf quand l'entretien a rendu un prompt : le code de sortie de la commande en dépend.
    var succeeded: Bool { prompt != nil }

    // MARK: Construction

    init(
        launchedAt: Date, turnCount: Int, trace: InterviewTrace, signals: [ReplySignal?], maxQuestions: Int, turnSilence: Double,
        trailingSilence: Double, transcriptionLimit: Double, reactionMargin: Double, interruptAfter: Double?, voiceDescription: String
    ) {
        self.launchedAt = launchedAt
        self.turnCount = turnCount
        turns = trace.turns
        questions = trace.questions
        replySignals = signals.map(Self.words)
        interruptions = trace.interruptions
        notices = trace.notices.map(Self.words)
        self.maxQuestions = maxQuestions
        self.turnSilence = turnSilence
        self.trailingSilence = trailingSilence
        self.transcriptionLimit = transcriptionLimit
        self.reactionMargin = reactionMargin
        self.interruptAfter = interruptAfter
        self.voiceDescription = voiceDescription
        let ended = Self.read(trace.end)
        conversation = ended.conversation
        prompt = ended.prompt
        endReason = ended.reason
    }

    private static func read(_ end: ConversationEnd?) -> (reason: String, conversation: Conversation, prompt: String?) {
        switch end {
        case .prompt(let text, let conversation)?: ("prompt rédigé", conversation, text)
        case .conclusionFailed(let failure, let conversation)?:
            ("le modèle fort n'a pas rédigé le prompt : \(failure.message)", conversation, nil)
        case .failed(.microphone(let code), let conversation)?: ("panne du micro simulé (code \(code))", conversation, nil)
        case .failed(.engine(let code), let conversation)?: ("panne d'un moteur (code \(code))", conversation, nil)
        case .nothingSaid?: ("rien n'a été dit : aucun tour n'a été entendu", Conversation(), nil)
        case .cancelled?: ("entretien annulé", Conversation(), nil)
        case nil: ("le flux de l'entretien s'est arrêté sans annoncer de fin", Conversation(), nil)
        }
    }

    static func words(_ signal: ReplySignal?) -> String {
        switch signal {
        case .continue?: "suite (une question)"
        case .propose?: "proposition de conclure"
        case .conclude?: "conclusion"
        case nil: "aucun texte reçu"
        }
    }

    static func words(_ notice: ConversationNotice) -> String {
        switch notice {
        case .notUnderstood: "un tour n'a donné aucun texte"
        case .modelFailed(let failure): "le modèle rapide n'a pas répondu : \(failure.message)"
        case .voiceFellBack: "la voix de secours a parlé à la place de la voix choisie"
        case .voiceUnavailable: "aucune voix n'a parlé : les répliques sont restées en texte"
        case .proposal: "l'intervieweur a proposé de conclure"
        case .lastQuestion: "la dernière question a été posée"
        case .lastWordsLost: "les derniers mots n'ont pas pu être transcrits à la conclusion"
        }
    }

    // MARK: Markdown

    func markdown() -> String {
        var text = "# Entretien du banc\n\n"
        text += "> **Lecture des durées.** Les durées de ce rapport ne sont pas comparables aux mesures de latence des étapes précédentes "
            + "(`latency`) : la forme des requêtes est différente (historique de la conversation, consigne de système avec le nombre de "
            + "questions restantes). « Fin de tour » est la date où la dernière voix du fichier WAV a fini d'être poussée, avant le "
            + "silence qui la suit ; la lecture est simulée (aucun haut-parleur) : « fin de lecture simulée » compte la durée réelle du "
            + "clip. Les dates sont lues quand la commande reçoit l'événement. La voix d'un tour et les "
            + "\(Reports.decimal(trailingSilence, digits: 3)) s de silence qui la suivent sont poussées d'un coup, sans attente réelle : "
            + "le silence de fin de tour n'est donc pas dans ces durées (la "
            + "commande n'attend pas ce silence avant la transcription, comme le ferait un micro), et elles comprennent le temps que le "
            + "détecteur et la transcription mettent à rattraper le fichier entier.\n\n"

        text += "## Résumé\n\n"
        text += "- Fin : \(endReason).\n"
        text += "- Tours poussés : \(turns.count) sur \(turnCount) ; textes rendus par la transcription : "
            + "\(turns.filter(\.heard).count).\n"
        text += "- Questions posées : \(questions) (au plus \(maxQuestions)).\n"
        text += "- Signal de chaque réplique du modèle rapide : "
            + (replySignals.isEmpty ? "aucune réplique" : replySignals.joined(separator: " ; ")) + ".\n"
        text += "- Interruptions : \(interruptions.count)"
        if !interruptions.isEmpty {
            text += " (ce qui avait été entendu : "
                + interruptions.map { $0.isEmpty ? "rien" : "« \(Reports.oneLine($0)) »" }.joined(separator: " ; ") + ")"
        }
        text += ".\n"
        text += "- Modèles : « rapide » pour les répliques, « fort » pour la conclusion (noms non reportés).\n"
        text += "- Voix : \(voiceDescription).\n"
        text += "- Silence de fin de tour du détecteur : \(Reports.decimal(turnSilence, digits: 2)) s ; "
        text += interruptAfter.map { "tour suivant poussé \(Reports.decimal($0, digits: 2)) s après le début de la lecture.\n" }
            ?? "tour suivant poussé après la fin de la réplique.\n"
        text += "- Un tour est noté « aucune réaction » : le moteur n'a rien répondu au tour au bout de "
            + "\(Self.duration(transcriptionLimit + reactionMargin)) s, soit la limite de temps de transcription du moteur "
            + "(\(Self.duration(transcriptionLimit)) s) plus une marge de \(Self.duration(reactionMargin)) s.\n"

        text += "\n## Durées par tour (secondes)\n\n"
        text += "| Tour | Fin de tour → premier texte | → première phrase synthétisée | → fin de lecture simulée | Remarque |\n"
        text += "|---|---|---|---|---|\n"
        for turn in turns {
            let note = turn.noReaction ? "aucune réaction du moteur (fichier sans voix ?)" : (turn.heard ? "" : "aucun texte")
            text += "| \(turn.number) | \(Self.seconds(turn.toFirstText)) | \(Self.seconds(turn.toFirstSentence)) | "
                + "\(Self.seconds(turn.toPlayed)) | \(note) |\n"
        }

        if !notices.isEmpty {
            text += "\n## Avis\n\n" + notices.map { "- \($0)\n" }.joined()
        }
        text += "\n## Conversation\n\n"
        text += conversation.turns.isEmpty ? "Aucun tour.\n" : Self.fenced(conversation.transcript)
        if let prompt {
            text += "\n## Prompt\n\n" + Self.fenced(prompt)
        }
        let format = ISO8601DateFormatter()
        format.timeZone = .current
        text += "\n## Lancement\n\n- Date du lancement : \(format.string(from: launchedAt))\n"
        return text
    }

    /// Une durée de réglage en secondes : sans décimale quand elle est entière (« 150 »), à une décimale sinon (« 112,5 »).
    private static func duration(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : Reports.decimal(value, digits: 1)
    }

    private static func seconds(_ value: Double?) -> String {
        value.map { Reports.decimal($0, digits: 2) } ?? "—"
    }

    /// Un bloc de code dont la clôture est plus longue que toute suite d'apostrophes inverses du texte : il ne s'y ferme jamais.
    static func fenced(_ text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\n\(text)\n\(fence)\n"
    }
}
