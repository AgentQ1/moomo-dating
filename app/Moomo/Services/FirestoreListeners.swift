import Foundation
import os

/// Central sink for realtime listener failures.
///
/// A snapshot listener that errors delivers a nil snapshot; dropping that on
/// the floor leaves the screen frozen on stale data with no trace anywhere.
/// Every Firestore listener routes its error here: always logged, and
/// re-published so the tab shell can tell the user live updates stopped.
enum FirestoreListeners {
    private static let log = Logger(subsystem: "com.moomo.dating", category: "firestore-listener")

    /// The most recent listener failure (listener name), nil when healthy.
    /// `MainTabView` renders a "live updates paused" banner from this.
    static let failures = StreamBroadcaster<String?>(nil)

    static func report(_ error: Error?, in listener: StaticString) {
        log.error("Listener \(listener, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        failures.send("\(listener)")
    }

    /// A healthy snapshot arrived: clear any banner for this listener.
    static func recovered(_ listener: StaticString) {
        if failures.value == "\(listener)" {
            failures.send(nil)
        }
    }
}
