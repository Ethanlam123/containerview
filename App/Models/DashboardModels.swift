// Mirrored Codable shapes for the dashboard API. Duplicated from
// Sources/ContainerDashboard/Models + Service/StateService rather than shared
// via a lib target, so the native app builds independently and the server
// ("the function") stays untouched. Codable ignores unknown keys, so additive
// server changes don't break decode. All types are Sendable value types.

import Foundation

struct DashboardState: Codable, Sendable {
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

struct Warning: Codable, Sendable {
    let section: String
    let message: String
}

// MARK: - Containers

struct ContainerList: Codable, Sendable, Identifiable {
    let id: String
    let configuration: Configuration
    let status: Status

    struct Configuration: Codable, Sendable {
        let id: String
        let image: Image
        let resources: Resources
        let platform: Platform
        let publishedPorts: [PublishedPort]?
        let mounts: [Mount]?
        let hostname: String?
    }

    struct Image: Codable, Sendable {
        let reference: String
        let descriptor: Descriptor
        struct Descriptor: Codable, Sendable {
            let digest: String
            let size: Int64
            let mediaType: String?
        }
    }

    struct Resources: Codable, Sendable {
        let cpus: Int
        let memoryInBytes: Int64
        let cpuOverhead: Int?
    }

    struct Platform: Codable, Sendable {
        let architecture: String
        let os: String
    }

    struct PublishedPort: Codable, Sendable {
        let hostPort: Int
        let containerPort: Int
        let hostAddress: String
        let proto: String
    }

    struct Mount: Codable, Sendable {
        let source: String
        let destination: String
        let type: MountType
        /// Real JSON is a single-key object: `{"virtiofs":{}}` or `{"bind":{...}}`.
        struct MountType: Codable, Sendable {
            let virtiofs: [String: String]?
            let bind: [String: String]?
            var kind: String { virtiofs != nil ? "virtiofs" : (bind != nil ? "bind" : "unknown") }
        }
    }

    struct Status: Codable, Sendable {
        let state: String
        let networks: [NetStatus]?
        let startedDate: String?
    }

    struct NetStatus: Codable, Sendable {
        let network: String
        let ipv4Address: String?
        let ipv6Address: String?
        let ipv4Gateway: String?
        let macAddress: String?
        let hostname: String?
    }
}

struct ContainerStats: Codable, Sendable {
    let id: String
    let memoryUsageBytes: Int64
    let memoryLimitBytes: Int64
    let cpuUsageUsec: Int64
    let networkRxBytes: Int64
    let networkTxBytes: Int64
    let blockReadBytes: Int64
    let blockWriteBytes: Int64
    let numProcesses: Int
}

struct StatsWithCPU: Codable, Sendable {
    let stats: ContainerStats
    let cpuPercent: Double
}

// MARK: - Images

struct ImageList: Codable, Sendable, Identifiable {
    let id: String
    let configuration: Configuration
    let variants: [Variant]

    struct Configuration: Codable, Sendable {
        let name: String
        let creationDate: String
        let descriptor: Descriptor
        struct Descriptor: Codable, Sendable {
            let digest: String
            let size: Int64
            let mediaType: String?
        }
    }

    struct Variant: Codable, Sendable {
        let digest: String
        let size: Int64
        let platform: Platform
        struct Platform: Codable, Sendable {
            let architecture: String
            let os: String
            let variant: String?
        }
    }
}

// MARK: - Machines

struct MachineList: Codable, Sendable {
    let id: String?
    let configuration: Configuration?
    let status: Status?

    struct Configuration: Codable, Sendable {
        let name: String?
        let image: String?
        let resources: Resources?
        let creationDate: String?
        struct Resources: Codable, Sendable {
            let cpus: Int?
            let memoryInBytes: Int64?
        }
    }

    struct Status: Codable, Sendable {
        let state: String?
        let ipv4Address: String?
    }
}

// MARK: - Networks

struct NetworkList: Codable, Sendable {
    let id: String
    let configuration: Configuration
    let status: Status

    struct Configuration: Codable, Sendable {
        let name: String
        let mode: String
        let plugin: String
        let creationDate: String
    }

    struct Status: Codable, Sendable {
        let ipv4Gateway: String
        let ipv4Subnet: String
        let ipv6Subnet: String?
    }
}

// MARK: - System

struct SystemStatus: Codable, Sendable { let status: String }

struct VersionComponent: Codable, Sendable {
    let appName: String
    let version: String
    let buildType: String
    let commit: String
}

struct SystemDF: Codable, Sendable {
    let containers: Category
    let images: Category
    let volumes: Category
    struct Category: Codable, Sendable {
        let active: Int
        let reclaimable: Int64
        let sizeInBytes: Int64
        let total: Int
    }
}

struct BuilderStatus: Codable, Sendable {
    let state: String?
    let cpus: Int?
    let memoryInBytes: Int64?
    let containerID: String?
}

struct Capabilities: Codable, Sendable {
    let exec: Bool
}

// MARK: - Derived row for the containers table (joins containers + stats by id)

struct ContainerRow: Identifiable, Sendable {
    let id: String
    let imageRef: String
    let state: String
    let ip: String
    let cpuPercent: Double?
    let memoryBytes: Int64?
    let memoryLimit: Int64?
    let arch: String
    let cpus: Int
}

func deriveRows(_ state: DashboardState) -> [ContainerRow] {
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
