import Foundation
import Vapor

/// `container ls --format json --all` and `container inspect <id>` (same shape; an array).
///
/// Modeled against the captured fixture (2026-07-07), which is the ground truth
/// where it diverges from the prose spec: `image.reference` is a sibling of
/// `descriptor`, not nested inside it.
struct ContainerList: Content, Sendable {
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
        /// The key is the type tag; the associated value is only displayed.
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

/// `container stats --format json --no-stream` - flat camelCase, an array.
/// `cpuUsageUsec` is cumulative microseconds since start, NOT a percentage.
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
