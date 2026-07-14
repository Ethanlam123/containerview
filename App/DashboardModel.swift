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
    func act(_ kind: Action, id: String) async {
        do {
            switch kind {
            case .stop: try await client?.stopContainer(id)
            case .start: try await client?.startContainer(id)
            case .kill: try await client?.killContainer(id)
            }
            poll()
        } catch {
            lastError = (error as? APIError)?.reason ?? error.localizedDescription
        }
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
