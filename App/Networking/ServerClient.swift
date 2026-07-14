// Async URLSession client mirroring Resources/Public/api.js. A native
// URLSession/URLSessionWebSocketTask sends no Origin or Sec-Fetch-Site header,
// so the server's OriginGuard treats it like curl/CLI and allows all writes and
// the exec ws upgrade - no custom headers needed.

import Foundation

struct APIError: LocalizedError, Sendable {
    let reason: String
    var errorDescription: String? { reason }
}

/// Sendable: holds only an Int port and uses URLSession.shared.
struct ServerClient: Sendable {
    let port: Int
    private var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    // MARK: Reads

    func fetchState() async throws -> DashboardState {
        let (data, resp) = try await get("api/state")
        try ensureOk(resp, data: data)
        return try decode(DashboardState.self, from: data)
    }

    func inspectContainer(_ id: String) async throws -> ContainerList {
        let (data, resp) = try await get("api/containers/\(escaped(id))")
        try ensureOk(resp, data: data)
        let list = try decode([ContainerList].self, from: data)
        guard let first = list.first else { throw APIError(reason: "no container") }
        return first
    }

    func inspectImage(_ name: String) async throws -> [ImageList] {
        let (data, resp) = try await get("api/images/inspect?name=\(escaped(name))")
        try ensureOk(resp, data: data)
        return try decode([ImageList].self, from: data)
    }

    func fetchCapabilities() async throws -> Capabilities {
        let (data, resp) = try await get("api/capabilities")
        // Fail-closed: any error hides the Terminal button.
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return Capabilities(exec: false)
        }
        return (try? decode(Capabilities.self, from: data)) ?? Capabilities(exec: false)
    }

    /// Raw passthrough JSON (system properties / dns).
    func fetchJson(_ path: String) async throws -> Data {
        let (data, resp) = try await get(path)
        try ensureOk(resp, data: data)
        return data
    }

    // MARK: Writes

    func stopContainer(_ id: String) async throws { try await post("api/containers/\(escaped(id))/stop") }
    func startContainer(_ id: String) async throws { try await post("api/containers/\(escaped(id))/start") }
    func killContainer(_ id: String) async throws { try await post("api/containers/\(escaped(id))/kill") }
    func startBuilder() async throws { try await post("api/builder/start") }
    func stopBuilder() async throws { try await post("api/builder/stop") }
    func prune(_ category: String) async throws { try await post("api/prune/\(escaped(category))") }

    func createContainer(_ body: ContainerRunRequest) async throws -> String {
        var req = URLRequest(url: url("api/containers/run"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOk(resp, data: data)
        return try decode(RunResponse.self, from: data).id
    }

    func pullImage(_ reference: String) async throws {
        var req = URLRequest(url: url("api/images/pull"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["reference": reference])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOk(resp, data: data)
    }

    /// SSE logs stream for one container. The server caps every connection at
    /// 120s (Support/SSE.swift); URLSession does NOT auto-reconnect like
    /// EventSource, so the caller must reopen on stream end. Yields one String
    /// per `data:` event.
    func logs(id: String) -> AsyncThrowingStream<String, Error> {
        let u = url("api/containers/\(escaped(id))/logs")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: URLRequest(url: u))
                    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                        continuation.finish(throwing: APIError(reason: "logs HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"))
                        return
                    }
                    // `bytes.lines` reassembles frames split across chunks.
                    for try await line in bytes.lines {
                        if Task.isCancelled { return }
                        if line.hasPrefix("data:") {
                            continuation.yield(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Helpers

    private func get(_ path: String) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url(path))
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await URLSession.shared.data(for: req)
    }

    private func post(_ path: String) async throws {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOk(resp, data: data)
    }

    private func url(_ path: String) -> URL { base.appendingPathComponent(path) }

    private func escaped(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    private func ensureOk(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw APIError(reason: "no response") }
        guard (200..<300).contains(http.statusCode) else {
            let reason = (try? decode(ErrorBody.self, from: data))?.reason
            throw APIError(reason: reason ?? "HTTP \(http.statusCode)")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw APIError(reason: "decode failed: \(error.localizedDescription)") }
    }

    private struct ErrorBody: Decodable { let reason: String? }
}
