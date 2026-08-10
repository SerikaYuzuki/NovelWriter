@testable import NovelSyncCloudKit
import Testing

@Suite("Apple Device Sync entitlement probe")
struct AppleDeviceSyncEntitlementProbeTests {
    @Test("the exact container and CloudKit service are both required")
    func exactContainerAndServiceAreRequired() {
        let expected = "iCloud.dev.serikayuzuki.fuminiwa.sync"
        #expect(
            AppleDeviceSyncEntitlementProbe.hasCloudKitContainer(
                expected,
                installedContainers: [expected],
                installedServices: ["CloudKit"]
            )
        )
        #expect(
            !AppleDeviceSyncEntitlementProbe.hasCloudKitContainer(
                expected,
                installedContainers: ["iCloud.example.other"],
                installedServices: ["CloudKit"]
            )
        )
        #expect(
            !AppleDeviceSyncEntitlementProbe.hasCloudKitContainer(
                expected,
                installedContainers: [expected],
                installedServices: []
            )
        )
    }
}
