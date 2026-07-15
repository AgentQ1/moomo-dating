import Foundation

/// Obtains a provider credential — the step that shows Apple's or Google's
/// sheet, before any backend is involved.
///
/// Split out from `SessionStore` because it is the one part of sign-in that
/// cannot run headless: it needs a window and a real Apple ID. With it behind
/// a protocol, the session logic — consent gating, error mapping, retry,
/// linking, routing — is testable without a UI, while the app still runs the
/// genuine system flows.
protocol CredentialProviding: Sendable {
    func credential(for provider: AuthProvider) async throws -> ProviderCredential
}

/// The real thing: Apple's system sheet, Google's SDK, Firebase anonymous.
struct LiveCredentialProvider: CredentialProviding {

    func credential(for provider: AuthProvider) async throws -> ProviderCredential {
        switch provider {
        case .apple:
            return try await AppleSignInCoordinator().signIn()

        case .google:
            #if canImport(GoogleSignIn)
            return try await GoogleSignInCoordinator().signIn()
            #else
            // No SDK linked. In mock mode this stands in for the provider round
            // trip so the rest of the flow is exercisable; in a real build it
            // is a hard failure rather than a silent fake success.
            guard BackendConfiguration.current.isMock else {
                throw AuthError.providerFailed("Google")
            }
            return .google(idToken: "mock-id-token", accessToken: "mock-access-token")
            #endif

        case .guest:
            // Anonymous needs no provider round trip; the backend mints it.
            return .anonymous
        }
    }
}

/// Deterministic credentials for tests.
struct MockCredentialProvider: CredentialProviding {
    /// Injects a provider-stage failure (user cancelled the Apple sheet, say).
    var failure: AuthError?

    func credential(for provider: AuthProvider) async throws -> ProviderCredential {
        if let failure { throw failure }

        switch provider {
        case .apple:
            return .apple(
                idToken: "test-apple-token",
                nonce: "test-nonce",
                fullName: nil,
                email: nil
            )
        case .google:
            return .google(idToken: "test-google-token", accessToken: "test-access-token")
        case .guest:
            return .anonymous
        }
    }
}
