import Vapor

/// Registers every API endpoint. `runner` is the cache-decorated runner;
/// `tracker` holds CPU% baselines across polls. Both are constructed once in
/// `configure` and threaded in (no global state).
func registerRoutes(_ app: Application, runner: any CommandRunner, tracker: StatsTracker) {
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
        catch { throw Abort(.badRequest, reason: "invalid run request") }
        do {
            let id = try await ContainerCLI.run(runner, req: body)
            let json = try JSONEncoder().encode(RunResponse(id: id))
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            return Response(status: .created, headers: headers, body: Response.Body(data: json))
        } catch {
            throw Abort(.internalServerError, reason: "container run failed")
        }
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

/// Run a side-effecting CLI command; 2xx on success, 500 with the CLI error on failure.
private func runAction(_ work: () async throws -> Void) async throws -> Response {
    do {
        try await work()
        return Response(status: .ok)
    } catch {
        throw Abort(.internalServerError, reason: "\(error)")
    }
}

/// Serve raw JSON bytes (for heterogeneous system properties / dns payloads).
private func passthrough(_ data: () async throws -> Data) async throws -> Response {
    let bytes = try await data()
    var headers = HTTPHeaders()
    headers.add(name: .contentType, value: "application/json; charset=utf-8")
    return Response(status: .ok, headers: headers, body: Response.Body(data: bytes))
}

/// `POST /api/containers/run` success body: the new container id.
private struct RunResponse: Codable {
    let id: String
}
