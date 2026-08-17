import Foundation

/// An item retained by the explicit `.novelpkg` transfer boundary.
public struct PortableResource: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case directory
        case regularFile
    }

    public let pathComponents: [String]
    public let kind: Kind
    public let bytes: Data?

    public init(pathComponents: [String], kind: Kind, bytes: Data? = nil) {
        self.pathComponents = pathComponents
        self.kind = kind
        self.bytes = bytes
    }
}

/// Validated metadata and the opaque remainder of a portable package tree.
public struct PortablePackageMetadata: Sendable, Equatable {
    public let createdAt: Date
    public let resources: [PortableResource]

    public init(createdAt: Date, resources: [PortableResource] = []) {
        self.createdAt = createdAt
        self.resources = resources
    }
}
