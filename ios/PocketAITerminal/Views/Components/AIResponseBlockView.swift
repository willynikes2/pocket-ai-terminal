import SwiftUI

/// Renders Claude Code AI response blocks with distinct styling.
/// Per build-sheet Section 17.2 "AI Response Block" and Section 17.5 "Claude Heuristics".
struct AIResponseBlockView: View {
    let block: ThreadBlock

    @State private var isExpanded = true

    private let collapseThreshold = 50
    private let previewLines = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // AI header
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(PATColors.aiAccent)
                Text("Claude")
                    .font(PATFonts.monoBold)
                    .foregroundStyle(PATColors.aiAccent)
                Spacer()

                if block.isComplete {
                    exitBadge
                }
            }

            // Content: prose + optional diff
            let extracted = DiffExtractor.extract(from: block.content)

            // Prose content (non-diff text)
            if !extracted.prose.isEmpty {
                let displayText = shouldCollapse && !isExpanded
                    ? String(extracted.prose.split(separator: "\n").prefix(previewLines).joined(separator: "\n"))
                    : extracted.prose

                Text(ANSIParser.parse(displayText))
                    .font(PATFonts.mono)
                    .foregroundStyle(PATColors.command)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if shouldCollapse && !isExpanded {
                    Button {
                        isExpanded = true
                    } label: {
                        Text("Show more")
                            .font(PATFonts.monoSmall)
                            .foregroundStyle(PATColors.aiAccent)
                    }
                }
            }

            // Diff preview (collapsible)
            if !extracted.diff.isEmpty {
                DiffPreviewView(diffContent: extracted.diff)
            }

            // Running indicator
            if !block.isComplete {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Claude is working...")
                        .font(PATFonts.monoSmall)
                        .foregroundStyle(PATColors.prompt)
                }
            }

            // Actions
            if block.isComplete {
                HStack(spacing: 12) {
                    AIActionChip(label: "Copy", icon: "doc.on.doc") {
                        UIPasteboard.general.string = ANSIParser.stripANSI(block.content)
                    }
                    if DiffExtractor.containsDiff(block.content) {
                        AIActionChip(label: "View Diff", icon: "doc.text") {
                            // Diff is shown inline via DiffPreviewView
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PATColors.aiBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(PATColors.aiAccent.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    private var shouldCollapse: Bool {
        block.lineCount > collapseThreshold
    }

    @ViewBuilder
    private var exitBadge: some View {
        if let code = block.exitCode {
            HStack(spacing: 2) {
                Image(systemName: code == 0 ? "checkmark" : "xmark")
                    .font(.caption2)
                Text("\(code)")
                    .font(PATFonts.monoSmall)
            }
            .foregroundStyle(code == 0 ? PATColors.success : PATColors.error)
        }
    }
}

/// Action chip styled for AI blocks.
private struct AIActionChip: View {
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
            .background(PATColors.aiAccent.opacity(0.15))
            .foregroundStyle(PATColors.aiAccent)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
