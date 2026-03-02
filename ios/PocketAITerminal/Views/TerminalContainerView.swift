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
    @State private var showFilePicker = false
    @State private var isUploading = false
    @State private var toastMessage: String?

    var body: some View {
        ZStack(alignment: .top) {
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
                        terminalStream: terminalStream,
                        onUpload: { showFilePicker = true }
                    )

                case .terminal:
                    TerminalModeView(terminalStream: terminalStream)
                }
            }

            // Toast overlay
            if let message = toastMessage {
                ToastView(message: message)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }

            // Upload spinner overlay
            if isUploading {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("Uploading...")
                            .font(PATFonts.monoSmall)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
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
        .sheet(isPresented: $showFilePicker) {
            FilePickerView { files in
                guard !files.isEmpty else { return }
                handleUpload(files: files)
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

    // MARK: - Upload

    private func handleUpload(files: [(filename: String, data: Data)]) {
        let apiClient = APIClient(authManager: authManager, baseURL: { appState.baseURL })

        Task {
            isUploading = true
            do {
                let response = try await apiClient.uploadFiles(files, sessionId: session.sessionId)
                for file in response.uploaded {
                    let sizeKB = String(format: "%.1f", Double(file.size) / 1024.0)
                    terminalStream.addMetaBlock(
                        content: "Uploaded \(file.name) → \(file.path) (\(sizeKB) KB)"
                    )
                }
                showToast("Uploaded \(response.uploaded.count) file\(response.uploaded.count == 1 ? "" : "s")")
            } catch {
                showToast("Upload failed: \(error.localizedDescription)")
            }
            isUploading = false
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.3)) {
            toastMessage = message
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut(duration: 0.3)) {
                toastMessage = nil
            }
        }
    }
}

// MARK: - Toast View

private struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(PATFonts.monoSmall)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(PATColors.commandBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(PATColors.blockBorder, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }
}
