import CoreLocation
import Foundation
import os

/// The coarse position that lets the backend rank closer people first.
///
/// This is the ONLY thing in the app that sends a coordinate anywhere, and it
/// is built so that the strongest statements in the privacy policy and the
/// permission prompt stay literally true:
///
///  - **Never finer than the grid.** The fix is requested at
///    `kCLLocationAccuracyReduced` (iOS's own coarsened location) and then
///    snapped to a `gridDegrees` lattice before it leaves the device. The
///    precise coordinate exists as a local constant inside one function and is
///    never stored, logged, or transmitted. Two people a few hundred metres
///    apart produce byte-identical documents.
///  - **Never public.** It is written to `users/{uid}/private/location`, which
///    Firestore rules make readable by its owner and nobody else — not other
///    users, not people you have called. `publicProfiles` allows `get` to any
///    signed-in user who knows a uid, so a coordinate there would be a
///    position-polling endpoint. Ranking works because Cloud Functions use the
///    Admin SDK, which bypasses rules.
///  - **Never a new prompt.** `refreshIfAuthorized` returns immediately unless
///    permission has ALREADY been granted. The one place the app asks for
///    location is the city picker's "use my current location" button, which
///    predates this file. Deny it, or never touch it, and nothing here runs —
///    Discover keeps working and the backend ranks that account neutrally.
///
/// The rules re-validate the grid on write, so a tampered client cannot store
/// a precise position even in its own private document.
enum CoarseLocation {

    /// The lattice every stored coordinate is snapped to, in degrees.
    ///
    /// 0.01° of latitude is ~1.11 km everywhere, and 0.01° of longitude is
    /// ~1.11 km at the equator and less towards the poles — so a cell is at
    /// most ~1.11 km on a side, and rounding to its centre displaces a real
    /// position by up to ~0.8 km.
    ///
    /// MUST equal `LOCATION_GRID_DEGREES` in
    /// backend/functions/src/proximity.ts and the tolerance in
    /// `isCoarseGridValue` in backend/firestore.rules. A change here that
    /// isn't made there bounces every legitimate write.
    static let gridDegrees = 0.01

    /// How often a fresh fix is worth taking. Long on purpose: ranking only
    /// needs to know which city someone is in, and a tighter cadence would be
    /// a movement trail — which is precisely what this design refuses to
    /// build, and would fail the "we don't track you" claim.
    static let minimumRefreshInterval: TimeInterval = 6 * 60 * 60

    /// A coordinate component rounded to its cell centre. The mirror of
    /// `snapToGrid` in proximity.ts; pure, so the ~1 km guarantee is a
    /// property a unit test can assert rather than a comment.
    static func snap(_ value: Double) -> Double {
        (value / gridDegrees).rounded() * gridDegrees
    }

    /// True when a coordinate is one this app could legitimately have stored:
    /// on the grid and inside the real range. The rules enforce the same
    /// thing server-side; this is the client-side half of the contract.
    static func isSnapped(_ value: Double, limit: Double) -> Bool {
        value >= -limit && value <= limit
            && abs(value / gridDegrees - (value / gridDegrees).rounded()) < 0.001
    }
}

/// Process-lifetime throttle, matching `PresenceHeartbeatTracker`: rebuilding
/// the service graph (tab switches, sign-in cycles) must not reset it into
/// taking a fix on every Discover open.
final class CoarseLocationRefreshTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSentByUid: [String: Date] = [:]

    /// True exactly when a refresh should happen now — and records it, so the
    /// next `minimumRefreshInterval` of calls answer false. Recorded even if
    /// the write then fails: this is best-effort, and retrying a failed fix on
    /// every feed load would be a battery bug.
    func markSendable(uid: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastSentByUid[uid],
           now.timeIntervalSince(last) < CoarseLocation.minimumRefreshInterval {
            return false
        }
        lastSentByUid[uid] = now
        return true
    }
}

#if canImport(FirebaseFirestore)
import FirebaseFirestore

/// Takes one reduced-accuracy fix and stores its snapped form.
///
/// Silent by construction: it never calls `requestWhenInUseAuthorization`, so
/// it can never surface a permission dialog. If the user has not already
/// granted location access — the default, and the permanent state for anyone
/// who declines — every call is a no-op and their feed is ranked by recency
/// alone, exactly as it was before proximity shipped.
@MainActor
final class CoarseLocationReporter: NSObject {

    private static let log = Logger(subsystem: "com.moomo.dating", category: "location")
    private static let refreshes = CoarseLocationRefreshTracker()

    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        // Reduced, not "best": the answer is thrown onto a ~1 km grid anyway,
        // so asking iOS for precision would collect more than is used.
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    /// Refreshes the stored position if — and only if — permission is already
    /// granted and the throttle window has passed.
    ///
    /// Best-effort and non-throwing: a failed fix or a failed write must never
    /// disturb whatever the caller was actually doing (loading the feed).
    static func refreshIfAuthorized(uid: String) async {
        let status = CLLocationManager().authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        guard refreshes.markSendable(uid: uid) else { return }

        let reporter = CoarseLocationReporter()
        guard let location = await reporter.fix() else { return }
        await write(location.coordinate, uid: uid)
    }

    /// Snaps and stores. Split out from the fix so the coordinate's journey is
    /// one short, readable path: raw fix → snap → write. Nothing between them
    /// keeps the precise value.
    private static func write(_ coordinate: CLLocationCoordinate2D, uid: String) async {
        let lat = CoarseLocation.snap(coordinate.latitude)
        let lng = CoarseLocation.snap(coordinate.longitude)
        // Defensive: a coordinate outside the real range is a broken fix, not
        // a position, and the rules would refuse it anyway.
        guard CoarseLocation.isSnapped(lat, limit: 90),
              CoarseLocation.isSnapped(lng, limit: 180) else { return }
        do {
            try await Firestore.firestore()
                .collection(FirestorePath.users).document(uid)
                .collection(FirestorePath.privateCollection)
                .document(FirestorePath.locationDocument)
                .setData([
                    "lat": lat,
                    "lng": lng,
                    // The rules require the SERVER's clock: staleness decides
                    // whether a position still ranks, so a client-claimed
                    // stamp could keep a dead position alive forever.
                    "updatedAt": FieldValue.serverTimestamp()
                ])
        } catch {
            // Ranking degrades to neutral for this user. Nothing else breaks.
            Self.log.debug("coarse location write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// One fix, or nil. Never throws and never waits forever — a device that
    /// cannot get a fix (indoors, airplane mode) must not hang the caller.
    private func fix() async -> CLLocation? {
        await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    self.pending = continuation
                    self.manager.requestLocation()
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func resume(with location: CLLocation?) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: location)
    }
}

extension CoarseLocationReporter: CLLocationManagerDelegate {

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        let last = locations.last
        Task { @MainActor in self.resume(with: last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resume(with: nil) }
    }
}
#endif
