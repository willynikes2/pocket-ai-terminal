import SwiftUI

struct OnboardingView: View {
    let appState: AppState
    let authManager: AuthManager

    @State private var devToken = ""
    @State private var serverURL = "http://localhost:8000"
    @State private var anthropicKey = ""
    @State private var openaiKey = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    serverSection
                    authSection
                    apiKeysSection
                    connectButton
                }
                .padding()
            }
            .background(PATColors.sessionBg)
            .navigationTitle("Pocket AI Terminal")
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(PATColors.aiAccent)
            Text("Cloud Terminal Sessions")
                .font(.headline)
                .foregroundStyle(PATColors.command)
            Text("Connect to your backend to start coding")
                .font(.subheadline)
                .foregroundStyle(PATColors.prompt)
        }
        .padding(.top, 32)
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Server URL", systemImage: "server.rack")
                .font(PATFonts.monoSmall)
                .foregroundStyle(PATColors.prompt)
            TextField("http://localhost:8000", text: $serverURL)
                .textFieldStyle(.roundedBorder)
                .font(PATFonts.mono)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    private var authSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Dev Token", systemImage: "key")
                .font(PATFonts.monoSmall)
                .foregroundStyle(PATColors.prompt)
            SecureField("dev-token-change-me", text: $devToken)
                .textFieldStyle(.roundedBorder)
                .font(PATFonts.mono)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    private var apiKeysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("API Keys (stored in Keychain)", systemImage: "lock.shield")
                .font(PATFonts.monoSmall)
                .foregroundStyle(PATColors.prompt)

            VStack(alignment: .leading, spacing: 4) {
                Text("Anthropic API Key")
                    .font(PATFonts.monoSmall)
                    .foregroundStyle(PATColors.prompt)
                SecureField("sk-ant-...", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
                    .font(PATFonts.mono)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("OpenAI API Key (optional)")
                    .font(PATFonts.monoSmall)
                    .foregroundStyle(PATColors.prompt)
                SecureField("sk-...", text: $openaiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(PATFonts.mono)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
    }

    private var connectButton: some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Text(errorMessage)
                    .font(PATFonts.monoSmall)
                    .foregroundStyle(PATColors.error)
            }

            Button(action: connect) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    }
                    Text("Connect")
                        .font(PATFonts.monoBold)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(PATColors.aiAccent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(devToken.isEmpty || isLoading)
        }
        .padding(.top, 8)
    }

    // MARK: - Actions

    private func connect() {
        isLoading = true
        errorMessage = nil

        Task {
            do {
                // Save API keys to Keychain
                if !anthropicKey.isEmpty {
                    var keyData = Data(anthropicKey.utf8)
                    try KeychainService.saveAPIKey(keyData, account: KeychainService.anthropicKeyAccount)
                    keyData.resetBytes(in: 0..<keyData.count)
                }
                if !openaiKey.isEmpty {
                    var keyData = Data(openaiKey.utf8)
                    try KeychainService.saveAPIKey(keyData, account: KeychainService.openaiKeyAccount)
                    keyData.resetBytes(in: 0..<keyData.count)
                }

                // Authenticate
                try await authManager.login(devToken: devToken, baseURL: serverURL)
                appState.baseURL = serverURL

                // Clear sensitive fields from memory
                devToken = ""
                anthropicKey = ""
                openaiKey = ""
            } catch {
                errorMessage = error.localizedDescription
            }

            isLoading = false
        }
    }
}
