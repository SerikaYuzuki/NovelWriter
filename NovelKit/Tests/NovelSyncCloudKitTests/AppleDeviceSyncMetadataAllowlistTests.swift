import Foundation
import NovelCore
import NovelSync
@testable import NovelSyncCloudKit
import Testing

@Suite("Apple Device Sync episode allowlist")
struct AppleDeviceSyncMetadataAllowlistTests {
    @Test("episode allowlists are bounded, unique, persistent, and decoded fail-closed")
    func episodeAllowlistValidation() async throws {
        let root = try makeCloudTestDirectory()
        defer { removeCloudTestDirectory(root) }
        let store = try AppleDeviceSyncMetadataStore(rootURL: root)
        _ = try await store.installAccountScope(
            AppleCloudAccountScope(
                containerIdentifier: "iCloud.dev.serikayuzuki.fuminiwa.sync",
                userRecordName: "account-a"
            )
        )
        let locator = try AppleLocalDocumentLocator(rawValue: "mac.document.allowlist")
        let addedEpisodeID = EpisodeID()
        let binding = try await store.bind(
            locator,
            to: cloudTestWorkID,
            allowedEpisodeIDs: [addedEpisodeID, cloudTestEpisodeID]
        )
        #expect(binding.allowedEpisodeIDs == [cloudTestEpisodeID, addedEpisodeID])

        let localOnlyEpisodeID = EpisodeID()
        let repeatedBind = try await store.bind(
            locator,
            to: cloudTestWorkID,
            allowedEpisodeIDs: [cloudTestEpisodeID, addedEpisodeID, localOnlyEpisodeID]
        )
        #expect(repeatedBind == binding)
        #expect(!repeatedBind.allowedEpisodeIDs.contains(localOnlyEpisodeID))

        await #expect(throws: AppleDeviceSyncServicesError.duplicateAllowedEpisodeID) {
            try await store.bind(
                locator,
                to: cloudTestWorkID,
                allowedEpisodeIDs: [cloudTestEpisodeID, cloudTestEpisodeID]
            )
        }
        let oversized = (0 ... AppleDeviceSyncMetadataStore.maximumAllowedEpisodeCount)
            .map { _ in EpisodeID() }
        let oversizedLocator = try AppleLocalDocumentLocator(
            rawValue: "mac.document.too-many"
        )
        await #expect(throws: AppleDeviceSyncServicesError.tooManyAllowedEpisodes) {
            try await store.bind(
                oversizedLocator,
                to: cloudTestWorkID,
                allowedEpisodeIDs: oversized
            )
        }
        #expect(await store.bindingSnapshot(for: locator) == binding)

        let safeRoot = await store.safeRootURL()
        let metadataURL = safeRoot.appendingPathComponent(
            AppleDeviceSyncMetadataStore.metadataFileName
        )
        let data = try Data(contentsOf: metadataURL)
        var json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var bindings = try #require(json["bindings"] as? [[String: Any]])
        var firstBinding = try #require(bindings.first)
        var episodeIDs = try #require(firstBinding["allowedEpisodeIDs"] as? [Any])
        let duplicateEpisodeID = try #require(episodeIDs.first)
        episodeIDs.append(duplicateEpisodeID)
        firstBinding["allowedEpisodeIDs"] = episodeIDs
        bindings[0] = firstBinding
        json["bindings"] = bindings
        let malformed = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try malformed.write(to: metadataURL, options: [.atomic])

        #expect(throws: AppleDeviceSyncServicesError.invalidMetadata) {
            try AppleDeviceSyncMetadataStore(rootURL: safeRoot)
        }
    }
}
