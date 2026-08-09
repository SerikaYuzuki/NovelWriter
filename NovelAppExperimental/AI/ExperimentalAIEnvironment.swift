import EditorKit
import SwiftUI

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Experimental AI environment must only compile in FUMINIWAExperimental")
#endif

extension EnvironmentValues {
    @Entry var experimentalAISelectionSession: EditorAISelectionSession?
}
