import AppKit

@MainActor
enum CaretExperimentPreferences {
    static let enabledKey = "animateCaret"
    static let didChange = Notification.Name("FUMINIWACaretLab.preferencesDidChange")

    static var isEnabled: Bool {
        #if FUMINIWA_CARET_EXPERIMENT_TESTS
        false
        #else
        UserDefaults.standard.bool(forKey: enabledKey)
        #endif
    }
}
