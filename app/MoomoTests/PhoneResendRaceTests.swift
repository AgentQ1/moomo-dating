import XCTest
@testable import Moomo

/// The resend button's race: the cooldown only starts once the SMS is OUT, so
/// a double-tap (or a tap during a slow send) used to fire two SMS — and the
/// second invalidated the code from the first.
@MainActor
final class PhoneResendRaceTests: XCTestCase {

    /// Counts SMS sends; each send takes `sendDelay` to complete.
    private final class CountingAuthService: AuthenticationService, @unchecked Sendable {
        private let lock = NSLock()
        private var _smsCount = 0
        var smsCount: Int { lock.withLock { _smsCount } }
        let sendDelay: Duration

        init(sendDelay: Duration) {
            self.sendDelay = sendDelay
        }

        var userStream: AsyncStream<User?> { AsyncStream { $0.finish() } }
        var currentUser: User? { nil }

        func sendCode(to phoneNumber: String) async throws -> String {
            lock.withLock { _smsCount += 1 }
            try? await Task.sleep(for: sendDelay)
            return "verification-\(UUID().uuidString)"
        }

        func signIn(verificationID: String, code: String, consent: ConsentRecord) async throws -> User {
            throw AuthError.cancelled
        }
        func updateProfile(_ profile: Profile) async throws {}
        func completeOnboarding() async throws {}
        func signOut() async throws {}
        func deleteAccount() async throws {}
    }

    func testDoubleTappedResendSendsExactlyOneSMS() async {
        let auth = CountingAuthService(sendDelay: .milliseconds(200))
        // Zero cooldown isolates the in-flight race from the timer throttle.
        let model = PhoneAuthModel(auth: auth, resendInterval: 0)
        model.nationalNumber = "5550100200"
        model.sendCode(hasConsented: true)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.stage, .codeSent)
        XCTAssertEqual(auth.smsCount, 1)

        model.resendCode()
        XCTAssertTrue(model.isResending, "Resend must lock synchronously, before any await")
        model.resendCode()
        model.resendCode()
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(auth.smsCount, 2, "One tap, one SMS — the extra taps must be refused")
        XCTAssertFalse(model.isResending)
    }
}
