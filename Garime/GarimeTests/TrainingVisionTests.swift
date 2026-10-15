import XCTest
@testable import Garime

final class TrainingVisionPromptTests: XCTestCase {
    func testPromptCarriesPathExerciseAndNonce() {
        let prompt = TrainingVisionPrompt.text(
            imagePath: "/Users/biel/garime-uploads/treino.jpg",
            exercise: "remada baixa",
            nonce: "GVABCD1234"
        )
        XCTAssertTrue(prompt.contains("/Users/biel/garime-uploads/treino.jpg"))
        XCTAssertTrue(prompt.contains("remada baixa"))
        XCTAssertTrue(prompt.contains("GVABCD1234"))
        XCTAssertTrue(prompt.contains("weightKg"))
    }

    func testNonceIsShortAndUnique() {
        let first = TrainingVisionPrompt.nonce()
        let second = TrainingVisionPrompt.nonce()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, 10)
        XCTAssertTrue(first.hasPrefix("GV"))
    }
}

final class TrainingVisionReplyTests: XCTestCase {
    private let nonce = "GVABCD1234"

    private func message(_ text: String, role: AgentChatRole = .assistant, id: String = UUID().uuidString) -> AgentChatMessage {
        AgentChatMessage(id: id, role: role, text: text, tool: "", truncated: false)
    }

    func testReadsMachineAndWeight() {
        let reading = TrainingVisionReply.parse(
            text: "\(nonce) {\"machine\":\"puxada alta\",\"weightKg\":45,\"confidence\":0.9,\"note\":\"pino na 45\"}",
            nonce: nonce
        )
        XCTAssertEqual(reading?.machine, "puxada alta")
        XCTAssertEqual(reading?.weightKg, 45)
        XCTAssertEqual(reading?.confidence, 0.9)
        XCTAssertEqual(reading?.note, "pino na 45")
    }

    func testSurvivesMarkdownFenceAndChatter() {
        let text = """
        Olhei a foto!

        \(nonce)
        ```json
        {"machine":"leg press 45","weightKg":100.5,"confidence":0.7,"note":"4 anilhas de 20 + 2 de 10"}
        ```
        Qualquer coisa me chama.
        """
        let reading = TrainingVisionReply.parse(text: text, nonce: nonce)
        XCTAssertEqual(reading?.machine, "leg press 45")
        XCTAssertEqual(reading?.weightKg, 100.5)
    }

    func testUnreadableWeightStillReturnsTheMachine() {
        let reading = TrainingVisionReply.parse(
            text: "\(nonce) {\"machine\":\"cadeira extensora\",\"weightKg\":null,\"confidence\":0.4,\"note\":\"pino encoberto\"}",
            nonce: nonce
        )
        XCTAssertEqual(reading?.machine, "cadeira extensora")
        XCTAssertNil(reading?.weightKg)
        XCTAssertEqual(reading?.note, "pino encoberto")
    }

    func testAbsurdWeightIsDiscardedInsteadOfLogged() {
        let reading = TrainingVisionReply.parse(
            text: "\(nonce) {\"machine\":\"supino\",\"weightKg\":99999,\"confidence\":0.9,\"note\":\"\"}",
            nonce: nonce
        )
        XCTAssertNil(reading?.weightKg, "peso impossível não pode virar sugestão")
        XCTAssertEqual(reading?.machine, "supino")
    }

    func testAnswerWithoutTheNonceIsIgnored() {
        XCTAssertNil(TrainingVisionReply.parse(
            text: "{\"machine\":\"supino\",\"weightKg\":40,\"confidence\":1,\"note\":\"\"}",
            nonce: nonce
        ))
    }

    func testPlainTextAnswerYieldsNothing() {
        XCTAssertNil(TrainingVisionReply.parse(text: "\(nonce) acho que é uma polia, uns 40kg", nonce: nonce))
    }

    func testPicksTheAnswerOfThisQuestionNotAnOldOne() {
        let messages = [
            message("GVOLD00000 {\"machine\":\"velha\",\"weightKg\":10,\"confidence\":1,\"note\":\"\"}"),
            message("\(nonce) {\"machine\":\"nova\",\"weightKg\":60,\"confidence\":0.8,\"note\":\"\"}"),
        ]
        let reading = TrainingVisionReply.parse(messages: messages, nonce: nonce)
        XCTAssertEqual(reading?.machine, "nova")
        XCTAssertEqual(reading?.weightKg, 60)
    }

    func testUserEchoOfThePromptIsNotReadAsTheAnswer() {
        let messages = [
            message("\(nonce) {\"machine\":\"nome curto\",\"weightKg\":40,\"confidence\":0.5,\"note\":\"\"}", role: .user)
        ]
        XCTAssertNil(TrainingVisionReply.parse(messages: messages, nonce: nonce))
    }

    func testEmptyTranscriptIsNotAnAnswer() {
        XCTAssertNil(TrainingVisionReply.parse(messages: [], nonce: nonce))
    }

    func testExtractsBalancedObjectWithNestedBraces() {
        let json = TrainingVisionReply.firstJSONObject(in: "lixo {\"a\":{\"b\":1},\"c\":\"}\"} sobra")
        XCTAssertEqual(json, "{\"a\":{\"b\":1},\"c\":\"}\"}")
    }

    func testIncompleteJSONIsRejected() {
        XCTAssertNil(TrainingVisionReply.firstJSONObject(in: "{\"machine\":\"supino\""))
    }
}
