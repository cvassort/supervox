import Foundation
import SupervoxCore
import Testing

@testable import SupervoxApp

@Suite(.timeLimit(.minutes(1))) struct InterviewRecordTests {
    /// Une conversation de quatre tours qui alternent (deux ajouts du même côté ne feraient qu'un tour).
    static func conversation() throws -> Conversation {
        var conversation = Conversation()
        conversation.appendInterviewer("Que voulez-vous construire ?")
        conversation.appendUser("Un outil d'exemple, en ligne de commande.")
        conversation.appendInterviewer("Pour qui ?")
        conversation.appendUser("Pour moi, et deux collègues d'exemple.")
        try #require(conversation.turns.count == 4, "les tours devaient alterner")
        return conversation
    }

    static let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    /// Une date fixe (2026-11-17 12:00:00 UTC), jamais « maintenant ».
    static let date = Date(timeIntervalSince1970: 1_794_916_800)

    @Test("l'aller-retour JSON garde la conversation entière, dans l'ordre, et un prompt absent reste absent")
    func aRecordWithoutAPromptSurvivesAJSONRoundTrip() throws {
        let record = InterviewRecord(id: Self.id, date: Self.date, prompt: nil, conversation: try Self.conversation())

        let data = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(InterviewRecord.self, from: data)

        #expect(back == record)
        #expect(back.prompt == nil)
        #expect(back.conversation.turns.map(\.text) == record.conversation.turns.map(\.text))
        #expect(back.conversation.turns.map(\.speaker) == [.interviewer, .user, .interviewer, .user])
    }

    @Test("l'aller-retour JSON garde un prompt rédigé")
    func aRecordWithAPromptSurvivesAJSONRoundTrip() throws {
        let record = InterviewRecord(
            id: Self.id, date: Self.date, prompt: "Écris un outil d'exemple.", conversation: try Self.conversation())

        let back = try JSONDecoder().decode(InterviewRecord.self, from: try JSONEncoder().encode(record))

        #expect(back == record)
        #expect(back.prompt == "Écris un outil d'exemple.")
    }

    /// La forme est figée ici pour la tâche 11, qui l'écrit sur le disque : un JSON écrit à la main, qui ne passe pas par
    /// l'encodeur, fixe les noms des clés et ceux des locuteurs.
    @Test("le format est celui qu'on attend : clés id, date, prompt et conversation, prompt facultatif")
    func theRecordDecodesFromHandWrittenJSON() throws {
        let json = """
            {"id": "00000000-0000-4000-8000-000000000001", "date": "2026-11-17T12:00:00Z",
             "conversation": {"turns": [
               {"speaker": "interviewer", "text": "Que voulez-vous construire ?"},
               {"speaker": "user", "text": "Un outil d'exemple."}]}}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = try decoder.decode(InterviewRecord.self, from: Data(json.utf8))

        #expect(record.id == Self.id)
        #expect(record.date == Self.date)
        #expect(record.prompt == nil, "sans clé prompt, pas de prompt")
        #expect(
            record.conversation.turns == [
                ConversationTurn(speaker: .interviewer, text: "Que voulez-vous construire ?"),
                ConversationTurn(speaker: .user, text: "Un outil d'exemple."),
            ])
    }

    @Test("la date écrite en ISO 8601 se relit à l'identique : le magasin de la tâche 11 peut choisir cette stratégie")
    func theDateSurvivesTheISO8601Strategy() throws {
        let record = InterviewRecord(id: Self.id, date: Self.date, prompt: nil, conversation: try Self.conversation())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(record)
        #expect(String(decoding: data, as: UTF8.self).contains("2026-11-17T12:00:00Z"))
        #expect(try decoder.decode(InterviewRecord.self, from: data) == record)
    }
}
