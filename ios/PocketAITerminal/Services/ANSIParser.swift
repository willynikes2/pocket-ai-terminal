import SwiftUI

/// Converts a string containing ANSI SGR escape sequences into an AttributedString
/// suitable for SwiftUI Text rendering.
///
/// Supports:
/// - Reset (0), bold (1), dim (2), italic (3), underline (4)
/// - 8-color foreground (30-37) and background (40-47)
/// - Bright foreground (90-97) and background (100-107)
/// - 256-color: 38;5;N / 48;5;N
/// - 24-bit truecolor: 38;2;R;G;B / 48;2;R;G;B
/// - Strips non-SGR CSI sequences (cursor movement, etc.)
enum ANSIParser {

    /// Parse ANSI-escaped text into an AttributedString with colors and styles.
    static func parse(_ input: String) -> AttributedString {
        var result = AttributedString()
        var currentFg: Color?
        var currentBg: Color?
        var isBold = false
        var isDim = false
        var isItalic = false
        var isUnderline = false

        var i = input.startIndex
        var segmentStart = i

        while i < input.endIndex {
            if input[i] == "\u{1B}" {
                // Flush text before this escape
                if segmentStart < i {
                    let text = String(input[segmentStart..<i])
                    var segment = AttributedString(text)
                    applyStyle(
                        &segment,
                        fg: currentFg, bg: currentBg,
                        bold: isBold, dim: isDim,
                        italic: isItalic, underline: isUnderline
                    )
                    result.append(segment)
                }

                // Try to parse CSI sequence: ESC [ ... final_byte
                let next = input.index(after: i)
                if next < input.endIndex && input[next] == "[" {
                    // Find end of CSI sequence (letter byte 0x40-0x7E)
                    var j = input.index(after: next)
                    while j < input.endIndex {
                        let c = input[j].asciiValue ?? 0
                        if c >= 0x40 && c <= 0x7E {
                            break
                        }
                        j = input.index(after: j)
                    }

                    if j < input.endIndex {
                        let finalByte = input[j]
                        if finalByte == "m" {
                            // SGR sequence — parse parameters
                            let paramStr = String(input[input.index(after: next)..<j])
                            let codes = parseSGRCodes(paramStr)
                            applySGR(
                                codes,
                                fg: &currentFg, bg: &currentBg,
                                bold: &isBold, dim: &isDim,
                                italic: &isItalic, underline: &isUnderline
                            )
                        }
                        // Skip past the sequence (SGR or non-SGR CSI)
                        i = input.index(after: j)
                    } else {
                        // Unterminated CSI — skip ESC [
                        i = input.index(after: next)
                    }
                } else if next < input.endIndex && input[next] == "]" {
                    // OSC sequence — skip until BEL (0x07) or ST (ESC \)
                    var j = input.index(after: next)
                    while j < input.endIndex && input[j] != "\u{07}" {
                        j = input.index(after: j)
                    }
                    if j < input.endIndex {
                        i = input.index(after: j)
                    } else {
                        i = j
                    }
                } else {
                    // Other escape — skip ESC + next byte
                    i = next < input.endIndex ? input.index(after: next) : next
                }
                segmentStart = i
            } else {
                i = input.index(after: i)
            }
        }

        // Flush remaining text
        if segmentStart < input.endIndex {
            let text = String(input[segmentStart...])
            var segment = AttributedString(text)
            applyStyle(
                &segment,
                fg: currentFg, bg: currentBg,
                bold: isBold, dim: isDim,
                italic: isItalic, underline: isUnderline
            )
            result.append(segment)
        }

        return result
    }

    /// Strip all ANSI escape sequences, returning plain text.
    static func stripANSI(_ input: String) -> String {
        // Remove ESC [ ... final_byte and ESC ] ... BEL
        var result = ""
        var i = input.startIndex
        while i < input.endIndex {
            if input[i] == "\u{1B}" {
                let next = input.index(after: i)
                if next < input.endIndex && input[next] == "[" {
                    var j = input.index(after: next)
                    while j < input.endIndex {
                        let c = input[j].asciiValue ?? 0
                        if c >= 0x40 && c <= 0x7E { break }
                        j = input.index(after: j)
                    }
                    i = j < input.endIndex ? input.index(after: j) : j
                } else if next < input.endIndex && input[next] == "]" {
                    var j = input.index(after: next)
                    while j < input.endIndex && input[j] != "\u{07}" {
                        j = input.index(after: j)
                    }
                    i = j < input.endIndex ? input.index(after: j) : j
                } else {
                    i = next < input.endIndex ? input.index(after: next) : next
                }
            } else {
                result.append(input[i])
                i = input.index(after: i)
            }
        }
        return result
    }

    // MARK: - Private

    private static func parseSGRCodes(_ paramStr: String) -> [Int] {
        if paramStr.isEmpty { return [0] } // ESC[m is same as ESC[0m
        return paramStr.split(separator: ";").compactMap { Int($0) }
    }

    private static func applySGR(
        _ codes: [Int],
        fg: inout Color?, bg: inout Color?,
        bold: inout Bool, dim: inout Bool,
        italic: inout Bool, underline: inout Bool
    ) {
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0: // Reset
                fg = nil; bg = nil
                bold = false; dim = false; italic = false; underline = false

            case 1: bold = true
            case 2: dim = true
            case 3: italic = true
            case 4: underline = true
            case 22: bold = false; dim = false
            case 23: italic = false
            case 24: underline = false

            // Standard foreground (30-37)
            case 30...37:
                fg = standard8Color(code - 30)
            case 39: fg = nil // default fg

            // Standard background (40-47)
            case 40...47:
                bg = standard8Color(code - 40)
            case 49: bg = nil // default bg

            // Bright foreground (90-97)
            case 90...97:
                fg = bright8Color(code - 90)

            // Bright background (100-107)
            case 100...107:
                bg = bright8Color(code - 100)

            // Extended foreground: 38;5;N or 38;2;R;G;B
            case 38:
                if i + 1 < codes.count && codes[i + 1] == 5 && i + 2 < codes.count {
                    fg = color256(codes[i + 2])
                    i += 2
                } else if i + 1 < codes.count && codes[i + 1] == 2 && i + 4 < codes.count {
                    fg = Color(
                        red: Double(codes[i + 2]) / 255.0,
                        green: Double(codes[i + 3]) / 255.0,
                        blue: Double(codes[i + 4]) / 255.0
                    )
                    i += 4
                }

            // Extended background: 48;5;N or 48;2;R;G;B
            case 48:
                if i + 1 < codes.count && codes[i + 1] == 5 && i + 2 < codes.count {
                    bg = color256(codes[i + 2])
                    i += 2
                } else if i + 1 < codes.count && codes[i + 1] == 2 && i + 4 < codes.count {
                    bg = Color(
                        red: Double(codes[i + 2]) / 255.0,
                        green: Double(codes[i + 3]) / 255.0,
                        blue: Double(codes[i + 4]) / 255.0
                    )
                    i += 4
                }

            default:
                break
            }
            i += 1
        }
    }

    private static func applyStyle(
        _ segment: inout AttributedString,
        fg: Color?, bg: Color?,
        bold: Bool, dim: Bool,
        italic: Bool, underline: Bool
    ) {
        if let fg {
            segment.foregroundColor = dim ? fg.opacity(0.6) : fg
        }
        if let bg {
            segment.backgroundColor = bg
        }
        if bold {
            segment.font = PATFonts.monoBold
        }
        if italic {
            segment.font = Font.system(.body, design: .monospaced).italic()
        }
        if underline {
            segment.underlineStyle = .single
        }
    }

    // MARK: - Color Tables

    private static func standard8Color(_ index: Int) -> Color {
        switch index {
        case 0: Color(red: 0.0, green: 0.0, blue: 0.0)       // black
        case 1: Color(red: 0.8, green: 0.0, blue: 0.0)       // red
        case 2: Color(red: 0.0, green: 0.8, blue: 0.0)       // green
        case 3: Color(red: 0.8, green: 0.8, blue: 0.0)       // yellow
        case 4: Color(red: 0.0, green: 0.0, blue: 0.8)       // blue
        case 5: Color(red: 0.8, green: 0.0, blue: 0.8)       // magenta
        case 6: Color(red: 0.0, green: 0.8, blue: 0.8)       // cyan
        case 7: Color(red: 0.8, green: 0.8, blue: 0.8)       // white
        default: Color.white
        }
    }

    private static func bright8Color(_ index: Int) -> Color {
        switch index {
        case 0: Color(red: 0.5, green: 0.5, blue: 0.5)       // bright black (gray)
        case 1: Color(red: 1.0, green: 0.3, blue: 0.3)       // bright red
        case 2: Color(red: 0.3, green: 1.0, blue: 0.3)       // bright green
        case 3: Color(red: 1.0, green: 1.0, blue: 0.3)       // bright yellow
        case 4: Color(red: 0.3, green: 0.3, blue: 1.0)       // bright blue
        case 5: Color(red: 1.0, green: 0.3, blue: 1.0)       // bright magenta
        case 6: Color(red: 0.3, green: 1.0, blue: 1.0)       // bright cyan
        case 7: Color(red: 1.0, green: 1.0, blue: 1.0)       // bright white
        default: Color.white
        }
    }

    /// 256-color palette: 0-7 standard, 8-15 bright, 16-231 color cube, 232-255 grayscale.
    private static func color256(_ n: Int) -> Color {
        switch n {
        case 0...7:
            return standard8Color(n)
        case 8...15:
            return bright8Color(n - 8)
        case 16...231:
            let idx = n - 16
            let r = idx / 36
            let g = (idx % 36) / 6
            let b = idx % 6
            return Color(
                red: r == 0 ? 0 : (Double(r) * 40 + 55) / 255.0,
                green: g == 0 ? 0 : (Double(g) * 40 + 55) / 255.0,
                blue: b == 0 ? 0 : (Double(b) * 40 + 55) / 255.0
            )
        case 232...255:
            let gray = Double(n - 232) * 10 + 8
            return Color(red: gray / 255.0, green: gray / 255.0, blue: gray / 255.0)
        default:
            return Color.white
        }
    }
}
