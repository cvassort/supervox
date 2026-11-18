import Foundation
import SupervoxCore

/// Un entretien conclu, tel que l'historique le garde : la conversation entière, et le prompt qui en est sorti.
///
/// La forme est fixée ici : le magasin sur disque (tâche 11) l'écrit tel quel. `prompt` est `nil` quand le modèle fort n'a pas pu
/// rédiger (`ConversationEnd.conclusionFailed`) : la conversation, elle, est gardée.
public struct InterviewRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var prompt: String?
    public var conversation: Conversation

    public init(id: UUID, date: Date, prompt: String?, conversation: Conversation) {
        self.id = id
        self.date = date
        self.prompt = prompt
        self.conversation = conversation
    }
}

/// Où l'historique des entretiens est gardé. Le contrôleur de l'entretien l'appelle une fois par entretien conclu ; une erreur
/// d'enregistrement n'empêche pas la relecture.
public protocol InterviewHistoryStoring: Sendable {
    func save(_ entry: InterviewRecord) async throws
}

/// Le magasin que l'application reçoit tant que l'historique sur disque n'existe pas (tâche 11) : n'écrit rien.
public struct DiscardingInterviewHistory: InterviewHistoryStoring {
    public init() {}

    public func save(_ entry: InterviewRecord) async throws {}
}
