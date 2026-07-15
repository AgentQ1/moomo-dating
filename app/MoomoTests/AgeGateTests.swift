import XCTest
@testable import Moomo

/// The 18+ gate. This is the one piece of validation with legal consequences,
/// so the boundaries are tested explicitly rather than by sampling.
final class AgeGateTests: XCTestCase {

    /// Fixed "now" so these can never start failing on a birthday.
    ///
    /// Built through `Calendar.current` rather than an epoch literal so it
    /// shares a timezone with the birthdays below — a UTC literal against
    /// local-time birthdays shifts the boundary cases by a day.
    private lazy var now = date(2026, 7, 15)

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components)!
    }

    private func birthday(_ year: Int, _ month: Int, _ day: Int) -> Date {
        date(year, month, day)
    }

    func testExactly18TodayIsAllowed() {
        let dob = birthday(2008, 7, 15)
        XCTAssertTrue(AgeGate.isOldEnough(birthDate: dob, now: now))
        XCTAssertEqual(AgeGate.validate(birthDate: dob, now: now), .valid)
    }

    /// The critical boundary: one day short of 18 must fail.
    func testOneDayBefore18thBirthdayIsRejected() {
        let dob = birthday(2008, 7, 16)
        XCTAssertFalse(AgeGate.isOldEnough(birthDate: dob, now: now))
        XCTAssertEqual(AgeGate.validate(birthDate: dob, now: now), .invalid(.underage))
    }

    func testOneDayAfter18thBirthdayIsAllowed() {
        XCTAssertTrue(AgeGate.isOldEnough(birthDate: birthday(2008, 7, 14), now: now))
    }

    func testClearlyUnderageIsRejected() {
        XCTAssertEqual(
            AgeGate.validate(birthDate: birthday(2015, 1, 1), now: now),
            .invalid(.underage)
        )
    }

    func testFutureDateIsRejected() {
        XCTAssertEqual(
            AgeGate.validate(birthDate: birthday(2030, 1, 1), now: now),
            .invalid(.inFuture)
        )
    }

    func testImplausiblyOldDateIsRejected() {
        XCTAssertEqual(
            AgeGate.validate(birthDate: birthday(1850, 1, 1), now: now),
            .invalid(.implausible)
        )
    }

    func testLatestAllowedBirthDateIsExactly18YearsAgo() {
        let latest = AgeGate.latestAllowedBirthDate(now: now)
        XCTAssertTrue(AgeGate.isOldEnough(birthDate: latest, now: now))

        let oneDayLater = Calendar.current.date(byAdding: .day, value: 1, to: latest)!
        XCTAssertFalse(AgeGate.isOldEnough(birthDate: oneDayLater, now: now))
    }

    func testAgeCalculation() {
        XCTAssertEqual(AgeGate.age(for: birthday(2000, 1, 1), now: now), 26)
        XCTAssertEqual(AgeGate.age(for: birthday(2008, 7, 15), now: now), 18)
    }
}
