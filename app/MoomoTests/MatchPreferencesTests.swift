import XCTest
@testable import Moomo

/// The pairing-compatibility table. Mirrored by `wantsGender` in
/// backend/functions/src/matchmaking.ts — if a case changes here, it must
/// change there, or Discover shows people matchmaking refuses to pair.
final class MatchPreferencesTests: XCTestCase {

    func testEveryoneAcceptsEveryGenderIncludingUnknown() {
        for gender in [Gender.woman, .man, .nonBinary, .other] {
            XCTAssertTrue(MatchPreferences.wants([.everyone], gender: gender))
        }
        XCTAssertTrue(MatchPreferences.wants([.everyone], gender: nil))
    }

    func testEmptyPreferencesReadAsEveryone() {
        // Pre-preference accounts must keep pairing, not soft-lock.
        XCTAssertTrue(MatchPreferences.wants([], gender: .woman))
        XCTAssertTrue(MatchPreferences.wants([], gender: nil))
    }

    func testBinaryPreferencesMatchExactly() {
        XCTAssertTrue(MatchPreferences.wants([.women], gender: .woman))
        XCTAssertFalse(MatchPreferences.wants([.women], gender: .man))
        XCTAssertTrue(MatchPreferences.wants([.men], gender: .man))
        XCTAssertFalse(MatchPreferences.wants([.men], gender: .woman))
        XCTAssertTrue(MatchPreferences.wants([.women, .men], gender: .woman))
    }

    func testBinaryPreferencesNeverGuessForNonBinaryOrUnknown() {
        // Only "everyone" accepts non-binary/other/unknown — a binary bucket
        // guess would misgender people structurally.
        XCTAssertFalse(MatchPreferences.wants([.women, .men], gender: .nonBinary))
        XCTAssertFalse(MatchPreferences.wants([.women], gender: .other))
        XCTAssertFalse(MatchPreferences.wants([.men], gender: nil))
    }

    func testMutualCompatibilityRequiresBothDirections() {
        let womanSeekingWomen: Person = (.woman, [.women], nil)
        let manSeekingWomen: Person = (.man, [.women], nil)
        let womanSeekingMen: Person = (.woman, [.men], nil)

        // He wants her; she does not want him.
        XCTAssertFalse(MatchPreferences.areMutuallyCompatible(womanSeekingWomen, manSeekingWomen))
        // Both directions hold.
        XCTAssertTrue(MatchPreferences.areMutuallyCompatible(manSeekingWomen, womanSeekingMen))
        XCTAssertTrue(MatchPreferences.areMutuallyCompatible(womanSeekingWomen, womanSeekingWomen))
    }

    // MARK: - Dating intention

    private typealias Person = (
        gender: Gender?, interestedIn: Set<InterestedIn>, intention: DatingIntention?
    )

    /// The point of the filter: opposite ends of the spectrum never meet.
    func testLifePartnerAndShortTermNeverMatch() {
        XCTAssertFalse(MatchPreferences.areIntentionsCompatible(.lifePartner, .shortTerm))
        XCTAssertFalse(MatchPreferences.areIntentionsCompatible(.shortTerm, .lifePartner))
        XCTAssertFalse(MatchPreferences.areIntentionsCompatible(.longTerm, .shortTerm))
    }

    /// The "open to" answers are the bridge between the two ends.
    func testOpenToAnswersBridgeBothEnds() {
        XCTAssertTrue(MatchPreferences.areIntentionsCompatible(.lifePartner, .longTermOpenToShort))
        XCTAssertTrue(MatchPreferences.areIntentionsCompatible(.shortTerm, .longTermOpenToShort))
        XCTAssertTrue(MatchPreferences.areIntentionsCompatible(.lifePartner, .shortTermOpenToLong))
        XCTAssertTrue(MatchPreferences.areIntentionsCompatible(.shortTerm, .shortTermOpenToLong))
    }

    func testSameEndOfTheSpectrumMatches() {
        XCTAssertTrue(MatchPreferences.areIntentionsCompatible(.lifePartner, .longTerm))
        XCTAssertTrue(MatchPreferences.areIntentionsCompatible(.shortTerm, .shortTerm))
    }

    /// Undecided and pre-intention accounts must never be soft-locked out of
    /// matching — the same rule empty gender preferences follow.
    func testFiguringItOutAndMissingIntentionMatchEveryone() {
        for intention in DatingIntention.allCases {
            XCTAssertTrue(
                MatchPreferences.areIntentionsCompatible(.figuringItOut, intention),
                "\(intention) must be reachable by someone still figuring it out"
            )
            XCTAssertTrue(
                MatchPreferences.areIntentionsCompatible(nil, intention),
                "\(intention) must be reachable by an account with no intention set"
            )
        }
        XCTAssertTrue(MatchPreferences.areIntentionsCompatible(nil, nil))
    }

    /// Intention is an AND with gender, not a replacement for it.
    func testIntentionGatesOtherwiseCompatiblePeople() {
        let manSeekingWomenLongTerm: Person = (.man, [.women], .lifePartner)
        let womanSeekingMenShortTerm: Person = (.woman, [.men], .shortTerm)
        let womanSeekingMenLongTerm: Person = (.woman, [.men], .longTerm)

        XCTAssertFalse(
            MatchPreferences.areMutuallyCompatible(
                manSeekingWomenLongTerm, womanSeekingMenShortTerm
            ),
            "Gender preferences line up, but the intentions cannot both be satisfied"
        )
        XCTAssertTrue(
            MatchPreferences.areMutuallyCompatible(
                manSeekingWomenLongTerm, womanSeekingMenLongTerm
            )
        )
    }
}
