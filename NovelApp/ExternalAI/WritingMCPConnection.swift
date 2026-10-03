#if os(macOS)
import Foundation
import Network

/// One bounded HTTP message per loopback connection. No cookies, redirects, uploads or SSE.
@MainActor
final class WritingMCPConnection {
    private let connection: NWConnection
    private let port: UInt16
    private let authorize: (String) -> UUID?
    private let handle: (Data, UUID, WritingMCPVersion) async -> Data?
    private let finished: () -> Void
    private var bytes = Data()
    private var timeout: Task<Void, Never>?
    private var processing: Task<Void, Never>?
    private var closed = false
    init(connection: NWConnection, port: UInt16, authorize: @escaping (String) -> UUID?,
         handle: @escaping (Data, UUID, WritingMCPVersion) async -> Data?, finished: @escaping () -> Void) {
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
                guard self.bytes.count <= WritingMCPHTTPRequest.maximumMessageBytes else { self.send(status: 413); return }
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
        switch WritingMCPHTTPRequest.parse(bytes, port: port, authorize: authorize) {
        case .incomplete: return false
        case let .rejected(failure): send(status: failure.status, body: failure.body)
        case let .accepted(body, client, version):
            processing = Task { @MainActor in
                let result = await handle(body, client, version)
                guard !Task.isCancelled, !closed else { return }
                send(status: version.status(for: result), body: result ?? Data())
            }
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
