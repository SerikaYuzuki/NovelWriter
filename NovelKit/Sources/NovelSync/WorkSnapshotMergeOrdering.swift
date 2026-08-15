import Foundation

/// Stable-ID ordering primitives used by the whole-work merger.
/// Keeping the graph and anchor rules together makes the deterministic order
/// policy auditable without mixing it into field conflict resolution.
struct WorkOrderConstraints {
    let nodes: Set<WorkStableID>
    private var outgoing: [WorkStableID: Set<WorkStableID>] = [:]

    init(nodes: Set<WorkStableID>) {
        self.nodes = nodes
    }

    mutating func addSequence(_ sequence: [WorkStableID]) {
        addAdjacentEdges(in: sequence) { _, _ in true }
    }

    mutating func addAdjacentEdges(
        in sequence: [WorkStableID],
        where include: (WorkStableID, WorkStableID) -> Bool
    ) {
        for (first, second) in zip(sequence, sequence.dropFirst())
            where include(first, second) {
            addEdge(from: first, to: second)
        }
    }

    func sorted() -> [WorkStableID]? {
        var incoming = Dictionary(uniqueKeysWithValues: nodes.map { ($0, 0) })
        for targets in outgoing.values {
            for target in targets {
                incoming[target, default: 0] += 1
            }
        }
        var ready = incoming.compactMap { $0.value == 0 ? $0.key : nil }
        ready.sort(by: stableIDLessThan)
        var result: [WorkStableID] = []
        result.reserveCapacity(nodes.count)

        while let next = ready.first {
            ready.removeFirst()
            result.append(next)
            for target in (outgoing[next] ?? []).sorted(by: stableIDLessThan) {
                incoming[target, default: 0] -= 1
                if incoming[target] == 0 {
                    ready.append(target)
                    ready.sort(by: stableIDLessThan)
                }
            }
        }
        return result.count == nodes.count ? result : nil
    }

    private mutating func addEdge(from first: WorkStableID, to second: WorkStableID) {
        guard first != second, nodes.contains(first), nodes.contains(second) else { return }
        outgoing[first, default: []].insert(second)
    }
}

func insertMissingAnchored(
    from source: [WorkStableID],
    into result: inout [WorkStableID]
) {
    for (sourceIndex, id) in source.enumerated() where !result.contains(id) {
        let previous = source[..<sourceIndex].last(where: result.contains)
        let next = source[source.index(after: sourceIndex)...].first(where: result.contains)
        switch (previous, next) {
        case let (previous?, next?):
            guard let previousIndex = result.firstIndex(of: previous),
                  let nextIndex = result.firstIndex(of: next) else { continue }
            if previousIndex < nextIndex {
                result.insert(id, at: nextIndex)
            } else {
                result.insert(id, at: result.index(after: previousIndex))
            }
        case let (previous?, nil):
            guard let previousIndex = result.firstIndex(of: previous) else { continue }
            result.insert(id, at: result.index(after: previousIndex))
        case let (nil, next?):
            guard let nextIndex = result.firstIndex(of: next) else { continue }
            result.insert(id, at: nextIndex)
        case (nil, nil):
            result.append(id)
        }
    }
}

func stableIDLessThan(_ lhs: WorkStableID, _ rhs: WorkStableID) -> Bool {
    lhs.rawValue.uuidString < rhs.rawValue.uuidString
}

extension Set<WorkStableID> {
    func sortedByUUIDString() -> [WorkStableID] {
        sorted(by: stableIDLessThan)
    }
}
