import Foundation
import NovelAuth
import NovelSyncV2

public struct ProductionLocalRoot: Hashable, Sendable {
    public let url: URL

    package init(baseDirectory: URL) throws {
        let canonicalApplicationSupport = try canonicalProductionBase(
            baseDirectory
        )
        let candidate = canonicalApplicationSupport
            .appendingPathComponent("FUMINIWA", isDirectory: true)
            .appendingPathComponent("SnapshotSyncV2", isDirectory: true)
            .standardizedFileURL
        guard canonicalApplicationSupport.isFileURL,
              isSafeLocalPath(
                  candidate,
                  within: canonicalApplicationSupport
              ) else {
            throw SyncV2ApplicationError.invalidRuntimeMode
        }
        url = candidate
    }
}

private func canonicalProductionBase(_ reported: URL) throws -> URL {
    let standardized = reported.standardizedFileURL
    guard standardized.isFileURL else {
        throw SyncV2ApplicationError.invalidRuntimeMode
    }
    let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
    guard canonical.path == standardized.path ||
        canonical.path == "/private" + standardized.path &&
        (standardized.path == "/var" || standardized.path.hasPrefix("/var/") ||
            standardized.path == "/tmp" || standardized.path.hasPrefix("/tmp/")) else {
        throw SyncV2ApplicationError.invalidRuntimeMode
    }
    return canonical
}

public struct ProductionHTTPSOrigin: Hashable, Sendable {
    public let url: URL

    public init(url: URL) throws {
        guard url.isFileURL == false,
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw SyncV2ApplicationError.invalidRuntimeMode
        }
        self.url = url
    }
}

public struct ProductionRuntimeConfiguration: Sendable {
    public let localRoot: ProductionLocalRoot
    public let origin: ProductionHTTPSOrigin?
    public let vault: (any AuthSessionVault)?
    /// The app composition owns this coordinator. Runtime must reuse it so
    /// UI sign-in/sign-out and remote refresh share one vault operation owner.
    public let authSessionCoordinator: AuthSessionCoordinator?
    public let documentGate: (any SyncV2DocumentGate)?
    public let clientVersion: String
    public let clientPlatform: AuthClientPlatform

    public init(
        origin: ProductionHTTPSOrigin? = nil,
        vault: (any AuthSessionVault)? = nil,
        authSessionCoordinator: AuthSessionCoordinator? = nil,
        documentGate: any SyncV2DocumentGate,
        clientVersion: String,
        clientPlatform: AuthClientPlatform
    ) throws {
        guard clientVersion.range(
            of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"#,
            options: .regularExpression
        ) != nil else { throw SyncV2ApplicationError.invalidRuntimeMode }
        guard let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { throw SyncV2ApplicationError.invalidRuntimeMode }
        localRoot = try ProductionLocalRoot(
            baseDirectory: applicationSupportDirectory
        )
        self.origin = origin
        self.vault = vault
        self.authSessionCoordinator = authSessionCoordinator
        self.documentGate = documentGate
        self.clientVersion = clientVersion
        self.clientPlatform = clientPlatform
    }
}

public struct TestLocalRoot: Hashable, Sendable {
    public let url: URL
    public let runID: UUID

    package init(baseDirectory: URL, runID: UUID) throws {
        let candidate = baseDirectory
            .appendingPathComponent("FUMINIWA-SnapshotSyncV2-Tests")
            .appendingPathComponent(runID.uuidString.lowercased())
            .standardizedFileURL
        guard baseDirectory.isFileURL,
              isSafeLocalPath(candidate, within: baseDirectory) else {
            throw SyncV2ApplicationError.invalidRuntimeMode
        }
        self.runID = runID
        url = candidate
    }
}

public struct TestDefaults: Hashable, Sendable {
    public let suiteName: String

    package init(runID: UUID) {
        suiteName = "jp.fuminiwa.sync-v2.tests.\(runID.uuidString.lowercased())"
    }
}

public struct TestAccount: Hashable, Sendable {
    public let accountID: String
    public let accountFence: String

    public init(accountID: String, accountFence: String) {
        self.accountID = accountID
        self.accountFence = accountFence
    }
}

public actor TestSyncV2Vault {
    private var account: TestAccount?

    public init(account: TestAccount?) {
        self.account = account
    }

    public func currentAccount() -> TestAccount? {
        account
    }

    public func replaceAccount(_ account: TestAccount?) {
        self.account = account
    }
}

public struct TestRuntimeConfiguration: Sendable {
    public let localRoot: TestLocalRoot
    public let defaults: TestDefaults
    public let vault: TestSyncV2Vault
    public let remote: FakeSyncV2RemoteClient

    public init(
        account: TestAccount? = TestAccount(
            accountID: "test-account",
            accountFence: "test-fence"
        ),
        remote: FakeSyncV2RemoteClient = FakeSyncV2RemoteClient()
    ) throws {
        let runID = UUID()
        localRoot = try TestLocalRoot(
            baseDirectory: FileManager.default.temporaryDirectory
                .resolvingSymlinksInPath(),
            runID: runID
        )
        defaults = TestDefaults(runID: runID)
        vault = TestSyncV2Vault(account: account)
        self.remote = remote
    }
}

public struct PreviewRuntimeConfiguration: Hashable, Sendable {
    public init() {}
}

public enum RuntimeMode: Sendable {
    case production(ProductionRuntimeConfiguration)
    case test(TestRuntimeConfiguration)
    case preview(PreviewRuntimeConfiguration)
}

package struct SyncV2RuntimeComposition: Sendable {
    package enum Identity: Sendable {
        case production
        case test
        case preview
    }

    package let identity: Identity
    package let kernel: any SyncV2LocalKernel
    package let planner: any SyncV2CommandPlanner
    package let remote: any SyncV2RemoteClient
    package let gate: any SyncV2DocumentGate
    package let library: any SyncV2LibraryProvider

    package init(
        identity: Identity,
        kernel: any SyncV2LocalKernel,
        planner: any SyncV2CommandPlanner,
        remote: any SyncV2RemoteClient,
        gate: any SyncV2DocumentGate,
        library: any SyncV2LibraryProvider
    ) {
        self.identity = identity
        self.kernel = kernel
        self.planner = planner
        self.remote = remote
        self.gate = gate
        self.library = library
    }
}

private func isSafeLocalPath(_ candidate: URL, within base: URL) -> Bool {
    let standardizedBase = base.standardizedFileURL
    let standardizedCandidate = candidate.standardizedFileURL
    guard standardizedCandidate.path == standardizedBase.path ||
        standardizedCandidate.path.hasPrefix(standardizedBase.path + "/") else {
        return false
    }
    var ancestor = standardizedCandidate
    while true {
        if (try? FileManager.default.destinationOfSymbolicLink(
            atPath: ancestor.path
        )) != nil {
            return false
        }
        if ancestor.path == standardizedBase.path {
            break
        }
        ancestor.deleteLastPathComponent()
    }
    return true
}
