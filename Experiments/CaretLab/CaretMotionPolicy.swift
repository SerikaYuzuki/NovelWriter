import Foundation

enum CaretMotionPolicy {
    static let duration: TimeInterval = 0.09

    static func shouldAnimate(from previous: CGRect?, to next: CGRect, requested: Bool) -> Bool {
        guard requested, let previous else { return false }
        guard abs(previous.height - next.height) < 0.5 else { return false }
        let verticalDistance = abs(next.minY - previous.minY)
        // 改行・削除・上下移動・折返しは、隣の行までなら横の距離にかかわらず補間する。
        if verticalDistance >= 0.5, verticalDistance <= next.height * 1.5 {
            return true
        }
        // 行内の大移動や複数行のジャンプはその場に配置する。
        return verticalDistance < 0.5 &&
            abs(previous.minX - next.minX) <= max(next.height * 4, 80)
    }
}
