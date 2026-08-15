import Foundation

enum PortableScalarDiff {
    static let maximumEditDistance = 1024
    static let maximumWork = 16_000_000

    struct Edit: Equatable {
        let range: Range<Int>
        let replacement: [Unicode.Scalar]
    }

    private enum Token {
        case equal(Int)
        case delete
        case insert(Unicode.Scalar)
    }

    private struct TraceRow {
        let lowerK: Int
        let values: [Int]

        func furthestBaseIndex(for diagonal: Int) -> Int {
            values[diagonal - lowerK]
        }
    }

    static func edits(
        base: [Unicode.Scalar],
        variant: [Unicode.Scalar]
    ) -> [Edit]? {
        let bounds = changedBounds(base: base, variant: variant)
        guard bounds.baseCount > 0 || bounds.variantCount > 0 else { return [] }
        guard let tokens = shortestEditTokens(
            base: base,
            variant: variant,
            bounds: bounds
        ) else { return nil }
        return makeEdits(tokens: tokens, baseOffset: bounds.prefix)
    }

    private struct ChangedBounds {
        let prefix: Int
        let baseCount: Int
        let variantCount: Int
    }

    private static func changedBounds(
        base: [Unicode.Scalar],
        variant: [Unicode.Scalar]
    ) -> ChangedBounds {
        var prefix = 0
        let commonLimit = min(base.count, variant.count)
        while prefix < commonLimit, base[prefix] == variant[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < base.count - prefix,
              suffix < variant.count - prefix,
              base[base.count - suffix - 1] == variant[variant.count - suffix - 1] {
            suffix += 1
        }
        return ChangedBounds(
            prefix: prefix,
            baseCount: base.count - prefix - suffix,
            variantCount: variant.count - prefix - suffix
        )
    }

    private static func shortestEditTokens(
        base: [Unicode.Scalar],
        variant: [Unicode.Scalar],
        bounds: ChangedBounds
    ) -> [Token]? {
        let maximumDistance = min(
            bounds.baseCount + bounds.variantCount,
            maximumEditDistance
        )
        let offset = maximumDistance + 1
        var furthestX = [Int](repeating: 0, count: maximumDistance * 2 + 3)
        furthestX[offset + 1] = 0
        var trace: [TraceRow] = []
        var work = 0

        for distance in 0 ... maximumDistance {
            let lowerK = -distance - 1
            let upperK = distance + 1
            trace.append(
                TraceRow(
                    lowerK: lowerK,
                    values: Array(furthestX[(offset + lowerK) ... (offset + upperK)])
                )
            )
            for diagonal in stride(from: -distance, through: distance, by: 2) {
                work += 1
                guard work <= maximumWork else { return nil }
                let index = offset + diagonal
                var baseCursor = if diagonal == -distance
                    || (diagonal != distance && furthestX[index - 1] < furthestX[index + 1]) {
                    furthestX[index + 1]
                } else {
                    furthestX[index - 1] + 1
                }
                var variantCursor = baseCursor - diagonal
                while baseCursor < bounds.baseCount,
                      variantCursor < bounds.variantCount,
                      base[bounds.prefix + baseCursor] == variant[bounds.prefix + variantCursor] {
                    baseCursor += 1
                    variantCursor += 1
                    work += 1
                    guard work <= maximumWork else { return nil }
                }
                furthestX[index] = baseCursor
                if baseCursor == bounds.baseCount, variantCursor == bounds.variantCount {
                    return backtrack(
                        trace: trace,
                        distance: distance,
                        base: base,
                        variant: variant,
                        bounds: bounds
                    )
                }
            }
        }
        return nil
    }

    private static func backtrack(
        trace: [TraceRow],
        distance: Int,
        base _: [Unicode.Scalar],
        variant: [Unicode.Scalar],
        bounds: ChangedBounds
    ) -> [Token] {
        var baseCursor = bounds.baseCount
        var variantCursor = bounds.variantCount
        var reversed: [Token] = []

        for depth in stride(from: distance, through: 1, by: -1) {
            let row = trace[depth]
            let diagonal = baseCursor - variantCursor
            let previousDiagonal = if diagonal == -depth
                || (diagonal != depth
                    && row.furthestBaseIndex(for: diagonal - 1)
                    < row.furthestBaseIndex(for: diagonal + 1)) {
                diagonal + 1
            } else {
                diagonal - 1
            }
            let previousX = row.furthestBaseIndex(for: previousDiagonal)
            let previousY = previousX - previousDiagonal
            let equalCount = min(baseCursor - previousX, variantCursor - previousY)
            if equalCount > 0 {
                reversed.append(.equal(equalCount))
                baseCursor -= equalCount
                variantCursor -= equalCount
            }
            if baseCursor == previousX {
                variantCursor -= 1
                reversed.append(.insert(variant[bounds.prefix + variantCursor]))
            } else {
                baseCursor -= 1
                reversed.append(.delete)
            }
        }
        if baseCursor > 0, variantCursor > 0 {
            reversed.append(.equal(min(baseCursor, variantCursor)))
        }
        return reversed.reversed()
    }

    private static func makeEdits(tokens: [Token], baseOffset: Int) -> [Edit] {
        var baseIndex = baseOffset
        var start: Int?
        var replacement: [Unicode.Scalar] = []
        var edits: [Edit] = []

        func flush() {
            guard let start else { return }
            edits.append(Edit(range: start ..< baseIndex, replacement: replacement))
        }
        for token in tokens {
            switch token {
            case let .equal(count):
                flush()
                start = nil
                replacement.removeAll(keepingCapacity: true)
                baseIndex += count
            case .delete:
                start = start ?? baseIndex
                baseIndex += 1
            case let .insert(scalar):
                start = start ?? baseIndex
                replacement.append(scalar)
            }
        }
        flush()
        return edits
    }
}
