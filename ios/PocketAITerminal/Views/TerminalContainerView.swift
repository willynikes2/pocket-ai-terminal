import SwiftUI

enum TerminalMode: String, CaseIterable {
    case thread = "Thread"
    case terminal = "Terminal"
}

struct TerminalContainerView: View {
    let session: Session
    let appState: AppState
    let authManager: AuthManager

    @State private var selectedMode: TerminalMode = .thread
    @State private var terminalStream = TerminalStream()
    @State private var blocks: [ThreadBlock] = []

    var body: some View {
        VStack(spacing: 0) {
            // Mode toggle
            Picker("Mode", selection: $selectedMode) {
                ForEach(TerminalMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Content
            switch selectedMode {
            case .thread:
                ThreadTerminalView(
                    blocks: blocks,
                    terminalStream: terminalStream
                )

            case .terminal:
                TerminalModeView(terminalStream: terminalStream)
            }
        }
        .background(PATColors.sessionBg)
        .navigationTitle(session.shortId)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                connectionIndicator
            }
        }
        .task {
            connectToSession()
        }
        .onDisappear {
            terminalStream.disconnect()
        }
    }

    // MARK: - Connection

    private var connectionIndicator: some View {
        Circle()
            .fill(indicatorColor)
            .frame(width: 8, height: 8)
    }

    private var indicatorColor: Color {
        switch terminalStream.connectionState {
        case .connected: PATColors.success
        case .connecting, .authenticating: .orange
        case .disconnected: PATColors.error
        }
    }

    private func connectToSession() {
        guard let ticket = session.wsTicket else { return }

        // Wire block updates for Thread Mode
        terminalStream.onBlocksChanged = { newBlocks in
            self.blocks = newBlocks
        }

        let apiClient = APIClient(authManager: authManager, baseURL: { appState.baseURL })

        terminalStream.connect(
            sessionId: session.sessionId,
            ticket: ticket,
            baseURL: appState.baseURL,
            ticketProvider: {
                let resumed = try await apiClient.resumeSession(id: session.sessionId)
                guard let newTicket = resumed.wsTicket else {
                    throw URLError(.badServerResponse)
                }
                return newTicket
            }
        )
    }
}
