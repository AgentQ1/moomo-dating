import Foundation

/// Decides whether the app talks to a real backend or runs locally.
///
/// # The boundary
///
/// The app compiles and runs with no Firebase whatsoever. Two independent
/// things have to be true before it will use a real backend:
///
/// 1. **The SDK is linked.** Every Firebase call site is inside
///    `#if canImport(FirebaseAuth)`, so without the package those files
///    compile to nothing.
/// 2. **A config file is present.** `GoogleService-Info.plist` must be in the
///    app bundle.
///
/// If either is missing the app runs in `.localMock`, which is surfaced in the
/// UI by `MockModeBanner` — it is never silent. There are no fabricated
/// credentials anywhere in this repo, and `GoogleService-Info.plist` is
/// gitignored.
///
/// # Never mix projects
///
/// The Moomo **AI** app uses Firebase project `moomoios-2026`. That project
/// must never be used here: different product, different users, different
/// retention and consent basis. `assertNotAIProject()` fails the launch loudly
/// if that plist is ever dropped in by mistake.
enum BackendConfiguration {

    enum Mode: Equatable {
        /// Real Firebase. SDK linked and config present.
        case firebase(projectID: String)
        /// In-memory backend. Labeled in the UI.
        case localMock(reason: MockReason)

        var isMock: Bool {
            if case .localMock = self { return true }
            return false
        }
    }

    enum MockReason: Equatable {
        case sdkNotLinked
        case configFileMissing
        /// Requested by a test via `forceMockArgument`. DEBUG builds only.
        case forcedForTesting

        var explanation: String {
            switch self {
            case .sdkNotLinked:
                "Firebase SDK not linked"
            case .configFileMissing:
                "GoogleService-Info.plist not found"
            case .forcedForTesting:
                "Forced to mock for tests"
            }
        }
    }

    /// Launch argument that forces the in-memory backend regardless of the
    /// plist.
    ///
    /// Deterministic UI tests must not touch live Firebase: they would depend
    /// on the network, mint real accounts per run, and leave those accounts
    /// and their documents behind in the project.
    static let forceMockArgument = "-use-mock-backend"

    /// Set to `"1"` to let a test bundle's host app use real Firebase. Only the
    /// integration suite sets it; see `MoomoIntegration.xcscheme`.
    static let liveFirebaseEnvironmentKey = "MOOMO_USE_LIVE_FIREBASE"

    /// The Firebase project belonging to the *other* Moomo app. Refusing it
    /// here is cheaper than discovering the mistake in production data.
    static let forbiddenProjectID = "moomoios-2026"

    /// Resolved once at launch.
    static let current: Mode = resolve()

    private static func resolve() -> Mode {
        // DEBUG-only on purpose. A release build must never be talked into the
        // mock by a launch argument or a stray environment variable — that would
        // sign users into an in-memory account that looks real and loses
        // everything.
        #if DEBUG
        let process = ProcessInfo.processInfo

        if process.arguments.contains(forceMockArgument) {
            return .localMock(reason: .forcedForTesting)
        }

        // The app is hosting a unit-test bundle.
        //
        // This matters even though those tests inject their own mocks: hosting
        // launches the *app*, whose auth listener restores any persisted session
        // and bootstraps it against real Firestore. That is not hypothetical —
        // it is how ordinary `xcodebuild test` runs were quietly writing
        // documents into moomo-c7a37. The tests were on mocks; the app around
        // them was not.
        //
        // `XCTestConfigurationFilePath` is set in the host process for a hosted
        // unit-test bundle, and is absent from the app under UI test (there the
        // runner is a separate process), so this catches exactly the case it
        // should. The integration suite opts back in explicitly.
        if process.environment["XCTestConfigurationFilePath"] != nil,
           process.environment[liveFirebaseEnvironmentKey] != "1" {
            return .localMock(reason: .forcedForTesting)
        }
        #endif

        #if canImport(FirebaseCore)
        guard let path = Bundle.main.path(
            forResource: "GoogleService-Info", ofType: "plist"
        ) else {
            return .localMock(reason: .configFileMissing)
        }
        guard
            let plist = NSDictionary(contentsOfFile: path),
            let projectID = plist["PROJECT_ID"] as? String
        else {
            return .localMock(reason: .configFileMissing)
        }
        assertNotAIProject(projectID)
        return .firebase(projectID: projectID)
        #else
        return .localMock(reason: .sdkNotLinked)
        #endif
    }

    /// Traps if the AI app's Firebase project is configured here. This is a
    /// crash on purpose: silently writing dating data into the AI app's
    /// project would be far worse than failing to launch.
    private static func assertNotAIProject(_ projectID: String) {
        precondition(
            projectID != forbiddenProjectID,
            """
            Refusing to launch: GoogleService-Info.plist points at \
            '\(forbiddenProjectID)', which belongs to the Moomo AI app. \
            Moomo dating requires its own Firebase project.
            """
        )
    }
}
