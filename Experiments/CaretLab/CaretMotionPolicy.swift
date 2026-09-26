import Foundation

enum CaretMotionPolicy {
    static let duration: TimeInterval = 0.09

    static func shouldAnimate(from previous: CGRect?, to next: CGRect, requested: Bool) -> Bool {
        guard requested, let previous else { return false }
        // 改行、折返し、遠い位置への移動はその場に配置する。
        return abs(previous.minY - next.minY) < 0.5 &&
            abs(previous.height - next.height) < 0.5 &&
            abs(previous.minX - next.minX) <= max(next.height * 4, 80)
    }
}
