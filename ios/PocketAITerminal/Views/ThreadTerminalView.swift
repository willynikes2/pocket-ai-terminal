import SwiftUI

/// Thread Mode: chat-like view of terminal blocks.
/// Per build-sheet Section 17 — the product differentiator.
struct ThreadTerminalView: View {
    let blocks: [ThreadBlock]
    let terminalStream: TerminalStream
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
                onUpload: {
                    // Upload handled in M6
                },
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
            OutputBlockView(block: block)

        case .error:
            ErrorBlockView(block: block) { aiPrompt in
                inputText = aiPrompt
            }

        case .meta:
            SystemBlockView(block: block)
        }
    }
}
