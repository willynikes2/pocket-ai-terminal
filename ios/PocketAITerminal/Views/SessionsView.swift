import SwiftUI

struct SessionsView: View {
    let appState: AppState
    let authManager: AuthManager

    @State private var isCreating = false
    @State private var showSettings = false
    @State private var errorMessage: String?
    @State private var selectedProvider = "anthropic"

    private var apiClient: APIClient {
        APIClient(authManager: authManager, baseURL: { appState.baseURL })
    }

    var body: some View {
        NavigationStack {
            List {
                if appState.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "terminal",
                        description: Text("Create a new session to get started")
                    )
                }

                ForEach(appState.sessions) { session in
                    NavigationLink(value: session) {
                        SessionRow(session: session)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteSession(session)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        if session.status == .active {
                            Button {
                                sleepSession(session)
                            } label: {
                                Label("Sleep", systemImage: "moon")
                            }
                            .tint(.orange)
                        }

                        if session.status == .sleeping {
                            Button {
                                resumeSession(session)
                            } label: {
                                Label("Resume", systemImage: "play")
                            }
                            .tint(PATColors.success)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .background(PATColors.sessionBg)
            .scrollContentBackground(.hidden)
            .navigationTitle("Sessions")
            .navigationDestination(for: Session.self) { session in
                TerminalContainerView(
                    session: session,
                    appState: appState,
                    authManager: authManager
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isCreating = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .refreshable {
                await loadSessions()
            }
            .sheet(isPresented: $isCreating) {
                createSessionSheet
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(authManager: authManager)
            }
            .task {
                await loadSessions()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Create Session Sheet

    private var createSessionSheet: some View {
        NavigationStack {
            Form {
                Picker("AI Provider", selection: $selectedProvider) {
                    Text("Anthropic").tag("anthropic")
                    Text("OpenAI").tag("openai")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(PATColors.error)
                        .font(PATFonts.monoSmall)
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isCreating = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createSession() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Actions

    private func loadSessions() async {
        do {
            appState.sessions = try await apiClient.getSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createSession() {
        Task {
            do {
                // Load API key from Keychain
                let account = selectedProvider == "anthropic"
                    ? KeychainService.anthropicKeyAccount
                    : KeychainService.openaiKeyAccount

                guard let keyData = try KeychainService.loadAPIKey(account: account),
                      let apiKey = String(data: keyData, encoding: .utf8) else {
                    errorMessage = "No \(selectedProvider) API key configured. Add it in Settings."
                    return
                }

                let session = try await apiClient.createSession(
                    provider: selectedProvider,
                    apiKey: apiKey
                )
                appState.upsertSession(session)
                isCreating = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func sleepSession(_ session: Session) {
        Task {
            do {
                let updated = try await apiClient.sleepSession(id: session.sessionId)
                appState.upsertSession(updated)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func resumeSession(_ session: Session) {
        Task {
            do {
                let updated = try await apiClient.resumeSession(id: session.sessionId)
                appState.upsertSession(updated)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteSession(_ session: Session) {
        Task {
            do {
                try await apiClient.deleteSession(id: session.sessionId)
                appState.removeSession(id: session.sessionId)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.shortId)
                    .font(PATFonts.monoBold)
                    .foregroundStyle(PATColors.command)

                if let date = session.lastActiveDate {
                    Text(date, style: .relative)
                        .font(PATFonts.timestamp)
                        .foregroundStyle(PATColors.prompt)
                }
            }

            Spacer()

            StatusBadge(status: session.status)
        }
        .padding(.vertical, 4)
    }
}

private struct StatusBadge: View {
    let status: SessionStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(PATFonts.monoSmall)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(backgroundColor.opacity(0.2))
            .foregroundStyle(backgroundColor)
            .clipShape(Capsule())
    }

    private var backgroundColor: Color {
        switch status {
        case .active: PATColors.success
        case .sleeping: .orange
        case .stopped: PATColors.prompt
        }
    }
}
