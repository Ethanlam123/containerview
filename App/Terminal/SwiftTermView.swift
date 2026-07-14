// Native terminal pane for container exec, backed by SwiftTerm's macOS
// TerminalView. Bridges the ExecSocket bidirectionally:
//   - socket bytes -> terminalView.feed(byteArray:)
//   - TerminalViewDelegate.send (keystrokes) -> socket.send(text)
// Teardown in dismantleNSView (not deinit - unreliable in SwiftUI) so the ws
// closes and the server's ws.onClose reaps the PTY child.

import AppKit
import SwiftUI
import SwiftTerm

struct SwiftTermView: NSViewRepresentable {
    let port: Int
    let id: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        tv.terminalDelegate = context.coordinator
        // 80x24 matches terminal.js defaults; the CLI has no resize API so the
        // PTY size is fixed at open.
        context.coordinator.start(port: port, id: id, cols: 80, rows: 24, terminal: tv)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        // nonisolated(unsafe): mutated only in start/stop (main) and read in the
        // delegate send (also main - TerminalView is AppKit). The opt-out lets the
        // nonisolated delegate read it without a self-capture that would trip the
        // Swift 6 sending check.
        nonisolated(unsafe) private var socket: ExecSocket?
        private weak var terminal: TerminalView?

        @MainActor
        func start(port: Int, id: String, cols: Int, rows: Int, terminal: TerminalView) {
            self.terminal = terminal
            let socket = ExecSocket(
                port: port, id: id, cols: cols, rows: rows,
                onOutput: { [weak terminal] data in
                    guard let terminal else { return }
                    terminal.feed(byteArray: [UInt8](data)[...])
                },
                onClose: { [weak terminal] reason in
                    // Server dropped the ws (30-min cap, ping-timeout, pool full).
                    // Local teardown prints [disconnected] via stop(); this is the
                    // remote-side counterpart so the terminal says why, not freeze.
                    guard let terminal else { return }
                    let msg = "\r\n\u{1b}[31m[\(reason)]\u{1b}[0m\r\n"
                    terminal.feed(byteArray: [UInt8](msg.utf8)[...])
                })
            self.socket = socket
            socket.connect()
        }

        @MainActor
        func stop() {
            // Mirror terminal.js: signal the disconnect in-band before closing.
            if let terminal {
                let msg = "\r\n\u{1b}[31m[disconnected]\u{1b}[0m\r\n"
                terminal.feed(byteArray: [UInt8](msg.utf8)[...])
            }
            socket?.close()
        }

        // Keystrokes -> socket. Called by TerminalView on the main thread; read
        // the socket into a local so the assumeIsolated closure captures the
        // Sendable ExecSocket (not self).
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let text = String(decoding: data, as: UTF8.self)
            let socket = self.socket
            MainActor.assumeIsolated {
                socket?.send(text)
            }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
