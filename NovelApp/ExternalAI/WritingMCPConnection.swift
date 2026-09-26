#if os(macOS)
import Foundation
import Network

/// One bounded HTTP message per loopback connection. No cookies, redirects, uploads or SSE.
@MainActor
final class WritingMCPConnection {
    private let connection: NWConnection
    private let port: UInt16
    private let authorize: (String) -> UUID?
    private let handle: (Data, UUID) async -> Data?
    private let finished: () -> Void
    private var bytes = Data()
    private var timeout: Task<Void, Never>?
    private var processing: Task<Void, Never>?
    private var closed = false
    init(connection: NWConnection, port: UInt16, authorize: @escaping (String) -> UUID?,
         handle: @escaping (Data, UUID) async -> Data?, finished: @escaping () -> Void) {
        self.connection = connection; self.port = port; self.authorize = authorize; self.handle = handle; self.finished = finished
    }

    func start() {
        connection.start(queue: .main)
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.cancel()
        }
        receive()
    }

    func cancel() {
        guard !closed else { return }; closed = true
        timeout?.cancel(); processing?.cancel(); connection.cancel(); finished()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data {
                    self.bytes.append(data)
                }
                guard self.bytes.count <= 2_100_000 else { self.send(status: 413); return }
                if self.parse() {
                    return
                }
                if complete || error != nil {
                    self.cancel()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func parse() -> Bool {
        guard let range = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if bytes.count > 16384 {
                send(status: 431); return true
            }; return false
        }
        guard range.lowerBound < 16384, let header = String(data: bytes[..<range.lowerBound], encoding: .utf8) else { send(status: 400); return true }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { send(status: 400); return true }
        let request = first.split(separator: " ")
        guard request.count == 3, request[1] == "/mcp", request[2] == "HTTP/1.1" else { send(status: 404); return true }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { send(status: 400); return true }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { send(status: 400); return true }
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == "127.0.0.1:\(port)", headers["transfer-encoding"] == nil,
              headers["origin"] == nil || headers["origin"] == "http://127.0.0.1:\(port)" else { send(status: 403); return true }
        guard let bearer = headers["authorization"], bearer.hasPrefix("Bearer "),
              let client = authorize(String(bearer.dropFirst(7))) else { send(status: 401); return true }
        guard request[0] == "POST" else { send(status: 405); return true }
        guard headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json",
              let rawLength = headers["content-length"], let count = Int(rawLength), count > 0,
              count <= 2_000_000 else { send(status: 400); return true }
        let version = headers["mcp-protocol-version"] ?? "2025-03-26"
        guard ["2025-03-26", "2025-06-18", "2025-11-25"].contains(version) else { send(status: 400); return true }
        let offset = range.upperBound
        guard bytes.count >= offset + count else { return false }
        guard bytes.count == offset + count else { send(status: 400); return true }
        let body = Data(bytes[offset...])
        processing = Task { @MainActor in
            let result = await handle(body, client)
            guard !Task.isCancelled, !closed else { return }
            send(status: result == nil ? 202 : 200, body: result ?? Data())
        }
        return true
    }

    private func send(status: Int, body: Data = Data()) {
        guard !closed else { return }
        let phrase = status == 200 ? "OK" : status == 202 ? "Accepted" : "Rejected"
        var output = Data("HTTP/1.1 \(status) \(phrase)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
            .utf8)
        output.append(body)
        connection.send(content: output, completion: .contentProcessed { [weak self] _ in Task { @MainActor in self?.cancel() } })
    }
}
#endif
