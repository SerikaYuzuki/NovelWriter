import Foundation

enum CaretMotionPolicy {
    static let duration: TimeInterval = 0.09

    static func shouldAnimate(from previous: CGRect?, to next: CGRect, requested: Bool,
                              afterNewline: Bool = false) -> Bool {
        guard requested, let previous else { return false }
        guard abs(previous.height - next.height) < 0.5 else { return false }
        let verticalDistance = next.minY - previous.minY
        // Returnによる1行下への移動だけは、行頭までの距離にかかわらず補間する。
        if afterNewline, verticalDistance > 0.5, verticalDistance <= next.height * 1.5 {
            return true
        }
        // 折返しや遠い位置への移動はその場に配置する。
        return abs(verticalDistance) < 0.5 &&
            abs(previous.minX - next.minX) <= max(next.height * 4, 80)
    }
}
