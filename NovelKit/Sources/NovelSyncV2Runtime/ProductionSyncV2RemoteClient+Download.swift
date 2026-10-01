import Foundation
import NovelAuth
import NovelSyncV2Application

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ProductionSyncV2RemoteClient {
    /// Retry only the failed read, retaining the verified objects already fetched
    /// by this traversal. Never replay mutations or retry validation/scope failures.
    func requestSnapshotData(
        _ request: URLRequest,
        session: FuminiwaSession
    ) async throws -> (Data, URLResponse) {
        guard request.httpMethod == "GET" else {
            throw SyncV2Failure.fatal(.unexpected)
        }
        for attempt in 0 ..< 3 {
            try Task.checkCancellation()
            do {
                let response = try await requestData(request, session: session)
                guard let http = response.1 as? HTTPURLResponse else {
                    throw SyncV2Failure.retryable(.lostResponse)
                }
                guard http.statusCode == 200 else {
                    if http.statusCode == 429 {
                        // Leave server-directed throttling to a later user retry.
                        throw SyncV2Failure.retryable(.rateLimited)
                    }
                    throw mapStatus(http.statusCode)
                }
                return response
            } catch {
                try Task.checkCancellation()
                guard attempt < 2,
                      let failure = error as? SyncV2Failure,
                      failure == .retryable(.lostResponse) || failure == .retryable(.serverUnavailable) else {
                    throw error
                }
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw SyncV2Failure.retryable(.serverUnavailable)
    }
}
