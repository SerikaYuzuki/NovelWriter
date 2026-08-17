import Foundation

public struct ProductionRoot: Hashable, Sendable {
    public let url: URL

    public init(url: URL) throws {
        guard url.isFileURL == false,
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            throw SyncV2ApplicationError.invalidRuntimeMode
        }
        self.url = url
    }
}

public struct TestRoot: Hashable, Sendable {
    public let url: URL

    public init(url: URL) throws {
        guard url.isFileURL,
              !FileManager.default.fileExists(atPath: url.path, isDirectory: nil) ||
              url.resolvingSymlinksInPath().path == url.path else {
            throw SyncV2ApplicationError.invalidRuntimeMode
        }
        self.url = url
    }
}

public struct ProductionVault: Sendable {
    public init() {}
}

public struct TestVault: Sendable {
    public init() {}
}

public struct TestDefaults: Sendable {
    public init() {}
}

public struct TestAccount: Hashable, Sendable {
    public let accountID: String
    public let accountFence: String

    public init(accountID: String, accountFence: String) {
        self.accountID = accountID
        self.accountFence = accountFence
    }
}

public actor FakeTransport: SyncV2Transport {
    public enum Behavior: Sendable {
        case response(SyncV2TransportResponse)
        case offline
        case lostAcknowledgement
    }

    private var behavior: Behavior = .offline
    private var requests: [SyncV2TransportRequest] = []

    public init() {}

    public func setBehavior(_ behavior: Behavior) {
        self.behavior = behavior
    }

    public func recordedRequests() -> [SyncV2TransportRequest] {
        requests
    }

    public func send(_ request: SyncV2TransportRequest) async throws -> SyncV2TransportResponse {
        requests.append(request)
        switch behavior {
        case let .response(response):
            return response
        case .offline:
            throw SyncV2ApplicationError.transport("offline")
        case .lostAcknowledgement:
            throw SyncV2ApplicationError.transport("lostAcknowledgement")
        }
    }
}

public struct ProductionDependencies: Sendable {
    public let root: ProductionRoot
    public let transport: any SyncV2Transport
    public let vault: ProductionVault
    public let kernel: any SyncV2LocalKernel

    public init(
        root: ProductionRoot,
        transport: any SyncV2Transport,
        vault: ProductionVault,
        kernel: any SyncV2LocalKernel
    ) {
        self.root = root
        self.transport = transport
        self.vault = vault
        self.kernel = kernel
    }
}

public struct TestDependencies: Sendable {
    public let root: TestRoot
    public let transport: FakeTransport
    public let vault: TestVault
    public let defaults: TestDefaults
    public let account: TestAccount
    public let kernel: any SyncV2LocalKernel

    public init(
        root: TestRoot,
        transport: FakeTransport,
        vault: TestVault,
        defaults: TestDefaults,
        account: TestAccount,
        kernel: any SyncV2LocalKernel
    ) {
        self.root = root
        self.transport = transport
        self.vault = vault
        self.defaults = defaults
        self.account = account
        self.kernel = kernel
    }
}

public struct PreviewDependencies: Sendable {
    public init() {}
}

public enum RuntimeMode: Sendable {
    case production(ProductionDependencies)
    case test(TestDependencies)
    case preview(PreviewDependencies)
}
