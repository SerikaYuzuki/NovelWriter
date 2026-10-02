import Foundation

/// A result row retains SQLite's column names independently of SELECT order.
struct SQLiteRow: Sendable {
    private let names: [String]
    private let values: [SQLiteValue]

    init(names: [String], values: [SQLiteValue]) {
        self.names = names
        self.values = values
    }

    func value(named name: String) throws -> SQLiteValue {
        guard let index = names.firstIndex(of: name), index < values.count,
              names.lastIndex(of: name) == index else {
            throw SyncV2StoreError.sqlite("missing or ambiguous column: \(name)")
        }
        return values[index]
    }

    /// Preserve SQL NULL for the existing operation-specific guards and defaults.
    /// Missing columns and incompatible non-NULL storage types are decode errors.
    func text(_ name: String) throws -> String? {
        switch try value(named: name) {
        case .null: return nil
        case let .text(value): return value
        default: throw SyncV2StoreError.sqlite("invalid text column: \(name)")
        }
    }

    func int64(_ name: String) throws -> Int64? {
        switch try value(named: name) {
        case .null: return nil
        case let .int(value): return value
        default: throw SyncV2StoreError.sqlite("invalid integer column: \(name)")
        }
    }

    func blob(_ name: String) throws -> Data? {
        switch try value(named: name) {
        case .null: return nil
        case let .blob(value): return value
        default: throw SyncV2StoreError.sqlite("invalid blob column: \(name)")
        }
    }

    var count: Int {
        values.count
    }

    /// Only ad-hoc single-column SELECTs (COUNT, EXISTS, IDs and other scalars).
    /// Multi-column projections must use SQLiteRowDecodable by column name.
    var scalar: SQLiteValue {
        get throws {
            guard names.count == 1, values.count == 1, let value = values.first else {
                throw SyncV2StoreError.sqlite("expected a single scalar column")
            }
            return value
        }
    }
}

protocol SQLiteRowDecodable: Sendable {
    static var columns: String { get }
    init(_ row: SQLiteRow) throws
}

extension SQLiteRowDecodable {
    static func qualifiedColumns(_ qualifier: String) -> String {
        columns.split(separator: ",").map {
            qualifier + "." + $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.joined(separator: ",")
    }
}
