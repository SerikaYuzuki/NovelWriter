import NovelAI

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("FUMINIWAExperimental requires FUMINIWA_ENABLE_EXPERIMENTAL_AI")
#endif

/// 個人用AI実験を通常版からbuild graphで分離できていることを示すcompile-time marker。
///
/// このsource directoryは`FUMINIWAExperimental` targetだけがcompileする。
/// 通常の`FUMINIWA` targetは`NovelAI`へ依存せず、この型も含まない。
enum ExperimentalBuildIdentity {
    static let isEnabled = true
    static let providerBoundary = AIProviderID.codex
}
