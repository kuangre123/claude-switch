import Foundation

public enum ClaudeDesktopSettingsError: LocalizedError {
    case rootIsNotObject(URL)
    case metaEntriesIsNotArray(URL)
    case invalidBaseURL
    case missingCredential
    case unsupportedModelIDs([String])
    case rollbackFailed(original: String, rollback: String)

    public var errorDescription: String? {
        switch self {
        case let .rootIsNotObject(url):
            "Claude Desktop 配置的根节点不是 JSON 对象：\(url.path)"
        case let .metaEntriesIsNotArray(url):
            "Claude Desktop 配置库的 entries 节点不是数组：\(url.path)"
        case .invalidBaseURL:
            "Claude Desktop 自定义 API 地址必须是有效的 http:// 或 https:// 地址"
        case .missingCredential:
            "同步到 Claude Desktop 需要访问密钥；若本地服务无需鉴权，请填写该服务支持的占位密钥"
        case let .unsupportedModelIDs(modelIDs):
            "Claude Desktop 直连不支持这些模型 ID：\(modelIDs.joined(separator: "、"))。请使用 claude-sonnet-*、claude-opus-*、claude-haiku-* 或 claude-fable-* 路由名，或关闭 Desktop 同步；任意模型需要本地转换代理（当前版本暂未提供）"
        case let .rollbackFailed(original, rollback):
            "写入 Claude Desktop 配置失败：\(original)；回滚也失败：\(rollback)"
        }
    }
}

/// Manages Claude Desktop's local first-party/third-party deployment selection.
///
/// Claude Desktop stores first-party state under `Claude` and third-party state
/// under `Claude-3p`. This manager only owns one profile in the third-party
/// configuration library and preserves all unrelated JSON fields and profiles.
public struct ClaudeDesktopSettingsManager: Sendable {
    /// Deliberately different from CC Switch's well-known profile identifier.
    public static let managedProfileID = "7a12f311-20f9-4d58-8e22-504130ee8f93"
    public static let managedProfileName = "Claude Switch"

    public let officialRootURL: URL
    public let thirdPartyRootURL: URL
    public let backupDirectoryURL: URL
    public let selectionStateURL: URL

    public var officialConfigURL: URL {
        officialRootURL.appendingPathComponent("claude_desktop_config.json", isDirectory: false)
    }

    public var thirdPartyConfigURL: URL {
        thirdPartyRootURL.appendingPathComponent("claude_desktop_config.json", isDirectory: false)
    }

    public var configLibraryURL: URL {
        thirdPartyRootURL.appendingPathComponent("configLibrary", isDirectory: true)
    }

    public var managedProfileURL: URL {
        configLibraryURL.appendingPathComponent(
            "\(Self.managedProfileID).json",
            isDirectory: false
        )
    }

    public var metaURL: URL {
        configLibraryURL.appendingPathComponent("_meta.json", isDirectory: false)
    }

    public init(
        officialRootURL: URL? = nil,
        thirdPartyRootURL: URL? = nil,
        backupDirectoryURL: URL? = nil,
        selectionStateURL: URL? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let applicationSupport = home.appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )
        let resolvedOfficialRoot = officialRootURL
            ?? applicationSupport.appendingPathComponent("Claude", isDirectory: true)
        let resolvedThirdPartyRoot = thirdPartyRootURL
            ?? applicationSupport.appendingPathComponent("Claude-3p", isDirectory: true)
        let resolvedBackupDirectory = backupDirectoryURL
            ?? applicationSupport.appendingPathComponent(
                "ClaudeSwitch/Backups/ClaudeDesktop",
                isDirectory: true
            )
        self.officialRootURL = resolvedOfficialRoot
        self.thirdPartyRootURL = resolvedThirdPartyRoot
        self.backupDirectoryURL = resolvedBackupDirectory
        self.selectionStateURL = selectionStateURL
            ?? resolvedThirdPartyRoot.deletingLastPathComponent()
                .appendingPathComponent("ClaudeSwitch", isDirectory: true)
                .appendingPathComponent(
                    "claude-desktop-selection.json",
                    isDirectory: false
                )
    }

    /// Applies a direct Anthropic-compatible gateway profile or restores
    /// Claude Desktop's first-party deployment mode.
    public func apply(
        profile: ProfileID,
        configuration: ProfileConfiguration,
        credential: String?
    ) throws {
        switch profile {
        case .custom:
            let baseURL = try normalizedAndValidatedBaseURL(configuration.baseURL)
            let modelIDs = try desktopModelIDs(from: configuration.environment)
            guard let credential = credential?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !credential.isEmpty else {
                throw ClaudeDesktopSettingsError.missingCredential
            }
            try performTransaction {
                try writeDeploymentMode("3p", to: officialConfigURL)
                try writeDeploymentMode("3p", to: thirdPartyConfigURL)
                try writeGatewayProfile(
                    baseURL: baseURL,
                    credentialKind: configuration.credentialKind,
                    credential: credential,
                    modelIDs: modelIDs
                )
                try writeMeta(selectManagedProfile: true)
            }
        case .official:
            try performTransaction {
                try writeDeploymentMode("1p", to: officialConfigURL)
                try writeDeploymentMode("1p", to: thirdPartyConfigURL)
                try removeManagedProfile()
                try writeMeta(selectManagedProfile: false)
            }
        }
    }

    private var managedURLs: [URL] {
        [
            officialConfigURL,
            thirdPartyConfigURL,
            managedProfileURL,
            metaURL,
            selectionStateURL
        ]
    }

    private func normalizedAndValidatedBaseURL(_ rawURL: String) throws -> String {
        var value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }

        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            throw ClaudeDesktopSettingsError.invalidBaseURL
        }
        return value
    }

    private func writeDeploymentMode(_ mode: String, to url: URL) throws {
        var root = try readJSONObject(at: url, allowMissing: true)
        root["deploymentMode"] = mode
        try writeJSONObjectIfChanged(root, to: url)
    }

    private func writeGatewayProfile(
        baseURL: String,
        credentialKind: CredentialKind,
        credential: String,
        modelIDs: [String]
    ) throws {
        let authScheme = switch credentialKind {
        case .apiKey: "x-api-key"
        case .bearerToken: "bearer"
        }
        var profile: [String: Any] = [
            "disableDeploymentModeChooser": true,
            "inferenceGatewayApiKey": credential,
            "inferenceGatewayAuthScheme": authScheme,
            "inferenceGatewayBaseUrl": baseURL,
            "inferenceProvider": "gateway"
        ]
        if !modelIDs.isEmpty {
            profile["inferenceModels"] = modelIDs
        }
        try writeJSONObjectIfChanged(profile, to: managedProfileURL)
    }

    private func desktopModelIDs(from environment: [String: String]) throws -> [String] {
        let keys = [
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_FABLE_MODEL",
            "ANTHROPIC_MODEL",
            "ANTHROPIC_SMALL_FAST_MODEL"
        ]
        var seen = Set<String>()
        var accepted: [String] = []
        var unsupported: [String] = []
        for key in keys {
            let value = environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else {
                continue
            }
            if isClaudeDesktopSafeModelID(value) {
                if seen.insert(value).inserted {
                    accepted.append(value)
                }
            } else if seen.insert(value).inserted {
                unsupported.append(value)
            }
        }
        if !unsupported.isEmpty {
            throw ClaudeDesktopSettingsError.unsupportedModelIDs(unsupported)
        }
        return accepted
    }

    private func isClaudeDesktopSafeModelID(_ value: String) -> Bool {
        let normalized = value.lowercased()
        guard !normalized.contains(where: \.isWhitespace) else {
            return false
        }
        let tail: Substring
        if normalized.hasPrefix("anthropic/claude-") {
            tail = normalized.dropFirst("anthropic/claude-".count)
        } else if normalized.hasPrefix("claude-") {
            tail = normalized.dropFirst("claude-".count)
        } else {
            return false
        }
        return ["sonnet-", "opus-", "haiku-", "fable-"].contains {
            tail.hasPrefix($0) && tail.count > $0.count
        }
    }

    private func removeManagedProfile() throws {
        guard FileManager.default.fileExists(atPath: managedProfileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: managedProfileURL)
    }

    private func writeMeta(selectManagedProfile: Bool) throws {
        let fileExists = FileManager.default.fileExists(atPath: metaURL.path)
        if !selectManagedProfile, !fileExists {
            try removeSelectionState()
            return
        }

        var root = try readJSONObject(at: metaURL, allowMissing: true)
        let rawEntries = root["entries"]
        if rawEntries != nil, !(rawEntries is [Any]) {
            throw ClaudeDesktopSettingsError.metaEntriesIsNotArray(metaURL)
        }
        var entries = rawEntries as? [Any] ?? []
        let hadManagedEntry = entries.contains { entry in
            (entry as? [String: Any])?["id"] as? String == Self.managedProfileID
        }
        entries.removeAll { entry in
            (entry as? [String: Any])?["id"] as? String == Self.managedProfileID
        }

        if selectManagedProfile {
            try rememberPreviousSelection(from: root)
            entries.append([
                "id": Self.managedProfileID,
                "name": Self.managedProfileName
            ])
            root["entries"] = entries
            root["appliedId"] = Self.managedProfileID
            try writeJSONObjectIfChanged(root, to: metaURL)
            return
        }

        let hadManagedSelection = root["appliedId"] as? String == Self.managedProfileID
        guard hadManagedEntry || hadManagedSelection else {
            try removeSelectionState()
            return
        }

        root["entries"] = entries
        if hadManagedSelection {
            let remainingIDs = Set(entries.compactMap {
                ($0 as? [String: Any])?["id"] as? String
            })
            if let state = try readSelectionState(), state.hadAppliedID {
                if let previousID = state.appliedID, remainingIDs.contains(previousID) {
                    root["appliedId"] = previousID
                } else if let fallback = remainingIDs.sorted().first {
                    root["appliedId"] = fallback
                } else {
                    root.removeValue(forKey: "appliedId")
                }
            } else {
                root.removeValue(forKey: "appliedId")
            }
        }
        try writeJSONObjectIfChanged(root, to: metaURL)
        try removeSelectionState()
    }

    private struct SelectionState: Codable {
        let hadAppliedID: Bool
        let appliedID: String?
    }

    private func rememberPreviousSelection(from meta: [String: Any]) throws {
        let appliedID = meta["appliedId"] as? String
        guard appliedID != Self.managedProfileID else {
            return
        }
        let state = SelectionState(
            hadAppliedID: appliedID != nil,
            appliedID: appliedID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(state)
        data.append(0x0A)
        try atomicWrite(data, to: selectionStateURL)
    }

    private func readSelectionState() throws -> SelectionState? {
        guard FileManager.default.fileExists(atPath: selectionStateURL.path) else {
            return nil
        }
        return try JSONDecoder().decode(
            SelectionState.self,
            from: Data(contentsOf: selectionStateURL)
        )
    }

    private func removeSelectionState() throws {
        guard FileManager.default.fileExists(atPath: selectionStateURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: selectionStateURL)
    }

    private func readJSONObject(at url: URL, allowMissing: Bool) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if allowMissing {
                return [:]
            }
            throw CocoaError(.fileNoSuchFile)
        }

        let data = try Data(contentsOf: url)
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            throw ClaudeDesktopSettingsError.rootIsNotObject(url)
        }
        return object
    }

    private func writeJSONObjectIfChanged(_ object: [String: Any], to url: URL) throws {
        if let existingData = try? Data(contentsOf: url),
           let existingObject = try? JSONSerialization.jsonObject(with: existingData),
           NSDictionary(dictionary: object).isEqual(to: existingObject as? [AnyHashable: Any] ?? [:]) {
            return
        }

        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0A])
        try atomicWrite(data, to: url)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private struct FileSnapshot {
        let url: URL
        let data: Data?
    }

    private func performTransaction(_ operation: () throws -> Void) throws {
        let snapshots = try managedURLs.map { url in
            FileSnapshot(
                url: url,
                data: FileManager.default.fileExists(atPath: url.path)
                    ? try Data(contentsOf: url)
                    : nil
            )
        }
        try createBackup(from: snapshots)

        do {
            try operation()
        } catch {
            do {
                try restore(snapshots)
            } catch let rollbackError {
                throw ClaudeDesktopSettingsError.rollbackFailed(
                    original: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }
    }

    private func createBackup(from snapshots: [FileSnapshot]) throws {
        let existing = snapshots.compactMap { snapshot -> FileSnapshot? in
            guard snapshot.data != nil, snapshot.url != managedProfileURL else {
                return nil
            }
            return snapshot
        }
        guard !existing.isEmpty else {
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let operationDirectory = backupDirectoryURL.appendingPathComponent(
            "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: operationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        for snapshot in existing {
            guard let data = snapshot.data else { continue }
            let relativeName: String
            switch snapshot.url {
            case officialConfigURL:
                relativeName = "Claude/claude_desktop_config.json"
            case thirdPartyConfigURL:
                relativeName = "Claude-3p/claude_desktop_config.json"
            case managedProfileURL:
                relativeName = "Claude-3p/configLibrary/\(Self.managedProfileID).json"
            case selectionStateURL:
                relativeName = "ClaudeSwitch/claude-desktop-selection.json"
            default:
                relativeName = "Claude-3p/configLibrary/_meta.json"
            }
            try atomicWrite(
                data,
                to: operationDirectory.appendingPathComponent(relativeName, isDirectory: false)
            )
        }
    }

    private func restore(_ snapshots: [FileSnapshot]) throws {
        for snapshot in snapshots {
            if let data = snapshot.data {
                try atomicWrite(data, to: snapshot.url)
            } else if FileManager.default.fileExists(atPath: snapshot.url.path) {
                try FileManager.default.removeItem(at: snapshot.url)
            }
        }
    }
}
