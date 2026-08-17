import Foundation

enum DocumentURLPolicy {
    static func urlsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.path
        let right = rhs.standardizedFileURL.path
        return left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }
}
