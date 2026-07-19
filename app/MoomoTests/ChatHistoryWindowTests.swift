import XCTest
@testable import Moomo

/// The thread window regression: an open conversation must render the NEWEST
/// 500 messages. The original ascending-query-with-limit kept the OLDEST 500,
/// so message 501 and everything after it never rendered.
final class ChatHistoryWindowTests: XCTestCase {

    /// 501 messages in send order, as the pipeline sees them.
    private let transcript = (1...501).map { "message-\($0)" }

    func testWindowOver501MessagesKeepsTheNewest500() {
        let window = ChatHistoryWindow.window(overAscending: transcript)

        XCTAssertEqual(window.count, ChatHistoryWindow.messageLimit)
        XCTAssertEqual(window.first, "message-2", "Only the OLDEST message may fall out")
        XCTAssertEqual(window.last, "message-501", "The newest message must always render")
        XCTAssertFalse(window.contains("message-1"))
    }

    /// The live pipeline: Firestore serves the newest `messageLimit` in
    /// descending order (that is what `order(descending:) + limit` returns for
    /// 501 stored messages), and the service flips it for display. The result
    /// must be exactly the newest-500 window, oldest first.
    func testDescendingQueryPageRendersAsTheNewestWindowInSendOrder() {
        let queryPage = Array(transcript.reversed().prefix(ChatHistoryWindow.messageLimit))

        let rendered = ChatHistoryWindow.renderOrder(newestFirst: queryPage)

        XCTAssertEqual(rendered, ChatHistoryWindow.window(overAscending: transcript))
        XCTAssertEqual(rendered.first, "message-2")
        XCTAssertEqual(rendered.last, "message-501")
    }

    func testShortThreadsRenderWhole() {
        let rendered = ChatHistoryWindow.renderOrder(newestFirst: ["b", "a"])
        XCTAssertEqual(rendered, ["a", "b"])
        XCTAssertEqual(ChatHistoryWindow.window(overAscending: ["a", "b"]), ["a", "b"])
    }
}
