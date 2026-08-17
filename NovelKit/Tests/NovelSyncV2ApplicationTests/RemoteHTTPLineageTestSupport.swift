import Foundation
import NovelCore
import NovelSyncV2

struct LineageHTTPReply: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

final class LineageHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private let replies: [String: LineageHTTPReply]
    private var paths: [String] = []

    init(workID: WorkID, snapshots: [EncodedSnapshot], publishResponse: Data?) {
        replies = Self.makeReplies(
            workID: workID,
            snapshots: snapshots,
            publishResponse: publishResponse
        )
    }

    private static func makeReplies(
        workID: WorkID,
        snapshots: [EncodedSnapshot],
        publishResponse: Data?
    ) -> [String: LineageHTTPReply] {
        var replies: [String: LineageHTTPReply] = [:]
        let headers = [
            "Cache-Control": "no-store",
            "Pragma": "no-cache",
            "Content-Type": "application/vnd.fuminiwa.sync.v2+jcs"
        ]
        if let head = snapshots.last {
            replies["GET /v2/works/\(workID.description)/head"] = LineageHTTPReply(
                status: 200,
                headers: headers,
                body: Data(
                    "{\"head\":{\"generation\":1,\"snapshotId\":\"\(head.snapshotId.rawValue)\"}}".utf8
                )
            )
        }
        for snapshot in snapshots {
            add(snapshot: snapshot, headers: headers, to: &replies)
        }
        if let publishResponse {
            let path = "POST /v2/works/\(workID.description)/publish"
            replies[path] = LineageHTTPReply(
                status: 409,
                headers: headers,
                body: publishResponse
            )
        }
        return replies
    }

    private static func add(
        snapshot: EncodedSnapshot,
        headers: [String: String],
        to replies: inout [String: LineageHTTPReply]
    ) {
        let manifest = snapshot.manifestBytes.base64URLEncodedString()
        let body = [
            "{\"manifestBase64URL\":\"", manifest,
            "\",\"manifestBytesDigest\":\"",
            ObjectID(data: snapshot.manifestBytes).rawValue,
            "\",\"result\":\"noChanges\",\"snapshotId\":\"",
            snapshot.snapshotId.rawValue, "\"}"
        ].joined()
        replies[
            "GET /v2/snapshots/\(snapshot.snapshotId.rawValue)/manifest"
        ] = LineageHTTPReply(
            status: 200,
            headers: headers,
            body: Data(body.utf8)
        )
        for entry in snapshot.manifest.entries {
            replies["GET /v2/objects/\(entry.objectId.rawValue)"] = LineageHTTPReply(
                status: 200,
                headers: [
                    "Cache-Control": "no-store",
                    "Pragma": "no-cache",
                    "Content-Type": "application/octet-stream",
                    "X-Fuminiwa-Object-Digest": entry.objectId.rawValue,
                    "X-Fuminiwa-Byte-Count": String(
                        snapshot.objects[entry.objectId]?.count ?? 0
                    )
                ],
                body: snapshot.objects[entry.objectId] ?? Data()
            )
        }
    }

    func reply(for request: URLRequest) -> LineageHTTPReply? {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        lock.lock()
        paths.append(path)
        lock.unlock()
        return replies["\(method) \(path)"]
    }

    func count(path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return paths.count(where: { $0 == path })
    }
}

class LineageURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var state: LineageHTTPState?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let reply = Self.state?.reply(for: request),
              let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: reply.status,
                  httpVersion: nil,
                  headerFields: reply.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
