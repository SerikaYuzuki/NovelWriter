import Foundation
import CryptoKit
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ProductionSyncV2RemoteClient {
    /// The temporary URL is owned by this scope, including HTTP/auth failures.
    func downloadObjectFile(_ original: URLRequest, entry: SnapshotEntry,
                            session originalSession: FuminiwaSession) async throws -> Data {
        var current = originalSession
        for attempt in 0..<6 {
            try Task.checkCancellation()
            var retryAfter: TimeInterval?
            do {
                if let context = SnapshotDownloadContext.current {
                    current = try await context.session(matching: current)
                }
                for authAttempt in 0..<2 {
                    var request = original
                    request.timeoutInterval = 30
                    request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
                    let (url, response) = try await performFileRequest(request)
                    defer { try? FileManager.default.removeItem(at: url) }
                    guard let http = response as? HTTPURLResponse else {
                        throw SyncV2Failure.retryable(.lostResponse)
                    }
                    if http.statusCode == 401, authAttempt == 0 {
                        let refreshed: FuminiwaSession
                        do { refreshed = try await sessionProvider.refresh(afterUnauthorizedFor: current) }
                        catch let failure as SyncV2Failure { throw failure }
                        catch { throw SyncV2Failure.authenticationRequired }
                        guard refreshed.binding == current.binding, refreshed.syncProtocolEpoch == 2,
                              refreshed.refreshGeneration > current.refreshGeneration else {
                            throw SyncV2Failure.accountFenceChanged
                        }
                        current = refreshed
                        await SnapshotDownloadContext.current?.update(refreshed)
                        continue
                    }
                    retryAfter = Self.downloadRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
                    guard http.statusCode == 200 else {
                        if http.statusCode == 429 { throw SyncV2Failure.retryable(.rateLimited) }
                        throw mapStatus(http.statusCode)
                    }
                    return try await Self.validateObjectFile(url, response: response, entry: entry)
                }
                throw SyncV2Failure.authenticationRequired
            } catch {
                try Task.checkCancellation()
                guard attempt < 5, let failure = error as? SyncV2Failure,
                      failure == .retryable(.lostResponse) || failure == .retryable(.serverUnavailable) else { throw error }
                try await Task.sleep(for: .seconds(max(pow(2, Double(attempt)) * Double.random(in: 0.8...1.2), retryAfter ?? 0)))
            }
        }
        throw SyncV2Failure.retryable(.serverUnavailable)
    }

    private func performFileRequest(_ request: URLRequest) async throws -> (URL, URLResponse) {
        do {
            return try await session.download(for: request, delegate: ImportByteProgress(progress: ImportProgress.current))
        } catch {
            try Task.checkCancellation()
            if (error as NSError).domain == NSURLErrorDomain,
               (error as NSError).code == NSURLErrorNotConnectedToInternet { throw SyncV2Failure.offline }
            throw SyncV2Failure.retryable(.lostResponse)
        }
    }

    nonisolated static func validateObjectFile(_ url: URL, response: URLResponse, entry: SnapshotEntry) async throws -> Data {
        try validateObjectHeaders(response, entry: entry)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var count = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            count += chunk.count
            guard count <= entry.byteCount else { throw SyncV2Failure.quarantined(.invalidRemoteData) }
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == entry.byteCount, digest == entry.objectId.rawValue else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        try Task.checkCancellation()
        // Existing graph API owns Data. Mapping avoids another full heap copy;
        // the mapping survives unlinking the temporary file by the caller.
        return try Data(contentsOf: url, options: .alwaysMapped)
    }

    nonisolated static func validateObjectHeaders(_ response: URLResponse, entry: SnapshotEntry) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              http.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache",
              httpContentType(response) == "application/octet-stream",
              http.value(forHTTPHeaderField: "X-Fuminiwa-Object-Digest") == entry.objectId.rawValue,
              Int(http.value(forHTTPHeaderField: "X-Fuminiwa-Byte-Count") ?? "") == entry.byteCount else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
    }
}
