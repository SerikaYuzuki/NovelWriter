import Foundation

/// Closed command discriminator. Raw values are the unchanged v2 wire spellings.
public enum SyncV2CommandKind: String, CaseIterable, Codable, Hashable, Sendable {
    case cloneWork
    case createWork
    case finalizeObject
    case prepareObject
    case publish
    case registerSnapshot
    case resolveDevice
    case resolveServer
    case restore
}
