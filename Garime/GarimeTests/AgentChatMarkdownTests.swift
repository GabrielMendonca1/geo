import XCTest
@testable import Garime

final class AgentChatMarkdownTests: XCTestCase {
    private func plain(_ raw: String) -> String {
        String(AgentChatMarkup.attributed(raw).characters)
    }

    func testPlainTextIsOneParagraphAndSurvivesByteForByte() {
        let raw = "sem marcação nenhuma aqui\nsegunda linha com 2 * 3 e caminho a_b_c"
        XCTAssertEqual(AgentChatMarkup.blocks(raw), [.paragraph(raw)])
        XCTAssertEqual(AgentChatMarkup.spans(raw), [.text(raw)])
        XCTAssertEqual(plain(raw), raw)
    }

    func testBlankLinesInsidePlainTextStayInTheSameParagraph() {
        let raw = "primeiro\n\nsegundo"
        XCTAssertEqual(AgentChatMarkup.blocks(raw), [.paragraph(raw)])
    }

    func testHeadingLevels() {
        XCTAssertEqual(AgentChatMarkup.blocks("# um"), [.heading(1, "um")])
        XCTAssertEqual(AgentChatMarkup.blocks("## dois"), [.heading(2, "dois")])
        XCTAssertEqual(AgentChatMarkup.blocks("### três"), [.heading(3, "três")])
    }

    func testHashWithoutSpaceOrTooDeepIsProse() {
        XCTAssertEqual(AgentChatMarkup.blocks("#hashtag"), [.paragraph("#hashtag")])
        XCTAssertEqual(AgentChatMarkup.blocks("#### quatro"), [.paragraph("#### quatro")])
    }

    func testHeadingInsideFenceStaysCode() {
        XCTAssertEqual(
            AgentChatMarkup.blocks("olha:\n```\n# não é título\n- nem lista\n```"),
            [.paragraph("olha:"), .code("# não é título\n- nem lista")]
        )
    }

    func testUnclosedFenceKeepsRemainderAsCode() {
        XCTAssertEqual(
            AgentChatMarkup.blocks("roda:\n```\nmake test"),
            [.paragraph("roda:"), .code("make test")]
        )
    }

    func testListMixedWithProse() {
        let raw = "antes\n- um\n* dois\n1. três\ndepois"
        XCTAssertEqual(AgentChatMarkup.blocks(raw), [
            .paragraph("antes"),
            .bullet("um"),
            .bullet("dois"),
            .ordered("1.", "três"),
            .paragraph("depois"),
        ])
    }

    func testIndentedBulletStillCountsAndDeepIndentDoesNot() {
        XCTAssertEqual(AgentChatMarkup.blocks("lista:\n  - filho"), [.paragraph("lista:"), .bullet("filho")])
        XCTAssertEqual(
            AgentChatMarkup.blocks("lista:\n        - fundo"),
            [.paragraph("lista:\n        - fundo")]
        )
    }

    func testDashWithoutSpaceIsNotAList() {
        XCTAssertEqual(AgentChatMarkup.blocks("-5 graus"), [.paragraph("-5 graus")])
    }

    func testInlineCodeAndLooseBacktick() {
        XCTAssertEqual(AgentChatMarkup.spans("usa `git status` agora"), [
            .text("usa "),
            .code("git status"),
            .text(" agora"),
        ])
        XCTAssertEqual(AgentChatMarkup.spans("um ` solto"), [.text("um ` solto")])
        XCTAssertEqual(plain("um ` solto"), "um ` solto")
    }

    func testBoldAndItalic() {
        XCTAssertEqual(AgentChatMarkup.spans("isso é **forte** e *fraco*"), [
            .text("isso é "),
            .strong("forte"),
            .text(" e "),
            .emphasis("fraco"),
        ])
    }

    func testLooseAsterisksStayLiteral() {
        XCTAssertEqual(AgentChatMarkup.spans("2 * 3 * 4"), [.text("2 * 3 * 4")])
        XCTAssertEqual(AgentChatMarkup.spans("um ** solto"), [.text("um ** solto")])
        XCTAssertEqual(plain("2 * 3 * 4"), "2 * 3 * 4")
    }

    func testLinkKeepsOnlyTheLabel() {
        XCTAssertEqual(AgentChatMarkup.spans("veja [o doc](https://x.dev) ali"), [
            .text("veja "),
            .link("o doc"),
            .text(" ali"),
        ])
        XCTAssertEqual(AgentChatMarkup.spans("[incompleto] aqui"), [.text("[incompleto] aqui")])
    }

    func testCodeSpanWinsOverEmphasisInside() {
        XCTAssertEqual(AgentChatMarkup.spans("`a * b`"), [.code("a * b")])
    }

    func testHeadingWithBoldIsParsedInline() {
        guard case .heading(let level, let text)? = AgentChatMarkup.blocks("## **peso**").first else {
            return XCTFail("esperava heading")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(AgentChatMarkup.spans(text), [.strong("peso")])
    }

    func testCodeExtractionIsUnchanged() {
        XCTAssertEqual(AgentChatMarkup.code(in: "a\n```\num\n```\nb\n```\ndois\n```"), "um\n\ndois")
    }
}

@MainActor
final class AgentChatFeedKeyTests: XCTestCase {
    func testFeedKeyChangesWhenLastMessageGrowsWithoutNewMessages() async {
        let target = AgentChatTarget(session: "claude", agent: "claude")
        let fake = GrowingChatBridge()
        let model = AgentChatModel(target: target, client: fake)

        fake.body = #"{"agent":"claude","status":"working","messages":[{"role":"assistant","text":"comecei a rodar os testes e"}]}"#
        await model.refresh()
        let first = model.feedKey

        fake.body = #"{"agent":"claude","status":"working","messages":[{"role":"assistant","text":"comecei a rodar os testes e terminei"}]}"#
        await model.refresh()

        XCTAssertEqual(model.messages.count, 1)
        XCTAssertNotEqual(model.feedKey, first)
    }
}

private final class GrowingChatBridge: BridgeAPI, @unchecked Sendable {
    var body = "{}"

    func getData(_ path: String, token: String?) async throws -> Data { Data(body.utf8) }
    func postData(_ path: String, body: Data?, token: String?) async throws -> Data { Data("{}".utf8) }
    func delete(_ path: String, token: String?) async throws -> Data { throw BridgeError.unsupported(path) }
    func uploadFile(_ path: String, body: Data, filename: String, token: String?) async throws -> Data {
        throw BridgeError.unsupported(path)
    }
    func get<T: Decodable>(_ path: String, decoder: JSONDecoder) async throws -> T {
        try decoder.decode(T.self, from: try await getData(path, token: nil))
    }
    func post<T: Decodable>(_ path: String, body: Data?, decoder: JSONDecoder) async throws -> T {
        throw BridgeError.unsupported(path)
    }
    func stream(_ path: String, method: String, body: Data?, token: String?) -> AsyncThrowingStream<SSEMessage, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func health() async throws {}
}
