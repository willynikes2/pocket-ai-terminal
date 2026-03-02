import SwiftUI

enum PATColors {
    // Backgrounds
    static let sessionBg = Color(hex: "#0D1117")
    static let commandBg = Color(hex: "#161B22")
    static let outputBg = Color(hex: "#0D1117")
    static let errorBg = Color(hex: "#1A0E0E")
    static let aiBg = Color(hex: "#0E1525")
    static let metaBg = Color(hex: "#12151A")
    static let inputBarBg = Color(hex: "#161B22")

    // Accents
    static let success = Color(hex: "#3FB950")
    static let error = Color(hex: "#F85149")
    static let aiAccent = Color(hex: "#A371F7")
    static let prompt = Color(hex: "#8B949E")
    static let command = Color(hex: "#E6EDF3")

    // Borders
    static let blockBorder = Color(hex: "#21262D")
    static let errorBorder = Color(hex: "#F85149").opacity(0.5)

    // Terminal
    static let terminalFg = Color.white
    static let terminalBg = Color(hex: "#1E1E24")
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        default:
            r = 0; g = 0; b = 0
        }

        self.init(red: r, green: g, blue: b)
    }
}
