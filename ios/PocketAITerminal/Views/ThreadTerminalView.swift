import SwiftUI

/// Thread Mode: chat-like view of terminal blocks.
/// Per build-sheet Section 17 — the product differentiator.
struct ThreadTerminalView: View {
    let blocks: [ThreadBlock]
    let terminalStream: TerminalStream
    let onUpload: () -> Void
    @State private var inputText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Block list
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(blocks) { block in
                        blockView(for: block)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)

            Divider()
                .background(PATColors.blockBorder)

            // Input bar pinned at bottom
            InputBarView(
                text: $inputText,
                onSubmit: { command in
                    terminalStream.submitCommand(command)
                },
                onUpload: onUpload,
                onKey: { data in
                    terminalStream.sendInput(data)
                }
            )
        }
        .background(PATColors.sessionBg)
    }

    @ViewBuilder
    private func blockView(for block: ThreadBlock) -> some View {
        switch block.type {
        case .user:
            CommandBlockView(block: block)

        case .output:
            if block.category == .claude {
                AIResponseBlockView(block: block)
            } else {
                OutputBlockView(block: block)
            }

        case .error:
            if block.category == .claude {
                AIResponseBlockView(block: block)
            } else {
                ErrorBlockView(block: block) { aiPrompt in
                    inputText = aiPrompt
                }
            }

        case .meta:
            SystemBlockView(block: block)
        }
    }
}
