// Exec WebSocket client for `container exec -i -t <id> /bin/sh`. The server
// sends BINARY frames (pty output) and the occasional TEXT notice (e.g.
// "[terminal pool full]"); keystrokes go back as TEXT. A native
// URLSessionWebSocketTask sends no Origin header, so the server's shouldBlockWS
// (which only blocks a present non-loopback Origin) allows the upgrade.
//
// The receive loop calls `onClose` when the stream ends for a reason OTHER than
// our own close() - e.g. the server's 30-min cap, a ping-timeout, or the pool
// being full. Without this the terminal would just freeze with no feedback.

import Foundation

@MainActor
final class ExecSocket {
    private let task: URLSessionWebSocketTask
    private var receiveTask: Task<Void, Never>?
    private let onOutput: (Data) -> Void
    private let onClose: (String) -> Void
    // Set by close() before cancelling so the receive loop knows the disconnect
    // is local (stop() already prints [disconnected]) and stays silent.
    private var intentionalClose = false

    init(port: Int, id: String, cols: Int, rows: Int,
         onOutput: @escaping (Data) -> Void,
         onClose: @escaping (String) -> Void) {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        // ponytail: cols/rows fixed at open (the container CLI has no resize API),
        // matching terminal.js. The displayed grid may differ from the PTY size.
        let url = URL(string: "ws://127.0.0.1:\(port)/api/containers/\(escaped)/exec?cols=\(cols)&rows=\(rows)")!
        self.task = URLSession(configuration: .default).webSocketTask(with: url)
        self.onOutput = onOutput
        self.onClose = onClose
    }

    func connect() {
        task.resume()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let msg = try await self?.task.receive() else { break }
                    switch msg {
                    case .data(let d): self?.onOutput(d)
                    case .string(let s): self?.onOutput(Data(s.utf8))
                    @unknown default: break
                    }
                } catch {
                    break
                }
            }
            // Stream ended. Silent on our own teardown; otherwise tell the UI.
            if self?.intentionalClose != true { self?.onClose("connection lost") }
        }
    }

    func send(_ text: String) {
        Task { [weak self] in try? await self?.task.send(.string(text)) }
    }

    func close() {
        intentionalClose = true
        receiveTask?.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }
}
