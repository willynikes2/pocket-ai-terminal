import Foundation
import Observation

/// Binary framing type bytes matching backend WSMessageType.
enum WSMessageType {
    // Client → Server
    static let auth: UInt8 = 0x00
    static let stdin: UInt8 = 0x01
    static let resize: UInt8 = 0x02
    static let ping: UInt8 = 0x03
    static let tokenRefresh: UInt8 = 0x04

    // Server → Client
    static let stdout: UInt8 = 0x80
    static let sessionInfo: UInt8 = 0x81
    static let pong: UInt8 = 0x82
    static let tokenRefreshed: UInt8 = 0x83
    static let error: UInt8 = 0x84
}

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case authenticating
    case connected
}

@Observable
final class TerminalStream {
    private(set) var connectionState: ConnectionState = .disconnected
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

    // Connection parameters for reconnection
    private var lastSessionId: String?
    private var lastBaseURL: String?
    private var ticketProvider: (() async throws -> String)?

    // Thread Mode parsers
    private let osc133Parser = OSC133Parser()
    private let blockStateMachine = BlockStateMachine()

    /// Terminal Mode consumes raw bytes through this callback.
    var onRawOutput: ((Data) -> Void)?

    /// Thread Mode consumes parsed blocks through this callback.
    var onBlocksChanged: (([ThreadBlock]) -> Void)?

    /// Session info updates.
    var onSessionInfo: (([String: Any]) -> Void)?

    /// Error messages from server.
    var onError: ((String) -> Void)?

    // MARK: - Connect

    func connect(
        sessionId: String,
        ticket: String,
        baseURL: String,
        ticketProvider: (() async throws -> String)? = nil
    ) {
        disconnect()

        lastSessionId = sessionId
        lastBaseURL = baseURL
        self.ticketProvider = ticketProvider
        connectionState = .connecting

        let wsScheme = baseURL.hasPrefix("https") ? "wss" : "ws"
        let host = baseURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        let urlString = "\(wsScheme)://\(host)/sessions/\(sessionId)/ws"

        guard let url = URL(string: urlString) else {
            connectionState = .disconnected
            onError?("Invalid WebSocket URL")
            return
        }

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config)
        webSocket = session?.webSocketTask(with: url)
        webSocket?.resume()

        connectionState = .authenticating
        sendAuth(ticket: ticket)
        startReceiving()
        startPingLoop()
        reconnectAttempt = 0
    }

    // MARK: - Send

    func sendInput(_ data: Data) {
        guard connectionState == .connected else { return }
        var message = Data([WSMessageType.stdin])
        message.append(data)
        webSocket?.send(.data(message)) { [weak self] error in
            if let error {
                self?.handleDisconnect(error: error)
            }
        }
    }

    /// Submit a command from Thread Mode's InputBarView.
    /// Records the command in the block state machine, then sends it as terminal input.
    func submitCommand(_ command: String) {
        blockStateMachine.userSubmittedCommand(command)
        onBlocksChanged?(blockStateMachine.blocks)
        sendInput(Data((command + "\n").utf8))
    }

    /// Add a system/meta block (e.g., upload notification).
    func addMetaBlock(content: String) {
        blockStateMachine.addMetaBlock(content: content)
        onBlocksChanged?(blockStateMachine.blocks)
    }

    func sendResize(cols: Int, rows: Int) {
        guard connectionState == .connected || connectionState == .authenticating else { return }
        let json = "{\"cols\":\(cols),\"rows\":\(rows)}"
        var message = Data([WSMessageType.resize])
        message.append(Data(json.utf8))
        webSocket?.send(.data(message)) { _ in }
    }

    // MARK: - Disconnect

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
        connectionState = .disconnected
        osc133Parser.reset()
    }

    // MARK: - Private

    private func sendAuth(ticket: String) {
        let json = "{\"ticket\":\"\(ticket)\"}"
        var message = Data([WSMessageType.auth])
        message.append(Data(json.utf8))
        webSocket?.send(.data(message)) { [weak self] error in
            if let error {
                self?.handleDisconnect(error: error)
            }
        }
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let ws = self?.webSocket else { break }
                do {
                    let message = try await ws.receive()
                    self?.handleMessage(message)
                } catch {
                    self?.handleDisconnect(error: error)
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            guard let typeByte = data.first else { return }
            let payload = data.dropFirst()

            switch typeByte {
            case WSMessageType.stdout:
                if connectionState == .authenticating {
                    connectionState = .connected
                }
                let outputData = Data(payload)
                // Terminal Mode: raw bytes
                onRawOutput?(outputData)
                // Thread Mode: parse OSC 133 → blocks
                let events = osc133Parser.process(outputData)
                blockStateMachine.process(events)
                onBlocksChanged?(blockStateMachine.blocks)

            case WSMessageType.sessionInfo:
                connectionState = .connected
                if let json = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] {
                    onSessionInfo?(json)
                }

            case WSMessageType.pong:
                break // heartbeat acknowledged

            case WSMessageType.tokenRefreshed:
                break // handled by AuthManager via callback if needed

            case WSMessageType.error:
                if let json = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: String],
                   let errorMessage = json["message"] {
                    onError?(errorMessage)
                }

            default:
                break
            }

        case .string(let text):
            // Server shouldn't send text frames, but handle gracefully
            if let data = text.data(using: .utf8) {
                onRawOutput?(data)
            }

        @unknown default:
            break
        }
    }

    private func startPingLoop() {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                let message = Data([WSMessageType.ping])
                self?.webSocket?.send(.data(message)) { _ in }
            }
        }
    }

    // MARK: - Reconnection (exponential backoff: 1s → 2s → 4s → 8s → max 30s)

    private func handleDisconnect(error: Error) {
        guard connectionState != .disconnected else { return }
        connectionState = .disconnected
        pingTask?.cancel()
        receiveTask?.cancel()

        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard let sessionId = lastSessionId,
              let baseURL = lastBaseURL else { return }

        let delay = min(30.0, pow(2.0, Double(reconnectAttempt)))
        reconnectAttempt += 1

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }

            // Get a fresh ticket if provider available
            if let provider = self?.ticketProvider,
               let ticket = try? await provider() {
                self?.connect(
                    sessionId: sessionId,
                    ticket: ticket,
                    baseURL: baseURL,
                    ticketProvider: provider
                )
            }
        }
    }
}
