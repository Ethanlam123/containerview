// Dashboard poll model. Mirrors Resources/Public/app.js: a debounce-guarded
// poll loop, last-known-good UserDefaults cache shown before the first tick
// resolves, auto-refresh + interval controls, visibility pause, and a one-shot
// capabilities fetch to gate the Terminal button.

import Foundation
import SwiftUI
import ContainerMonitorCore

@MainActor
@Observable
final class DashboardModel {
    private(set) var lastState: DashboardState?
    private(set) var lastError: String?
    private(set) var polling = false
    var autoRefresh = true
    var intervalSec = 5.0
    private(set) var execEnabled = false

    private(set) var client: ServerClient?
    private var pollTask: Task<Void, Never>?
    private var inFlight = false
    private var cacheTick = 0

    private static let cacheKey = "containerDashboard:lastState"

    enum Action: Sendable { case stop, start, kill }

    /// Run a container lifecycle action, then refresh so the row confirms.
    /// The optimistic flip makes the row respond instantly; the poll (3s+ while
    /// the images section is slow) confirms or reverts. Without it the row lagged
    /// long enough that Stop/Start looked broken.
    func act(_ kind: Action, id: String) async {
        applyOptimistic(kind, id: id)
        do {
            switch kind {
            case .stop: try await client?.stopContainer(id)
            case .start: try await client?.startContainer(id)
            case .kill: try await client?.killContainer(id)
            }
            poll()
        } catch {
            lastError = (error as? APIError)?.reason ?? error.localizedDescription
            poll()   // revert the optimistic state to the server's truth
        }
    }

    private func applyOptimistic(_ kind: Action, id: String) {
        guard var state = lastState, var containers = state.containers,
              let i = containers.firstIndex(where: { $0.id == id }) else { return }
        let next = kind == .start ? "running" : "stopped"
        let old = containers[i]
        containers[i] = ContainerList(
            id: old.id, configuration: old.configuration,
            status: ContainerList.Status(state: next, networks: old.status.networks, startedDate: old.status.startedDate))
        state.containers = containers
        lastState = state
    }

    /// Permanently remove a container. The server exposes no remove endpoint
    /// (only prune-all), so this shells out to `container rm --force` directly.
    /// The id is server-provided state (never user-typed); it is still validated
    /// against the server's ID pattern since deletion is irreversible. The CLI
    /// runs off the main actor (waitUntilExit would otherwise freeze the UI).
    func remove(id: String) async {
        guard let path = findOnPATH("container") else {
            lastError = "container CLI not found"; return
        }
        guard let pattern = try? Regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"),
              id.wholeMatch(of: pattern) != nil else {
            lastError = "invalid container id"; return
        }
        let exit = await Task.detached(priority: .userInitiated) { Self.runRemove(path: path, id: id) }.value
        if exit != 0 {
            lastError = "remove failed (container rm exit \(exit))"
            poll()
            return
        }
        if var state = lastState, var containers = state.containers {
            containers.removeAll { $0.id == id }
            state.containers = containers
            lastState = state
        }
        poll()
    }

    private static nonisolated func runRemove(path: String, id: String) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["rm", "--force", id]
        if let devnull = FileHandle(forWritingAtPath: "/dev/null") {
            proc.standardOutput = devnull
            proc.standardError = devnull
        }
        do { try proc.run(); proc.waitUntilExit() }
        catch { return -1 }
        return proc.terminationStatus
    }

    /// Pull an image; returns nil on success or an error message.
    func pullImage(_ ref: String) async -> String? {
        do { try await client?.pullImage(ref); poll(); return nil }
        catch {
            let m = (error as? APIError)?.reason ?? error.localizedDescription
            lastError = m
            return m
        }
    }

    func controlBuilder(start: Bool) async {
        do {
            if start { try await client?.startBuilder() } else { try await client?.stopBuilder() }
            poll()
        } catch { lastError = (error as? APIError)?.reason ?? error.localizedDescription }
    }

    func prune(_ category: String) async {
        do { try await client?.prune(category); poll() }
        catch { lastError = (error as? APIError)?.reason ?? error.localizedDescription }
    }

    var rows: [ContainerRow] { lastState.map(deriveRows) ?? [] }

    var systemRunning: Bool? {
        guard let s = lastState?.health?.status.lowercased() else { return nil }
        if s.contains("not running") || s.contains("stopped") { return false }
        if s.contains("running") { return true }
        return nil
    }

    func activate(port: Int) {
        guard client == nil else { return }
        client = ServerClient(port: port)

        // Render last-known-good immediately so a stopped system still shows
        // something (matches app.js).
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(DashboardState.self, from: data) {
            lastState = cached
        }

        Task { [weak self] in
            let caps = try? await self?.client?.fetchCapabilities()
            self?.execEnabled = caps?.exec ?? false
        }

        poll()
        scheduleNext()
    }

    func refresh() { poll() }

    func setAutoRefresh(_ on: Bool) { autoRefresh = on; scheduleNext() }
    func setInterval(_ s: Double) { intervalSec = max(1, min(60, s)); scheduleNext() }

    func pause() {
        // Authoritative cache write on background; poll() also writes every 10th
        // tick as a force-quit-during-foreground safety net.
        cacheToDefaults()
        pollTask?.cancel()
        polling = false
    }
    func resume() { poll(); scheduleNext() }

    private func scheduleNext() {
        pollTask?.cancel()
        guard autoRefresh else { return }
        let secs = intervalSec
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(secs))
            if Task.isCancelled { return }
            self?.poll()
            self?.scheduleNext()
        }
    }

    private func poll() {
        guard let client, !inFlight else { return }
        inFlight = true
        polling = true
        Task { [weak self] in
            defer { self?.inFlight = false; self?.polling = false }
            do {
                let state = try await client.fetchState()
                self?.lastState = state
                self?.lastError = nil
                self?.cacheTick += 1
                if self?.cacheTick.isMultiple(of: 10) == true { self?.cacheToDefaults() }
            } catch {
                self?.lastError = (error as? APIError)?.reason ?? error.localizedDescription
            }
        }
    }

    private func cacheToDefaults() {
        guard let state = lastState,
              let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
    }
}
