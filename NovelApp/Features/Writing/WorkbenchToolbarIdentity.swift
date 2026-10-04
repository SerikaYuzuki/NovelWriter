import Foundation

enum WorkbenchToolbarIdentity {
    /// The requested default replaces v8 once. Future launches retain user customization.
    static let current: String = {
        #if FUMINIWA_TEST_COMPOSITION
        "fuminiwa.test.toolbar.\(UUID().uuidString)"
        #else
        "novelwriter.workbench.v9"
        #endif
    }()
}
