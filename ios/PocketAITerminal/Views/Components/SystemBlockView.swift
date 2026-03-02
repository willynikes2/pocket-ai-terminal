import SwiftUI

/// Renders a system/meta block for uploads, session events, etc.
/// Per build-sheet Section 17.2 "System/Meta Block".
struct SystemBlockView: View {
    let block: ThreadBlock

    var body: some View {
        Text(block.content)
            .font(PATFonts.monoSmall)
            .foregroundStyle(PATColors.prompt)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(PATColors.metaBg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
