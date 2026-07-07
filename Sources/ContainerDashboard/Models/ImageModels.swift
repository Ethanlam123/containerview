import Foundation
import Vapor

/// `container image list --format json` and `container image inspect <name>`
/// (same shape; inspect returns an array). The Images panel uses
/// `configuration.name` (the `name:tag` reference), `configuration.creationDate`,
/// and the arm64 variant for OS/arch + size.
struct ImageList: Content, Sendable {
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
