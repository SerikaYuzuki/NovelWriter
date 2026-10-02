#if os(macOS)
import Foundation

/// Shared by the socket adapter and network-free tests. Authentication precedes protocol dispatch.
enum WritingMCPHTTPRequest {
    enum Parsed {
        case incomplete
        case rejected(WritingMCPFailure)
        case accepted(Data, UUID, WritingMCPVersion)
    }

    static func parse(_ bytes: Data, port: UInt16, authorize: (String) -> UUID?) -> Parsed {
        func reject(_ status: Int) -> Parsed {
            .rejected(.init(status: status, body: Data()))
        }
        guard bytes.count <= 2_100_000 else { return reject(413) }
        guard let range = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            return bytes.count > 16384 ? reject(431) : .incomplete
        }
        guard range.lowerBound < 16384,
              let header = String(data: bytes[..<range.lowerBound], encoding: .utf8) else { return reject(400) }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { return reject(400) }
        let request = first.split(separator: " ")
        guard request.count == 3, request[1] == "/mcp", request[2] == "HTTP/1.1" else { return reject(404) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "),
                  !line.hasPrefix("\t") else { return reject(400) }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { return reject(400) }
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil,
              headers["origin"] == nil || headers["origin"] == "http://127.0.0.1:\(port)" else { return reject(403) }
        guard let bearer = headers["authorization"], bearer.hasPrefix("Bearer "),
              let client = authorize(String(bearer.dropFirst(7))) else { return reject(401) }
        guard request[0] == "POST" else { return reject(405) }
        guard headers["content-type"]?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces) == "application/json",
            let rawLength = headers["content-length"], let count = Int(rawLength), count > 0,
            count <= 2_000_000 else { return reject(400) }
        let offset = range.upperBound
        guard bytes.count >= offset + count else { return .incomplete }
        guard bytes.count == offset + count else { return reject(400) }
        let body = Data(bytes[offset...])
        switch WritingMCPVersion.resolveHTTP(body, headers: headers) {
        case let .success(version): return .accepted(body, client, version)
        case let .failure(failure): return .rejected(failure)
        }
    }
}
#endif
