import Foundation

/// Timeout bounds a broken test; successful assertions wait for state, never a fixed delay.
@MainActor
func waitForWorkSearchState(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while !predicate() {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw WorkSearchStateTimeout.notCompleted }
        await Task.yield()
    }
}

private enum WorkSearchStateTimeout: Error { case notCompleted }
