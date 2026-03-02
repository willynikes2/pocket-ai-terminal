import SwiftUI

struct SettingsView: View {
    let authManager: AuthManager

    @Environment(\.dismiss) private var dismiss
    @State private var anthropicKey = ""
    @State private var openaiKey = ""
    @State private var hasAnthropicKey = false
    @State private var hasOpenaiKey = false
    @State private var showSaveConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                apiKeysSection
                accountSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                checkExistingKeys()
            }
        }
    }

    // MARK: - Sections

    private var apiKeysSection: some View {
        Section("API Keys") {
            HStack {
                VStack(alignment: .leading) {
                    Text("Anthropic")
                        .font(PATFonts.mono)
                    Text(hasAnthropicKey ? "Configured" : "Not set")
                        .font(PATFonts.monoSmall)
                        .foregroundStyle(hasAnthropicKey ? PATColors.success : PATColors.prompt)
                }
                Spacer()
                if hasAnthropicKey {
                    Button("Remove", role: .destructive) {
                        removeKey(account: KeychainService.anthropicKeyAccount)
                        hasAnthropicKey = false
                    }
                    .font(PATFonts.monoSmall)
                }
            }

            if !hasAnthropicKey {
                SecureField("sk-ant-...", text: $anthropicKey)
                    .font(PATFonts.mono)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { saveAnthropicKey() }
            }

            HStack {
                VStack(alignment: .leading) {
                    Text("OpenAI")
                        .font(PATFonts.mono)
                    Text(hasOpenaiKey ? "Configured" : "Not set")
                        .font(PATFonts.monoSmall)
                        .foregroundStyle(hasOpenaiKey ? PATColors.success : PATColors.prompt)
                }
                Spacer()
                if hasOpenaiKey {
                    Button("Remove", role: .destructive) {
                        removeKey(account: KeychainService.openaiKeyAccount)
                        hasOpenaiKey = false
                    }
                    .font(PATFonts.monoSmall)
                }
            }

            if !hasOpenaiKey {
                SecureField("sk-...", text: $openaiKey)
                    .font(PATFonts.mono)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { saveOpenaiKey() }
            }

            if !anthropicKey.isEmpty || !openaiKey.isEmpty {
                Button("Save Keys") {
                    if !anthropicKey.isEmpty { saveAnthropicKey() }
                    if !openaiKey.isEmpty { saveOpenaiKey() }
                    showSaveConfirmation = true
                }
            }
        }
        .alert("Keys Saved", isPresented: $showSaveConfirmation) {
            Button("OK") {}
        } message: {
            Text("API keys have been securely stored in the Keychain.")
        }
    }

    private var accountSection: some View {
        Section("Account") {
            Button("Log Out", role: .destructive) {
                authManager.logout()
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack {
                Text("Version")
                    .font(PATFonts.mono)
                Spacer()
                Text("0.1.0")
                    .font(PATFonts.monoSmall)
                    .foregroundStyle(PATColors.prompt)
            }
        }
    }

    // MARK: - Helpers

    private func checkExistingKeys() {
        hasAnthropicKey = (try? KeychainService.loadAPIKey(account: KeychainService.anthropicKeyAccount)) != nil
        hasOpenaiKey = (try? KeychainService.loadAPIKey(account: KeychainService.openaiKeyAccount)) != nil
    }

    private func saveAnthropicKey() {
        guard !anthropicKey.isEmpty else { return }
        var data = Data(anthropicKey.utf8)
        try? KeychainService.saveAPIKey(data, account: KeychainService.anthropicKeyAccount)
        data.resetBytes(in: 0..<data.count)
        anthropicKey = ""
        hasAnthropicKey = true
    }

    private func saveOpenaiKey() {
        guard !openaiKey.isEmpty else { return }
        var data = Data(openaiKey.utf8)
        try? KeychainService.saveAPIKey(data, account: KeychainService.openaiKeyAccount)
        data.resetBytes(in: 0..<data.count)
        openaiKey = ""
        hasOpenaiKey = true
    }

    private func removeKey(account: String) {
        try? KeychainService.deleteAPIKey(account: account)
    }
}
