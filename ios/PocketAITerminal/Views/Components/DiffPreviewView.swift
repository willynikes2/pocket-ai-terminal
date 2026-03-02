import SwiftUI

/// Collapsible inline diff rendering for AI response blocks.
/// Collapsed by default — shows file count summary. Expanded shows syntax-highlighted diff.
struct DiffPreviewView: View {
    let diffContent: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header / toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Image(systemName: "doc.text")
                        .font(.caption)
                    Text(summary)
                        .font(PATFonts.monoSmall)
                    Spacer()
                }
                .foregroundStyle(PATColors.aiAccent)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                        Text(line.text)
                            .font(PATFonts.monoSmall)
                            .foregroundStyle(line.color)
                            .fontWeight(line.isBold ? .bold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .background(line.backgroundColor)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(PATColors.blockBorder, lineWidth: 0.5)
                )
            }
        }
        .padding(8)
        .background(PATColors.commandBg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Diff Parsing

    private var summary: String {
        let fileCount = diffContent.components(separatedBy: "diff --git").count - 1
        let additions = diffContent.split(separator: "\n")
            .filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
        let deletions = diffContent.split(separator: "\n")
            .filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count

        if fileCount > 0 {
            return "\(fileCount) file\(fileCount == 1 ? "" : "s") changed (+\(additions) -\(deletions))"
        }
        return "Diff preview"
    }

    private struct DiffLine {
        let text: String
        let color: Color
        let backgroundColor: Color
        let isBold: Bool
    }

    private var diffLines: [DiffLine] {
        diffContent.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let str = String(line)
            if str.hasPrefix("diff --git") || str.hasPrefix("index ") {
                return DiffLine(
                    text: str, color: PATColors.prompt,
                    backgroundColor: .clear, isBold: true
                )
            } else if str.hasPrefix("---") || str.hasPrefix("+++") {
                return DiffLine(
                    text: str, color: PATColors.command,
                    backgroundColor: .clear, isBold: true
                )
            } else if str.hasPrefix("@@") {
                return DiffLine(
                    text: str, color: PATColors.aiAccent,
                    backgroundColor: PATColors.aiAccent.opacity(0.1), isBold: false
                )
            } else if str.hasPrefix("+") {
                return DiffLine(
                    text: str, color: PATColors.success,
                    backgroundColor: PATColors.success.opacity(0.08), isBold: false
                )
            } else if str.hasPrefix("-") {
                return DiffLine(
                    text: str, color: PATColors.error,
                    backgroundColor: PATColors.error.opacity(0.08), isBold: false
                )
            } else {
                return DiffLine(
                    text: str, color: PATColors.prompt,
                    backgroundColor: .clear, isBold: false
                )
            }
        }
    }
}

// MARK: - Diff Extraction Utility

enum DiffExtractor {
    /// Check if text contains diff content.
    static func containsDiff(_ text: String) -> Bool {
        text.contains("diff --git") || text.contains("@@") && (
            text.contains("+++ ") || text.contains("--- ")
        )
    }

    /// Extract diff sections from mixed text content.
    /// Returns (nonDiffText, diffText) tuple.
    static func extract(from text: String) -> (prose: String, diff: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var prose: [String] = []
        var diff: [String] = []
        var inDiff = false

        for line in lines {
            let str = String(line)
            if str.hasPrefix("diff --git") {
                inDiff = true
            }
            if inDiff {
                diff.append(str)
                // End diff block when we hit a non-diff line after content
                if !str.hasPrefix("diff ") && !str.hasPrefix("index ") &&
                   !str.hasPrefix("---") && !str.hasPrefix("+++") &&
                   !str.hasPrefix("@@") && !str.hasPrefix("+") &&
                   !str.hasPrefix("-") && !str.hasPrefix(" ") && !str.isEmpty {
                    inDiff = false
                    // Move this line back to prose
                    diff.removeLast()
                    prose.append(str)
                }
            } else {
                prose.append(str)
            }
        }

        return (
            prose: prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            diff: diff.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
