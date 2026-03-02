import SwiftUI

struct ExtendedKeyboardView: View {
    let onKey: (Data) -> Void

    @State private var ctrlActive = false

    var body: some View {
        HStack(spacing: 12) {
            KeyButton(label: "Ctrl", isActive: ctrlActive) {
                ctrlActive.toggle()
            }
            KeyButton(label: "Tab") {
                ctrlActive = false
                onKey(Data([0x09])) // HT
            }
            KeyButton(label: "Esc") {
                ctrlActive = false
                onKey(Data([0x1B])) // ESC
            }

            Divider()
                .frame(height: 20)

            KeyButton(label: "\u{2191}") { // ↑
                sendArrow("A")
            }
            KeyButton(label: "\u{2193}") { // ↓
                sendArrow("B")
            }
            KeyButton(label: "\u{2190}") { // ←
                sendArrow("D")
            }
            KeyButton(label: "\u{2192}") { // →
                sendArrow("C")
            }

            Spacer()

            KeyButton(label: "\u{2328}") { // ⌨
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
    }

    private func sendArrow(_ code: String) {
        ctrlActive = false
        // CSI sequence: ESC [ {code}
        onKey(Data([0x1B, 0x5B, UInt8(code.utf8.first!)]))
    }

    /// Call this from the terminal view when a regular key is pressed
    /// while Ctrl is active, to send the control character.
    func controlCharacter(for key: UInt8) -> UInt8? {
        guard ctrlActive else { return nil }
        // Control characters: key & 0x1F (maps a-z to 1-26)
        if key >= 0x61 && key <= 0x7A { // a-z
            return key & 0x1F
        }
        return nil
    }
}

private struct KeyButton: View {
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(isActive ? PATColors.aiAccent : PATColors.command)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
