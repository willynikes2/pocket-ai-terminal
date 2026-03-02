import SwiftUI

/// Renders a failed command block with red accent, exit code, and action buttons.
/// Per build-sheet Section 17.2 "Error Block".
struct ErrorBlockView: View {
    let block: ThreadBlock
    var onAskAI: ((String) -> Void)?

    @State private var isExpanded = false

    private let collapseThreshold = 20
    private let previewLines = 10

    var body: some View {
        HStack(spacing: 0) {
            // Red left border accent
            Rectangle()
                .fill(PATColors.error)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 8) {
                // Content
                let displayText = displayContent
                Text(ANSIParser.parse(displayText))
                    .font(PATFonts.mono)
                    .foregroundStyle(PATColors.command)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // "Show more" if collapsed
                if shouldCollapse && !isExpanded {
                    Button {
                        isExpanded = true
                    } label: {
                        Text("Show \(block.lineCount - previewLines) more lines")
                            .font(PATFonts.monoSmall)
                            .foregroundStyle(PATColors.aiAccent)
                    }
                }

                // Exit code badge
                HStack {
                    Spacer()
                    HStack(spacing: 2) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                        Text("\(block.exitCode ?? 1)")
                            .font(PATFonts.monoSmall)
                    }
                    .foregroundStyle(PATColors.error)
                }

                // Action buttons
                HStack(spacing: 12) {
                    ActionChip(label: "Copy", icon: "doc.on.doc") {
                        UIPasteboard.general.string = ANSIParser.stripANSI(block.content)
                    }
                    ActionChip(label: "Ask AI", icon: "sparkles") {
                        let errorSnippet = String(
                            ANSIParser.stripANSI(block.content).prefix(500)
                        )
                        let prompt = "pat claude \"Explain this error and suggest a fix: \(errorSnippet)\""
                        onAskAI?(prompt)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(PATColors.errorBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(PATColors.errorBorder, lineWidth: 0.5)
        )
    }

    private var shouldCollapse: Bool {
        block.lineCount > collapseThreshold
    }

    private var displayContent: String {
        if shouldCollapse && !isExpanded {
            return block.firstLines(previewLines)
        }
        return block.content
    }
}

/// Small tappable chip for block actions.
private struct ActionChip: View {
    let label: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
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
