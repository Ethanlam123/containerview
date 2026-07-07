import Foundation

/// `container system status --format json`. Only `status` is consumed; the
/// payload carries API-server metadata that the decoder ignores.
struct SystemStatus: Codable, Sendable {
    let status: String
}

/// `container system version --format json` - array of up to 2 component rows
/// (CLI always present; API-server row only if reachable).
struct VersionComponent: Codable, Sendable {
    let appName: String
    let version: String
    let buildType: String
    let commit: String
}

/// `container system df --format json` - an OBJECT with three categories.
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

/// `container builder status --format json`. Returns `[]` when never started;
/// the running-shape was not captured. All fields optional so an unexpected
/// running-shape decodes leniently instead of failing the composite poll.
struct BuilderStatus: Codable, Sendable {
    let state: String?
    let cpus: Int?
    let memoryInBytes: Int64?
    let containerID: String?
}
