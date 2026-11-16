import Foundation
import Testing
@testable import SupervoxCore

// La conversation d'un entretien : des tours qui alternent, rendus au modèle comme un historique et un dernier message.

@Suite struct ConversationTests {
    // MARK: Fusion des tours (règle 2)

    @Test func twoUserTurnsInARowAreOneTurnJoinedByASpace() {
        var conversation = Conversation()
        conversation.appendUser("je veux")
        conversation.appendUser("refactorer le module")

        #expect(conversation.turns == [ConversationTurn(speaker: .user, text: "je veux refactorer le module")])
    }

    @Test func twoInterviewerTurnsInARowAreOneTurnJoinedByASpace() {
        var conversation = Conversation()
        conversation.appendUser("bonjour")
        conversation.appendInterviewer("Bonjour.")
        conversation.appendInterviewer("Que voulez-vous faire ?")

        #expect(conversation.turns == [
            ConversationTurn(speaker: .user, text: "bonjour"),
            ConversationTurn(speaker: .interviewer, text: "Bonjour. Que voulez-vous faire ?"),
        ])
    }

    @Test func aTextThatIsEmptyOnceTrimmedAddsNothing() {
        var conversation = Conversation()
        conversation.appendUser("")
        conversation.appendUser("  \n\t ")
        conversation.appendInterviewer(" ")
        #expect(conversation.turns.isEmpty)

        conversation.appendUser("bonjour")
        conversation.appendUser("   ")
        conversation.appendInterviewer("\n")
        #expect(conversation.turns == [ConversationTurn(speaker: .user, text: "bonjour")])
    }

    @Test func aTextIsTrimmedBeforeItIsKeptAndBeforeItIsJoined() {
        var conversation = Conversation()
        conversation.appendUser("  un \n")
        conversation.appendUser("\t deux  ")

        #expect(conversation.turns == [ConversationTurn(speaker: .user, text: "un deux")])
    }

    @Test func speakersAlternateWhateverTheOrderOfTheAppends() {
        var conversation = Conversation()
        conversation.appendInterviewer("Question ?")
        conversation.appendUser("Réponse.")
        conversation.appendUser("Suite.")
        conversation.appendInterviewer("Autre ?")

        #expect(conversation.turns.map(\.speaker) == [.interviewer, .user, .interviewer])
    }

    @Test func theCountsOnlyLookAtTheUserTurns() {
        var conversation = Conversation()
        #expect(conversation.userTurnCount == 0 && !conversation.hasUserTurn)

        conversation.appendInterviewer("Bonjour.")
        #expect(conversation.userTurnCount == 0 && !conversation.hasUserTurn)

        conversation.appendUser("a")
        conversation.appendUser("b")   // fusionné avec « a » : un seul tour
        conversation.appendInterviewer("Et ?")
        conversation.appendUser("c")
        #expect(conversation.userTurnCount == 2 && conversation.hasUserTurn)
    }

    // MARK: Ce que reçoit le modèle (règle 2)

    @Test func theLastUserTurnIsTheInputAndEverythingBeforeItIsTheHistory() throws {
        var conversation = Conversation()
        conversation.appendInterviewer("Bonjour. Que voulez-vous faire ?")
        conversation.appendUser("refactorer")
        conversation.appendInterviewer("Pourquoi ?")
        conversation.appendUser("c'est trop long")

        let completion = try #require(conversation.completion())

        #expect(completion.input == "c'est trop long")
        #expect(completion.history == [
            CompletionTurn(role: .assistant, text: "Bonjour. Que voulez-vous faire ?"),
            CompletionTurn(role: .user, text: "refactorer"),
            CompletionTurn(role: .assistant, text: "Pourquoi ?"),
        ])
    }

    @Test func aConversationOfOneUserTurnHasAnEmptyHistory() throws {
        var conversation = Conversation()
        conversation.appendUser("bonjour")

        let completion = try #require(conversation.completion())

        #expect(completion.input == "bonjour" && completion.history.isEmpty)
    }

    @Test func thereIsNothingToSendWhenTheLastTurnIsNotTheUsersOrThereIsNoTurn() {
        var conversation = Conversation()
        #expect(conversation.completion() == nil)

        conversation.appendUser("bonjour")
        conversation.appendInterviewer("Bonjour.")
        #expect(conversation.completion() == nil)
    }

    @Test func theHistoryKeepsTheAlternationOfTheTurns() throws {
        var conversation = Conversation()
        for index in 1...4 {
            conversation.appendUser("réponse \(index)")
            conversation.appendInterviewer("question \(index)")
        }
        conversation.appendUser("dernière")

        let completion = try #require(conversation.completion())
        let roles = completion.history.map(\.role)

        #expect(roles == [.user, .assistant, .user, .assistant, .user, .assistant, .user, .assistant])
        #expect(completion.input == "dernière")
    }

    // MARK: Transcription (règle 2)

    @Test func theTranscriptIsOneParagraphPerTurnSeparatedByABlankLine() {
        var conversation = Conversation()
        conversation.appendInterviewer("Bonjour. Que voulez-vous faire ?")
        conversation.appendUser("refactorer le module")

        #expect(conversation.transcript == "Supervox : Bonjour. Que voulez-vous faire ?\n\nVous : refactorer le module")
        #expect(Conversation().transcript == "")
    }

    // MARK: Codage

    @Test func theJSONCodingRoundTripsWithoutLoss() throws {
        var conversation = Conversation()
        conversation.appendInterviewer("Bonjour, « on commence » ?")
        conversation.appendUser("oui — \"tout\" de suite\nligne deux")
        conversation.appendInterviewer("Parfait.")

        let data = try JSONEncoder().encode(conversation)
        let decoded = try JSONDecoder().decode(Conversation.self, from: data)

        #expect(decoded == conversation)
        #expect(decoded.transcript == conversation.transcript)
    }

    @Test func theSpeakersAreCodedByTheirName() throws {
        var conversation = Conversation()
        conversation.appendUser("a")
        conversation.appendInterviewer("b")
        let text = String(decoding: try JSONEncoder().encode(conversation), as: UTF8.self)

        #expect(text.contains("\"user\"") && text.contains("\"interviewer\""))
    }
}
