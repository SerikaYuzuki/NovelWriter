import Foundation
import NovelLocalStore
import os

enum DeviceSyncLog {
    private static let noteLogger = Logger(
        subsystem: "dev.serikayuzuki.fuminiwa",
        category: "note-sync"
    )
    private static let libraryLogger = Logger(
        subsystem: "dev.serikayuzuki.fuminiwa",
        category: "cloud-library"
    )
    private static let snapshotLogger = Logger(
        subsystem: "dev.serikayuzuki.fuminiwa",
        category: "snapshot-sync"
    )
    private static let fileQueue = DispatchQueue(
        label: "dev.serikayuzuki.fuminiwa.snapshot-sync-log"
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
        errorToken(error)
    }

    /// Keeps sync diagnostics actionable without logging request bodies,
    /// credentials, document text, or filesystem URLs.
    static func errorToken(_ error: any Error) -> String {
        switch error {
        case let error as LocalStoreError:
            switch error {
            case let .openFailed(message): "LocalStoreError.openFailed(\(message))"
            case let .migrationFailed(message): "LocalStoreError.migrationFailed(\(message))"
            case let .statementFailed(message): "LocalStoreError.statementFailed(\(message))"
            case .invalidIdentity: "LocalStoreError.invalidIdentity"
            case .invalidSnapshot: "LocalStoreError.invalidSnapshot"
            case .objectMismatch: "LocalStoreError.objectMismatch"
            case .missingWork: "LocalStoreError.missingWork"
            case .missingSnapshot: "LocalStoreError.missingSnapshot"
            }
        case let error as SnapshotSyncError:
            switch error {
            case .invalidManifest: "SnapshotSyncError.invalidManifest"
            case let .transport(message): "SnapshotSyncError.transport(\(message.prefix(240)))"
            case .offline: "SnapshotSyncError.offline"
            case .unauthorized: "SnapshotSyncError.unauthorized"
            case .conflict: "SnapshotSyncError.conflict"
            }
        default:
            String(reflecting: type(of: error))
        }
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

    /// Post-cutover SQLite/Rust sync diagnostics. This deliberately records
    /// only event names and typed error tokens; access tokens, document text,
    /// URLs, and request bodies are never written to the log.
    static func snapshot(_ name: String, error: (any Error)? = nil) {
        emit(prefix: "snapshot-sync", name: name, error: error, logger: snapshotLogger)
    }

    static func looksTemporarilyOffline(_ error: any Error) -> Bool {
        if let urlError = error as? URLError {
            return [
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .notConnectedToInternet,
                .timedOut,
                .dnsLookupFailed
            ].contains(urlError.code)
        }
        return false
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
        appendToDebugFile(line)
    }

    private static func appendToDebugFile(_ line: String) {
        guard isDebugEnabled else { return }
        fileQueue.async {
            do {
                let directory = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                )[0].appendingPathComponent("FUMINIWA", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let url = directory.appendingPathComponent(
                    "snapshot-sync-debug.log",
                    isDirectory: false
                )
                let data = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                // Logging must never affect editing or local durability.
            }
        }
    }
}
