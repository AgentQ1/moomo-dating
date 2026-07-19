import SwiftUI

@main
struct MoomoApp: App {
    /// UIKit bridge for Firebase Phone Auth: APNs registration, the silent
    /// verification push, and auth callback URLs all arrive through delegate
    /// methods SwiftUI has no equivalent for.
    @UIApplicationDelegateAdaptor(MoomoAppDelegate.self) private var appDelegate
    @StateObject private var session: SessionStore

    init() {
        // Firebase is deliberately NOT configured here. This initializer runs
        // before UIApplicationMain, and FirebaseAuth (an always-eager Firebase
        // component) captures UIApplication.sharedApplication during
        // configure() — nil at this point, which permanently disables its
        // phone-auth machinery (every verifyPhoneNumber then fails with the
        // "app delegate swizzling" error, and the first APNs token delivery
        // crashes). MoomoAppDelegate.didFinishLaunching configures instead,
        // and runs before any view — or the session below — exists.

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
                    // Phone verification's reCAPTCHA return. Without this the
                    // web page comes back to a blank screen rather than the
                    // app.
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
                    WelcomeView(auth: session.auth)

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
                    // Keyed by id so switching accounts rebuilds the tab
                    // shell and its per-session services — one user's
                    // matches, chats, and blocks must never leak to another.
                    if let user = session.user {
                        MainTabView(user: user)
                            .id(user.id)
                    } else {
                        LaunchView()
                    }
                }
            }
            .transition(.opacity)
        }
        .animation(Motion.transition, value: session.route)
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { session.error != nil },
                set: { if !$0 { session.error = nil } }
            )
        ) {
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
