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

        var explanation: String {
            switch self {
            case .sdkNotLinked:
                "Firebase SDK not linked"
            case .configFileMissing:
                "GoogleService-Info.plist not found"
            }
        }
    }

    /// The Firebase project belonging to the *other* Moomo app. Refusing it
    /// here is cheaper than discovering the mistake in production data.
    static let forbiddenProjectID = "moomoios-2026"

    /// Resolved once at launch.
    static let current: Mode = resolve()

    private static func resolve() -> Mode {
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
