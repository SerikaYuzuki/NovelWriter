#if canImport(NovelSyncCloudKit) && !FUMINIWA_ENABLE_EXPERIMENTAL_AI
import Foundation
import NovelCore
import NovelSync

struct FileDeviceSyncEditIntentEnvelope: Codable {
    static let currentProtocolVersion = 2

    let protocolVersion: Int
    var marker: DeviceSyncEditIntentMarker?
    var preservedMarkers: [DeviceSyncEditIntentMarker]
    var committedPackage: DeviceSyncPackageCheckpoint?
    var preparedPackage: DeviceSyncPackageCheckpoint?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case markers
        case marker
        case preservedMarkers
        case committedPackage
        case preparedPackage
    }

    init(
        marker: DeviceSyncEditIntentMarker? = nil,
        preservedMarkers: [DeviceSyncEditIntentMarker] = [],
        committedPackage: DeviceSyncPackageCheckpoint? = nil,
        preparedPackage: DeviceSyncPackageCheckpoint? = nil
    ) {
        protocolVersion = Self.currentProtocolVersion
        self.marker = marker
        self.preservedMarkers = preservedMarkers
        self.committedPackage = committedPackage
        self.preparedPackage = preparedPackage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .protocolVersion)
        switch version {
        case 1:
            let markers = try container.decode([DeviceSyncEditIntentMarker].self, forKey: .markers)
            guard markers.count == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .markers,
                    in: container,
                    debugDescription: "A version 1 envelope must contain exactly one marker."
                )
            }
            marker = markers[0]
            preservedMarkers = []
            committedPackage = nil
            preparedPackage = nil
        case Self.currentProtocolVersion:
            marker = try container.decodeIfPresent(DeviceSyncEditIntentMarker.self, forKey: .marker)
            preservedMarkers = try container.decodeIfPresent(
                [DeviceSyncEditIntentMarker].self,
                forKey: .preservedMarkers
            ) ?? []
            committedPackage = try container.decodeIfPresent(
                DeviceSyncPackageCheckpoint.self,
                forKey: .committedPackage
            )
            preparedPackage = try container.decodeIfPresent(
                DeviceSyncPackageCheckpoint.self,
                forKey: .preparedPackage
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .protocolVersion,
                in: container,
                debugDescription: "Unsupported edit-intent envelope version."
            )
        }
        protocolVersion = Self.currentProtocolVersion
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentProtocolVersion, forKey: .protocolVersion)
        try container.encodeIfPresent(marker, forKey: .marker)
        if !preservedMarkers.isEmpty {
            try container.encode(preservedMarkers, forKey: .preservedMarkers)
        }
        try container.encodeIfPresent(committedPackage, forKey: .committedPackage)
        try container.encodeIfPresent(preparedPackage, forKey: .preparedPackage)
    }

    var snapshot: DeviceSyncLocalPersistenceSnapshot {
        DeviceSyncLocalPersistenceSnapshot(
            marker: marker,
            preservedMarkers: preservedMarkers,
            committedPackage: committedPackage,
            preparedPackage: preparedPackage
        )
    }

    var isEmpty: Bool {
        marker == nil && preservedMarkers.isEmpty && committedPackage == nil && preparedPackage == nil
    }
}

actor FileDeviceSyncEditIntentStore: DeviceSyncEditIntentStoring {
    typealias Envelope = FileDeviceSyncEditIntentEnvelope

    static let maximumMarkerBytes = 8 * 1024 * 1024
    static let maximumEnvelopeBytes = 34 * 1024 * 1024

    let rootURL: URL
    let rootIdentity: FileDeviceSyncMergeRecoveryStore.RootIdentity
    let fileManager: FileManager
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    init(rootURL: URL, trustedAncestorURL: URL) throws {
        let fileManager = FileManager()
        let prepared = try Self.prepareAnchoredRoot(
            rootURL,
            trustedAncestorURL: trustedAncestorURL,
            fileManager: fileManager
        )
        self.rootURL = prepared.url
        rootIdentity = prepared.identity
        self.fileManager = fileManager
        encoder.outputFormatting = [.sortedKeys]
    }
}

#endif
