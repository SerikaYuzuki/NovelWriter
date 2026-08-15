import CloudKit
import Foundation
import NovelSync
import os

/// Console-only CloudKit / Device Sync tokens. Path, WorkID, title, and
/// `localizedDescription` stay out; CKError code and typed cases stay in.
public enum CloudKitSyncDiagnostic {
    private static let logger = Logger(
        subsystem: "dev.serikayuzuki.fuminiwa",
        category: "note-sync"
    )
    public static func token(for error: any Error) -> String {
        var parts: [String] = []
        var current: (any Error)? = error
        for _ in 0 ..< 5 {
            guard let error = current else { break }
            let part = describe(error)
            if parts.last != part {
                parts.append(part)
            }
            current = underlying(error)
        }
        return parts.joined(separator: " <- ")
    }

    public static func log(_ event: String, error: (any Error)? = nil) {
        let line: String = if let error {
            "\(event)(\(token(for: error)))"
        } else {
            event
        }
        print("[FUMINIWA] \(line)")
        logger.error("\(line, privacy: .public)")
    }

    /// Query/schema errors are not offline. Network, account, and missing zone are.
    public static func looksTemporarilyOffline(_ error: any Error) -> Bool {
        switch CloudKitErrorMapper.map(error) {
        case .temporarilyUnavailable, .accountUnavailable, .zoneUnavailable, .zoneReset:
            true
        case let .partialFailure(kinds):
            kinds.contains(.temporarilyUnavailable)
                || kinds.contains(.accountUnavailable)
                || kinds.contains(.zoneUnavailable)
        default:
            false
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let typed = typedToken(error) {
            return typed
        }
        if let cloudError = error as? CKError {
            return ckToken(cloudError)
        }
        let nsError = error as NSError
        if nsError.domain == CKErrorDomain,
           let code = CKError.Code(rawValue: nsError.code) {
            return ckToken(CKError(code))
        }
        return nsToken(nsError)
    }

    private static func typedToken(_ error: any Error) -> String? {
        if let adapter = error as? CloudKitSyncAdapterError {
            return "CloudKitSyncAdapterError.\(adapter)"
        }
        if let services = error as? AppleDeviceSyncServicesError {
            return "AppleDeviceSyncServicesError.\(services)"
        }
        if let transport = error as? EpisodeSyncTransportError {
            return "EpisodeSyncTransportError.\(transport)"
        }
        if let catalog = error as? SyncCatalogError {
            return "SyncCatalogError.\(catalog)"
        }
        if let work = error as? WorkSyncCoordinatorError {
            return "WorkSyncCoordinatorError.\(work)"
        }
        if let note = error as? NoteSyncRecordError {
            return "NoteSyncRecordError.\(note)"
        }
        if let projection = error as? NoteSyncProjectionError {
            return "NoteSyncProjectionError.\(projection)"
        }
        if let reconcile = error as? NoteSyncReconcileError {
            return "NoteSyncReconcileError.\(reconcile)"
        }
        if let state = error as? NoteSyncStateError {
            return "NoteSyncStateError.\(state)"
        }
        return nil
    }

    private static func ckToken(_ error: CKError) -> String {
        let mapped = CloudKitErrorMapper.map(error)
        return "CKError.\(ckCodeName(error.code))(\(error.code.rawValue))->\(mapped)"
    }

    private static func nsToken(_ error: NSError) -> String {
        let domain = error.domain
        if domain.contains("/") || domain.contains("\\")
            || domain.lowercased().contains("novelpkg") {
            return String(reflecting: type(of: error as any Error))
        }
        if domain == NSCocoaErrorDomain {
            return "NSError.NSCocoaErrorDomain(\(error.code))"
        }
        if domain == NSPOSIXErrorDomain {
            return "NSError.NSPOSIXErrorDomain(\(error.code))"
        }
        if isSafeTokenText(domain) {
            return "NSError.\(domain)(\(error.code))"
        }
        return String(reflecting: type(of: error as any Error))
    }

    private static func underlying(_ error: any Error) -> (any Error)? {
        let nsError = error as NSError
        return nsError.userInfo[NSUnderlyingErrorKey] as? NSError
    }

    private static func isSafeTokenText(_ text: String) -> Bool {
        !text.contains("/") && !text.contains("\\")
            && !text.lowercased().contains("novelpkg")
            && text.utf8.count <= 80
    }

    // CKError.Code names are a fixed lookup table.
    // swiftlint:disable:next cyclomatic_complexity
    private static func ckCodeName(_ code: CKError.Code) -> String {
        switch code {
        case .internalError: "internalError"
        case .partialFailure: "partialFailure"
        case .networkUnavailable: "networkUnavailable"
        case .networkFailure: "networkFailure"
        case .badContainer: "badContainer"
        case .serviceUnavailable: "serviceUnavailable"
        case .requestRateLimited: "requestRateLimited"
        case .missingEntitlement: "missingEntitlement"
        case .notAuthenticated: "notAuthenticated"
        case .permissionFailure: "permissionFailure"
        case .unknownItem: "unknownItem"
        case .invalidArguments: "invalidArguments"
        case .resultsTruncated: "resultsTruncated"
        case .serverRecordChanged: "serverRecordChanged"
        case .serverRejectedRequest: "serverRejectedRequest"
        case .assetFileNotFound: "assetFileNotFound"
        case .assetFileModified: "assetFileModified"
        case .incompatibleVersion: "incompatibleVersion"
        case .constraintViolation: "constraintViolation"
        case .operationCancelled: "operationCancelled"
        case .changeTokenExpired: "changeTokenExpired"
        case .batchRequestFailed: "batchRequestFailed"
        case .zoneBusy: "zoneBusy"
        case .badDatabase: "badDatabase"
        case .quotaExceeded: "quotaExceeded"
        case .zoneNotFound: "zoneNotFound"
        case .limitExceeded: "limitExceeded"
        case .userDeletedZone: "userDeletedZone"
        case .tooManyParticipants: "tooManyParticipants"
        case .alreadyShared: "alreadyShared"
        case .referenceViolation: "referenceViolation"
        case .managedAccountRestricted: "managedAccountRestricted"
        case .participantMayNeedVerification: "participantMayNeedVerification"
        case .serverResponseLost: "serverResponseLost"
        case .assetNotAvailable: "assetNotAvailable"
        case .accountTemporarilyUnavailable: "accountTemporarilyUnavailable"
        default: "code\(code.rawValue)"
        }
    }
}
