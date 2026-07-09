import Vapor

/// Registers every API endpoint. `runner` is the cache-decorated runner;
/// `tracker` holds CPU% baselines across polls. Both are constructed once in
/// `configure` and threaded in (no global state).
func registerRoutes(_ app: Application, runner: any CommandRunner, tracker: StatsTracker, execEnabled: Bool) {
    // MARK: Reads

    app.get("api", "state") { _ async -> DashboardState in
        await StateService().state(runner: runner, tracker: tracker)
    }

    app.get("api", "containers", ":id") { req async throws -> [ContainerList] in
        try await ContainerCLI.inspect(runner, id: try validatedID(req))
    }

    app.get("api", "images", "inspect") { req async throws -> [ImageList] in
        let ref = req.query[String.self, at: "name"] ?? ""
        guard ImageRefValidator.validate(ref) else {
            throw Abort(.badRequest, reason: "invalid image reference")
        }
        return try await ContainerCLI.imageInspect(runner, ref: ref)
    }

    app.get("api", "machines", ":id") { req async throws -> [MachineList] in
        try await ContainerCLI.machineInspect(runner, id: try validatedID(req))
    }

    app.get("api", "containers", ":id", "logs") { req async throws -> Response in
        SSE.logs(runner: runner, id: try validatedID(req))
    }

    app.get("api", "system", "properties") { req async throws -> Response in
        try await passthrough { try await ContainerCLI.systemProperties(runner) }
    }

    app.get("api", "system", "dns") { req async throws -> Response in
        try await passthrough { try await ContainerCLI.dnsDomains(runner) }
    }

    /// Capability flags for the frontend (e.g. hide the Terminal button when exec
    /// is disabled). Cheap GET; mirrors the opt-in read at configure time.
    app.get("api", "capabilities") { _ async -> CapabilitiesResponse in
        CapabilitiesResponse(exec: execEnabled)
    }

    // MARK: Container lifecycle

    app.post("api", "containers", ":id", "stop") { req async throws -> Response in
        try await runAction { try await ContainerCLI.stop(runner, id: try validatedID(req)) }
    }
    app.post("api", "containers", ":id", "start") { req async throws -> Response in
        try await runAction { try await ContainerCLI.start(runner, id: try validatedID(req)) }
    }
    app.post("api", "containers", ":id", "kill") { req async throws -> Response in
        try await runAction { try await ContainerCLI.kill(runner, id: try validatedID(req)) }
    }

    // Create + start a container from a validated request body. Validation
    // happens inside `ContainerRunRequest` decoding (each field is a validator-
    // backed value type); a decode failure is a generic 400 whose body does not
    // echo the offending value. The CLI error is likewise not reflected back
    // (it may contain user-supplied image/env values).
    app.post("api", "containers", "run") { req async throws -> Response in
        let body: ContainerRunRequest
        do { body = try req.content.decode(ContainerRunRequest.self) }
        catch {
            // SpecError reasons are fixed server labels (never the offending
            // value), safe to surface for UX; other decode errors stay generic.
            let detail = (error as? SpecError).map { "\($0)" } ?? "format"
            throw Abort(.badRequest, reason: "invalid run request: \(detail)")
        }
        do {
            let id = try await ContainerCLI.run(runner, req: body)
            return jsonResponse(try JSONEncoder().encode(RunResponse(id: id)), status: .created)
        } catch {
            throw Abort(.internalServerError, reason: "container run failed")
        }
    }

    // Pull an image by reference. The ref is validated at the boundary
    // (ImageRefValidator); pull runs uncached + output-discarding (its progress
    // would overflow a pipe buffer). 202 on success; generic error on failure
    // (CLI output may carry the ref and is not reflected back).
    app.post("api", "images", "pull") { req async throws -> Response in
        let body: ImagePullRequest
        do { body = try req.content.decode(ImagePullRequest.self) }
        catch { throw Abort(.badRequest, reason: "invalid pull request") }
        guard ImageRefValidator.validate(body.reference) else {
            throw Abort(.badRequest, reason: "invalid image reference")
        }
        do {
            try await ContainerCLI.imagePull(runner, ref: body.reference)
            return Response(status: .accepted)
        } catch {
            throw Abort(.internalServerError, reason: "image pull failed")
        }
    }

    // MARK: Exec (interactive terminal; opt-in)

    // `container exec -i -t <id> /bin/sh` over a WebSocket. The id is validated
    // and the ws Origin/Sec-Fetch-Site checked BEFORE the upgrade (a ws upgrade
    // is a GET, so the POST/DELETE OriginGuard does not cover it). The checks run
    // in the GET handler so a cross-origin upgrade is rejected with a real 403
    // (not a nil-upgrade). Disabled entirely (404) unless CONTAINERDASHBOARD_ENABLE_EXEC=1.
    app.get("api", "containers", ":id", "exec") { req async throws -> Response in
        guard execEnabled else { throw Abort(.notFound) }
        let id = try validatedID(req)
        if OriginGuardMiddleware.shouldBlockWS(
            origin: req.headers.first(name: .origin),
            secFetchSite: req.headers.first(name: HTTPHeaders.Name("Sec-Fetch-Site"))
        ) {
            throw Abort(.forbidden, reason: "cross-origin websocket blocked")
        }
        let cols = clampQuery(req, "cols", min: 20, max: 300, default: 80)
        let rows = clampQuery(req, "rows", min: 1, max: 100, default: 24)
        return req.webSocket(
            shouldUpgrade: { _ async throws -> HTTPHeaders? in [:] },
            onUpgrade: { _, ws async in
                // Pool cap. Acquired here (post-upgrade) so a refused session
                // closes cleanly; released on close (clean or ping-timeout).
                do { try await ExecPool.shared.acquire() }
                catch {
                    try? await ws.send("[terminal pool full]\n")
                    _ = try? await ws.close().get()
                    return
                }
                let stream = PTYProcessRunner().exec(
                    binary: "container", args: ["exec", "-i", "-t", id, "/bin/sh"],
                    cols: cols, rows: rows
                )
                // client -> child. onUpgrade runs off the channel event loop (Vapor
                // wraps it in a Task), so the loop-bound sync setters would trap -
                // use the async overloads, which self-hop to the loop.
                let onTextCb: @Sendable (WebSocket, String) async -> Void = { _, text in
                    stream.send(Data(text.utf8))
                }
                let onBinaryCb: @Sendable (WebSocket, ByteBuffer) async -> Void = { _, buf in
                    stream.send(Data(buf.readableBytesView))
                }
                ws.onText(onTextCb)
                ws.onBinary(onBinaryCb)
                // Dirty-disconnect heartbeat: the library pings every interval and
                // force-closes if no pong arrives before the next ping (~60s bound
                // on lid-close / VPN-drop / NAT-idle, where no FIN is ever sent).
                ws.pingInterval = .seconds(30)
                // child -> client
                Task {
                    for try await chunk in stream.output { try await ws.send(raw: chunk, opcode: .binary) }
                    _ = try? await ws.close().get()
                }
                // Safety net: bound any one session to 30 min regardless.
                let net = Task {
                    try? await Task.sleep(for: .seconds(1800))
                    stream.close()
                    _ = try? await ws.close().get()
                }
                // Teardown (clean close, ping-timeout, or safety net): reap the
                // child and free the pool slot.
                ws.onClose.whenComplete { _ in
                    stream.close()
                    net.cancel()
                    Task { await ExecPool.shared.release() }
                }
            }
        )
    }

    // MARK: Builder

    app.post("api", "builder", "start") { _ async throws -> Response in
        try await runAction { try await ContainerCLI.builderStart(runner) }
    }
    app.post("api", "builder", "stop") { _ async throws -> Response in
        try await runAction { try await ContainerCLI.builderStop(runner) }
    }

    // MARK: Prune (whitelisted category)

    app.post("api", "prune", ":category") { req async throws -> Response in
        let raw = req.parameters.get("category") ?? ""
        guard let category = PruneCategory(rawValue: raw) else {
            throw Abort(.badRequest, reason: "invalid prune category")
        }
        return try await runAction { try await ContainerCLI.prune(runner, category: category) }
    }

    // GET / + SSE logs are registered in later phases.
}

// MARK: - Route helpers

private func validatedID(_ req: Request, _ param: String = "id") throws -> String {
    let value = req.parameters.get(param) ?? ""
    guard IDValidator.validate(value) else {
        throw Abort(.badRequest, reason: "invalid \(param)")
    }
    return value
}

/// Run a side-effecting CLI command; 2xx on success, generic 500 on failure (do
/// not reflect CLI output - future stderr-carrying errors may contain user input).
private func runAction(_ work: () async throws -> Void) async throws -> Response {
    do {
        try await work()
        return Response(status: .ok)
    } catch {
        throw Abort(.internalServerError, reason: "command failed")
    }
}

/// JSON response from raw bytes. Shared by passthrough reads + the run route.
private func jsonResponse(_ data: Data, status: HTTPResponseStatus = .ok) -> Response {
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json; charset=utf-8")
    return Response(status: status, headers: headers, body: Response.Body(data: data))
}

/// Serve raw JSON bytes (for heterogeneous system properties / dns payloads).
private func passthrough(_ data: () async throws -> Data) async throws -> Response {
    jsonResponse(try await data())
}

/// `POST /api/containers/run` success body: the new container id.
private struct RunResponse: Codable {
    let id: String
}

/// `POST /api/images/pull` body. The reference is validated after decoding.
private struct ImagePullRequest: Codable {
    let reference: String
}

/// `GET /api/capabilities` body: feature flags the frontend renders against.
private struct CapabilitiesResponse: Content {
    let exec: Bool
}

/// Parse `?key=` as Int, fail-closed to `default` on any parse error, then clamp
/// into `[min, max]`. Used for the exec ws cols/rows query params.
private func clampQuery(_ req: Request, _ key: String, min lo: Int, max hi: Int, default def: Int) -> UInt16 {
    let raw = req.query[Int.self, at: key] ?? def
    return UInt16(Swift.max(lo, Swift.min(hi, raw)))
}
