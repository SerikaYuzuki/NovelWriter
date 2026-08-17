public enum SyncV2TypeError: Error, Equatable, Sendable {
    case invalidUUID
    case invalidDigest
    case invalidManifest
    case invalidEntityKey
    case missingEntity(String)
    case duplicateEntity(String)
    case schemaViolation(String)
    case digestMismatch
    case byteCountMismatch
    case unsupportedContentType
    case referenceViolation(String)
    case commandViolation(String)
}

/// Shared wire and storage limits. Keep these values identical across the
/// Swift client, Rust server, and both database schemas.
public enum SnapshotSyncV2Limits {
    public static let maxEntries = 100_000
    public static let maxManifestBytes = 16 * 1024 * 1024
    public static let maxStructuredEntityBytes = 16 * 1024 * 1024
    public static let maxObjectBytes = 250 * 1024 * 1024
    public static let maxCommandBytes = 32 * 1024 * 1024
    public static let maxManifestBase64URLCharacters = 22_369_624
    public static let maxCanonicalJSONDepth = 128
}
