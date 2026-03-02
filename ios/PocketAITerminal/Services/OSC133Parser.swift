import Foundation

/// Events emitted by the OSC 133 parser.
enum OSC133Event: Equatable {
    case promptStart        // A — start of prompt
    case promptEnd          // B — end of prompt, input begins
    case commandStart       // C — command executed, output follows
    case commandEnd(exitCode: Int)  // D;N — command finished
    case output(Data)       // Non-escape bytes passed through
}

/// Byte-level state machine that detects OSC 133 escape sequences in a raw
/// terminal byte stream.
///
/// OSC 133 sequences have the form:
///   ESC ] 133 ; <param> BEL
///   0x1B 0x5D  "133;"  ...  0x07
///
/// The parser buffers incomplete sequences across chunk boundaries.
final class OSC133Parser {

    private enum State {
        case ground
        case escape         // saw ESC (0x1B)
        case oscStart       // saw ESC ]
        case oscPayload     // accumulating payload until BEL (0x07) or ST
    }

    private var state: State = .ground
    private var payloadBuffer: [UInt8] = []
    private var outputBuffer: [UInt8] = []

    /// Process a chunk of raw bytes, returning a list of events.
    func process(_ data: Data) -> [OSC133Event] {
        var events: [OSC133Event] = []

        for byte in data {
            switch state {
            case .ground:
                if byte == 0x1B { // ESC
                    flushOutput(&events)
                    state = .escape
                } else {
                    outputBuffer.append(byte)
                }

            case .escape:
                if byte == 0x5D { // ] — start of OSC
                    state = .oscStart
                    payloadBuffer.removeAll()
                } else if byte == 0x5B { // [ — CSI sequence, not OSC
                    // Pass through ESC [ as regular output
                    outputBuffer.append(0x1B)
                    outputBuffer.append(byte)
                    state = .ground
                } else {
                    // Unknown escape — pass through
                    outputBuffer.append(0x1B)
                    outputBuffer.append(byte)
                    state = .ground
                }

            case .oscStart:
                if byte == 0x07 { // BEL — empty OSC, ignore
                    state = .ground
                } else {
                    payloadBuffer.append(byte)
                    state = .oscPayload
                }

            case .oscPayload:
                if byte == 0x07 { // BEL — end of OSC
                    if let event = parseOSC133Payload(payloadBuffer) {
                        events.append(event)
                    } else {
                        // Not an OSC 133 sequence — pass through as output
                        outputBuffer.append(0x1B)
                        outputBuffer.append(0x5D)
                        outputBuffer.append(contentsOf: payloadBuffer)
                        outputBuffer.append(0x07)
                    }
                    payloadBuffer.removeAll()
                    state = .ground
                } else if byte == 0x1B {
                    // Could be ST (ESC \) — check next byte
                    // For now, treat ESC inside OSC as end-of-sequence fallback
                    // and re-process this ESC
                    if let event = parseOSC133Payload(payloadBuffer) {
                        events.append(event)
                    }
                    payloadBuffer.removeAll()
                    flushOutput(&events)
                    state = .escape
                } else {
                    payloadBuffer.append(byte)
                    // Safety: if payload gets unreasonably long, abort
                    if payloadBuffer.count > 64 {
                        outputBuffer.append(0x1B)
                        outputBuffer.append(0x5D)
                        outputBuffer.append(contentsOf: payloadBuffer)
                        payloadBuffer.removeAll()
                        state = .ground
                    }
                }
            }
        }

        flushOutput(&events)
        return events
    }

    /// Reset parser state (e.g., on reconnect).
    func reset() {
        state = .ground
        payloadBuffer.removeAll()
        outputBuffer.removeAll()
    }

    // MARK: - Private

    private func flushOutput(_ events: inout [OSC133Event]) {
        if !outputBuffer.isEmpty {
            events.append(.output(Data(outputBuffer)))
            outputBuffer.removeAll()
        }
    }

    /// Parse an OSC payload to see if it's a 133 sequence.
    /// Payload is the bytes between ESC ] and BEL, e.g. "133;A" or "133;D;0".
    private func parseOSC133Payload(_ payload: [UInt8]) -> OSC133Event? {
        guard let str = String(bytes: payload, encoding: .ascii) else {
            return nil
        }

        // Must start with "133;"
        guard str.hasPrefix("133;") else {
            return nil
        }

        let param = String(str.dropFirst(4)) // everything after "133;"

        switch param {
        case "A":
            return .promptStart
        case "B":
            return .promptEnd
        case "C":
            return .commandStart
        default:
            // D;N where N is the exit code
            if param.hasPrefix("D") {
                let parts = param.split(separator: ";", maxSplits: 1)
                if parts.count == 2, let code = Int(parts[1]) {
                    return .commandEnd(exitCode: code)
                }
                // D with no code — treat as exit 0
                if parts.count == 1 || param == "D" {
                    return .commandEnd(exitCode: 0)
                }
            }
            return nil
        }
    }
}
