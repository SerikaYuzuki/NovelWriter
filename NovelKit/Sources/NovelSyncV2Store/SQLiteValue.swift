import Foundation
import NovelCore
import NovelSyncV2

enum SQLiteValue: Sendable {
    case null
    case text(String)
    case blob(Data)
    case int(Int64)

    var text: String? {
        if case let .text(value) = self {
            return value
        }
        return nil
    }

    var blob: Data? {
        if case let .blob(value) = self {
            return value
        }
        return nil
    }

    var int64: Int64? {
        if case let .int(value) = self {
            return value
        }
        return nil
    }
}

extension V2AccountBinding {
    var values: [SQLiteValue] {
        [
            .text(serverInstanceID), .int(protocolEpoch),
            .text(accountID), .text(accountFence)
        ]
    }
}

extension V2LocalWorkScope {
    var intentPredicateSQL: String {
        switch self {
        case .unbound:
            " AND scope_kind='unbound'"
        case .parked:
            // Parked work is local-only. Its legacy/unbound intent rows are
            // retained as audit evidence but are never actionable.
            " AND 1=0"
        case .bound:
            """
             AND scope_kind='bound' AND server_instance_id=?
             AND protocol_epoch=? AND account_id=? AND account_fence=?
            """
        }
    }

    var intentPredicateValues: [SQLiteValue] {
        switch self {
        case .unbound, .parked: []
        case let .bound(binding): binding.values
        }
    }

    var intentFields: [SQLiteValue] {
        switch self {
        case .unbound, .parked:
            [.text("unbound"), .null, .null, .null, .null]
        case let .bound(binding):
            [.text("bound")] + binding.values
        }
    }
}

extension Data {
    var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(count * 2)
        for byte in self {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    init?(hex: String) {
        let input = Array(hex.utf8)
        guard input.count.isMultiple(of: 2) else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48 ... 57: byte - 48
            case 65 ... 70: byte - 65 + 10
            case 97 ... 102: byte - 97 + 10
            default: nil
            }
        }
        var bytes = Data()
        bytes.reserveCapacity(input.count / 2)
        for index in stride(from: 0, to: input.count, by: 2) {
            guard let high = nibble(input[index]), let low = nibble(input[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        self = bytes
    }
}

extension ObjectID {
    var bytes: Data {
        Data(hex: rawValue)! // Typed IDs already enforce a lowercase SHA-256 digest.
    }
}

extension SnapshotID {
    var bytes: Data {
        Data(hex: rawValue)! // Typed IDs already enforce a lowercase SHA-256 digest.
    }
}

extension EncodedSnapshot {
    var snapshotIDBytes: Data {
        snapshotId.bytes
    }
}
