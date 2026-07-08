import SwiftUI

/// `#RRGGBB` 形式の色文字列を扱う小さなユーティリティ。
public enum ColorHex {
    public static func components(from hex: String) -> ColorHexComponents? {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else { return nil }

        return ColorHexComponents(
            red: (value >> 16) & 0xFF,
            green: (value >> 8) & 0xFF,
            blue: value & 0xFF
        )
    }

    public static func string(red: Int, green: Int, blue: Int) -> String? {
        guard (0 ... 255).contains(red), (0 ... 255).contains(green), (0 ... 255).contains(blue) else {
            return nil
        }

        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

public struct ColorHexComponents: Equatable, Sendable {
    public var red: Int
    public var green: Int
    public var blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public extension Color {
    init?(hex: String) {
        guard let components = ColorHex.components(from: hex) else { return nil }
        self.init(
            red: Double(components.red) / 255.0,
            green: Double(components.green) / 255.0,
            blue: Double(components.blue) / 255.0
        )
    }
}
