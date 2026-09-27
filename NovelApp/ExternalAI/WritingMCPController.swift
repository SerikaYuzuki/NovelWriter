#if os(macOS)
import CryptoKit
import Foundation
import Network
import NovelCore
import NovelWritingSupport
import Observation
import Security

struct WritingMCPClient: Codable, Identifiable {
    let id: UUID
    let name: String
    let digest: String
}

@MainActor @Observable
final class WritingMCPController {
    private(set) var clients: [WritingMCPClient]
    private(set) var status = "外部AIを登録すると接続を開始できます。"
    private(set) var port: UInt16
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let host: () -> WritingAssistantHost?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [UUID: WritingMCPConnection] = [:]
    @ObservationIgnored private var requests: [UUID: (UUID, Task<Data?, Never>)] = [:]

    init(defaults: UserDefaults, host: @escaping () -> WritingAssistantHost?) {
        self.defaults = defaults; self.host = host
        clients = defaults.data(forKey: "assistant.mcp.clients").flatMap { try? JSONDecoder().decode([WritingMCPClient].self, from: $0) } ?? []
        let saved = defaults.integer(forKey: "assistant.mcp.port")
        port = (1024 ... 65535).contains(saved) ? UInt16(saved) : UInt16.random(in: 49152 ... 65535)
        defaults.set(Int(port), forKey: "assistant.mcp.port")
        if !clients.isEmpty {
            start()
        }
    }

    var endpoint: String {
        "http://127.0.0.1:\(port)/mcp"
    }

    private var allowsCredentials: Bool {
        #if FUMINIWA_TEST_COMPOSITION
        false
        #else
        true
        #endif
    }

    func register(name: String) throws -> WritingMCPClient {
        guard allowsCredentials else { throw WritingError.unavailable }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WritingError.invalidRecord }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WritingError.unavailable }
        let token = Data(bytes).base64EncodedString()
        let client = WritingMCPClient(id: UUID(), name: String(name.prefix(80)), digest: Self.digest(token))
        var query = keyQuery(client.id)
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw WritingError.unavailable }
        clients.append(client); persist(); start(); return client
    }

    func configuration(for client: WritingMCPClient) throws -> String {
        guard allowsCredentials else { throw WritingError.unavailable }
        var query = keyQuery(client.id); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data, let token = String(data: data, encoding: .utf8) else { throw WritingError.unavailable }
        let object: [String: Any] = ["mcpServers": ["fuminiwa": ["type": "http", "url": endpoint, "headers": ["Authorization": "Bearer \(token)"]]]]
        return try String(decoding: JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    func revoke(_ client: WritingMCPClient) throws {
        guard allowsCredentials else { throw WritingError.unavailable }
        let status = SecItemDelete(keyQuery(client.id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WritingError.unavailable }
        clients.removeAll { $0.id == client.id }; persist()
        for (id, task) in requests.values where id == client.id {
            task.cancel()
        }
        if clients.isEmpty {
            stop()
        }
    }

    func start() {
        guard !clients.isEmpty else {
            status = "外部AIを登録すると接続を開始できます。"
            return
        }
        guard listener == nil else { return }
        #if FUMINIWA_TEST_COMPOSITION
        status = "テスト構成では外部接続を開始しません。"
        return
        #else
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.status = "接続受付中（このMacのみ）"
                    case .failed: self.stop(); self.status = "接続を開始できませんでした。再開してください。"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.connections.count < 16 else { connection.cancel(); return }
                    let id = UUID()
                    let client = WritingMCPConnection(connection: connection, port: self.port,
                                                      authorize: { [weak self] token in self?.authorize(token) },
                                                      handle: { [weak self] data, clientID in
                                                          guard let controller = self else { return nil }
                                                          return await controller.dispatch(data, client: clientID)
                                                      }, finished: { [weak self] in self?.connections[id] = nil })
                    self.connections[id] = client; client.start()
                }
            }
            listener.start(queue: .main)
        } catch { status = "接続を開始できませんでした。再開してください。" }
        #endif
    }

    func stop() {
        listener?.cancel(); listener = nil
        for (_, task) in requests.values {
            task.cancel()
        }
        for value in Array(connections.values) {
            value.cancel()
        }
        connections = [:]
        status = clients.isEmpty ? "外部AIを登録すると接続を開始できます。" : "停止中"
    }

    private func authorize(_ token: String) -> UUID? {
        let digest = Array(Self.digest(token).utf8)
        return clients.first { client in
            let expected = Array(client.digest.utf8)
            return expected.count == digest.count && zip(expected, digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }?.id
    }

    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func keyQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.serikayuzuki.fuminiwa.mcp",
         kSecAttrAccount as String: id.uuidString, kSecAttrSynchronizable as String: false]
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(clients), forKey: "assistant.mcp.clients")
    }

    private func dispatch(_ data: Data, client: UUID) async -> Data? {
        guard clients.contains(where: { $0.id == client }) else { return nil }
        let id = UUID()
        let task = Task { @MainActor in await WritingMCPProtocol.respond(data, host: self.host()) }
        requests[id] = (client, task)
        defer { requests[id] = nil }
        return await task.value
    }
}
#endif
