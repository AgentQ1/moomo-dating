import AuthenticationServices
import CryptoKit
import Foundation

/// Runs the real Sign in with Apple sheet and returns a credential.
///
/// This is genuine `AuthenticationServices` — the system sheet, a real
/// identity token, real cancellation. It works the same in mock and Firebase
/// mode because the credential is produced by Apple either way; only who
/// exchanges it differs.
@MainActor
final class AppleSignInCoordinator: NSObject {

    private var continuation: CheckedContinuation<ProviderCredential, Error>?
    /// Retained for the token exchange: Firebase requires the raw nonce whose
    /// SHA-256 was sent to Apple.
    private var currentNonce: String?

    func signIn() async throws -> ProviderCredential {
        let nonce = Self.randomNonce()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func finish(with result: Result<ProviderCredential, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    // MARK: - Nonce

    /// Apple requires a nonce to bind the token to this request and stop
    /// replay. Firebase then checks the raw value against the hash Apple
    /// signed.
    static func randomNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        guard status == errSecSuccess else {
            // A failure here means the system CSPRNG is unavailable; proceeding
            // with a predictable nonce would defeat the replay protection.
            fatalError("Unable to generate a secure nonce: OSStatus \(status)")
        }

        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let nonce = currentNonce
            else {
                finish(with: .failure(AuthError.providerFailed("Apple")))
                return
            }

            // Apple returns the name only on the very first authorization, so
            // it must be captured now — it is unrecoverable afterwards.
            let name = [
                credential.fullName?.givenName,
                credential.fullName?.familyName
            ]
            .compactMap { $0 }
            .joined(separator: " ")

            finish(with: .success(.apple(
                idToken: idToken,
                nonce: nonce,
                fullName: name.isEmpty ? nil : name,
                email: credential.email
            )))
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            let authError = (error as? ASAuthorizationError).map { asError -> AuthError in
                switch asError.code {
                case .canceled: .cancelled
                case .failed, .invalidResponse, .notHandled: .providerFailed("Apple")
                case .notInteractive: .providerFailed("Apple")
                default: .unknown(asError.localizedDescription)
                }
            } ?? .unknown(error.localizedDescription)

            finish(with: .failure(authError))
        }
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }

            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }
}
