enum AppBuildFlavor {
    #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
    static let defaultDocumentDirectoryName = "FUMINIWAExperimental"
    static let migratesLegacyPreferences = false
    #else
    static let defaultDocumentDirectoryName = "FUMINIWA"
    static let migratesLegacyPreferences = true
    #endif
}
