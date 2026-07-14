// Exec WebSocket client for `container exec -i -t <id> /bin/sh`. The server
// sends BINARY frames (pty output) and the occasional TEXT notice (e.g.
// "[terminal pool full]"); keystrokes go back as TEXT. A native
// URLSessionWebSocketTask sends no Origin header, so the server's shouldBlockWS
// (which only blocks a present non-loopback Origin) allows the upgrade.

import Foundation

@MainActor
final class ExecSocket {
    private let task: URLSessionWebSocketTask
    private var receiveTask: Task<Void, Never>?
    private let onOutput: (Data) -> Void

    init(port: Int, id: String, cols: Int, rows: Int, onOutput: @escaping (Data) -> Void) {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        // ponytail: cols/rows fixed at open (the container CLI has no resize API),
        // matching terminal.js. The displayed grid may differ from the PTY size.
        let url = URL(string: "ws://127.0.0.1:\(port)/api/containers/\(escaped)/exec?cols=\(cols)&rows=\(rows)")!
        self.task = URLSession(configuration: .default).webSocketTask(with: url)
        self.onOutput = onOutput
    }

    func connect() {
        task.resume()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let msg = try await self?.task.receive() else { return }
                    switch msg {
                    case .data(let d): self?.onOutput(d)
                    case .string(let s): self?.onOutput(Data(s.utf8))
                    @unknown default: break
                    }
                } catch {
                    return
                }
            }
        }
    }

    func send(_ text: String) {
        Task { [weak self] in try? await self?.task.send(.string(text)) }
    }

    func close() {
        receiveTask?.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }
}
