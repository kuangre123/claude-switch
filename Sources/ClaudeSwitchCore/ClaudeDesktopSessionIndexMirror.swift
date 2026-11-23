import Darwin
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
        public var refreshed: Int
        public var alreadyPresent: Int
        public var missingTranscript: Int
        public var archivedOrDeleted: Int
        public var unreadable: Int

        public init(
            imported: Int = 0,
            refreshed: Int = 0,
            alreadyPresent: Int = 0,
            missingTranscript: Int = 0,
            archivedOrDeleted: Int = 0,
            unreadable: Int = 0
        ) {
            self.imported = imported
            self.refreshed = refreshed
            self.alreadyPresent = alreadyPresent
            self.missingTranscript = missingTranscript
            self.archivedOrDeleted = archivedOrDeleted
            self.unreadable = unreadable
        }

        public var examined: Int {
            imported + refreshed + alreadyPresent + missingTranscript + archivedOrDeleted + unreadable
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
    /// Only the sidebar timestamp is refreshed on existing copies we imported.
    @discardableResult
    public func importOfficialSessions() throws -> Summary {
        try withImportLock { try scan(preview: false) }
    }

    /// Removes only the records this mirror previously copied, leaving
    /// conversations that started in third-party mode untouched.
    @discardableResult
    public func removeImportedSessions() throws -> Int {
        try withImportLock {
            guard let destination = try thirdPartyIndexDirectory(createIfMissing: false) else { return 0 }
            var state = try readImportState()
            let key = destinationKey(destination)
            guard let names = state.recordsByDestination[key] else { return 0 }
            var removed = 0
            for name in names {
                guard name.hasPrefix(Self.recordPrefix), name.hasSuffix(".json"), !name.contains("/") else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let url = destination.appendingPathComponent(name, isDirectory: false)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    removed += 1
                }
            }
            state.recordsByDestination.removeValue(forKey: key)
            if state.recordsByDestination.isEmpty && state.unassignedLegacyRecords.isEmpty {
                try removeImportState()
            } else {
                try writeImportState(state)
            }
            return removed
        }
    }

    /// Whether any first-party record is eligible to import right now.
    public func hasImportableSessions() -> Bool {
        guard let summary = try? previewImportableSessions() else {
            return false
        }
        return summary.imported > 0 || summary.refreshed > 0
    }

    /// Counts what an import would do without writing anything.
    public func previewImportableSessions() throws -> Summary {
        try scan(preview: true)
    }
}
private extension ClaudeDesktopSessionIndexMirror {
    func scan(preview: Bool) throws -> Summary {
        let destination = try thirdPartyIndexDirectory(createIfMissing: !preview)
        if !preview && destination == nil {
            throw ClaudeDesktopSessionMirrorError.missingThirdPartyAccount
        }
        var state = try readImportState()
        let key = destination.map(destinationKey)
        let tracked = key.flatMap { state.recordsByDestination[$0] } ?? []
        let destinationTombstones = destination.map(tombstonedSessionIDs(in:)) ?? []
        let transcripts = availableTranscriptIDs()
        var summary = Summary()

        for source in try officialIndexDirectories() {
            let tombstoned = destinationTombstones.union(tombstonedSessionIDs(in: source))
            for record in try recordURLs(in: source) {
                let sessionID = sessionID(for: record)
                if tombstoned.contains(sessionID) {
                    summary.archivedOrDeleted += 1
                    continue
                }
                let name = record.lastPathComponent
                let target = destination?.appendingPathComponent(name)
                let exists = target.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                if exists && !tracked.contains(name) {
                    summary.alreadyPresent += 1
                    continue
                }
                guard let object = try? readRecord(at: record) else {
                    summary.unreadable += 1
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
                if exists, let target {
                    guard var local = try? readRecord(at: target) else {
                        summary.unreadable += 1
                        continue
                    }
                    guard local["isArchived"] as? Bool != true,
                          local["cliSessionId"] as? String == cliSessionID,
                          let sourceActivity = object["lastActivityAt"] as? Int64,
                          sourceActivity > (local["lastActivityAt"] as? Int64 ?? 0) else {
                        summary.alreadyPresent += 1
                        continue
                    }
                    if !preview {
                        local["lastActivityAt"] = sourceActivity
                        try atomicWrite(try JSONSerialization.data(withJSONObject: local), to: target)
                    }
                    summary.refreshed += 1
                } else if preview {
                    summary.imported += 1
                } else if let target, let key, try writeNewRecord(object, to: target) {
                    state.recordsByDestination[key, default: []].insert(name)
                    do {
                        try writeImportState(state)
                    } catch {
                        try FileManager.default.removeItem(at: target)
                        throw error
                    }
                    summary.imported += 1
                } else {
                    summary.alreadyPresent += 1
                }
            }
        }
        return summary
    }

    struct ImportState: Codable {
        var recordsByDestination: [String: Set<String>] = [:]
        var unassignedLegacyRecords: Set<String> = []
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
              UUID(uuidString: accountID) != nil else {
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
        // Static gateway mode uses the device identity. Older installs may
        // only have the account UUID cached by Desktop in config.json.
        let deviceIDFile = thirdPartyRootURL.appendingPathComponent("ant-did")
        let accountID: String?
        if FileManager.default.fileExists(atPath: deviceIDFile.path) {
            let encoded = try String(contentsOf: deviceIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            accountID = Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) }
        } else {
            accountID = self.accountID(for: thirdPartyRootURL)
        }
        guard let accountID, UUID(uuidString: accountID) != nil else {
            return nil
        }
        let accountDirectory = thirdPartySessionsRootURL.appendingPathComponent(
            accountID,
            isDirectory: true
        )

        let directory = accountDirectory.appendingPathComponent(
            try thirdPartyOrganizationID(),
            isDirectory: true
        )
        guard createIfMissing else {
            return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    func thirdPartyOrganizationID() throws -> String {
        struct Selection: Decodable { var appliedId: String? }
        struct Deployment: Decodable { var deploymentOrganizationUuid: String? }
        let library = thirdPartyRootURL.appendingPathComponent("configLibrary")
        let meta = library.appendingPathComponent("_meta.json")
        guard FileManager.default.fileExists(atPath: meta.path) else { return Self.placeholderOrganizationID }
        let selection = try JSONDecoder().decode(Selection.self, from: Data(contentsOf: meta))
        guard let id = selection.appliedId else { return Self.placeholderOrganizationID }
        guard UUID(uuidString: id) != nil else { throw CocoaError(.fileReadCorruptFile) }
        let profile = library.appendingPathComponent(id + ".json")
        let deployment = try JSONDecoder().decode(Deployment.self, from: Data(contentsOf: profile))
        guard let org = deployment.deploymentOrganizationUuid else { return Self.placeholderOrganizationID }
        guard UUID(uuidString: org) != nil else { throw CocoaError(.fileReadCorruptFile) }
        return org
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

    /// Publish the complete record only if Desktop hasn't created it in the meantime.
    func writeNewRecord(_ object: [String: Any], to url: URL) throws -> Bool {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data([0x0A])
        var template = Array((url.deletingLastPathComponent().path + "/.claude-switch.XXXXXX").utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let stagedPath = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        defer { _ = unlink(stagedPath) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        guard renamex_np(stagedPath, url.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
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

    func destinationKey(_ directory: URL) -> String {
        directory.deletingLastPathComponent().lastPathComponent + "/" + directory.lastPathComponent
    }

    func readImportState() throws -> ImportState {
        guard FileManager.default.fileExists(atPath: importStateURL.path) else {
            return ImportState()
        }
        let data = try Data(contentsOf: importStateURL)
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(ImportState.self, from: data) { return state }
        // v1.4 stored only filenames. Claim those records only when there is
        // exactly one possible third-party account and organization on disk.
        struct Legacy: Decodable { var importedRecordNames: Set<String> }
        let old = try decoder.decode(Legacy.self, from: data)
        func uuidDirectories(_ root: URL) throws -> [URL] {
            guard FileManager.default.fileExists(atPath: root.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { try UUID(uuidString: $0.lastPathComponent) != nil && $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
        }
        let accounts = try uuidDirectories(thirdPartySessionsRootURL)
        if accounts.count == 1 {
            let orgs = try uuidDirectories(accounts[0])
            if orgs.count == 1 {
                return ImportState(recordsByDestination: [destinationKey(orgs[0]): old.importedRecordNames])
            }
        }
        return ImportState(unassignedLegacyRecords: old.importedRecordNames)
    }

    func writeImportState(_ state: ImportState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(state)
        data.append(0x0A)
        try atomicWrite(data, to: importStateURL)
    }

    // The menu and a second running switcher can otherwise each replace the
    // other instance's ownership ledger while publishing different records.
    func withImportLock<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: importStateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = open(importStateURL.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try operation()
    }

    func removeImportState() throws {
        guard FileManager.default.fileExists(atPath: importStateURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: importStateURL)
    }
}
