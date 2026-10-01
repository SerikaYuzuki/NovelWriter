import Foundation
import NovelAuth
import NovelSyncV2Application

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One import's refreshed credentials; never shared with another account or import.
actor SnapshotDownloadContext {
    @TaskLocal static var current: SnapshotDownloadContext?
    var session: FuminiwaSession
    let backgroundBackfill: Bool

    init(session: FuminiwaSession, backgroundBackfill: Bool = false) {
        self.backgroundBackfill = backgroundBackfill
        self.session = session
    }

    func update(_ value: FuminiwaSession) {
        // A slower concurrent 200 response can finish after another read's
        // refresh. It must not roll credentials back to the older generation.
        guard value.binding == session.binding,
              value.refreshGeneration >= session.refreshGeneration else { return }
        session = value
    }

    func session(matching original: FuminiwaSession) throws -> FuminiwaSession {
        guard session.binding == original.binding else { throw SyncV2Failure.accountFenceChanged }
        return session
    }
}

extension ProductionSyncV2RemoteClient {
    /// Retry only the failed read, retaining pages, cursor and verified objects.
    func requestSnapshotData(
        _ request: URLRequest,
        session: FuminiwaSession,
        allowMissingEndpoint: Bool = false,
        allowTotalsFallback: Bool = false
    ) async throws -> (Data, URLResponse) {
        guard request.httpMethod == "GET" else { throw SyncV2Failure.fatal(.unexpected) }
        var current = await SnapshotDownloadContext.current?.session ?? session
        for attempt in 0 ..< 6 {
            try Task.checkCancellation()
            var retryAfter: TimeInterval?
            do {
                var request = request
                request.timeoutInterval = 30
                if SnapshotDownloadContext.current?.backgroundBackfill == true {
                    request.allowsConstrainedNetworkAccess = false
                    request.allowsExpensiveNetworkAccess = false
                }
                request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
                let (data, response, refreshed) = try await requestDataWithSession(request, session: current)
                current = refreshed
                await SnapshotDownloadContext.current?.update(refreshed)
                guard let http = response as? HTTPURLResponse else {
                    throw SyncV2Failure.retryable(.lostResponse)
                }
                retryAfter = Self.downloadRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
                guard http.statusCode == 200 ||
                    (allowMissingEndpoint && [404, 405].contains(http.statusCode)) ||
                    (allowTotalsFallback && [400, 422].contains(http.statusCode)) else {
                    if http.statusCode == 429 {
                        throw SyncV2Failure.retryable(.rateLimited)
                    }
                    throw mapStatus(http.statusCode)
                }
                return (data, response)
            } catch {
                try Task.checkCancellation()
                guard attempt < 5,
                      let failure = error as? SyncV2Failure,
                      failure == .retryable(.lostResponse) || failure == .retryable(.serverUnavailable) else {
                    throw error
                }
                let backoff = pow(2.0, Double(attempt)) * Double.random(in: 0.8 ... 1.2)
                try await Task.sleep(for: .seconds(max(backoff, retryAfter ?? 0)))
            }
        }
        throw SyncV2Failure.retryable(.serverUnavailable)
    }

    static func downloadRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite {
            return min(30, max(0, seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { min(30, max(0, $0.timeIntervalSince(now))) }
    }
}
