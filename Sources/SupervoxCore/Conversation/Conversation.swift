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
    /// personne, `assistant` pour l'intervieweur). `nil` si le dernier tour n'est pas celui de la personne (rien à répondre).
    public func completion() -> (history: [CompletionTurn], input: String)? {
        guard let last = turns.last, last.speaker == .user else { return nil }
        let history = turns.dropLast().map { turn in
            CompletionTurn(role: turn.speaker == .user ? .user : .assistant, text: turn.text)
        }
        return (history, last.text)
    }

    /// Un paragraphe par tour, « Vous : » ou « Supervox : » puis le texte, séparés par une ligne vide. C'est ce que lit le
    /// modèle fort pour rédiger le prompt final, et ce que montre la relecture.
    public var transcript: String {
        turns.map { ($0.speaker == .user ? "Vous : " : "Supervox : ") + $0.text }.joined(separator: "\n\n")
    }
}
