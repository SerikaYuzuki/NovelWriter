import Foundation
import NovelSyncV2
#if canImport(os)
import os
#endif

extension SyncV2Application {
    /// Bounded failure diagnostics. Never include associated error values:
    /// those can contain database text, paths, server payloads or manuscript data.
    func recordSyncDiagnostic(workID: WorkID, stage: String, error: any Error) {
        let mirror = Mirror(reflecting: error)
        let errorCase = mirror.displayStyle == .enum ? mirror.children.first?.label : nil
        let simpleCase = mirror.displayStyle == .enum && mirror.children.isEmpty ? String(describing: error) : "unclassified"
        let code = "stage=\(stage); type=\(String(reflecting: type(of: error))); case=\(errorCase ?? simpleCase)"
        syncDiagnostics[workID] = code
        #if canImport(os)
        Logger(subsystem: "dev.serikayuzuki.fuminiwa", category: "sync-debug")
            .error("\(code, privacy: .public)")
        #endif
    }

    func recordSyncDiagnosticIfAbsent(workID: WorkID, stage: String, error: any Error) {
        guard syncDiagnostics[workID] == nil else { return }
        recordSyncDiagnostic(workID: workID, stage: stage, error: error)
    }

    public func syncDebugDiagnostic(workID: WorkID) -> String? {
        #if DEBUG
        syncDiagnostics[workID]
        #else
        nil
        #endif
    }
}
