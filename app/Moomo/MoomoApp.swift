import SwiftUI

@main
struct MoomoApp: App {
    @StateObject private var session: SessionStore

    init() {
        // Must run before anything touches Auth or Firestore.
        FirebaseBootstrap.configureIfNeeded()

        // UI tests need a cold, signed-out app. Without this each test would
        // inherit the previous one's account and drafts.
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset") {
            MockUserStore.standard.reset()
            OnboardingDraftStorage.standard.resetAll()
        }

        // Composition root. This is the only place that decides which backend
        // the app talks to; nothing downstream knows or cares.
        _session = StateObject(wrappedValue: SessionStore(auth: Self.makeAuthService()))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .onOpenURL { url in
                    // Google's OAuth callback. Without this the sheet returns
                    // to a blank screen rather than the app.
                    _ = FirebaseBootstrap.handle(url: url)
                }
        }
    }

    private static func makeAuthService() -> AuthenticationService {
        switch BackendConfiguration.current {
        case .firebase:
            #if canImport(FirebaseAuth)
            return FirebaseAuthenticationService()
            #else
            // A real config with no SDK linked is a build misconfiguration.
            // Falling back to the mock here would silently ship an app that
            // authenticates nobody while looking like it works.
            fatalError(
                "GoogleService-Info.plist is present but the Firebase SDK is not linked."
            )
            #endif

        case .localMock(let reason):
            #if !DEBUG
            // Never in production. A release build that quietly used the mock
            // would sign users into an in-memory account and lose everything.
            fatalError("Release builds require Firebase. Mock reason: \(reason).")
            #else
            return MockAuthenticationService()
            #endif
        }
    }
}

/// Routes on session state. The single switch that decides what the user sees.
struct RootView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            if case .localMock(let reason) = BackendConfiguration.current {
                MockModeBanner(reason: reason)
            }

            Group {
                switch session.route {
                case .launching:
                    LaunchView()

                case .welcome:
                    WelcomeView()

                case .onboarding:
                    if let user = session.user {
                        // Keyed by id so switching accounts builds a fresh
                        // onboarding model rather than reusing the old draft.
                        OnboardingFlow(user: user)
                            .id(user.id)
                    } else {
                        LaunchView()
                    }

                case .main:
                    MainTabView()
                }
            }
            .transition(.opacity)
        }
        .animation(Motion.transition, value: session.route)
        .alert(
            "Sign-in failed",
            isPresented: Binding(
                get: { session.error != nil },
                set: { if !$0 { session.error = nil } }
            )
        ) {
            if let error = session.error,
               error.isRetryable,
               let provider = session.lastAttemptedProvider {
                Button("Try again") { session.retry(provider: provider) }
            }
            Button("OK", role: .cancel) { session.error = nil }
        } message: {
            Text(session.error?.errorDescription ?? "Something went wrong.")
        }
    }
}

/// Shown while the persisted session is resolved. Deliberately just the mark
/// on the brand background — no spinner, because this resolves in a frame or
/// two and a flashing spinner reads as jank.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            LogoMark(diameter: 180)
        }
    }
}
