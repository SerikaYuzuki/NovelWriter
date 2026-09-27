import Foundation

/// Returns a fresh app-test preferences domain. Callers pass it explicitly so
/// a hosted Test build can never fall back to the production app domain.
func makeIsolatedTestUserDefaults() -> UserDefaults {
    let suiteName = "jp.fuminiwa.app-tests.\(UUID().uuidString.lowercased())"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        preconditionFailure("Unable to create isolated app-test defaults")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
