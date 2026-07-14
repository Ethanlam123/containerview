// Container Monitor - app model.
//
// Owns the launch lifecycle: `container` CLI check, free-loopback-port alloc,
// spawn the Vapor server, health-poll /api/state, then expose a Phase the
// RootView switches on. Terminates the server on quit (graceful SIGTERM; the
// server's parent-watch is the Force-Quit backstop).

import Foundation

@MainActor
@Observable
final class AppModel {
    enum Phase: Sendable {
        case launching
        case failed(String)
        case ready(Int)   // loopback port
    }

    private(set) var phase: Phase = .launching

    private var server: ServerProcess?
    private var healthTask: Task<Void, Never>?
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        guard findOnPATH("container") != nil else {
            phase = .failed("Apple `container` CLI not found. Install Apple's `container`, run `container system start` once, then relaunch.")
            return
        }
        guard let port = findFreeLoopbackPort() else {
            phase = .failed("Could not allocate a local TCP port.")
            return
        }
        do {
            server = try ServerProcess.start(port: port)
        } catch {
            phase = .failed("Server failed to start: \(error.localizedDescription)")
            return
        }
        pollHealth(port: port)
    }

    func shutdown() {
        healthTask?.cancel()
        server?.terminate()
    }

    private func pollHealth(port: Int) {
        let url = URL(string: "http://127.0.0.1:\(port)/api/state")!
        healthTask = Task { [weak self] in
            // 5s ceiling: a cold Vapor release binary plus the first
            // `container system status` hit can exceed 2s on this machine.
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if Task.isCancelled { return }
                if await Self.isReachable(url) {
                    self?.phase = .ready(port)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.phase = .failed(self?.server?.diagnostics ?? "No response from the server within 5s.")
        }
    }

    private nonisolated static func isReachable(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }
}
