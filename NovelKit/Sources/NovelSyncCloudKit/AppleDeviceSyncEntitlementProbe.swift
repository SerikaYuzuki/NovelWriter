import Foundation
#if os(macOS)
import Security
#endif

/// `CKContainer`を生成する前に、現在の署名へ必要なCloudKit entitlementが
/// 実際に埋め込まれているかを確認する。署名なしtest hostではfalseを返し、
/// CloudKit frameworkのentitlement exceptionを起こさない。
public enum AppleDeviceSyncEntitlementProbe {
    public static func hasCloudKitContainer(_ containerIdentifier: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let containers = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.icloud-container-identifiers" as CFString,
                  nil
              ) as? [String],
              let services = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.icloud-services" as CFString,
                  nil
              ) as? [String] else { return false }
        return hasCloudKitContainer(
            containerIdentifier,
            installedContainers: containers,
            installedServices: services
        )
        #else
        // SecTask entitlement introspection is not public in the iOS SDK.
        // The iOS App excludes its unsigned XCTest host before constructing
        // this adapter; signed device capability remains an external Gate.
        return containerIdentifier.hasPrefix("iCloud.")
        #endif
    }

    static func hasCloudKitContainer(
        _ containerIdentifier: String,
        installedContainers: [String],
        installedServices: [String]
    ) -> Bool {
        containerIdentifier.hasPrefix("iCloud.")
            && installedContainers.contains(containerIdentifier)
            && installedServices.contains("CloudKit")
    }
}
