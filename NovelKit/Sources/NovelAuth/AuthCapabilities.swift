import Foundation

public struct AuthLimits: Codable, Equatable, Hashable, Sendable {
    public let accessTokenLifetimeSeconds: UInt64
    public let authReceiptLifetimeSeconds: UInt64
    public let challengeLifetimeSeconds: UInt64
    public let maxCanonicalCommandBytes: UInt64
    public let maxProviderClockSkewSeconds: UInt64
    public let refreshTokenLifetimeSeconds: UInt64

    public init(
        accessTokenLifetimeSeconds: UInt64,
        authReceiptLifetimeSeconds: UInt64,
        challengeLifetimeSeconds: UInt64,
        maxCanonicalCommandBytes: UInt64,
        maxProviderClockSkewSeconds: UInt64,
        refreshTokenLifetimeSeconds: UInt64
    ) throws {
        guard (300 ... 3600).contains(accessTokenLifetimeSeconds),
              (86400 ... 31_536_000).contains(authReceiptLifetimeSeconds),
              challengeLifetimeSeconds == 300,
              maxCanonicalCommandBytes == 65536,
              maxProviderClockSkewSeconds <= 300,
              (86400 ... 31_536_000).contains(refreshTokenLifetimeSeconds) else {
            throw AuthError.invalidResponseSemantics
        }
        self.accessTokenLifetimeSeconds = accessTokenLifetimeSeconds
        self.authReceiptLifetimeSeconds = authReceiptLifetimeSeconds
        self.challengeLifetimeSeconds = challengeLifetimeSeconds
        self.maxCanonicalCommandBytes = maxCanonicalCommandBytes
        self.maxProviderClockSkewSeconds = maxProviderClockSkewSeconds
        self.refreshTokenLifetimeSeconds = refreshTokenLifetimeSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AuthLimitsCodingKeys.self)
        try self.init(
            accessTokenLifetimeSeconds: container.decode(UInt64.self, forKey: .accessTokenLifetimeSeconds),
            authReceiptLifetimeSeconds: container.decode(UInt64.self, forKey: .authReceiptLifetimeSeconds),
            challengeLifetimeSeconds: container.decode(UInt64.self, forKey: .challengeLifetimeSeconds),
            maxCanonicalCommandBytes: container.decode(UInt64.self, forKey: .maxCanonicalCommandBytes),
            maxProviderClockSkewSeconds: container.decode(UInt64.self, forKey: .maxProviderClockSkewSeconds),
            refreshTokenLifetimeSeconds: container.decode(UInt64.self, forKey: .refreshTokenLifetimeSeconds)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AuthLimitsCodingKeys.self)
        try container.encode(accessTokenLifetimeSeconds, forKey: .accessTokenLifetimeSeconds)
        try container.encode(authReceiptLifetimeSeconds, forKey: .authReceiptLifetimeSeconds)
        try container.encode(challengeLifetimeSeconds, forKey: .challengeLifetimeSeconds)
        try container.encode(maxCanonicalCommandBytes, forKey: .maxCanonicalCommandBytes)
        try container.encode(maxProviderClockSkewSeconds, forKey: .maxProviderClockSkewSeconds)
        try container.encode(refreshTokenLifetimeSeconds, forKey: .refreshTokenLifetimeSeconds)
    }
}

public struct AuthContentProtection: Codable, Equatable, Hashable, Sendable {
    public let e2ee: Bool
    public let profile: String
    public let serverCanReadContent: Bool
    public let userManagedContentKey: Bool

    public init(e2ee: Bool, profile: String, serverCanReadContent: Bool, userManagedContentKey: Bool) throws {
        guard !e2ee, profile == "serverReadableV1", serverCanReadContent, !userManagedContentKey else {
            throw AuthError.invalidResponseSemantics
        }
        self.e2ee = e2ee
        self.profile = profile
        self.serverCanReadContent = serverCanReadContent
        self.userManagedContentKey = userManagedContentKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AuthContentProtectionCodingKeys.self)
        try self.init(
            e2ee: container.decode(Bool.self, forKey: .e2ee),
            profile: container.decode(String.self, forKey: .profile),
            serverCanReadContent: container.decode(Bool.self, forKey: .serverCanReadContent),
            userManagedContentKey: container.decode(Bool.self, forKey: .userManagedContentKey)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AuthContentProtectionCodingKeys.self)
        try container.encode(e2ee, forKey: .e2ee)
        try container.encode(profile, forKey: .profile)
        try container.encode(serverCanReadContent, forKey: .serverCanReadContent)
        try container.encode(userManagedContentKey, forKey: .userManagedContentKey)
    }
}

public struct AuthNativeAudience: Codable, Equatable, Hashable, Sendable {
    public let audience: String
    public let clientPlatform: AuthClientPlatform

    public init(audience: String, clientPlatform: AuthClientPlatform) {
        self.audience = audience
        self.clientPlatform = clientPlatform
    }
}

public struct AuthAppleNativeProviderCapabilities: Codable, Equatable, Hashable, Sendable {
    public let authorizationEndpoint: String
    public let clientPlatforms: [AuthClientPlatform]
    public let flow: String
    public let issuer: String
    public let jwksEndpoint: String
    public let nativeAudiences: [AuthNativeAudience]
    public let provider: AuthProvider
    public let providerConfigurationID: String
    public let requestedScopes: [String]
    public let tokenEndpoint: String

    public init(
        authorizationEndpoint: String,
        clientPlatforms: [AuthClientPlatform],
        flow: String,
        issuer: String,
        jwksEndpoint: String,
        nativeAudiences: [AuthNativeAudience],
        provider: AuthProvider,
        providerConfigurationID: String,
        requestedScopes: [String],
        tokenEndpoint: String
    ) throws {
        guard authorizationEndpoint == "https://appleid.apple.com/auth/authorize",
              clientPlatforms == [.ios, .ipados, .macos],
              flow == "native",
              issuer == "https://appleid.apple.com",
              jwksEndpoint == "https://appleid.apple.com/auth/keys",
              nativeAudiences == [
                  AuthNativeAudience(audience: "dev.serikayuzuki.fuminiwa", clientPlatform: .macos),
                  AuthNativeAudience(audience: "dev.serikayuzuki.fuminiwa.ios", clientPlatform: .ios),
                  AuthNativeAudience(audience: "dev.serikayuzuki.fuminiwa.ios", clientPlatform: .ipados)
              ],
              provider == .apple,
              providerConfigurationID == "apple-primary-fuminiwa-v1",
              requestedScopes.isEmpty,
              tokenEndpoint == "https://appleid.apple.com/auth/token" else {
            throw AuthError.invalidResponseSemantics
        }
        self.authorizationEndpoint = authorizationEndpoint
        self.clientPlatforms = clientPlatforms
        self.flow = flow
        self.issuer = issuer
        self.jwksEndpoint = jwksEndpoint
        self.nativeAudiences = nativeAudiences
        self.provider = provider
        self.providerConfigurationID = providerConfigurationID
        self.requestedScopes = requestedScopes
        self.tokenEndpoint = tokenEndpoint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AuthAppleProviderCodingKeys.self)
        try self.init(
            authorizationEndpoint: container.decode(String.self, forKey: .authorizationEndpoint),
            clientPlatforms: container.decode([AuthClientPlatform].self, forKey: .clientPlatforms),
            flow: container.decode(String.self, forKey: .flow),
            issuer: container.decode(String.self, forKey: .issuer),
            jwksEndpoint: container.decode(String.self, forKey: .jwksEndpoint),
            nativeAudiences: container.decode([AuthNativeAudience].self, forKey: .nativeAudiences),
            provider: container.decode(AuthProvider.self, forKey: .provider),
            providerConfigurationID: container.decode(String.self, forKey: .providerConfigurationID),
            requestedScopes: container.decode([String].self, forKey: .requestedScopes),
            tokenEndpoint: container.decode(String.self, forKey: .tokenEndpoint)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AuthAppleProviderCodingKeys.self)
        try container.encode(authorizationEndpoint, forKey: .authorizationEndpoint)
        try container.encode(clientPlatforms, forKey: .clientPlatforms)
        try container.encode(flow, forKey: .flow)
        try container.encode(issuer, forKey: .issuer)
        try container.encode(jwksEndpoint, forKey: .jwksEndpoint)
        try container.encode(nativeAudiences, forKey: .nativeAudiences)
        try container.encode(provider, forKey: .provider)
        try container.encode(providerConfigurationID, forKey: .providerConfigurationID)
        try container.encode(requestedScopes, forKey: .requestedScopes)
        try container.encode(tokenEndpoint, forKey: .tokenEndpoint)
    }
}

public struct AuthCapabilities: Codable, Equatable, Hashable, Sendable {
    public let authProtocolEpoch: UInt64
    public let authProtocolNamespace: String
    public let authProtocolVersion: String
    public let canonicalization: String
    public let contentProtection: AuthContentProtection
    public let limits: AuthLimits
    public let minimumClientVersion: String
    public let providers: [AuthAppleNativeProviderCapabilities]
    public let serverInstanceID: UUID
    public let syncProtocolEpoch: UInt64
    public let syncProtocolNamespace: String

    public init(
        authProtocolEpoch: UInt64,
        authProtocolNamespace: String,
        authProtocolVersion: String,
        canonicalization: String,
        contentProtection: AuthContentProtection,
        limits: AuthLimits,
        minimumClientVersion: String,
        providers: [AuthAppleNativeProviderCapabilities],
        serverInstanceID: UUID,
        syncProtocolEpoch: UInt64,
        syncProtocolNamespace: String
    ) throws {
        guard authProtocolEpoch == 1,
              authProtocolNamespace == "com.fuminiwa.auth",
              authProtocolVersion == "1.0.0",
              canonicalization == "rfc8785-jcs",
              Self.isSemanticVersion(minimumClientVersion),
              providers.count == 1,
              syncProtocolEpoch == 2,
              syncProtocolNamespace == "com.fuminiwa.snapshot-sync" else {
            throw AuthError.invalidResponseSemantics
        }
        self.authProtocolEpoch = authProtocolEpoch
        self.authProtocolNamespace = authProtocolNamespace
        self.authProtocolVersion = authProtocolVersion
        self.canonicalization = canonicalization
        self.contentProtection = contentProtection
        self.limits = limits
        self.minimumClientVersion = minimumClientVersion
        self.providers = providers
        self.serverInstanceID = serverInstanceID
        self.syncProtocolEpoch = syncProtocolEpoch
        self.syncProtocolNamespace = syncProtocolNamespace
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AuthCapabilitiesCodingKeys.self)
        try self.init(
            authProtocolEpoch: container.decode(UInt64.self, forKey: .authProtocolEpoch),
            authProtocolNamespace: container.decode(String.self, forKey: .authProtocolNamespace),
            authProtocolVersion: container.decode(String.self, forKey: .authProtocolVersion),
            canonicalization: container.decode(String.self, forKey: .canonicalization),
            contentProtection: container.decode(AuthContentProtection.self, forKey: .contentProtection),
            limits: container.decode(AuthLimits.self, forKey: .limits),
            minimumClientVersion: container.decode(String.self, forKey: .minimumClientVersion),
            providers: container.decode([AuthAppleNativeProviderCapabilities].self, forKey: .providers),
            serverInstanceID: container.decode(UUID.self, forKey: .serverInstanceID),
            syncProtocolEpoch: container.decode(UInt64.self, forKey: .syncProtocolEpoch),
            syncProtocolNamespace: container.decode(String.self, forKey: .syncProtocolNamespace)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AuthCapabilitiesCodingKeys.self)
        try container.encode(authProtocolEpoch, forKey: .authProtocolEpoch)
        try container.encode(authProtocolNamespace, forKey: .authProtocolNamespace)
        try container.encode(authProtocolVersion, forKey: .authProtocolVersion)
        try container.encode(canonicalization, forKey: .canonicalization)
        try container.encode(contentProtection, forKey: .contentProtection)
        try container.encode(limits, forKey: .limits)
        try container.encode(minimumClientVersion, forKey: .minimumClientVersion)
        try container.encode(providers, forKey: .providers)
        try container.encode(serverInstanceID, forKey: .serverInstanceID)
        try container.encode(syncProtocolEpoch, forKey: .syncProtocolEpoch)
        try container.encode(syncProtocolNamespace, forKey: .syncProtocolNamespace)
    }

    private static func isSemanticVersion(_ value: String) -> Bool {
        value.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"#, options: .regularExpression) != nil
    }
}

private enum AuthCapabilitiesCodingKeys: String, CodingKey {
    case authProtocolEpoch, authProtocolNamespace, authProtocolVersion, canonicalization, contentProtection, limits
    case minimumClientVersion, providers, serverInstanceID = "serverInstanceId", syncProtocolEpoch, syncProtocolNamespace
}

private enum AuthLimitsCodingKeys: String, CodingKey {
    case accessTokenLifetimeSeconds, authReceiptLifetimeSeconds, challengeLifetimeSeconds, maxCanonicalCommandBytes
    case maxProviderClockSkewSeconds, refreshTokenLifetimeSeconds
}

private enum AuthContentProtectionCodingKeys: String, CodingKey {
    case e2ee, profile, serverCanReadContent, userManagedContentKey
}

private enum AuthAppleProviderCodingKeys: String, CodingKey {
    case authorizationEndpoint, clientPlatforms, flow, issuer, jwksEndpoint, nativeAudiences, provider
    case providerConfigurationID = "providerConfigurationId", requestedScopes, tokenEndpoint
}
