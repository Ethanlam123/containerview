import Vapor

/// Server-Sent Events helper. Streams `container logs -f <id>` lines as `data:`
/// SSE frames.
///
/// Disconnect handling (honest notes): Vapor 4 does not surface a per-request
/// channel-inactive signal to a GET SSE handler, and writes to a half-closed
/// (CLOSE_WAIT) connection keep succeeding - so neither `writer.write` nor
/// `AsyncThrowingStream.onTermination` reliably signals that the client has
/// gone. To guarantee no `container logs -f` child leaks, a cap timer bounds
/// every connection. When it elapses (or the logs process exits), the group
/// tears down explicitly: `handle.cancel()` stops the poll-based producer (it
/// observes cancellation within ~250ms) which reaps the child
/// (SIGTERM -> grace -> SIGKILL), finishing the line stream; `group.cancelAll()`
/// + `waitForAll()` then drain the pumps. `EventSource` reconnects
/// automatically on the client, so the cap is invisible during normal use.
///
/// Net effect: an orphaned `container logs -f` from a closed tab lives at most
/// `maxAge` (plus ~250ms). This is the best Vapor's public API permits without a
/// custom channel handler, which it does not expose.
enum SSE {
    /// Guaranteed upper bound on an SSE connection. Bounds any orphaned
    /// `container logs -f` child; `EventSource` reconnects transparently.
    private static let maxAge: Duration = .seconds(120)

    static func logs(runner: any CommandRunner, id: String) -> Response {
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/event-stream")
        headers.add(name: .cacheControl, value: "no-cache")
        headers.add(name: .connection, value: "keep-alive")

        let body = Response.Body(managedAsyncStream: { writer in
            let handle = ContainerCLI.logsStream(runner, id: id)
            defer { handle.cancel() }
            try await withThrowingTaskGroup(of: Void.self) { group in
                // Line pump: frame each log line as `data:`. Runs until the logs
                // process exits or the group is torn down.
                group.addTask {
                    for try await line in handle.lines {
                        var buffer = ByteBufferAllocator().buffer(capacity: line.utf8.count + 8)
                        buffer.writeString("data: \(line)\n\n")
                        try await writer.write(.buffer(buffer))
                    }
                }
                // Cap pump: reliable lifetime bound. Returns after `maxAge`.
                group.addTask {
                    try await Task.sleep(for: Self.maxAge)
                }
                // End on the first child to finish: the cap timer (normal
                // rollover + reconnect) or the logs process exiting. Then tear
                // down explicitly - implicit group teardown would deadlock on
                // the line pump, whose stream can only finish once the producer
                // is cancelled here.
                _ = try await group.next()
                handle.cancel()          // stop producer -> stream finishes -> line pump ends
                group.cancelAll()        // cancel any remaining pump
                try await group.waitForAll()
            }
        })
        return Response(status: .ok, headers: headers, body: body)
    }
}
