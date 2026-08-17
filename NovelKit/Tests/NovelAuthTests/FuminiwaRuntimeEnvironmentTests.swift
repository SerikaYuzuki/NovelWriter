import Foundation
import NovelAuth
import Testing

@Suite("FUMINIWA production runtime endpoint")
struct FuminiwaRuntimeEnvironmentTests {
    @Test("retired HTTP preference cannot reconnect the v1 server")
    func retiredHTTPPreferenceFallsBackToV2HTTPS() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "http://192.168.11.5:18080",
            forKey: FuminiwaRuntimeEnvironment.syncServerURLKey
        )

        let environment = FuminiwaRuntimeEnvironment(
            userDefaults: defaults,
            environment: [:]
        )

        #expect(environment.networkPolicy == .enabled)
        #expect(environment.syncServerURL?.absoluteString == "https://192.168.11.5:8443")
    }

    @Test("an explicit HTTPS v2 endpoint remains configurable")
    func explicitHTTPSEndpointIsPreserved() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "https://sync.example.test:9443",
            forKey: FuminiwaRuntimeEnvironment.syncServerURLKey
        )

        let environment = FuminiwaRuntimeEnvironment(
            userDefaults: defaults,
            environment: [:]
        )

        #expect(environment.syncServerURL?.absoluteString == "https://sync.example.test:9443")
    }

    @Test("disabled network mode constructs no production URL")
    func disabledModeIsFailClosed() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let environment = FuminiwaRuntimeEnvironment(
            userDefaults: defaults,
            environment: [FuminiwaRuntimeEnvironment.networkModeKey: "disabled"]
        )

        #expect(environment.networkPolicy == .disabled)
        #expect(environment.syncServerURL == nil)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "fuminiwa.runtime-endpoint-tests.\(UUID())"
        return try (#require(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
