import Foundation
import XCTest
@testable import ClaudeSwitchCore

final class ClaudeDesktopSessionIndexMirrorTests: XCTestCase {
    func testImportsOnlyOpenableSessionsAndSkipsTombstones() throws {
        let fixture = try MirrorFixture()
        defer { fixture.cleanup() }

        try fixture.officialRecord(session: "aaaaaaaa", transcript: true)
        try fixture.officialRecord(session: "bbbbbbbb", transcript: false)
        try fixture.officialRecord(session: "cccccccc", transcript: true, archived: true)
        try fixture.officialRecord(session: "dddddddd", transcript: true)
        // Claude Desktop writes tombstones without a `.json` extension.
        try fixture.tombstone(session: "dddddddd", withExtension: false)

        let preview = try fixture.mirror.previewImportableSessions()
        let summary = try fixture.mirror.importOfficialSessions()

        XCTAssertEqual(preview.imported, 1)
        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.missingTranscript, 1)
        XCTAssertEqual(summary.archivedOrDeleted, 2)
        XCTAssertEqual(summary.examined, 4)

        XCTAssertTrue(fixture.thirdPartyHasRecord(session: "aaaaaaaa"))
        XCTAssertFalse(fixture.thirdPartyHasRecord(session: "bbbbbbbb"))
        XCTAssertFalse(fixture.thirdPartyHasRecord(session: "cccccccc"))
        XCTAssertFalse(
            fixture.thirdPartyHasRecord(session: "dddddddd"),
            "a session the user deleted in Desktop was imported back"
        )
    }

    func testTombstoneMatchingToleratesExtensionVariant() throws {
        let fixture = try MirrorFixture()
        defer { fixture.cleanup() }

        try fixture.officialRecord(session: "eeeeeeee", transcript: true)
        try fixture.tombstone(session: "eeeeeeee", withExtension: true)

        let summary = try fixture.mirror.importOfficialSessions()

        XCTAssertEqual(summary.imported, 0)
        XCTAssertEqual(summary.archivedOrDeleted, 1)
        XCTAssertFalse(fixture.thirdPartyHasRecord(session: "eeeeeeee"))
    }

    func testImportIsIdempotentAndRemovalSparesThirdPartySessions() throws {
        let fixture = try MirrorFixture()
        defer { fixture.cleanup() }

        try fixture.officialRecord(session: "11111111", transcript: true)
        try fixture.nativeThirdPartyRecord(session: "99999999")

        let first = try fixture.mirror.importOfficialSessions()
        let second = try fixture.mirror.importOfficialSessions()

        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.alreadyPresent, 1)

        let removed = try fixture.mirror.removeImportedSessions()

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(fixture.thirdPartyHasRecord(session: "11111111"))
        XCTAssertTrue(
            fixture.thirdPartyHasRecord(session: "99999999"),
            "removal deleted a conversation that started in third-party mode"
        )
        XCTAssertEqual(try fixture.mirror.removeImportedSessions(), 0)
    }

    func testImportedRecordLandsInThirdPartyPlaceholderOrganization() throws {
        let fixture = try MirrorFixture()
        defer { fixture.cleanup() }

        try fixture.officialRecord(session: "22222222", transcript: true)
        try fixture.mirror.importOfficialSessions()

        let expected = fixture.thirdPartyIndexDirectory
            .appendingPathComponent("local_22222222.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertEqual(
            expected.deletingLastPathComponent().lastPathComponent,
            ClaudeDesktopSessionIndexMirror.placeholderOrganizationID
        )
    }

    func testImportFailsClearlyWhenThirdPartyAccountIsUnknown() throws {
        let fixture = try MirrorFixture(thirdPartyAccount: nil)
        defer { fixture.cleanup() }

        try fixture.officialRecord(session: "33333333", transcript: true)

        XCTAssertThrowsError(try fixture.mirror.importOfficialSessions()) { error in
            XCTAssertTrue(error is ClaudeDesktopSessionMirrorError)
        }
    }

    func testTranscriptsAreNeverModified() throws {
        let fixture = try MirrorFixture()
        defer { fixture.cleanup() }

        try fixture.officialRecord(session: "44444444", transcript: true)
        let before = try fixture.transcriptSnapshot()

        try fixture.mirror.importOfficialSessions()
        try fixture.mirror.removeImportedSessions()

        XCTAssertEqual(try fixture.transcriptSnapshot(), before)
    }
}

/// Builds the on-disk layout Claude Desktop actually uses: a per-root
/// `config.json` naming the account, then `<account>/<organization>/local_*.json`.
private final class MirrorFixture {
    private static let officialAccount = "b615bd5b-9bf5-4214-b1f6-25c7bad62605"
    private static let officialOrganization = "bf5e86be-0059-4967-838c-5a7a4912972b"
    private static let thirdPartyAccountID = "5186a198-41a0-4102-85e4-10b41e22c452"

    private let fileManager = FileManager.default
    private let root: URL
    let mirror: ClaudeDesktopSessionIndexMirror

    private let officialRoot: URL
    private let thirdPartyRoot: URL
    private let projects: URL
    private let officialIndex: URL

    init(thirdPartyAccount: String? = MirrorFixture.thirdPartyAccountID) throws {
        let base = ProcessInfo.processInfo.environment["TMPDIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.temporaryDirectory
        root = base.appendingPathComponent(
            "ClaudeSwitchMirrorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        officialRoot = root.appendingPathComponent("Claude", isDirectory: true)
        thirdPartyRoot = root.appendingPathComponent("Claude-3p", isDirectory: true)
        projects = root.appendingPathComponent("projects", isDirectory: true)
        officialIndex = officialRoot
            .appendingPathComponent("claude-code-sessions", isDirectory: true)
            .appendingPathComponent(Self.officialAccount, isDirectory: true)
            .appendingPathComponent(Self.officialOrganization, isDirectory: true)

        try fileManager.createDirectory(at: officialIndex, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: projects, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thirdPartyRoot, withIntermediateDirectories: true)

        try Self.writeConfig(account: Self.officialAccount, in: officialRoot)
        if let thirdPartyAccount {
            try Self.writeConfig(account: thirdPartyAccount, in: thirdPartyRoot)
        }

        mirror = ClaudeDesktopSessionIndexMirror(
            officialRootURL: officialRoot,
            thirdPartyRootURL: thirdPartyRoot,
            projectsDirectoryURL: projects,
            importStateURL: root.appendingPathComponent("import-state.json")
        )
    }

    var thirdPartyIndexDirectory: URL {
        thirdPartyRoot
            .appendingPathComponent("claude-code-sessions", isDirectory: true)
            .appendingPathComponent(Self.thirdPartyAccountID, isDirectory: true)
            .appendingPathComponent(
                ClaudeDesktopSessionIndexMirror.placeholderOrganizationID,
                isDirectory: true
            )
    }

    func officialRecord(
        session: String,
        transcript: Bool,
        archived: Bool = false
    ) throws {
        var record: [String: Any] = [
            "cliSessionId": session,
            "title": "session \(session)",
            "cwd": "/Users/example/project"
        ]
        if archived {
            record["isArchived"] = true
        }
        try write(
            record,
            to: officialIndex.appendingPathComponent("local_\(session).json")
        )
        if transcript {
            let directory = projects.appendingPathComponent("-Users-example-project")
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(
                to: directory.appendingPathComponent("\(session).jsonl")
            )
        }
    }

    func nativeThirdPartyRecord(session: String) throws {
        try write(
            ["cliSessionId": session, "title": "native \(session)"],
            to: thirdPartyIndexDirectory.appendingPathComponent("local_\(session).json")
        )
    }

    func tombstone(session: String, withExtension: Bool) throws {
        let name = withExtension ? "deleted_\(session).json" : "deleted_\(session)"
        try Data("{}\n".utf8).write(to: officialIndex.appendingPathComponent(name))
    }

    func thirdPartyHasRecord(session: String) -> Bool {
        fileManager.fileExists(
            atPath: thirdPartyIndexDirectory
                .appendingPathComponent("local_\(session).json").path
        )
    }

    /// Every transcript path with its bytes, so a test can prove none changed.
    func transcriptSnapshot() throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        guard let enumerator = fileManager.enumerator(at: projects, includingPropertiesForKeys: nil)
        else {
            return snapshot
        }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            snapshot[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return snapshot
    }

    func cleanup() {
        try? fileManager.removeItem(at: root)
    }

    private static func writeConfig(account: String, in root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization
            .data(withJSONObject: ["lastKnownAccountUuid": account])
            .write(to: root.appendingPathComponent("config.json"))
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }
}
