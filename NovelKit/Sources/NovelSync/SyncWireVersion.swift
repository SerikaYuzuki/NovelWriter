import Foundation

public enum SyncWireProtocol {
    public static let currentVersion = 1
}

/// Sync wire上のtimestampはUTC・秒精度のRFC 3339文字列だけを正とする。
/// clockはhead勝敗へ使わず、表示・監査・lease UXにだけ使う。
func encodeCanonicalSyncTimestamp<Key: CodingKey>(
    _ date: Date,
    forKey key: Key,
    in container: inout KeyedEncodingContainer<Key>
) throws {
    try container.encode(canonicalSyncTimestampString(date), forKey: key)
}

func decodeCanonicalSyncTimestamp<Key: CodingKey>(
    forKey key: Key,
    in container: KeyedDecodingContainer<Key>
) throws -> Date {
    let value = try container.decode(String.self, forKey: key)
    let formatter = syncTimestampFormatter()
    guard let parsed = formatter.date(from: value),
          formatter.string(from: parsed) == value else {
        throw DecodingError.dataCorruptedError(
            forKey: key,
            in: container,
            debugDescription: "timestamp must be canonical RFC 3339 UTC whole seconds"
        )
    }
    return parsed
}

private func canonicalSyncTimestampString(_ date: Date) -> String {
    syncTimestampFormatter().string(from: normalizedSyncTimestamp(date))
}

private func syncTimestampFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}

public enum SyncWireError: Error, Equatable, Sendable {
    case unsupportedProtocolVersion(Int)
}

func requireCurrentSyncWireVersion<Key: CodingKey>(
    forKey key: Key,
    in container: KeyedDecodingContainer<Key>
) throws {
    let version = try container.decode(Int.self, forKey: key)
    guard version == SyncWireProtocol.currentVersion else {
        throw SyncWireError.unsupportedProtocolVersion(version)
    }
}
