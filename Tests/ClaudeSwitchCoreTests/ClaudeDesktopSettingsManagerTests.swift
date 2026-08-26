import Foundation
import XCTest
@testable import ClaudeSwitchCore

final class ClaudeDesktopSettingsManagerTests: XCTestCase {
    func testCustomModePreservesExistingConfigurationAndOtherProfiles() throws {
        let fixture = try DesktopFixture()
        defer { fixture.cleanup() }

        try fixture.write([
            "deploymentMode": "1p",
            "oauth": ["tokenCache": "official-token"],
            "keepNormal": true
        ], to: fixture.manager.officialConfigURL)
        try fixture.write([
            "deploymentMode": "1p",
            "oauth": ["tokenCacheV2": "third-party-token"],
            "keepThirdParty": true
        ], to: fixture.manager.thirdPartyConfigURL)
        try fixture.write([
            "appliedId": fixture.otherProfileID,
            "entries": [[
                "id": fixture.otherProfileID,
                "name": "Other Switcher"
            ]],
            "keepMeta": "yes"
        ], to: fixture.manager.metaURL)
        try fixture.write(
            ["inferenceProvider": "other"],
            to: fixture.otherProfileURL
        )

        try fixture.manager.apply(
            profile: .custom,
            configuration: ProfileConfiguration(
                baseURL: "  https://gateway.example.com/anthropic///  ",
                credentialKind: .apiKey,
                environment: [
                    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
                    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-6"
                ]
            ),
            credential: "  custom-key  "
        )

        let normal = try fixture.read(fixture.manager.officialConfigURL)
        XCTAssertEqual(normal["deploymentMode"] as? String, "3p")
        XCTAssertEqual(
            (normal["oauth"] as? [String: Any])?["tokenCache"] as? String,
            "official-token"
        )
        XCTAssertEqual(normal["keepNormal"] as? Bool, true)

        let thirdParty = try fixture.read(fixture.manager.thirdPartyConfigURL)
        XCTAssertEqual(thirdParty["deploymentMode"] as? String, "3p")
        XCTAssertEqual(
            (thirdParty["oauth"] as? [String: Any])?["tokenCacheV2"] as? String,
            "third-party-token"
        )
        XCTAssertEqual(thirdParty["keepThirdParty"] as? Bool, true)

        let profile = try fixture.read(fixture.manager.managedProfileURL)
        XCTAssertEqual(
            profile["inferenceGatewayBaseUrl"] as? String,
            "https://gateway.example.com/anthropic"
        )
        XCTAssertEqual(profile["inferenceGatewayApiKey"] as? String, "custom-key")
        XCTAssertEqual(profile["inferenceGatewayAuthScheme"] as? String, "x-api-key")
        XCTAssertEqual(profile["inferenceProvider"] as? String, "gateway")
        XCTAssertEqual(profile["disableDeploymentModeChooser"] as? Bool, true)
        XCTAssertNil(profile["coworkEgressAllowedHosts"])
        XCTAssertEqual(
            profile["inferenceModels"] as? [String],
            ["claude-sonnet-4-6", "claude-opus-4-6"]
        )

        let meta = try fixture.read(fixture.manager.metaURL)
        XCTAssertEqual(
            meta["appliedId"] as? String,
            ClaudeDesktopSettingsManager.managedProfileID
        )
        XCTAssertEqual(meta["keepMeta"] as? String, "yes")
        let entries = try XCTUnwrap(meta["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains {
            $0["id"] as? String == fixture.otherProfileID
                && $0["name"] as? String == "Other Switcher"
        })
        XCTAssertTrue(entries.contains {
            $0["id"] as? String == ClaudeDesktopSettingsManager.managedProfileID
                && $0["name"] as? String == ClaudeDesktopSettingsManager.managedProfileName
        })
        XCTAssertEqual(
            try fixture.read(fixture.otherProfileURL)["inferenceProvider"] as? String,
            "other"
        )

        let backupFiles = try fixture.backupFiles()
        XCTAssertTrue(backupFiles.contains { $0.hasSuffix("Claude/claude_desktop_config.json") })
        XCTAssertTrue(backupFiles.contains { $0.hasSuffix("Claude-3p/claude_desktop_config.json") })
        XCTAssertTrue(backupFiles.contains { $0.hasSuffix("Claude-3p/configLibrary/_meta.json") })
        XCTAssertFalse(backupFiles.contains {
            $0.hasSuffix("\(ClaudeDesktopSettingsManager.managedProfileID).json")
        })
    }

    func testBearerCredentialUsesBearerAuthScheme() throws {
        let fixture = try DesktopFixture()
        defer { fixture.cleanup() }

        try fixture.manager.apply(
            profile: .custom,
            configuration: ProfileConfiguration(
                baseURL: "https://gateway.example.com",
                credentialKind: .bearerToken
            ),
            credential: "bearer-secret"
        )

        let profile = try fixture.read(fixture.manager.managedProfileURL)
        XCTAssertEqual(profile["inferenceGatewayAuthScheme"] as? String, "bearer")
        XCTAssertEqual(profile["inferenceGatewayApiKey"] as? String, "bearer-secret")
    }

    func testCustomModeRejectsEmptyCredentialWithoutWritingConfiguration() throws {
        let fixture = try DesktopFixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(
            try fixture.manager.apply(
                profile: .custom,
                configuration: ProfileConfiguration(
                    baseURL: "https://gateway.example.com",
                    credentialKind: .apiKey
                ),
                credential: " \n "
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "同步到 Claude Desktop 需要访问密钥；若本地服务无需鉴权，请填写该服务支持的占位密钥"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.manager.officialConfigURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.manager.managedProfileURL.path)
        )
    }

    func testCustomModeRejectsUnsupportedDesktopModelWithoutWritingConfiguration() throws {
        let fixture = try DesktopFixture()
        defer { fixture.cleanup() }

        XCTAssertThrowsError(
            try fixture.manager.apply(
                profile: .custom,
                configuration: ProfileConfiguration(
                    baseURL: "https://gateway.example.com",
                    credentialKind: .apiKey,
                    environment: [
                        "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5.2",
                        "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5 [1m]"
                    ]
                ),
                credential: "secret"
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("glm-5.2"))
            XCTAssertTrue(error.localizedDescription.contains("本地转换代理"))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.manager.officialConfigURL.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.manager.managedProfileURL.path)
        )
    }

    func testOfficialModeRemovesOnlyManagedProfileAndPreservesLoginState() throws {
        let fixture = try DesktopFixture()
        defer { fixture.cleanup() }

        try fixture.write([
            "deploymentMode": "3p",
            "oauth": ["tokenCache": "official-token"],
            "keepNormal": 1
        ], to: fixture.manager.officialConfigURL)
        try fixture.write([
            "deploymentMode": "3p",
            "oauth": ["tokenCacheV2": "third-party-token"],
            "keepThirdParty": 2
        ], to: fixture.manager.thirdPartyConfigURL)
        try fixture.write([
            "inferenceProvider": "gateway",
            "inferenceGatewayApiKey": "managed-secret"
        ], to: fixture.manager.managedProfileURL)
        try fixture.write(
            ["inferenceProvider": "other", "secret": "other-secret"],
            to: fixture.otherProfileURL
        )
        try fixture.write([
            "appliedId": ClaudeDesktopSettingsManager.managedProfileID,
            "entries": [
                [
                    "id": fixture.otherProfileID,
                    "name": "Other Switcher"
                ],
                [
                    "id": ClaudeDesktopSettingsManager.managedProfileID,
                    "name": ClaudeDesktopSettingsManager.managedProfileName
                ]
            ],
            "keepMeta": true
        ], to: fixture.manager.metaURL)

        try fixture.manager.apply(
            profile: .official,
            configuration: ProfileConfiguration(),
            credential: nil
        )

        let normal = try fixture.read(fixture.manager.officialConfigURL)
        XCTAssertEqual(normal["deploymentMode"] as? String, "1p")
        XCTAssertEqual(
            (normal["oauth"] as? [String: Any])?["tokenCache"] as? String,
            "official-token"
        )
        XCTAssertEqual(normal["keepNormal"] as? Int, 1)

        let thirdParty = try fixture.read(fixture.manager.thirdPartyConfigURL)
        XCTAssertEqual(thirdParty["deploymentMode"] as? String, "1p")
        XCTAssertEqual(
            (thirdParty["oauth"] as? [String: Any])?["tokenCacheV2"] as? String,
            "third-party-token"
        )
        XCTAssertEqual(thirdParty["keepThirdParty"] as? Int, 2)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.manager.managedProfileURL.path)
        )
        XCTAssertEqual(
            try fixture.read(fixture.otherProfileURL)["secret"] as? String,
            "other-secret"
        )

        let meta = try fixture.read(fixture.manager.metaURL)
        XCTAssertEqual(meta["appliedId"] as? String, fixture.otherProfileID)
        XCTAssertEqual(meta["keepMeta"] as? Bool, true)
        let entries = try XCTUnwrap(meta["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?["id"] as? String, fixture.otherProfileID)
    }

    func testOfficialModeRestoresMostRecentOtherProfileSelection() throws {
        let fixture = try DesktopFixture()
        defer { fixture.cleanup() }
        let secondProfileID = "22222222-3333-4444-8555-666666666666"

        try fixture.write([
            "appliedId": secondProfileID,
            "entries": [
                ["id": fixture.otherProfileID, "name": "First Switcher"],
                ["id": secondProfileID, "name": "Second Switcher"]
            ]
        ], to: fixture.manager.metaURL)

        try fixture.manager.apply(
            profile: .custom,
            configuration: ProfileConfiguration(
                baseURL: "https://gateway.example.com",
                credentialKind: .apiKey
            ),
            credential: "secret"
        )
        var switchedMeta = try fixture.read(fixture.manager.metaURL)
        switchedMeta["appliedId"] = fixture.otherProfileID
        try fixture.write(switchedMeta, to: fixture.manager.metaURL)
        try fixture.manager.apply(
            profile: .custom,
            configuration: ProfileConfiguration(
                baseURL: "https://gateway.example.com",
                credentialKind: .apiKey
            ),
            credential: "secret"
        )
        try fixture.manager.apply(
            profile: .official,
            configuration: ProfileConfiguration(),
            credential: nil
        )

        let meta = try fixture.read(fixture.manager.metaURL)
        XCTAssertEqual(meta["appliedId"] as? String, fixture.otherProfileID)
        let entries = try XCTUnwrap(meta["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.compactMap { $0["id"] as? String }, [
            fixture.otherProfileID,
            secondProfileID
        ])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.manager.selectionStateURL.path)
        )
    }

    func testCustomModeRollsBackBothDeploymentFilesWhenProfileWriteFails() throws {
        let fixture = try DesktopFixture()
        defer { fixture.cleanup() }
        try fixture.write(
            ["deploymentMode": "1p", "keep": "normal"],
            to: fixture.manager.officialConfigURL
        )
        try fixture.write(
            ["deploymentMode": "1p", "keep": "third-party"],
            to: fixture.manager.thirdPartyConfigURL
        )
        let originalNormal = try Data(contentsOf: fixture.manager.officialConfigURL)
        let originalThirdParty = try Data(contentsOf: fixture.manager.thirdPartyConfigURL)
        try Data("not a directory".utf8).write(to: fixture.manager.configLibraryURL)

        XCTAssertThrowsError(
            try fixture.manager.apply(
                profile: .custom,
                configuration: ProfileConfiguration(
                    baseURL: "https://gateway.example.com",
                    credentialKind: .apiKey
                ),
                credential: "secret"
            )
        )

        XCTAssertEqual(
            try Data(contentsOf: fixture.manager.officialConfigURL),
            originalNormal
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.manager.thirdPartyConfigURL),
            originalThirdParty
        )
    }
}

private final class DesktopFixture {
    let root: URL
    let backups: URL
    let otherProfileID = "11111111-2222-4333-8444-555555555555"
    let manager: ClaudeDesktopSettingsManager

    var otherProfileURL: URL {
        manager.configLibraryURL.appendingPathComponent("\(otherProfileID).json")
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ClaudeDesktopSettingsManagerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        backups = root.appendingPathComponent("Backups", isDirectory: true)
        manager = ClaudeDesktopSettingsManager(
            officialRootURL: root.appendingPathComponent("Claude", isDirectory: true),
            thirdPartyRootURL: root.appendingPathComponent("Claude-3p", isDirectory: true),
            backupDirectoryURL: backups
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func backupFiles() throws -> [String] {
        guard FileManager.default.fileExists(atPath: backups.path) else {
            return []
        }
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: backups,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        return enumerator.compactMap { ($0 as? URL)?.path }
    }
}
