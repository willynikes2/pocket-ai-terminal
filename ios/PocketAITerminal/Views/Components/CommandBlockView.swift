import SwiftUI

/// Renders a user command block with chevron prefix, monospace text, and timestamp.
/// Per build-sheet Section 17.2 "Command Block".
struct CommandBlockView: View {
    let block: ThreadBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(">")
                    .font(PATFonts.monoBold)
                    .foregroundStyle(PATColors.aiAccent)

                Text(block.command ?? "")
                    .font(PATFonts.monoBold)
                    .foregroundStyle(PATColors.command)
                    .textSelection(.enabled)
            }

            Text(block.timestamp, style: .time)
                .font(PATFonts.timestamp)
                .foregroundStyle(PATColors.prompt)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PATColors.commandBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if let command = block.command {
                UIPasteboard.general.string = command
            }
        }
    }
}
