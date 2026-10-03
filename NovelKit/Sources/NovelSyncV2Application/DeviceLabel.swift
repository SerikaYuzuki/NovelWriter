import Foundation

/// Presentation metadata only. Neither defaults nor canonical storage live here.
public enum DeviceLabel {
    public static let defaultsKey = "fuminiwa.deviceLabel"
    public static let unknown = "別の端末"

    public static func validated(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.precomposedStringWithCanonicalMapping
        guard (1 ... 40).contains(normalized.unicodeScalars.count),
              !normalized.unicodeScalars.contains(where: {
                  isControl($0)
              }) else { return nil }
        return normalized
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value <= 0x1F || (0x7F ... 0x9F).contains(value) || value == 0x2028 || value == 0x2029
    }

    public static func setting(_ value: String) -> String {
        let scalars = value.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !isControl($0)
        }
        return String(String.UnicodeScalarView(scalars.prefix(40)))
    }

    public static func current(_ override: String?, defaultLabel: String) -> String {
        validated(override) ?? defaultLabel
    }

    public static func header(_ value: String?) -> String? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return validated(value)?.addingPercentEncoding(withAllowedCharacters: unreserved)
    }
}

public typealias DeviceLabelProvider = @Sendable () async -> String?
