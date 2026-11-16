import Foundation

/// Un tour de l'entretien : ce que dit la personne, ou ce que dit l'intervieweur.
public struct ConversationTurn: Codable, Equatable, Sendable {
    public enum Speaker: String, Codable, Sendable {
        case user, interviewer
    }

    public var speaker: Speaker
    public var text: String

    public init(speaker: Speaker, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

/// La conversation d'un entretien : des tours qui alternent entre la personne et l'intervieweur. Deux ajouts de suite du même
/// côté ne font qu'un tour (le texte s'allonge, d'une espace), ce qui garde l'alternance que les API de messages exigent ; un
/// texte vide une fois rogné n'ajoute rien.
public struct Conversation: Codable, Equatable, Sendable {
    public private(set) var turns: [ConversationTurn]

    /// Le message de la personne placé devant l'historique quand l'intervieweur a parlé le premier : les API de messages
    /// attendent un premier message de la personne.
    public static let openingUserMessage = "Commence l'entretien."

    public init(turns: [ConversationTurn] = []) {
        self.turns = turns
    }

    public mutating func appendUser(_ text: String) { append(text, by: .user) }

    public mutating func appendInterviewer(_ text: String) { append(text, by: .interviewer) }

    private mutating func append(_ text: String, by speaker: ConversationTurn.Speaker) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let last = turns.indices.last, turns[last].speaker == speaker {
            turns[last].text += " " + trimmed
        } else {
            turns.append(ConversationTurn(speaker: speaker, text: trimmed))
        }
    }

    /// Le nombre de tours de la personne (les tours fusionnés comptent pour un).
    public var userTurnCount: Int { turns.filter { $0.speaker == .user }.count }

    public var hasUserTurn: Bool { turns.contains { $0.speaker == .user } }

    /// Ce que reçoit le modèle : le dernier tour de la personne en `input`, tout ce qui précède en historique (`user` pour la
    /// personne, `assistant` pour l'intervieweur). Les API de messages demandent une alternance stricte qui commence par la
    /// personne ; ce qui part est donc **normalisé** (les tours restent tels quels dans `turns` et dans `transcript`, c'est la
    /// seule requête qui change) : un texte vide une fois rogné est écarté, deux tours de même rôle de suite sont fusionnés
    /// (séparés par une ligne vide), et si l'intervieweur a parlé le premier, `openingUserMessage` est placé devant. Aucun
    /// texte n'est perdu. `nil` si le dernier tour n'est pas celui de la personne (rien à répondre), ou s'il n'y a aucun tour.
    public func completion() -> (history: [CompletionTurn], input: String)? {
        var messages: [CompletionTurn] = []
        for turn in turns {
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let role: CompletionRole = turn.speaker == .user ? .user : .assistant
            if let last = messages.indices.last, messages[last].role == role {
                messages[last].text += "\n\n" + text
            } else {
                messages.append(CompletionTurn(role: role, text: text))
            }
        }
        guard let last = messages.popLast(), last.role == .user else { return nil }
        if messages.first?.role == .assistant {
            messages.insert(CompletionTurn(role: .user, text: Self.openingUserMessage), at: 0)
        }
        return (messages, last.text)
    }

    /// Un paragraphe par tour, « Vous : » ou « Supervox : » puis le texte, séparés par une ligne vide. C'est ce que lit le
    /// modèle fort pour rédiger le prompt final, et ce que montre la relecture.
    public var transcript: String {
        turns.map { ($0.speaker == .user ? "Vous : " : "Supervox : ") + $0.text }.joined(separator: "\n\n")
    }
}
