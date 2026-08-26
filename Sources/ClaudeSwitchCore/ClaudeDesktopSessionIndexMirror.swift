import Foundation

public enum ClaudeDesktopSessionMirrorError: LocalizedError {
    case missingThirdPartyAccount
    case indexRecordIsNotObject(URL)

    public var errorDescription: String? {
        switch self {
        case .missingThirdPartyAccount:
            "Claude Desktop 第三方模式还没有本地账号记录；请先用第三方模式启动一次 Desktop，再导入官方会话列表"
        case let .indexRecordIsNotObject(url):
            "Claude Desktop 会话索引记录不是 JSON 对象：\(url.path)"
        }
    }
}

/// Mirrors Claude Desktop's first-party session index into the third-party
/// deployment space so the sidebar still lists earlier conversations.
///
/// Claude Desktop keeps the session index under
/// `<root>/claude-code-sessions/<accountID>/<organizationID>/local_*.json` and
/// the transcripts themselves under `~/.claude/projects`. Only the index is
/// partitioned per deployment mode, so copying index records restores the
/// sidebar without touching a single transcript.
///
/// The copy is deliberately one-way, first-party to third-party. The
/// first-party space owns `pending-uploads`, meaning records placed there can be
/// synced to Anthropic; conversations produced through a custom gateway must
/// never be pushed into that space.
public struct ClaudeDesktopSessionIndexMirror: Sendable {
    /// Claude Desktop uses this fixed organization ID in third-party mode.
    public static let placeholderOrganizationID = "00000000-0000-4000-8000-000000000001"
    private static let sessionsDirectoryName = "claude-code-sessions"
    private static let recordPrefix = "local_"
    private static let deletedMarkerPrefix = "deleted_"

    public struct Summary: Sendable, Equatable {
        public var imported: Int
        public var alreadyPresent: Int
        public var missingTranscript: Int
        public var archivedOrDeleted: Int

        public init(
            imported: Int = 0,
            alreadyPresent: Int = 0,
            missingTranscript: Int = 0,
            archivedOrDeleted: Int = 0
        ) {
            self.imported = imported
            self.alreadyPresent = alreadyPresent
            self.missingTranscript = missingTranscript
            self.archivedOrDeleted = archivedOrDeleted
        }

        public var examined: Int {
            imported + alreadyPresent + missingTranscript + archivedOrDeleted
        }
    }

    public let officialRootURL: URL
    public let thirdPartyRootURL: URL
    public let projectsDirectoryURL: URL
    public let importStateURL: URL

    public init(
        officialRootURL: URL? = nil,
        thirdPartyRootURL: URL? = nil,
        projectsDirectoryURL: URL? = nil,
        importStateURL: URL? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let applicationSupport = home.appendingPathComponent(
            "Library/Application Support",
            isDirectory: true
        )
        self.officialRootURL = officialRootURL
            ?? applicationSupport.appendingPathComponent("Claude", isDirectory: true)
        self.thirdPartyRootURL = thirdPartyRootURL
            ?? applicationSupport.appendingPathComponent("Claude-3p", isDirectory: true)
        self.projectsDirectoryURL = projectsDirectoryURL
            ?? home
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
        self.importStateURL = importStateURL
            ?? applicationSupport
                .appendingPathComponent("ClaudeSwitch", isDirectory: true)
                .appendingPathComponent(
                    "claude-desktop-session-import.json",
                    isDirectory: false
                )
    }
}
extension ClaudeDesktopSessionIndexMirror {
    /// Copies eligible first-party index records into the third-party space.
    ///
    /// Skips records that are archived, tombstoned, already imported, or whose
    /// transcript no longer exists in `~/.claude/projects`, so the sidebar does
    /// not fill up with entries that cannot be opened.
    @discardableResult
    public func importOfficialSessions() throws -> Summary {
        guard let destination = try thirdPartyIndexDirectory() else {
            throw ClaudeDesktopSessionMirrorError.missingThirdPartyAccount
        }

        let transcripts = availableTranscriptIDs()
        var summary = Summary()
        var imported: [String] = []

        for source in try officialIndexDirectories() {
            let tombstoned = tombstonedSessionIDs(in: source)
            for record in try recordURLs(in: source) {
                let sessionID = sessionID(for: record)
                if tombstoned.contains(sessionID) {
                    summary.archivedOrDeleted += 1
                    continue
                }

                let target = destination.appendingPathComponent(
                    record.lastPathComponent,
                    isDirectory: false
                )
                if FileManager.default.fileExists(atPath: target.path) {
                    summary.alreadyPresent += 1
                    continue
                }

                let object = try readRecord(at: record)
                if object["isArchived"] as? Bool == true {
                    summary.archivedOrDeleted += 1
                    continue
                }
                guard let cliSessionID = object["cliSessionId"] as? String,
                      transcripts.contains(cliSessionID) else {
                    summary.missingTranscript += 1
                    continue
                }

                try write(object, to: target)
                imported.append(record.lastPathComponent)
                summary.imported += 1
            }
        }

        if !imported.isEmpty {
            try recordImportState(adding: imported)
        }
        return summary
    }

    /// Removes only the records this mirror previously copied, leaving
    /// conversations that started in third-party mode untouched.
    @discardableResult
    public func removeImportedSessions() throws -> Int {
        guard let destination = try thirdPartyIndexDirectory(createIfMissing: false),
              let state = try readImportState() else {
            return 0
        }

        var removed = 0
        for name in state.importedRecordNames {
            let url = destination.appendingPathComponent(name, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        try removeImportState()
        return removed
    }

    /// Whether any first-party record is eligible to import right now.
    public func hasImportableSessions() -> Bool {
        guard let summary = try? previewImportableSessions() else {
            return false
        }
        return summary.imported > 0
    }

    /// Counts what an import would do without writing anything.
    public func previewImportableSessions() throws -> Summary {
        let destination = try? thirdPartyIndexDirectory(createIfMissing: false)
        let transcripts = availableTranscriptIDs()
        var summary = Summary()

        for source in try officialIndexDirectories() {
            let tombstoned = tombstonedSessionIDs(in: source)
            for record in try recordURLs(in: source) {
                let sessionID = sessionID(for: record)
                if tombstoned.contains(sessionID) {
                    summary.archivedOrDeleted += 1
                    continue
                }
                if let destination,
                   FileManager.default.fileExists(
                       atPath: destination
                           .appendingPathComponent(record.lastPathComponent)
                           .path
                   ) {
                    summary.alreadyPresent += 1
                    continue
                }
                guard let object = try? readRecord(at: record) else {
                    summary.missingTranscript += 1
                    continue
                }
                if object["isArchived"] as? Bool == true {
                    summary.archivedOrDeleted += 1
                    continue
                }
                guard let cliSessionID = object["cliSessionId"] as? String,
                      transcripts.contains(cliSessionID) else {
                    summary.missingTranscript += 1
                    continue
                }
                summary.imported += 1
            }
        }
        return summary
    }
}
private extension ClaudeDesktopSessionIndexMirror {
    struct ImportState: Codable {
        var importedRecordNames: [String]
    }

    var officialSessionsRootURL: URL {
        officialRootURL.appendingPathComponent(
            Self.sessionsDirectoryName,
            isDirectory: true
        )
    }

    var thirdPartySessionsRootURL: URL {
        thirdPartyRootURL.appendingPathComponent(
            Self.sessionsDirectoryName,
            isDirectory: true
        )
    }

    /// Reads the account ID Claude Desktop recorded for a deployment root.
    ///
    /// Preferring `config.json` over directory globbing keeps the destination
    /// stable when several account directories linger from earlier logins.
    func accountID(for root: URL) -> String? {
        let configURL = root.appendingPathComponent("config.json", isDirectory: false)
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let accountID = object["lastKnownAccountUuid"] as? String,
              !accountID.isEmpty else {
            return nil
        }
        return accountID
    }

    func officialIndexDirectories() throws -> [URL] {
        guard let accountID = accountID(for: officialRootURL) else {
            return []
        }
        let accountDirectory = officialSessionsRootURL.appendingPathComponent(
            accountID,
            isDirectory: true
        )
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: accountDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        return contents
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func thirdPartyIndexDirectory(createIfMissing: Bool = true) throws -> URL? {
        guard let accountID = accountID(for: thirdPartyRootURL) else {
            return nil
        }
        let accountDirectory = thirdPartySessionsRootURL.appendingPathComponent(
            accountID,
            isDirectory: true
        )

        let existing = (try? FileManager.default.contentsOfDirectory(
            at: accountDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ))?.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        if let directory = existing?.first {
            return directory
        }
        guard createIfMissing else {
            return nil
        }

        let placeholder = accountDirectory.appendingPathComponent(
            Self.placeholderOrganizationID,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: placeholder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return placeholder
    }

    func recordURLs(in directory: URL) throws -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return contents
            .filter {
                $0.lastPathComponent.hasPrefix(Self.recordPrefix)
                    && $0.pathExtension == "json"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The bare session ID inside a `local_<uuid>.json` index record name.
    func sessionID(for record: URL) -> String {
        String(
            record.deletingPathExtension().lastPathComponent
                .dropFirst(Self.recordPrefix.count)
        )
    }

    /// Session IDs Claude Desktop tombstoned via a `deleted_<uuid>` marker.
    func tombstonedSessionIDs(in directory: URL) -> Set<String> {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return Set(
            contents
                .map(\.lastPathComponent)
                .filter { $0.hasPrefix(Self.deletedMarkerPrefix) }
                .map {
                    // Claude Desktop writes these markers without a `.json`
                    // extension, so compare on the bare session ID.
                    String($0.dropFirst(Self.deletedMarkerPrefix.count))
                        .replacingOccurrences(
                            of: ".json",
                            with: "",
                            options: [.anchored, .backwards]
                        )
                }
        )
    }

    func availableTranscriptIDs() -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var identifiers: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            identifiers.insert(url.deletingPathExtension().lastPathComponent)
        }
        return identifiers
    }

    func readRecord(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any] else {
            throw ClaudeDesktopSessionMirrorError.indexRecordIsNotObject(url)
        }
        return object
    }

    func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0A])
        try atomicWrite(data, to: url)
    }

    func atomicWrite(_ data: Data, to url: URL) throws {
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

    func readImportState() throws -> ImportState? {
        guard FileManager.default.fileExists(atPath: importStateURL.path) else {
            return nil
        }
        return try JSONDecoder().decode(
            ImportState.self,
            from: Data(contentsOf: importStateURL)
        )
    }

    func recordImportState(adding names: [String]) throws {
        var merged = (try? readImportState())??.importedRecordNames ?? []
        merged.append(contentsOf: names)
        let state = ImportState(importedRecordNames: Array(Set(merged)).sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(state)
        data.append(0x0A)
        try atomicWrite(data, to: importStateURL)
    }

    func removeImportState() throws {
        guard FileManager.default.fileExists(atPath: importStateURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: importStateURL)
    }
}
