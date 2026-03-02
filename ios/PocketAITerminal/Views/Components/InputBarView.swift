import SwiftUI

/// Bottom input bar with monospace TextField, send button, and quick action chips.
/// Per build-sheet Section 17.4.
struct InputBarView: View {
    @Binding var text: String
    let onSubmit: (String) -> Void
    let onUpload: () -> Void
    let onKey: (Data) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Quick action chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    QuickChip(label: "Upload", icon: "paperclip") {
                        onUpload()
                    }
                    QuickChip(label: "Claude", icon: "play.fill") {
                        submitCommand("pat claude \"\"")
                    }
                    QuickChip(label: "git status") {
                        submitCommand("git status")
                    }
                    QuickChip(label: "git diff") {
                        submitCommand("git diff")
                    }
                    QuickChip(label: "pat doctor") {
                        submitCommand("pat doctor")
                    }
                }
                .padding(.horizontal, 12)
            }

            // Input row
            HStack(spacing: 8) {
                Button(action: onUpload) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18))
                        .foregroundStyle(PATColors.prompt)
                        .frame(width: 36, height: 36)
                }

                TextField("$ command...", text: $text, axis: .vertical)
                    .font(PATFonts.mono)
                    .foregroundStyle(PATColors.command)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit {
                        submit()
                    }
                    .submitLabel(.send)

                Button(action: submit) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(text.isEmpty ? PATColors.prompt : PATColors.aiAccent)
                        .frame(width: 36, height: 36)
                        .background(
                            text.isEmpty
                                ? PATColors.blockBorder
                                : PATColors.aiAccent.opacity(0.2)
                        )
                        .clipShape(Circle())
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(PATColors.inputBarBg)
        }
        .background(PATColors.inputBarBg)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                ExtendedKeyboardView(onKey: onKey)
            }
        }
    }

    private func submit() {
        let command = text.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        onSubmit(command)
        text = ""
    }

    private func submitCommand(_ command: String) {
        onSubmit(command)
    }
}

/// Tappable quick action chip above the input bar.
private struct QuickChip: View {
    let label: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption)
                }
                Text(label)
                    .font(PATFonts.monoSmall)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(PATColors.blockBorder)
            .foregroundStyle(PATColors.command)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
