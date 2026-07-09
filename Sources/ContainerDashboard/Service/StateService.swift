import Vapor

/// One composite payload for the primary poll endpoint. Every section is
/// optional; a failing section becomes `nil` plus a `Warning` rather than
/// blanking the whole response.
struct DashboardState: Content, Sendable {
    var health: SystemStatus?
    var containers: [ContainerList]?
    var stats: [StatsWithCPU]?
    var machines: [MachineList]?
    var images: [ImageList]?
    var networks: [NetworkList]?
    var diskUsage: SystemDF?
    var builder: [BuilderStatus]?
    var version: [VersionComponent]?
    var macosVersion: String?
    var warnings: [Warning] = []
}

struct Warning: Content, Sendable {
    let section: String
    let message: String
}

/// Composes `/api/state`: fans out every CLI read concurrently, merges stats
/// with CPU% via the tracker, filters the buildkit builder out of containers
/// and stats, and collects per-section failures into `warnings`.
struct StateService {
    private static let builderRef = "container-builder-shim/builder"

    func state(runner: some CommandRunner, tracker: StatsTracker) async -> DashboardState {
        async let healthR     = Self.toResult { try await ContainerCLI.systemStatus(runner) }
        async let containersR = Self.toResult { try await ContainerCLI.ls(runner) }
        async let statsRawR   = Self.toResult { try await ContainerCLI.stats(runner) }
        async let machinesR   = Self.toResult { try await ContainerCLI.machines(runner) }
        async let imagesR     = Self.toResult { try await ContainerCLI.images(runner) }
        async let networksR   = Self.toResult { try await ContainerCLI.networks(runner) }
        async let dfR         = Self.toResult { try await ContainerCLI.systemDF(runner) }
        async let builderR    = Self.toResult { try await ContainerCLI.builderStatus(runner) }
        async let versionR    = Self.toResult { try await ContainerCLI.version(runner) }
        async let macosR      = Self.toResult { try await ContainerCLI.macosVersion(runner) }

        let health = await healthR
        let containers = await containersR
        let statsRaw = await statsRawR
        let wall = Date()   // approx when the stats fetch resolved
        let machines = await machinesR
        let images = await imagesR
        let networks = await networksR
        let df = await dfR
        let builder = await builderR
        let version = await versionR
        let macos = await macosR

        var s = DashboardState()
        var warnings: [Warning] = []

        s.health = Self.assign("health", health, &warnings)
        s.containers = Self.assign("containers", containers, &warnings)
        s.machines = Self.assign("machines", machines, &warnings)
        s.images = Self.assign("images", images, &warnings)
        s.networks = Self.assign("networks", networks, &warnings)
        s.diskUsage = Self.assign("diskUsage", df, &warnings)
        s.builder = Self.assign("builder", builder, &warnings)
        s.version = Self.assign("version", version, &warnings)
        s.macosVersion = Self.assign("macosVersion", macos, &warnings)

        switch statsRaw {
        case .success(let raw):
            s.stats = await tracker.update(raw, at: wall)
        case .failure(let e):
            warnings.append(Warning(section: "stats", message: "\(e)"))
        }

        Self.filterBuildkit(containers: &s.containers, stats: &s.stats, builder: builder)

        s.warnings = warnings
        return s
    }

    private static func toResult<T>(_ work: @escaping @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private static func assign<T>(_ section: String, _ r: Result<T, Error>, _ warnings: inout [Warning]) -> T? {
        switch r {
        case .success(let v): return v
        case .failure(let e):
            warnings.append(Warning(section: section, message: "\(e)"))
            return nil
        }
    }

    /// Drop the buildkit builder container from `containers` (by builder-reported
    /// id OR by image reference) and from `stats` (by id). No filter when the
    /// builder was never started (`[]`) or its status failed to decode.
    private static func filterBuildkit(containers: inout [ContainerList]?, stats: inout [StatsWithCPU]?, builder: Result<[BuilderStatus], Error>) {
        guard case .success(let b) = builder, !b.isEmpty else { return }
        let ids = Set(b.compactMap { $0.containerID })
        if let cs = containers {
            containers = cs.filter { c in
                !ids.contains(c.id) &&
                !c.configuration.image.reference.localizedCaseInsensitiveContains(builderRef)
            }
        }
        if let st = stats {
            stats = st.filter { !ids.contains($0.stats.id) }
        }
    }
}
