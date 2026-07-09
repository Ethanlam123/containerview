import Foundation

/// `container network list --format json`. Used for the Networks metric and an
/// optional name/gateway display.
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
