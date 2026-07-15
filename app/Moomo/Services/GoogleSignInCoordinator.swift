import Foundation

#if canImport(GoogleSignIn)
import GoogleSignIn
import UIKit

/// Runs the real Google Sign-In sheet and returns a credential.
@MainActor
struct GoogleSignInCoordinator {

    func signIn() async throws -> ProviderCredential {
        // GoogleSignIn needs a presenting view controller. On a backgrounded or
        // torn-down scene there isn't one — that is a real failure, not a
        // cancellation, and must not be silently swallowed.
        guard let presenter = Self.topViewController() else {
            throw AuthError.providerFailed("Google")
        }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter
            )

            guard let idToken = result.user.idToken?.tokenString else {
                throw AuthError.providerFailed("Google")
            }

            return .google(
                idToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
        } catch let error as NSError
                    where error.code == GIDSignInError.canceled.rawValue {
            // Backing out is a choice, not a failure.
            throw AuthError.cancelled
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.providerFailed("Google")
        }
    }

    /// The frontmost view controller of the active foreground scene.
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        guard var top = scene?.keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}
#endif
