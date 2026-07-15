import SwiftUI

@main
struct MoomoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Temporary root. Replaced in Phase 3 by the auth-gated flow coordinator.
struct RootView: View {
    var body: some View {
        WelcomeView()
    }
}
