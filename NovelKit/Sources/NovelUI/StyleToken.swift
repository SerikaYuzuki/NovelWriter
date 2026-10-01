import SwiftUI

/// Compatibility names for existing flag views. Colors have one owner in Theme.
public enum StyleToken {
    public static var warning: Color {
        FuminiwaColor.warning.color
    }

    public static var success: Color {
        FuminiwaColor.leaf.color
    }
}
