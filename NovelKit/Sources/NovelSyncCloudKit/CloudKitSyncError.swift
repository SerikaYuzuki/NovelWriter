import CloudKit
import Foundation

public enum CloudKitAccountProblem: String, Equatable, Sendable {
    case noAccount
    case restricted
    case couldNotDetermine
    case temporarilyUnavailable
}

public enum CloudKitPartialFailureKind: String, Equatable, Hashable, Sendable {
    case serverRecordChanged
    case unknownItem
    case zoneUnavailable
    case zoneReset
    case accountUnavailable
    case temporarilyUnavailable
    case permissionFailure
    case quotaExceeded
    case invalidArguments
    case other
}

/// CloudKitの具象errorやrecordを公開せず、App層が安全に表示できる分類だけを返す。
public enum CloudKitSyncAdapterError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidRestoredEngineState
    case unsafeAssetRoot
    case accountUnavailable(CloudKitAccountProblem)
    case temporarilyUnavailable(retryAfterSeconds: Double?)
    case serverRecordChanged
    case partialFailure(Set<CloudKitPartialFailureKind>)
    case recordNotFound
    case workNotFound
    case zoneUnavailable
    case zoneReset
    case permissionFailure
    case quotaExceeded
    case invalidArguments
    case invalidRemoteRecord
    case invalidRemoteAsset
    case unsupportedSchemaVersion(Int64)
    case operationFailed
}

enum CloudKitErrorMapper {
    static func map(_ error: any Error) -> CloudKitSyncAdapterError {
        guard let cloudError = cloudError(from: error) else {
            return .operationFailed
        }

        switch cloudError.code {
        case .notAuthenticated:
            return .accountUnavailable(.noAccount)
        case .accountTemporarilyUnavailable:
            return .accountUnavailable(.temporarilyUnavailable)
        case .networkFailure, .networkUnavailable, .requestRateLimited, .serviceUnavailable, .zoneBusy:
            return .temporarilyUnavailable(retryAfterSeconds: cloudError.retryAfterSeconds)
        case .serverRecordChanged:
            return .serverRecordChanged
        case .unknownItem:
            return .recordNotFound
        case .zoneNotFound:
            return .zoneUnavailable
        case .userDeletedZone:
            return .zoneReset
        case .permissionFailure:
            return .permissionFailure
        case .quotaExceeded:
            return .quotaExceeded
        case .invalidArguments, .constraintViolation, .serverRejectedRequest:
            return .invalidArguments
        case .partialFailure:
            let failures = partialFailureKinds(from: cloudError)
            return .partialFailure(failures.isEmpty ? [.other] : failures)
        default:
            return .operationFailed
        }
    }

    static func containsServerRecordChanged(_ error: any Error) -> Bool {
        switch map(error) {
        case .serverRecordChanged:
            true
        case let .partialFailure(kinds):
            kinds.contains(.serverRecordChanged)
        default:
            false
        }
    }

    static func isUnknownItem(_ error: any Error) -> Bool {
        switch map(error) {
        case .recordNotFound:
            true
        case let .partialFailure(kinds):
            kinds == [.unknownItem]
        default:
            false
        }
    }

    static func isZoneMissing(_ error: any Error) -> Bool {
        switch map(error) {
        case .zoneUnavailable:
            true
        case let .partialFailure(kinds):
            kinds.contains(.zoneUnavailable)
        default:
            false
        }
    }

    static func isZoneReset(_ error: any Error) -> Bool {
        switch map(error) {
        case .zoneReset:
            true
        case let .partialFailure(kinds):
            kinds.contains(.zoneReset)
        default:
            false
        }
    }

    static func isTransient(_ error: any Error) -> Bool {
        switch map(error) {
        case .temporarilyUnavailable, .accountUnavailable(.temporarilyUnavailable):
            true
        case let .partialFailure(kinds):
            !kinds.isEmpty && kinds.allSatisfy { $0 == .temporarilyUnavailable }
        default:
            false
        }
    }

    static func isBatchRequestFailed(_ error: any Error) -> Bool {
        cloudError(from: error)?.code == .batchRequestFailed
    }

    static func failureKind(_ error: any Error) -> CloudKitPartialFailureKind {
        switch map(error) {
        case .serverRecordChanged:
            .serverRecordChanged
        case .recordNotFound:
            .unknownItem
        case .zoneUnavailable:
            .zoneUnavailable
        case .zoneReset:
            .zoneReset
        case .accountUnavailable:
            .accountUnavailable
        case .temporarilyUnavailable:
            .temporarilyUnavailable
        case .permissionFailure:
            .permissionFailure
        case .quotaExceeded:
            .quotaExceeded
        case .invalidArguments:
            .invalidArguments
        case let .partialFailure(kinds):
            kinds.first ?? .other
        default:
            .other
        }
    }

    private static func cloudError(from error: any Error) -> CKError? {
        if let cloudError = error as? CKError {
            return cloudError
        }
        let nsError = error as NSError
        guard nsError.domain == CKErrorDomain,
              let code = CKError.Code(rawValue: nsError.code) else {
            return nil
        }
        return CKError(code, userInfo: nsError.userInfo)
    }

    private static func partialFailureKinds(from error: CKError) -> Set<CloudKitPartialFailureKind> {
        guard let itemErrors = error.partialErrorsByItemID else { return [] }
        return Set(itemErrors.values.map(failureKind))
    }
}
