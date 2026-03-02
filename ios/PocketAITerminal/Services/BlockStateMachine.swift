import Foundation

/// Consumes OSC133Events and user submissions to produce an array of ThreadBlocks.
///
/// State transitions per build-sheet Section 17.3:
///   idle → prompted (on A) → commandSent (user submits) → receiving (on C) → idle (on D;N)
final class BlockStateMachine {

    enum State: Equatable {
        case idle
        case prompted
        case commandSent
        case receiving
    }

    private(set) var state: State = .idle
    private(set) var blocks: [ThreadBlock] = []

    /// Index of the current in-progress output block (if any).
    private var currentOutputIndex: Int?

    /// The command text the user submitted (captured between B and C).
    private var pendingCommand: String?

    // MARK: - User Actions

    /// Called when the user submits a command from InputBarView.
    func userSubmittedCommand(_ command: String) {
        let category = ThreadBlock.detectCategory(for: command)

        let block = ThreadBlock(
            id: UUID().uuidString,
            type: .user,
            category: category,
            command: command,
            content: "",
            exitCode: nil,
            timestamp: Date(),
            isComplete: true
        )
        blocks.append(block)
        pendingCommand = command
        state = .commandSent
    }

    /// Add a system/meta block (e.g., upload notification).
    func addMetaBlock(content: String) {
        let block = ThreadBlock(
            id: UUID().uuidString,
            type: .meta,
            category: .system,
            command: nil,
            content: content,
            exitCode: nil,
            timestamp: Date(),
            isComplete: true
        )
        blocks.append(block)
    }

    // MARK: - Process OSC 133 Events

    /// Process a batch of events from OSC133Parser.
    func process(_ events: [OSC133Event]) {
        for event in events {
            processEvent(event)
        }
    }

    private func processEvent(_ event: OSC133Event) {
        switch event {
        case .promptStart:
            // If we were receiving, finalize the current block (fallback)
            if state == .receiving {
                finalizeCurrentBlock(exitCode: nil)
            }
            state = .prompted

        case .promptEnd:
            // Ready for user input — stay in prompted state
            if state == .idle {
                state = .prompted
            }

        case .commandStart:
            // Output is about to begin — create an output block
            let category: ThreadBlock.Category
            if let cmd = pendingCommand {
                category = ThreadBlock.detectCategory(for: cmd)
            } else {
                category = .system
            }

            let block = ThreadBlock(
                id: UUID().uuidString,
                type: .output,
                category: category,
                command: nil,
                content: "",
                exitCode: nil,
                timestamp: Date(),
                isComplete: false
            )
            blocks.append(block)
            currentOutputIndex = blocks.count - 1
            state = .receiving

        case .commandEnd(let exitCode):
            finalizeCurrentBlock(exitCode: exitCode)
            state = .idle

        case .output(let data):
            guard let text = String(data: data, encoding: .utf8) else { return }

            switch state {
            case .receiving:
                // Append output to the current block
                if let idx = currentOutputIndex, idx < blocks.count {
                    blocks[idx].content.append(text)
                }

            case .prompted:
                // Output during prompt (e.g., PS1 rendering) — ignore for Thread Mode
                // The prompt text itself is not shown as a block
                break

            case .commandSent:
                // Output before C marker — could be echo of command.
                // Some terminals echo input before emitting C.
                // Create an output block if we haven't yet.
                if currentOutputIndex == nil {
                    let category: ThreadBlock.Category
                    if let cmd = pendingCommand {
                        category = ThreadBlock.detectCategory(for: cmd)
                    } else {
                        category = .system
                    }
                    let block = ThreadBlock(
                        id: UUID().uuidString,
                        type: .output,
                        category: category,
                        command: nil,
                        content: text,
                        exitCode: nil,
                        timestamp: Date(),
                        isComplete: false
                    )
                    blocks.append(block)
                    currentOutputIndex = blocks.count - 1
                    state = .receiving
                }

            case .idle:
                // Unsolicited output (e.g., background process, replay on reconnect)
                // Create or append to an output block
                if let idx = currentOutputIndex, idx < blocks.count, !blocks[idx].isComplete {
                    blocks[idx].content.append(text)
                } else {
                    let block = ThreadBlock(
                        id: UUID().uuidString,
                        type: .output,
                        category: .system,
                        command: nil,
                        content: text,
                        exitCode: nil,
                        timestamp: Date(),
                        isComplete: false
                    )
                    blocks.append(block)
                    currentOutputIndex = blocks.count - 1
                }
            }
        }
    }

    // MARK: - Private

    private func finalizeCurrentBlock(exitCode: Int?) {
        guard let idx = currentOutputIndex, idx < blocks.count else {
            currentOutputIndex = nil
            pendingCommand = nil
            return
        }

        blocks[idx].exitCode = exitCode
        blocks[idx].isComplete = true

        // Trim trailing whitespace/newlines from content
        blocks[idx].content = blocks[idx].content
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Determine block type based on exit code
        if let code = exitCode, code != 0 {
            blocks[idx].type = .error
        } else if blocks[idx].content.isEmpty {
            // No output, successful — this becomes a "Done" indicator
            blocks[idx].type = .output
        }

        currentOutputIndex = nil
        pendingCommand = nil
    }

    /// Reset all state (e.g., on session change).
    func reset() {
        state = .idle
        blocks.removeAll()
        currentOutputIndex = nil
        pendingCommand = nil
    }
}
