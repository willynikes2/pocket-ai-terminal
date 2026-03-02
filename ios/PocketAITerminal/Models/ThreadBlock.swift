import Foundation

struct ThreadBlock: Identifiable, Equatable {
    let id: String
    var type: BlockType
    let category: Category
    var command: String?
    var content: String
    var exitCode: Int?
    let timestamp: Date
    var isCollapsed: Bool = false
    var isComplete: Bool = false

    enum BlockType: Equatable {
        case user
        case output
        case error
        case meta
    }

    enum Category: Equatable {
        case system
        case git
        case claude
    }

    /// Number of lines in content.
    var lineCount: Int {
        content.isEmpty ? 0 : content.components(separatedBy: "\n").count
    }

    /// First N lines of content for collapsed display.
    func firstLines(_ n: Int) -> String {
        content.components(separatedBy: "\n").prefix(n).joined(separator: "\n")
    }

    /// Detect category from command text.
    static func detectCategory(for command: String) -> Category {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("git ") || trimmed == "git" {
            return .git
        }
        if trimmed.hasPrefix("claude ") || trimmed.hasPrefix("pat claude") {
            return .claude
        }
        return .system
    }
}
