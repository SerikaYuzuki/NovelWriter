import Foundation

/// Runtime composition for the app's optional server lane.
///
/// Test hosts are deliberately offline-first: they must not construct an
/// HTTP transport from the production default or from a developer's
/// UserDefaults. The app may still exercise SQLite, import/export, and UI
/// behavior with this environment disabled.
public struct FuminiwaRuntimeEnvironment: Equatable, Sendable {
    public enum NetworkPolicy: Equatable, Sendable {
        case disabled
        case enabled
    }

    public let networkPolicy: NetworkPolicy
    public let syncServerURL: URL?
    public let isTestProcess: Bool

    public var allowsNetwork: Bool {
        networkPolicy == .enabled && syncServerURL != nil
    }

    public init(
        networkPolicy: NetworkPolicy,
        syncServerURL: URL? = nil,
        isTestProcess: Bool = false
    ) {
        self.networkPolicy = networkPolicy
        self.syncServerURL = syncServerURL
        self.isTestProcess = isTestProcess
    }

    /// Resolves the process composition. The environment argument is
    /// injectable so tests can prove the fail-closed branch without relying
    /// on XCTest implementation details.
    public init(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if Self.isTestProcess(environment: environment) {
            self.init(networkPolicy: .disabled, isTestProcess: true)
            return
        }

        if environment[Self.networkModeKey]?.lowercased() == "disabled" {
            self.init(networkPolicy: .disabled)
            return
        }

        let configuredURL = userDefaults.string(forKey: Self.syncServerURLKey)
        let url = URL(string: configuredURL ?? Self.defaultSyncServerURL)
        self.init(networkPolicy: url == nil ? .disabled : .enabled, syncServerURL: url)
    }

    public static let syncServerURLKey = "fuminiwa.syncServerURL"
    public static let testNetworkDisabledKey = "FUMINIWA_TEST_NETWORK_DISABLED"
    public static let networkModeKey = "FUMINIWA_NETWORK_MODE"

    /// Gives an app host a process-local preference domain during tests. This
    /// keeps test startup and durable intents out of the user's production
    /// UserDefaults while leaving ordinary unit-test suites free to inject
    /// their own domains.
    public static func applicationUserDefaults(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UserDefaults {
        guard isTestProcess(environment: environment) else { return .standard }
        let suite = "dev.serikayuzuki.fuminiwa.test-host.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Unable to create isolated test UserDefaults suite")
        }
        return defaults
    }

    private static let defaultSyncServerURL = "http://192.168.11.5:18080"

    public static func isTestProcess(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment[testNetworkDisabledKey] == "1" {
            return true
        }
        return environment.keys.contains { key in
            key == "XCTestConfigurationFilePath" || key == "XCTestSessionIdentifier"
        }
    }
}
