import Foundation
import os

#if canImport(NovelSyncCloudKit)
import NovelSyncCloudKit
#endif

enum DeviceSyncLog {
    private static let noteLogger = Logger(
        subsystem: "dev.serikayuzuki.fuminiwa",
        category: "note-sync"
    )
    private static let libraryLogger = Logger(
        subsystem: "dev.serikayuzuki.fuminiwa",
        category: "cloud-library"
    )

    /// Debug ビルドは既定オン。Scheme の環境変数 `FUMINIWA_NOTE_SYNC_DEBUG=0/1` で上書きできる。
    static var isDebugEnabled: Bool {
        switch ProcessInfo.processInfo.environment["FUMINIWA_NOTE_SYNC_DEBUG"] {
        case "1": true
        case "0": false
        default:
            #if DEBUG
            true
            #else
            false
            #endif
        }
    }

    static func token(_ error: any Error) -> String {
        #if canImport(NovelSyncCloudKit)
        CloudKitSyncDiagnostic.token(for: error)
        #else
        String(reflecting: type(of: error))
        #endif
    }

    static func userFacingMessage(_ message: String, error: any Error) -> String {
        guard isDebugEnabled else { return message }
        return "\(message)\n\n\(token(error))"
    }

    static func event(_ name: String, error: (any Error)? = nil) {
        emit(prefix: "cloud-library", name: name, error: error, logger: libraryLogger)
    }

    static func note(_ name: String, error: (any Error)? = nil) {
        emit(prefix: "note-sync", name: name, error: error, logger: noteLogger)
    }

    static func looksTemporarilyOffline(_ error: any Error) -> Bool {
        #if canImport(NovelSyncCloudKit)
        CloudKitSyncDiagnostic.looksTemporarilyOffline(error)
        #else
        false
        #endif
    }

    private static func emit(
        prefix: String,
        name: String,
        error: (any Error)?,
        logger: Logger
    ) {
        let line = if let error {
            "\(prefix) \(name)(\(token(error)))"
        } else {
            "\(prefix) \(name)"
        }
        print("[FUMINIWA] \(line)")
        if error != nil {
            logger.error("\(line, privacy: .public)")
        } else if isDebugEnabled {
            logger.info("\(line, privacy: .public)")
        }
    }
}
