import Foundation

public enum ProfileID: String, Codable, CaseIterable, Sendable {
    case official
    case custom

    public var displayName: String {
        switch self {
        case .official: "官方 API"
        case .custom: "自定义 API"
        }
    }
}

public enum CredentialKind: String, Codable, CaseIterable, Sendable {
    case apiKey
    case bearerToken

    public var environmentKey: String {
        switch self {
        case .apiKey: "ANTHROPIC_API_KEY"
        case .bearerToken: "ANTHROPIC_AUTH_TOKEN"
        }
    }
}

public struct ProfileConfiguration: Codable, Equatable, Sendable {
    public var baseURL: String
    public var credentialKind: CredentialKind
    public var environment: [String: String]

    public init(
        baseURL: String = "",
        credentialKind: CredentialKind = .apiKey,
        environment: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.credentialKind = credentialKind
        self.environment = environment
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var version: Int
    public var activeProfile: ProfileID?
    public var claudeDesktopSyncEnabled: Bool
    public var claudeDesktopSessionImportEnabled: Bool
    public var official: ProfileConfiguration
    public var custom: ProfileConfiguration

    public init(
        version: Int = 2,
        activeProfile: ProfileID? = nil,
        claudeDesktopSyncEnabled: Bool = false,
        claudeDesktopSessionImportEnabled: Bool = false,
        official: ProfileConfiguration = ProfileConfiguration(),
        custom: ProfileConfiguration = ProfileConfiguration()
    ) {
        self.version = version
        self.activeProfile = activeProfile
        self.claudeDesktopSyncEnabled = claudeDesktopSyncEnabled
        self.claudeDesktopSessionImportEnabled = claudeDesktopSessionImportEnabled
        self.official = official
        self.custom = custom
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case activeProfile
        case claudeDesktopSyncEnabled
        case claudeDesktopSessionImportEnabled
        case official
        case custom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        activeProfile = try container.decodeIfPresent(ProfileID.self, forKey: .activeProfile)
        claudeDesktopSyncEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .claudeDesktopSyncEnabled
        ) ?? false
        claudeDesktopSessionImportEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .claudeDesktopSessionImportEnabled
        ) ?? false
        official = try container.decodeIfPresent(
            ProfileConfiguration.self,
            forKey: .official
        ) ?? ProfileConfiguration()
        custom = try container.decodeIfPresent(
            ProfileConfiguration.self,
            forKey: .custom
        ) ?? ProfileConfiguration()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(activeProfile, forKey: .activeProfile)
        try container.encode(claudeDesktopSyncEnabled, forKey: .claudeDesktopSyncEnabled)
        try container.encode(
            claudeDesktopSessionImportEnabled,
            forKey: .claudeDesktopSessionImportEnabled
        )
        try container.encode(official, forKey: .official)
        try container.encode(custom, forKey: .custom)
    }

    public subscript(profile: ProfileID) -> ProfileConfiguration {
        get {
            switch profile {
            case .official: official
            case .custom: custom
            }
        }
        set {
            switch profile {
            case .official: official = newValue
            case .custom: custom = newValue
            }
        }
    }
}

public struct DetectedClaudeConfiguration: Sendable {
    public var profile: ProfileID
    public var configuration: ProfileConfiguration
    public var credential: String?

    public init(
        profile: ProfileID,
        configuration: ProfileConfiguration,
        credential: String?
    ) {
        self.profile = profile
        self.configuration = configuration
        self.credential = credential
    }
}
