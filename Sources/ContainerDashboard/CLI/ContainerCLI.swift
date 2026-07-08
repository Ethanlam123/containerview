import Foundation
import Darwin

/// Thin typed wrappers over the `container` CLI (+ `sw_vers`). Pure delegation to
/// a `CommandRunner` plus decode/parse - no business logic. Argument arrays only;
/// every id/ref reaches here already validated by the HTTP layer.
enum ContainerCLI {
    private static let decoder = JSONDecoder()
    private static let timeout = Duration.seconds(3)

    // MARK: Reads

    static func ls(_ r: some CommandRunner) async throws -> [ContainerList] {
        try await decode([ContainerList].self, from: run(r, ["ls", "--format", "json", "--all"]))
    }

    static func stats(_ r: some CommandRunner) async throws -> [ContainerStats] {
        try await decode([ContainerStats].self, from: run(r, ["stats", "--format", "json", "--no-stream"]))
    }

    /// `inspect` is JSON-default (no `--format`); returns the same shape as `ls`.
    static func inspect(_ r: some CommandRunner, id: String) async throws -> [ContainerList] {
        try await decode([ContainerList].self, from: run(r, ["inspect", id]))
    }

    static func systemStatus(_ r: some CommandRunner) async throws -> SystemStatus {
        try await decode(SystemStatus.self, from: run(r, ["system", "status", "--format", "json"]))
    }

    static func version(_ r: some CommandRunner) async throws -> [VersionComponent] {
        try await decode([VersionComponent].self, from: run(r, ["system", "version", "--format", "json"]))
    }

    static func systemDF(_ r: some CommandRunner) async throws -> SystemDF {
        try await decode(SystemDF.self, from: run(r, ["system", "df", "--format", "json"]))
    }

    static func builderStatus(_ r: some CommandRunner) async throws -> [BuilderStatus] {
        try await decode([BuilderStatus].self, from: run(r, ["builder", "status", "--format", "json"]))
    }

    static func machines(_ r: some CommandRunner) async throws -> [MachineList] {
        try await decode([MachineList].self, from: run(r, ["machine", "ls", "--format", "json"]))
    }

    static func machineInspect(_ r: some CommandRunner, id: String) async throws -> [MachineList] {
        try await decode([MachineList].self, from: run(r, ["machine", "inspect", id]))
    }

    static func images(_ r: some CommandRunner) async throws -> [ImageList] {
        try await decode([ImageList].self, from: run(r, ["image", "list", "--format", "json"]))
    }

    /// `image inspect` is JSON-default; the entire ref is one argv element
    /// (validated by ImageRefValidator before reaching here).
    static func imageInspect(_ r: some CommandRunner, ref: String) async throws -> [ImageList] {
        try await decode([ImageList].self, from: run(r, ["image", "inspect", ref]))
    }

    static func networks(_ r: some CommandRunner) async throws -> [NetworkList] {
        try await decode([NetworkList].self, from: run(r, ["network", "list", "--format", "json"]))
    }

    /// Heterogeneous config object (build/container/dns/kernel/machine/...).
    /// Served verbatim to the footer Advanced disclosure; not worth a rigid type.
    static func systemProperties(_ r: some CommandRunner) async throws -> Data {
        try await run(r, ["system", "property", "list", "--format", "json"])
    }

    static func dnsDomains(_ r: some CommandRunner) async throws -> Data {
        try await run(r, ["system", "dns", "list", "--format", "json"])
    }

    static func macosVersion(_ r: some CommandRunner) async throws -> String {
        let data = try await r.run(binary: "sw_vers", args: ["-productVersion"], timeout: timeout)
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func logsStream(_ r: some CommandRunner, id: String) -> LogStream {
        r.stream(binary: "container", args: ["logs", "-f", id])
    }

    // MARK: Writes (output ignored; non-zero exit throws)

    // Writes go through `runUncached` so the cache decorator cannot turn a
    // repeated (e.g. double-clicked) side-effecting call into a cached no-op.
    static func stop(_ r: some CommandRunner, id: String) async throws { _ = try await runUncached(r, ["stop", id]) }
    static func start(_ r: some CommandRunner, id: String) async throws { _ = try await runUncached(r, ["start", id]) }
    static func kill(_ r: some CommandRunner, id: String) async throws { _ = try await runUncached(r, ["kill", id]) }

    static func builderStart(_ r: some CommandRunner) async throws { _ = try await runUncached(r, ["builder", "start"]) }
    static func builderStop(_ r: some CommandRunner) async throws { _ = try await runUncached(r, ["builder", "stop"]) }

    static func prune(_ r: some CommandRunner, category: PruneCategory) async throws {
        _ = try await r.runUncached(binary: "container", args: category.argv, timeout: .seconds(30))
    }

    // MARK: Create + start (`container run`)

    /// `container run --detach` from a validated request. The argv is assembled
    /// in a fixed, server-controlled order from already-validated value types;
    /// `--detach` returns once started (we do not stream the init process here),
    /// `--cidfile` recovers the new id deterministically (no racy re-`ls`).
    static func run(_ r: some CommandRunner, req: ContainerRunRequest) async throws -> String {
        let cidFile = try reserveCidFile()
        defer { try? FileManager.default.removeItem(at: cidFile) }
        var argv = ["run", "--detach", "--cidfile", cidFile.path]
        if let name = req.name { argv += ["--name", name] }
        for p in req.ports { argv += ["-p", p.argv] }
        for e in req.env { argv += ["-e", e.argv] }
        for v in req.volumes { argv += ["-v", v.argv] }
        if let cpus = req.cpus { argv += ["-c", String(cpus)] }
        if let memory = req.memory { argv += ["-m", memory.argv] }
        if req.rm == true { argv += ["--rm"] }
        argv.append(req.image)
        argv += req.args
        _ = try await r.runUncached(binary: "container", args: argv, timeout: .seconds(60))
        guard let raw = try? String(contentsOf: cidFile, encoding: .utf8) else {
            throw CLIError.decoding("no container id from cidfile")
        }
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw CLIError.decoding("no container id from cidfile") }
        return id
    }

    /// Reserve a unique cidfile path. `O_CREAT|O_EXCL|O_NOFOLLOW` rules out both
    /// collision and symlink planting in the temp dir; the CLI overwrites it.
    /// A UUIDv4 basename makes a real collision astronomically unlikely, so a
    /// single attempt is enough - `O_EXCL` fails loudly if one happens anyway.
    private static func reserveCidFile() throws -> URL {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".cid")
        let fd = open(path.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY, mode_t(0o600))
        guard fd >= 0 else { throw CLIError.decoding("cidfile reserve failed") }
        close(fd)
        return path
    }

    // MARK: Helpers

    private static func run(_ r: some CommandRunner, _ args: [String]) async throws -> Data {
        try await r.run(binary: "container", args: args, timeout: timeout)
    }

    private static func runUncached(_ r: some CommandRunner, _ args: [String]) async throws -> Data {
        try await r.runUncached(binary: "container", args: args, timeout: timeout)
    }

    private static func decode<T: Decodable>(_ t: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(T.self, from: data) }
        catch { throw CLIError.decoding("\(error)") }
    }
}

/// Prune target. Whitelisted at the HTTP boundary; maps to a fixed argv so a
/// smuggled `:category` path segment can never reach `Process`.
enum PruneCategory: String, Sendable, CaseIterable {
    case containers, images, volumes

    var argv: [String] {
        switch self {
        case .containers: return ["prune"]
        case .images: return ["image", "prune", "-a"]
        case .volumes: return ["volume", "prune"]
        }
    }
}
