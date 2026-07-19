import XCTest
@testable import Moomo

/// Matches, conversations, messages, and the blocking ripple across them.
@MainActor
final class MatchChatTests: XCTestCase {

    /// The sample data's featured person — same id, so blocking him here is
    /// blocking the person Discover actually shows.
    private let kenji = DiscoveryCandidate(
        id: "u-featured", displayName: "Kenji", age: 26, city: "Chicago",
        photoPath: nil, isOnline: true, wantsToTalk: true, pronoun: .he
    )

    private func settle(_ ms: UInt64 = 60) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// Wires the same graph `AppServices.mock()` does, without latency.
    private func makeWorld(
        autoReplyDelay: Duration? = nil
    ) -> (matches: MockMatchService, chat: MockChatService, safety: MockSafetyService) {
        let chat = MockChatService(autoReplyDelay: autoReplyDelay)
        let matches = MockMatchService(
            latency: .milliseconds(1),
            onMatch: { await chat.createConversation(for: $0) }
        )
        let safety = MockSafetyService(onBlock: { userID in
            await matches.removeMatches(with: userID)
            await chat.removeConversations(with: userID)
        })
        return (matches, chat, safety)
    }

    private func makeMatch(
        _ world: (matches: MockMatchService, chat: MockChatService, safety: MockSafetyService)
    ) async throws -> Match {
        let outcome = try await world.matches.submitDecision(.like, about: kenji)
        guard case .matched(let match) = outcome else {
            XCTFail("Expected a match")
            throw ChatError.unknownConversation
        }
        return match
    }

    // MARK: - Matches

    func testMutualLikeIsRequiredForAMatch() async throws {
        let world = makeWorld()

        let passed = try await world.matches.submitDecision(.pass, about: kenji)
        XCTAssertEqual(passed, .passed)
        var matchList = await world.matches.matches()
        XCTAssertTrue(matchList.isEmpty, "A pass must never match")

        let liked = try await world.matches.submitDecision(.like, about: kenji)
        guard case .matched = liked else {
            return XCTFail("Kenji wants to talk; a like must be mutual")
        }
        matchList = await world.matches.matches()
        XCTAssertEqual(matchList.count, 1)
    }

    func testRepeatMatchIsNotDuplicated() async throws {
        let world = makeWorld()
        let first = try await makeMatch(world)

        // A second call with the same person, liked again.
        let outcome = try await world.matches.submitDecision(.like, about: kenji)

        guard case .matched(let again) = outcome else {
            return XCTFail("Expected the existing match back")
        }
        XCTAssertEqual(again.id, first.id, "Same person, same match")
        let matchList = await world.matches.matches()
        XCTAssertEqual(matchList.count, 1)
        let conversations = await world.chat.conversations()
        XCTAssertEqual(conversations.count, 1, "And no duplicate conversation")
    }

    // MARK: - Messages

    func testSendingAppendsToThreadAndUpdatesPreview() async throws {
        let world = makeWorld()
        let match = try await makeMatch(world)

        try await world.chat.send("Hey Kenji!", in: match.conversationID)

        let thread = await world.chat.messages(in: match.conversationID)
        XCTAssertEqual(thread.map(\.text), ["Hey Kenji!"])
        XCTAssertTrue(thread[0].isFromMe)

        let conversations = await world.chat.conversations()
        XCTAssertEqual(
            conversations[0].lastMessage?.text, "Hey Kenji!",
            "The list preview must show the last message without reading the thread"
        )
    }

    func testEmptyAndWhitespaceMessagesAreRejected() async throws {
        let world = makeWorld()
        let match = try await makeMatch(world)

        do {
            try await world.chat.send("   \n", in: match.conversationID)
            XCTFail("Whitespace is not a message")
        } catch let error as ChatError {
            XCTAssertEqual(error, .emptyMessage)
        }
        let thread = await world.chat.messages(in: match.conversationID)
        XCTAssertTrue(thread.isEmpty)
    }

    func testSendingToAMissingConversationFails() async throws {
        let world = makeWorld()
        do {
            try await world.chat.send("hello?", in: "no-such-conversation")
            XCTFail("Sending into the void must fail")
        } catch let error as ChatError {
            XCTAssertEqual(error, .unknownConversation)
        }
    }

    func testReplyArrivesUnreadAndMarkReadClearsIt() async throws {
        let world = makeWorld(autoReplyDelay: .milliseconds(30))
        let match = try await makeMatch(world)

        try await world.chat.send("Hey!", in: match.conversationID)
        await settle(300)

        var conversations = await world.chat.conversations()
        XCTAssertEqual(conversations[0].unreadCount, 1, "The reply arrives unread")
        XCTAssertEqual(conversations[0].lastMessage?.isFromMe, false)

        await world.chat.markRead(match.conversationID)
        conversations = await world.chat.conversations()
        XCTAssertEqual(conversations[0].unreadCount, 0)
    }

    func testMessagesPersistForTheSession() async throws {
        let world = makeWorld()
        let match = try await makeMatch(world)
        try await world.chat.send("one", in: match.conversationID)
        try await world.chat.send("two", in: match.conversationID)

        // A fresh observer (a re-opened chat screen) sees the whole thread.
        var received: [Message] = []
        for await messages in world.chat.messagesStream(in: match.conversationID) {
            received = messages
            break // the stream opens with the current transcript
        }
        XCTAssertEqual(received.map(\.text), ["one", "two"])
    }

    // MARK: - The open thread

    func testOpenThreadGoesUnavailableWhenTheConversationIsTornDown() async throws {
        let world = makeWorld()
        let match = try await makeMatch(world)

        let model = ChatDetailModel(conversationID: match.conversationID, service: world.chat)
        await settle()
        XCTAssertFalse(model.isUnavailable)

        // The block cascade deletes the conversation under the open screen.
        try await world.safety.block(kenji)
        await settle()

        XCTAssertTrue(model.isUnavailable, "An open thread must close when its conversation dies")
    }

    func testFailedSendPreservesTheDraftAndSaysSo() async throws {
        let world = makeWorld()
        // A conversation that never existed: every send fails.
        let model = ChatDetailModel(conversationID: "ghost", service: world.chat)
        model.draft = "hello there"

        await model.send()

        XCTAssertNotNil(model.sendFailure, "A failed send must say so")
        XCTAssertEqual(model.draft, "hello there", "The user's words must survive a failed send")
    }

    // MARK: - Blocking ripple

    func testBlockingRemovesMatchAndConversationAndDiscovery() async throws {
        let world = makeWorld()
        let match = try await makeMatch(world)
        try await world.chat.send("hi", in: match.conversationID)

        try await world.safety.block(kenji)

        let matchList = await world.matches.matches()
        XCTAssertTrue(matchList.isEmpty, "Blocking removes the match")
        let conversations = await world.chat.conversations()
        XCTAssertTrue(conversations.isEmpty, "Blocking removes the conversation")

        // And Discover filters them out.
        let discovery = BlockFilteringDiscoveryService(
            base: MockDiscoveryService(latency: .milliseconds(1)),
            safety: world.safety
        )
        let state = try await discovery.loadDiscovery()
        XCTAssertNil(state.featured, "The featured person was blocked")
        XCTAssertFalse(state.nearby.contains { $0.id == kenji.id })
    }

    func testUnblockRestoresDiscoveryVisibility() async throws {
        let world = makeWorld()
        try await world.safety.block(kenji)
        await world.safety.unblock(kenji.id)

        let discovery = BlockFilteringDiscoveryService(
            base: MockDiscoveryService(latency: .milliseconds(1)),
            safety: world.safety
        )
        let state = try await discovery.loadDiscovery()
        XCTAssertEqual(state.featured?.id, "u-featured")
        // The match and conversation stay gone — unblocking is not undo.
        let matchList = await world.matches.matches()
        XCTAssertTrue(matchList.isEmpty)
    }

    // MARK: - Boost

    func testBoostActivationIsRealStateWithRealExpiry() async throws {
        let boost = MockBoostService(initialBoosts: 2, boostDuration: 60)

        let state = try await boost.activate()
        XCTAssertTrue(state.isActive())
        XCTAssertEqual(state.remainingBoosts, 1)

        do {
            _ = try await boost.activate()
            XCTFail("A running boost cannot be stacked")
        } catch let error as BoostError {
            XCTAssertEqual(error, .alreadyActive)
        }
    }

    func testExhaustedBoostsRefuseHonestly() async throws {
        let boost = MockBoostService(initialBoosts: 0)
        do {
            _ = try await boost.activate()
            XCTFail("No boosts left must throw")
        } catch let error as BoostError {
            XCTAssertEqual(error, .noneRemaining)
        }
    }

    // MARK: - Tabs

    func testEveryTabShipsInEveryConfiguration() {
        XCTAssertEqual(
            Tab.available, Tab.allCases,
            "All five tabs have real content now; none may be hidden"
        )
    }
}
