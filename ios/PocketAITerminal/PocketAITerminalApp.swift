import SwiftUI

@main
struct PocketAITerminalApp: App {
    @State private var appState = AppState()
    @State private var authManager = AuthManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if authManager.isAuthenticated {
                    SessionsView(
                        appState: appState,
                        authManager: authManager
                    )
                } else {
                    OnboardingView(
                        appState: appState,
                        authManager: authManager
                    )
                }
            }
            .preferredColorScheme(.dark)
            .task {
                // Attempt silent token refresh on launch
                try? await authManager.refresh()
            }
        }
    }
}
