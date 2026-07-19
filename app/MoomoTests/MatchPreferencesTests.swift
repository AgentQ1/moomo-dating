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
        let womanSeekingWomen: (Gender?, Set<InterestedIn>) = (.woman, [.women])
        let manSeekingWomen: (Gender?, Set<InterestedIn>) = (.man, [.women])
        let womanSeekingMen: (Gender?, Set<InterestedIn>) = (.woman, [.men])

        // He wants her; she does not want him.
        XCTAssertFalse(MatchPreferences.areMutuallyCompatible(womanSeekingWomen, manSeekingWomen))
        // Both directions hold.
        XCTAssertTrue(MatchPreferences.areMutuallyCompatible(manSeekingWomen, womanSeekingMen))
        XCTAssertTrue(MatchPreferences.areMutuallyCompatible(womanSeekingWomen, womanSeekingWomen))
    }
}
