@testable import FUMINIWAExperimental
import NovelAI
import Testing

@Test("Experimental targetだけがNovelAI境界とcompile markerを持つ")
func experimentalTargetContainsNovelAIBoundary() {
    #expect(ExperimentalBuildIdentity.isEnabled)
    #expect(ExperimentalBuildIdentity.providerBoundary == .codex)
    #expect(!AppBuildFlavor.migratesLegacyPreferences)
    #expect(AppBuildFlavor.defaultDocumentDirectoryName == "FUMINIWAExperimental")
}

@MainActor
@Test("Experimental targetは通常版と異なる既定保存rootを使う")
func experimentalTargetUsesSeparateDefaultDocumentRoot() {
    let state = AppState(
        dependencies: AppDependencies(),
        initialStartupState: .ready
    )

    #expect(state.documentURL.pathComponents.contains("FUMINIWAExperimental"))
    #expect(!state.documentURL.pathComponents.contains("FUMINIWA"))
}
