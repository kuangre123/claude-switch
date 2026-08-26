import Foundation

public enum ClaudeSettingsError: LocalizedError {
    case rootIsNotObject
    case environmentIsNotObject
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .rootIsNotObject:
            "Claude settings.json 的根节点不是 JSON 对象"
        case .environmentIsNotObject:
            "Claude settings.json 的 env 节点不是 JSON 对象"
        case .invalidURL:
            "自定义 API 地址必须是有效的 http:// 或 https:// 地址"
        }
    }
}

public struct ClaudeSettingsManager: Sendable {
    public let settingsURL: URL
    public let backupDirectoryURL: URL

    public static let protectedEnvironmentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL"
    ]

    public static let providerEnvironmentKeys: Set<String> = protectedEnvironmentKeys.union([
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "ANTHROPIC_DEFAULT_FABLE_MODEL",
        "ANTHROPIC_DEFAULT_FABLE_MODEL_NAME",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME"
    ])

    public init(settingsURL: URL? = nil, backupDirectoryURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.settingsURL = settingsURL ?? home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        self.backupDirectoryURL = backupDirectoryURL ?? home
            .appendingPathComponent("Library/Application Support/ClaudeSwitch/Backups", isDirectory: true)
    }

    public func detectCurrentConfiguration() throws -> DetectedClaudeConfiguration? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return nil
        }

        let root = try readRoot()
        guard let rawEnvironment = root["env"] else {
            return nil
        }
        guard let environment = rawEnvironment as? [String: Any] else {
            throw ClaudeSettingsError.environmentIsNotObject
        }

        let strings = environment.compactMapValues { $0 as? String }
        let baseURL = strings["ANTHROPIC_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let profile: ProfileID = baseURL.isEmpty ? .official : .custom
        let credentialKind: CredentialKind = strings["ANTHROPIC_AUTH_TOKEN"] == nil ? .apiKey : .bearerToken
        let credential = strings[credentialKind.environmentKey]
        let advanced = strings.filter {
            Self.providerEnvironmentKeys.contains($0.key) &&
                !Self.protectedEnvironmentKeys.contains($0.key)
        }

        return DetectedClaudeConfiguration(
            profile: profile,
            configuration: ProfileConfiguration(
                baseURL: baseURL,
                credentialKind: credentialKind,
                environment: advanced
            ),
            credential: credential
        )
    }

    public func apply(
        profile profileID: ProfileID,
        configuration: AppConfiguration,
        credential: String?
    ) throws {
        let profile = configuration[profileID]
        if profileID == .custom {
            try validateCustomBaseURL(profile.baseURL)
        }

        var root = try readRoot(allowMissing: true)
        var environment: [String: Any]
        if let rawEnvironment = root["env"] {
            guard let parsedEnvironment = rawEnvironment as? [String: Any] else {
                throw ClaudeSettingsError.environmentIsNotObject
            }
            environment = parsedEnvironment
        } else {
            environment = [:]
        }

        let managedKeys = Self.providerEnvironmentKeys
            .union(configuration.official.environment.keys)
            .union(configuration.custom.environment.keys)
        for key in managedKeys {
            environment.removeValue(forKey: key)
        }

        for (key, value) in profile.environment where !Self.protectedEnvironmentKeys.contains(key) {
            environment[key] = value
        }
        if profileID == .custom {
            environment["ANTHROPIC_BASE_URL"] = normalizedBaseURL(profile.baseURL)
        }
        if let credential, !credential.isEmpty {
            environment[profile.credentialKind.environmentKey] = credential
        }

        root["env"] = environment
        try writeRootIfChanged(root)
    }

    public func validateCustomBaseURL(_ rawURL: String) throws {
        let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            throw ClaudeSettingsError.invalidURL
        }
    }

    private func normalizedBaseURL(_ rawURL: String) -> String {
        var value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private func readRoot(allowMissing: Bool = false) throws -> [String: Any] {
        if !FileManager.default.fileExists(atPath: settingsURL.path) {
            if allowMissing {
                return [:]
            }
            throw CocoaError(.fileNoSuchFile)
        }

        let data = try Data(contentsOf: settingsURL)
        let value = try JSONSerialization.jsonObject(with: data)
        guard let root = value as? [String: Any] else {
            throw ClaudeSettingsError.rootIsNotObject
        }
        return root
    }

    private func writeRootIfChanged(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0A])

        if let existing = try? Data(contentsOf: settingsURL),
           let existingObject = try? JSONSerialization.jsonObject(with: existing),
           NSDictionary(dictionary: root).isEqual(to: existingObject as? [AnyHashable: Any] ?? [:]) {
            return
        }

        try createBackupIfNeeded()
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: settingsURL.path
        )
    }

    private func createBackupIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return
        }
        try FileManager.default.createDirectory(
            at: backupDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let suffix = UUID().uuidString.prefix(8)
        let name = "settings-\(formatter.string(from: Date()))-\(suffix).json"
        let destination = backupDirectoryURL.appendingPathComponent(name)
        let sourceData = try Data(contentsOf: settingsURL)
        var backupData = sourceData
        if var root = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
           var environment = root["env"] as? [String: Any] {
            environment.removeValue(forKey: "ANTHROPIC_API_KEY")
            environment.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
            root["env"] = environment
            backupData = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ) + Data([0x0A])
        }
        try backupData.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }
}
