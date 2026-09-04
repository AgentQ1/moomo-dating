import XCTest
@testable import Moomo

/// The client half of the proximity privacy contract.
///
/// `CoarseLocationReporter` needs CoreLocation and Firestore to do its job, so
/// what is tested here is the part that carries the guarantee: the grid. The
/// promise made in the permission prompt, the privacy policy and the App Store
/// privacy label is that nothing finer than roughly a kilometre ever leaves the
/// device — and that promise is exactly the behaviour of `snap`.
///
/// The server-side mirrors are asserted in
/// backend/functions/test/proximity.test.mjs (same constant, same rounding) and
/// backend/rules-tests/firestore.rules.test.mjs (a write off the grid is
/// refused). All three must move together.
final class CoarseLocationTests: XCTestCase {

    // MARK: - The grid

    func testSnapRoundsToTheCellCentre() {
        XCTAssertEqual(CoarseLocation.snap(41.8781136), 41.88, accuracy: 1e-9)
        XCTAssertEqual(CoarseLocation.snap(-87.6297982), -87.63, accuracy: 1e-9)
        XCTAssertEqual(CoarseLocation.snap(0), 0, accuracy: 1e-9)
    }

    func testSnapIsIdempotent() {
        let once = CoarseLocation.snap(51.5073219)
        XCTAssertEqual(CoarseLocation.snap(once), once, accuracy: 1e-9)
    }

    /// The privacy property, stated as a test: two real positions a few
    /// hundred metres apart must become the same stored value. If this ever
    /// fails, the app is storing something finer than it promises.
    func testNearbyPositionsCollapseToOneIndistinguishablePoint() {
        let a = (CoarseLocation.snap(41.8781), CoarseLocation.snap(-87.6298))
        let b = (CoarseLocation.snap(41.8815), CoarseLocation.snap(-87.6262))
        XCTAssertEqual(a.0, b.0, accuracy: 1e-9)
        XCTAssertEqual(a.1, b.1, accuracy: 1e-9)
    }

    func testTheCellIsAboutOneKilometre() {
        // A degree of latitude is ~111.32 km everywhere, so one cell of
        // latitude is ~1.11 km — the coarsest claim the copy has to support.
        let cellKm = CoarseLocation.gridDegrees * 111.32
        XCTAssertGreaterThan(cellKm, 1.0)
        XCTAssertLessThan(cellKm, 1.2)
    }

    func testTheGridMatchesTheBackendConstant() {
        // LOCATION_GRID_DEGREES in backend/functions/src/proximity.ts and the
        // 0.001 tolerance on `value * 100` in backend/firestore.rules both
        // assume exactly this. A silent change here bounces every write.
        XCTAssertEqual(CoarseLocation.gridDegrees, 0.01)
    }

    // MARK: - Validation

    func testASnappedCoordinateValidates() {
        XCTAssertTrue(CoarseLocation.isSnapped(41.88, limit: 90))
        XCTAssertTrue(CoarseLocation.isSnapped(-87.63, limit: 180))
        XCTAssertTrue(CoarseLocation.isSnapped(0, limit: 90))
        XCTAssertTrue(CoarseLocation.isSnapped(-90, limit: 90))
        XCTAssertTrue(CoarseLocation.isSnapped(180, limit: 180))
    }

    func testAPreciseCoordinateIsRejected() {
        // The rules refuse these server-side too; catching them here means a
        // broken client never even attempts the write.
        XCTAssertFalse(CoarseLocation.isSnapped(41.8781136, limit: 90))
        XCTAssertFalse(CoarseLocation.isSnapped(-87.6297982, limit: 180))
    }

    func testACoordinateOffGridByATenthOfACellIsRejected() {
        // 0.001° ≈ 111 m — inside a cell, so it carries finer information
        // than the grid promises.
        XCTAssertFalse(CoarseLocation.isSnapped(41.881, limit: 90))
    }

    func testOutOfRangeCoordinatesAreRejected() {
        XCTAssertFalse(CoarseLocation.isSnapped(91, limit: 90))
        XCTAssertFalse(CoarseLocation.isSnapped(-181, limit: 180))
    }

    func testEverySnappedValueValidates() {
        // Round-trip property: whatever `snap` produces, `isSnapped` accepts —
        // so the reporter's own guard can never silently discard a legitimate
        // fix and leave a user permanently unlocated.
        for raw in stride(from: -89.9, through: 89.9, by: 7.3) {
            XCTAssertTrue(
                CoarseLocation.isSnapped(CoarseLocation.snap(raw), limit: 90),
                "snap(\(raw)) should validate"
            )
        }
    }

    // MARK: - Throttle

    func testTheFirstRefreshIsAllowed() {
        let tracker = CoarseLocationRefreshTracker()
        XCTAssertTrue(tracker.markSendable(uid: "u1"))
    }

    func testASecondRefreshInsideTheWindowIsRefused() {
        let tracker = CoarseLocationRefreshTracker()
        let now = Date()
        XCTAssertTrue(tracker.markSendable(uid: "u1", now: now))
        XCTAssertFalse(tracker.markSendable(uid: "u1", now: now.addingTimeInterval(60)))
    }

    func testARefreshAfterTheWindowIsAllowed() {
        let tracker = CoarseLocationRefreshTracker()
        let now = Date()
        XCTAssertTrue(tracker.markSendable(uid: "u1", now: now))
        XCTAssertTrue(
            tracker.markSendable(
                uid: "u1",
                now: now.addingTimeInterval(CoarseLocation.minimumRefreshInterval + 1)
            )
        )
    }

    func testTheThrottleIsPerUser() {
        // Signing out and back in as someone else must not inherit the
        // previous account's throttle.
        let tracker = CoarseLocationRefreshTracker()
        let now = Date()
        XCTAssertTrue(tracker.markSendable(uid: "u1", now: now))
        XCTAssertTrue(tracker.markSendable(uid: "u2", now: now))
    }

    func testTheRefreshCadenceIsCoarseEnoughToNotBeATrail() {
        // Hours, not minutes. A tight cadence would turn a series of coarse
        // points into a movement history, which is the thing this design
        // refuses to build.
        XCTAssertGreaterThanOrEqual(CoarseLocation.minimumRefreshInterval, 60 * 60)
    }
}
