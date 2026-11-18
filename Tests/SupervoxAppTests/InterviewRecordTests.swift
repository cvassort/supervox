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

    /// 00000000-0000-4000-8000-000000000001, sans déballage : le décodage du JSON en clair en est la preuve.
    static let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1))
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

    /// La forme est figée ici pour la tâche 11, qui l'écrit sur le disque : le JSON attendu est écrit en clair, avec toutes ses clés
    /// (`id`, `date`, `prompt`, `conversation`, `turns`, `speaker`, `text`), et ne vient jamais de l'encodeur. Renommer une clé fait
    /// tomber ces tests : ni l'aller-retour ni le décodage seuls ne le verraient.
    static let withPromptJSON = """
        {"id": "00000000-0000-4000-8000-000000000001", "date": "2026-11-17T12:00:00Z",
         "prompt": "Écris un outil d'exemple.",
         "conversation": {"turns": [
           {"speaker": "interviewer", "text": "Que voulez-vous construire ?"},
           {"speaker": "user", "text": "Un outil d'exemple."}]}}
        """
    static let withoutPromptJSON = """
        {"id": "00000000-0000-4000-8000-000000000001", "date": "2026-11-17T12:00:00Z",
         "conversation": {"turns": [
           {"speaker": "interviewer", "text": "Que voulez-vous construire ?"},
           {"speaker": "user", "text": "Un outil d'exemple."}]}}
        """

    static func shortConversation() -> Conversation {
        var conversation = Conversation()
        conversation.appendInterviewer("Que voulez-vous construire ?")
        conversation.appendUser("Un outil d'exemple.")
        return conversation
    }

    @Test("le JSON écrit en clair se décode : clés id, date, prompt et conversation, prompt facultatif")
    func theRecordDecodesFromHandWrittenJSON() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let with = try decoder.decode(InterviewRecord.self, from: Data(Self.withPromptJSON.utf8))
        let without = try decoder.decode(InterviewRecord.self, from: Data(Self.withoutPromptJSON.utf8))

        #expect(with.id == Self.id)
        #expect(with.date == Self.date)
        #expect(with.prompt == "Écris un outil d'exemple.")
        #expect(without.prompt == nil, "sans clé prompt, pas de prompt")
        #expect(without.id == Self.id && without.date == Self.date)
        let turns = [
            ConversationTurn(speaker: .interviewer, text: "Que voulez-vous construire ?"),
            ConversationTurn(speaker: .user, text: "Un outil d'exemple."),
        ]
        #expect(with.conversation.turns == turns)
        #expect(without.conversation.turns == turns)
    }

    @Test("l'encodeur écrit exactement ces clés : un prompt présent s'écrit sous « prompt », un prompt absent ne s'écrit pas")
    func theRecordEncodesToTheHandWrittenJSON() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        func object(_ data: Data) throws -> NSDictionary {
            try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        }

        let with = InterviewRecord(
            id: Self.id, date: Self.date, prompt: "Écris un outil d'exemple.", conversation: Self.shortConversation())
        let without = InterviewRecord(id: Self.id, date: Self.date, prompt: nil, conversation: Self.shortConversation())

        #expect(try object(try encoder.encode(with)) == (try object(Data(Self.withPromptJSON.utf8))))
        #expect(try object(try encoder.encode(without)) == (try object(Data(Self.withoutPromptJSON.utf8))))
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
