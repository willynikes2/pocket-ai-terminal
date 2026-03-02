import SwiftUI

/// Renders command output with ANSI colors and an exit code badge.
/// Collapses output >50 lines. Shows "Done" pill for empty successful commands.
/// Per build-sheet Section 17.2.
struct OutputBlockView: View {
    let block: ThreadBlock
    @State private var isExpanded = false

    private let collapseThreshold = 50
    private let previewLines = 20

    var body: some View {
        if block.content.isEmpty && block.isComplete {
            doneView
        } else {
            outputView
        }
    }

    // MARK: - "Done" pill for empty output, exit 0

    private var doneView: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .foregroundStyle(PATColors.success)
                .font(.caption)
            Text("Done (exit \(block.exitCode ?? 0))")
                .font(PATFonts.monoSmall)
                .foregroundStyle(PATColors.prompt)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(PATColors.metaBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Full output view

    private var outputView: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Content
            let displayText = displayContent
            Text(ANSIParser.parse(displayText))
                .font(PATFonts.mono)
                .foregroundStyle(PATColors.command)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            // "Show more" button if collapsed
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
            if block.isComplete {
                HStack {
                    Spacer()
                    exitCodeBadge
                }
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("Running...")
                        .font(PATFonts.monoSmall)
                        .foregroundStyle(PATColors.prompt)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PATColors.outputBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(PATColors.blockBorder, lineWidth: 0.5)
        )
        .contextMenu {
            Button {
                UIPasteboard.general.string = ANSIParser.stripANSI(block.content)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: - Helpers

    private var shouldCollapse: Bool {
        block.lineCount > collapseThreshold
    }

    private var displayContent: String {
        if shouldCollapse && !isExpanded {
            return block.firstLines(previewLines)
        }
        return block.content
    }

    private var exitCodeBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark")
                .font(.caption2)
            Text("\(block.exitCode ?? 0)")
                .font(PATFonts.monoSmall)
        }
        .foregroundStyle(PATColors.success)
    }
}
