import XCTest
@testable import Moomo

/// The Hinge-style chat organisation: turn grouping, the tab badge count,
/// hide/unhide, we-met, and the unmatch cascade.
@MainActor
final class ChatOrganizationTests: XCTestCase {

    private let kenji = DiscoveryCandidate(
        id: "u-featured", displayName: "Kenji", age: 26, city: "Chicago",
        photoPath: nil, isOnline: true, wantsToTalk: true, pronoun: .he
    )
    private let anaya = DiscoveryCandidate(
        id: "u-1", displayName: "Anaya", age: 24, city: "Chicago",
        photoPath: nil, isOnline: true, wantsToTalk: true, pronoun: .she
    )

    private func settle(_ ms: UInt64 = 60) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    /// The mock graph as `AppServices.mock()` wires it, without latency.
    private func makeWorld() -> (
        matches: MockMatchService, chat: MockChatService, safety: MockSafetyService
    ) {
        let chat = MockChatService(autoReplyDelay: nil)
        let matches = MockMatchService(
            latency: .milliseconds(1),
            onMatch: { await chat.createConversation(for: $0) }
        )
        let safety = MockSafetyService(
            onBlock: { userID in
                await matches.removeMatches(with: userID)
                await chat.removeConversations(with: userID)
            },
            onUnmatch: { userID in
                await matches.removeMatches(with: userID)
                await chat.removeConversations(with: userID)
            }
        )
        return (matches, chat, safety)
    }

    private func makeMatch(
        _ world: (matches: MockMatchService, chat: MockChatService, safety: MockSafetyService),
        with candidate: DiscoveryCandidate
    ) async throws -> Match {
        let outcome = try await world.matches.submitDecision(.like, about: candidate)
        guard case .matched(let match) = outcome else {
            XCTFail("Expected a match")
            throw ChatError.unknownConversation
        }
        return match
    }

    // MARK: - Turn

    func testTurnIsYoursUntilYouSpeakLast() async throws {
        let world = makeWorld()
        let match = try await makeMatch(world, with: kenji)

        var conversation = await world.chat.conversations()[0]
        XCTAssertEqual(conversation.turn, .yours, "A never-started chat is yours to open")

        try await world.chat.send("Hey!", in: match.conversationID)
        conversation = await world.chat.conversations()[0]
        XCTAssertEqual(conversation.turn, .theirs, "You spoke last")
    }

    func testTurnComesBackToYouWhenTheyReply() async throws {
        let world = (
            matches: MockMatchService(latency: .milliseconds(1)),
            chat: MockChatService(autoReplyDelay: .milliseconds(20)),
            safety: MockSafetyService()
        )
        let outcome = try await world.matches.submitDecision(.like, about: kenji)
        guard case .matched(let match) = outcome else { return XCTFail("Expected a match") }
        await world.chat.createConversation(for: match)

        try await world.chat.send("Hey!", in: match.conversationID)
        await settle(300) // the simulated peer replies once

        let conversation = await world.chat.conversations()[0]
        XCTAssertEqual(conversation.lastMessage?.isFromMe, false)
        XCTAssertEqual(conversation.turn, .yours, "They spoke last — your move again")
    }

    // MARK: - Sections and badge

    func testSectionsGroupByTurnAndHiddenWinsOverBoth() async throws {
        let world = makeWorld()
        let kenjiMatch = try await makeMatch(world, with: kenji)
        let anayaMatch = try await makeMatch(world, with: anaya)
        try await world.chat.send("Hi Anaya!", in: anayaMatch.conversationID)

        let model = ChatListModel(service: world.chat, safety: world.safety)
        await settle()

        XCTAssertEqual(model.conversations(in: .yourTurn).map(\.id), [kenjiMatch.conversationID])
        XCTAssertEqual(model.conversations(in: .theirTurn).map(\.id), [anayaMatch.conversationID])
        XCTAssertTrue(model.conversations(in: .hidden).isEmpty)
        XCTAssertEqual(model.awaitingYouCount, 1)

        // Hiding removes a conversation from its turn section — and from the
        // badge — no matter whose turn it was.
        await model.setHidden(true, model.conversations(in: .yourTurn)[0])
        await settle()

        XCTAssertTrue(model.conversations(in: .yourTurn).isEmpty)
        XCTAssertEqual(model.conversations(in: .hidden).map(\.id), [kenjiMatch.conversationID])
        XCTAssertEqual(model.awaitingYouCount, 0, "Hidden chats must not badge the tab")
    }

    func testUnhideReturnsTheConversationToTheRightSection() async throws {
        let world = makeWorld()
        let match = try await makeMatch(world, with: kenji)
        try await world.chat.send("Hello!", in: match.conversationID)

        let model = ChatListModel(service: world.chat, safety: world.safety)
        await settle()

        await model.setHidden(true, model.conversations(in: .theirTurn)[0])
        await settle()
        XCTAssertEqual(model.conversations(in: .hidden).count, 1)

        await model.setHidden(false, model.conversations(in: .hidden)[0])
        await settle()

        XCTAssertTrue(model.conversations(in: .hidden).isEmpty)
        XCTAssertEqual(
            model.conversations(in: .theirTurn).map(\.id), [match.conversationID],
            "Unhide restores the section the last message dictates"
        )
    }

    func testCollapseTogglesPerSection() async {
        let world = makeWorld()
        let model = ChatListModel(service: world.chat, safety: world.safety)

        XCTAssertFalse(model.isCollapsed(.yourTurn), "Sections start expanded")
        model.toggleCollapsed(.yourTurn)
        XCTAssertTrue(model.isCollapsed(.yourTurn))
        XCTAssertFalse(model.isCollapsed(.theirTurn), "Collapse is per-section")
        model.toggleCollapsed(.yourTurn)
        XCTAssertFalse(model.isCollapsed(.yourTurn))
    }

    // MARK: - We met

    func testWeMetIsStoredAndReversible() async throws {
        let world = makeWorld()
        let match = try await makeMatch(world, with: kenji)

        try await world.chat.setWeMet(true, in: match.conversationID)
        var conversation = await world.chat.conversations()[0]
        XCTAssertTrue(conversation.metByMe)

        try await world.chat.setWeMet(false, in: match.conversationID)
        conversation = await world.chat.conversations()[0]
        XCTAssertFalse(conversation.metByMe)
    }

    func testFlagsOnAMissingConversationFailHonestly() async {
        let world = makeWorld()
        do {
            try await world.chat.setHidden(true, in: "no-such-conversation")
            XCTFail("Hiding nothing must fail")
        } catch let error as ChatError {
            XCTAssertEqual(error, .unknownConversation)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Unmatch

    func testUnmatchRemovesMatchAndConversationAndStoresTheReason() async throws {
        let world = makeWorld()
        _ = try await makeMatch(world, with: kenji)

        let model = ChatListModel(service: world.chat, safety: world.safety)
        await settle()

        let failure = await model.unmatch(
            model.conversations(in: .yourTurn)[0],
            reason: .notInterested,
            alsoBlock: false
        )
        await settle()

        XCTAssertNil(failure)
        let matches = await world.matches.matches()
        XCTAssertTrue(matches.isEmpty, "Unmatching removes the match")
        let conversations = await world.chat.conversations()
        XCTAssertTrue(conversations.isEmpty, "Unmatching removes the conversation")

        let records = await world.safety.unmatches()
        XCTAssertEqual(records.map(\.userID), [kenji.id])
        XCTAssertEqual(records.map(\.reason), [.notInterested])

        let blocked = await world.safety.blockedUsers()
        XCTAssertTrue(blocked.isEmpty, "A plain unmatch is not a block")
    }

    func testUnmatchWithBlockAlsoBlocks() async throws {
        let world = makeWorld()
        _ = try await makeMatch(world, with: kenji)

        let model = ChatListModel(service: world.chat, safety: world.safety)
        await settle()

        let failure = await model.unmatch(
            model.conversations(in: .yourTurn)[0],
            reason: .fakeSpamScammer,
            alsoBlock: true
        )
        await settle()

        XCTAssertNil(failure)
        let blocked = await world.safety.blockedUsers()
        XCTAssertEqual(blocked.map(\.userID), [kenji.id])
        let isBlocked = await world.safety.isBlocked(kenji.id)
        XCTAssertTrue(isBlocked)
    }

    // MARK: - Reason catalogue

    func testUnmatchReasonWireValuesAreStable() {
        // These raw values are the backend contract (UNMATCH_REASONS in
        // backend/functions/src/shared.ts); a rename here silently breaks it.
        XCTAssertEqual(UnmatchReason.allCases.map(\.rawValue), [
            "no_reason",
            "not_interested",
            "fake_spam_scammer",
            "inappropriate_content",
            "underage",
            "off_app_behavior",
            "someone_in_danger",
        ])
        XCTAssertFalse(UnmatchReason.noReason.isSerious)
        XCTAssertFalse(UnmatchReason.notInterested.isSerious)
        XCTAssertTrue(UnmatchReason.someoneInDanger.isSerious)
    }
}
