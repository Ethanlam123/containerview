// Mirrored Codable shapes for the dashboard API. Duplicated from
// Sources/ContainerDashboard/Models + Service/StateService and split into a
// library target (`ContainerMonitorCore`) so the pure logic is unit-testable.
// The server ("the function") stays untouched. Codable ignores unknown keys, so
// additive server changes don't break decode. All types are Sendable value types.
//
// Public access throughout: the app target is a separate module, so decoding
// (needs a public synthesized init(from:)) and the test/memberwise constructors
// both cross the module boundary.

import Foundation

public struct DashboardState: Codable, Sendable {
    public var health: SystemStatus?
    public var containers: [ContainerList]?
    public var stats: [StatsWithCPU]?
    public var machines: [MachineList]?
    public var images: [ImageList]?
    public var networks: [NetworkList]?
    public var diskUsage: SystemDF?
    public var builder: [BuilderStatus]?
    public var version: [VersionComponent]?
    public var macosVersion: String?
    public var warnings: [Warning] = []

    public init(health: SystemStatus? = nil, containers: [ContainerList]? = nil,
                stats: [StatsWithCPU]? = nil, machines: [MachineList]? = nil,
                images: [ImageList]? = nil, networks: [NetworkList]? = nil,
                diskUsage: SystemDF? = nil, builder: [BuilderStatus]? = nil,
                version: [VersionComponent]? = nil, macosVersion: String? = nil,
                warnings: [Warning] = []) {
        self.health = health; self.containers = containers; self.stats = stats
        self.machines = machines; self.images = images; self.networks = networks
        self.diskUsage = diskUsage; self.builder = builder; self.version = version
        self.macosVersion = macosVersion; self.warnings = warnings
    }
}

public struct Warning: Codable, Sendable {
    public let section: String
    public let message: String
}

// MARK: - Containers

public struct ContainerList: Codable, Sendable, Identifiable {
    public let id: String
    public let configuration: Configuration
    public let status: Status

    public init(id: String, configuration: Configuration, status: Status) {
        self.id = id; self.configuration = configuration; self.status = status
    }

    public struct Configuration: Codable, Sendable {
        public let id: String
        public let image: Image
        public let resources: Resources
        public let platform: Platform
        public let publishedPorts: [PublishedPort]?
        public let mounts: [Mount]?
        public let hostname: String?

        public init(id: String, image: Image, resources: Resources, platform: Platform,
                    publishedPorts: [PublishedPort]?, mounts: [Mount]?, hostname: String?) {
            self.id = id; self.image = image; self.resources = resources
            self.platform = platform; self.publishedPorts = publishedPorts
            self.mounts = mounts; self.hostname = hostname
        }
    }

    public struct Image: Codable, Sendable {
        public let reference: String
        public let descriptor: Descriptor
        public init(reference: String, descriptor: Descriptor) {
            self.reference = reference; self.descriptor = descriptor
        }
        public struct Descriptor: Codable, Sendable {
            public let digest: String
            public let size: Int64
            public let mediaType: String?
            public init(digest: String, size: Int64, mediaType: String?) {
                self.digest = digest; self.size = size; self.mediaType = mediaType
            }
        }
    }

    public struct Resources: Codable, Sendable {
        public let cpus: Int
        public let memoryInBytes: Int64
        public let cpuOverhead: Int?
        public init(cpus: Int, memoryInBytes: Int64, cpuOverhead: Int?) {
            self.cpus = cpus; self.memoryInBytes = memoryInBytes; self.cpuOverhead = cpuOverhead
        }
    }

    public struct Platform: Codable, Sendable {
        public let architecture: String
        public let os: String
        public init(architecture: String, os: String) {
            self.architecture = architecture; self.os = os
        }
    }

    public struct PublishedPort: Codable, Sendable {
        public let hostPort: Int
        public let containerPort: Int
        public let hostAddress: String
        public let proto: String
    }

    public struct Mount: Codable, Sendable {
        public let source: String
        public let destination: String
        public let type: MountType
        /// Real JSON is a single-key object: `{"virtiofs":{}}` or `{"bind":{...}}`.
        public struct MountType: Codable, Sendable {
            public let virtiofs: [String: String]?
            public let bind: [String: String]?
            public var kind: String { virtiofs != nil ? "virtiofs" : (bind != nil ? "bind" : "unknown") }
        }
    }

    public struct Status: Codable, Sendable {
        public let state: String
        public let networks: [NetStatus]?
        public let startedDate: String?
        public init(state: String, networks: [NetStatus]?, startedDate: String?) {
            self.state = state; self.networks = networks; self.startedDate = startedDate
        }
    }

    public struct NetStatus: Codable, Sendable {
        public let network: String
        public let ipv4Address: String?
        public let ipv6Address: String?
        public let ipv4Gateway: String?
        public let macAddress: String?
        public let hostname: String?
        public init(network: String, ipv4Address: String?, ipv6Address: String?,
                    ipv4Gateway: String?, macAddress: String?, hostname: String?) {
            self.network = network; self.ipv4Address = ipv4Address; self.ipv6Address = ipv6Address
            self.ipv4Gateway = ipv4Gateway; self.macAddress = macAddress; self.hostname = hostname
        }
    }
}

public struct ContainerStats: Codable, Sendable {
    public let id: String
    public let memoryUsageBytes: Int64
    public let memoryLimitBytes: Int64
    public let cpuUsageUsec: Int64
    public let networkRxBytes: Int64
    public let networkTxBytes: Int64
    public let blockReadBytes: Int64
    public let blockWriteBytes: Int64
    public let numProcesses: Int

    public init(id: String, memoryUsageBytes: Int64, memoryLimitBytes: Int64,
                cpuUsageUsec: Int64, networkRxBytes: Int64, networkTxBytes: Int64,
                blockReadBytes: Int64, blockWriteBytes: Int64, numProcesses: Int) {
        self.id = id; self.memoryUsageBytes = memoryUsageBytes; self.memoryLimitBytes = memoryLimitBytes
        self.cpuUsageUsec = cpuUsageUsec; self.networkRxBytes = networkRxBytes
        self.networkTxBytes = networkTxBytes; self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes; self.numProcesses = numProcesses
    }
}

public struct StatsWithCPU: Codable, Sendable {
    public let stats: ContainerStats
    public let cpuPercent: Double
    public init(stats: ContainerStats, cpuPercent: Double) {
        self.stats = stats; self.cpuPercent = cpuPercent
    }
}

// MARK: - Images

public struct ImageList: Codable, Sendable, Identifiable {
    public let id: String
    public let configuration: Configuration
    public let variants: [Variant]

    public struct Configuration: Codable, Sendable {
        public let name: String
        public let creationDate: String
        public let descriptor: Descriptor
        public struct Descriptor: Codable, Sendable {
            public let digest: String
            public let size: Int64
            public let mediaType: String?
        }
    }

    public struct Variant: Codable, Sendable {
        public let digest: String
        public let size: Int64
        public let platform: Platform
        public struct Platform: Codable, Sendable {
            public let architecture: String
            public let os: String
            public let variant: String?
        }
    }
}

// MARK: - Machines

public struct MachineList: Codable, Sendable {
    public let id: String?
    public let configuration: Configuration?
    public let status: Status?

    public struct Configuration: Codable, Sendable {
        public let name: String?
        public let image: String?
        public let resources: Resources?
        public let creationDate: String?
        public struct Resources: Codable, Sendable {
            public let cpus: Int?
            public let memoryInBytes: Int64?
        }
    }

    public struct Status: Codable, Sendable {
        public let state: String?
        public let ipv4Address: String?
    }

    /// Stable identity for list diffing (M3). Apple `container` machines always
    /// carry a name; the `<anonymous>` fallback only collides in the degenerate
    /// nil/nil case, which does not occur in practice.
    public var stableID: String { configuration?.name ?? id ?? "<anonymous>" }
}

// MARK: - Networks

public struct NetworkList: Codable, Sendable {
    public let id: String
    public let configuration: Configuration
    public let status: Status

    public struct Configuration: Codable, Sendable {
        public let name: String
        public let mode: String
        public let plugin: String
        public let creationDate: String
    }

    public struct Status: Codable, Sendable {
        public let ipv4Gateway: String
        public let ipv4Subnet: String
        public let ipv6Subnet: String?
    }
}

// MARK: - System

public struct SystemStatus: Codable, Sendable { public let status: String }

public struct VersionComponent: Codable, Sendable {
    public let appName: String
    public let version: String
    public let buildType: String
    public let commit: String
}

public struct SystemDF: Codable, Sendable {
    public let containers: Category
    public let images: Category
    public let volumes: Category
    public struct Category: Codable, Sendable {
        public let active: Int
        public let reclaimable: Int64
        public let sizeInBytes: Int64
        public let total: Int
    }
}

public struct BuilderStatus: Codable, Sendable {
    public let state: String?
    public let cpus: Int?
    public let memoryInBytes: Int64?
    public let containerID: String?
}

public struct Capabilities: Codable, Sendable {
    public let exec: Bool
    public init(exec: Bool) { self.exec = exec }
}

// MARK: - Derived row for the containers table (joins containers + stats by id)

public struct ContainerRow: Identifiable, Sendable {
    public let id: String
    public let imageRef: String
    public let state: String
    public let ip: String
    public let cpuPercent: Double?
    public let memoryBytes: Int64?
    public let memoryLimit: Int64?
    public let arch: String
    public let cpus: Int
}

public func deriveRows(_ state: DashboardState) -> [ContainerRow] {
    let statsByID = Dictionary(
        (state.stats ?? []).map { ($0.stats.id, $0) },
        uniquingKeysWith: { a, _ in a }
    )
    return (state.containers ?? []).map { c in
        let stat = statsByID[c.id]
        let ip = (c.status.networks?.compactMap { $0.ipv4Address }.first)?.nonEmpty ?? "-"
        return ContainerRow(
            id: c.id,
            imageRef: c.configuration.image.reference,
            state: c.status.state,
            ip: ip,
            cpuPercent: stat?.cpuPercent,
            memoryBytes: stat?.stats.memoryUsageBytes,
            memoryLimit: stat?.stats.memoryLimitBytes,
            arch: c.configuration.platform.architecture,
            cpus: c.configuration.resources.cpus
        )
    }
}
