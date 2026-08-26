import Foundation
import XCTest
@testable import ClaudeSwitchCore

final class ClaudeSettingsManagerTests: XCTestCase {
    func testSwitchesWithoutTouchingOtherSettings() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.writeSettings([
            "theme": "dark",
            "permissions": ["allow": ["Read(*)"]],
            "env": [
                "KEEP_ME": "yes",
                "ANTHROPIC_API_KEY": "old-key",
                "ANTHROPIC_MODEL": "old-model"
            ]
        ])

        var configuration = AppConfiguration()
        configuration.official.environment = [:]
        configuration.custom = ProfileConfiguration(
            baseURL: "https://gateway.example.com/",
            credentialKind: .bearerToken,
            environment: ["ANTHROPIC_MODEL": "gateway-sonnet"]
        )

        try fixture.manager.apply(
            profile: .custom,
            configuration: configuration,
            credential: "custom-secret"
        )
        var result = try fixture.readSettings()
        var environment = try XCTUnwrap(result["env"] as? [String: Any])
        XCTAssertEqual(result["theme"] as? String, "dark")
        XCTAssertEqual(environment["KEEP_ME"] as? String, "yes")
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"] as? String, "https://gateway.example.com")
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"] as? String, "custom-secret")
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(environment["ANTHROPIC_MODEL"] as? String, "gateway-sonnet")

        try fixture.manager.apply(
            profile: .official,
            configuration: configuration,
            credential: "official-secret"
        )
        result = try fixture.readSettings()
        environment = try XCTUnwrap(result["env"] as? [String: Any])
        XCTAssertNotNil(result["permissions"])
        XCTAssertEqual(environment["KEEP_ME"] as? String, "yes")
        XCTAssertEqual(environment["ANTHROPIC_API_KEY"] as? String, "official-secret")
        XCTAssertNil(environment["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(environment["ANTHROPIC_BASE_URL"])
        XCTAssertNil(environment["ANTHROPIC_MODEL"])
        let backupNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.backups.path
        )
        XCTAssertEqual(backupNames.count, 2)
        for backupName in backupNames {
            let contents = try String(
                contentsOf: fixture.backups.appendingPathComponent(backupName),
                encoding: .utf8
            )
            XCTAssertFalse(contents.contains("old-key"))
            XCTAssertFalse(contents.contains("custom-secret"))
        }
    }

    func testDetectsExistingCustomConfiguration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeSettings([
            "env": [
                "ANTHROPIC_BASE_URL": "https://proxy.example.com",
                "ANTHROPIC_AUTH_TOKEN": "secret",
                "ANTHROPIC_DEFAULT_FABLE_MODEL": "mapped-fable",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "mapped-sonnet",
                "UNRELATED": "kept-out"
            ]
        ])

        let detected = try XCTUnwrap(fixture.manager.detectCurrentConfiguration())
        XCTAssertEqual(detected.profile, .custom)
        XCTAssertEqual(detected.configuration.credentialKind, .bearerToken)
        XCTAssertEqual(detected.credential, "secret")
        XCTAssertEqual(detected.configuration.environment, [
            "ANTHROPIC_DEFAULT_FABLE_MODEL": "mapped-fable",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "mapped-sonnet"
        ])
    }

    func testRejectsInvalidURL() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var configuration = AppConfiguration()
        configuration.custom.baseURL = "javascript:alert(1)"

        XCTAssertThrowsError(
            try fixture.manager.apply(
                profile: .custom,
                configuration: configuration,
                credential: nil
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.settings.path))
    }

    func testParsesAdvancedEnvironment() throws {
        let parsed = try AdvancedEnvironment.parse("""
        # model aliases
        ANTHROPIC_MODEL=claude-sonnet-custom
        SECOND=value=with=equals
        """)
        XCTAssertEqual(parsed["ANTHROPIC_MODEL"], "claude-sonnet-custom")
        XCTAssertEqual(parsed["SECOND"], "value=with=equals")

        XCTAssertThrowsError(
            try AdvancedEnvironment.parse("ANTHROPIC_API_KEY=do-not-store-here")
        )
    }

    func testDecodesLegacyConfigurationWithDesktopSyncDisabled() throws {
        let data = Data("""
        {
          "version": 1,
          "activeProfile": "custom",
          "official": {
            "baseURL": "",
            "credentialKind": "apiKey",
            "environment": {}
          },
          "custom": {
            "baseURL": "https://gateway.example.com",
            "credentialKind": "bearerToken",
            "environment": {}
          }
        }
        """.utf8)

        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
        XCTAssertEqual(configuration.activeProfile, .custom)
        XCTAssertFalse(configuration.claudeDesktopSyncEnabled)
    }
}

private final class Fixture {
    let root: URL
    let settings: URL
    let backups: URL
    let manager: ClaudeSettingsManager

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeSwitchTests-\(UUID().uuidString)", isDirectory: true)
        settings = root.appendingPathComponent(".claude/settings.json")
        backups = root.appendingPathComponent("backups")
        manager = ClaudeSettingsManager(settingsURL: settings, backupDirectoryURL: backups)
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeSettings(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: .prettyPrinted)
        try data.write(to: settings)
    }

    func readSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settings)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
