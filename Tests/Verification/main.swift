import ClaudeSwitchCore
import Foundation

enum VerificationError: Error {
    case failed(String)
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw VerificationError.failed(message)
    }
}

let fileManager = FileManager.default
let scratchBase = ProcessInfo.processInfo.environment["TMPDIR"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? fileManager.temporaryDirectory
let root = scratchBase
    .appendingPathComponent("ClaudeSwitchVerify-\(UUID().uuidString)", isDirectory: true)
let settings = root.appendingPathComponent(".claude/settings.json")
let backups = root.appendingPathComponent("backups")
try fileManager.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: root) }

let original: [String: Any] = [
    "theme": "dark",
    "permissions": ["allow": ["Read(*)"]],
    "env": [
        "KEEP_ME": "yes",
        "ANTHROPIC_API_KEY": "old-key",
        "ANTHROPIC_MODEL": "old-model"
    ]
]
try JSONSerialization.data(withJSONObject: original, options: .prettyPrinted).write(to: settings)

let manager = ClaudeSettingsManager(settingsURL: settings, backupDirectoryURL: backups)
var configuration = AppConfiguration()
configuration.custom = ProfileConfiguration(
    baseURL: "https://gateway.example.com/",
    credentialKind: .bearerToken,
    environment: [
        "ANTHROPIC_MODEL": "custom-sonnet",
        "ANTHROPIC_DEFAULT_FABLE_MODEL": "gateway-fable"
    ]
)

try manager.apply(profile: .custom, configuration: configuration, credential: "custom-secret")
var object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
var environment = object["env"] as! [String: Any]
try require(object["theme"] as? String == "dark", "unrelated root setting changed")
try require(environment["KEEP_ME"] as? String == "yes", "unrelated environment changed")
try require(environment["ANTHROPIC_BASE_URL"] as? String == "https://gateway.example.com", "base URL not applied")
try require(environment["ANTHROPIC_AUTH_TOKEN"] as? String == "custom-secret", "custom credential not applied")
try require(environment["ANTHROPIC_API_KEY"] == nil, "stale API key remains")
try require(
    environment["ANTHROPIC_DEFAULT_FABLE_MODEL"] as? String == "gateway-fable",
    "Fable model not applied"
)

try manager.apply(profile: .official, configuration: configuration, credential: "official-secret")
object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
environment = object["env"] as! [String: Any]
try require(environment["ANTHROPIC_API_KEY"] as? String == "official-secret", "official key not applied")
try require(environment["ANTHROPIC_BASE_URL"] == nil, "custom base URL remains")
try require(environment["ANTHROPIC_AUTH_TOKEN"] == nil, "custom token remains")
try require(environment["ANTHROPIC_MODEL"] == nil, "custom model remains")
try require(environment["ANTHROPIC_DEFAULT_FABLE_MODEL"] == nil, "custom Fable model remains")
try require(fileManager.fileExists(atPath: backups.path), "backup was not created")
for backupName in try fileManager.contentsOfDirectory(atPath: backups.path) {
    let backupText = try String(
        contentsOf: backups.appendingPathComponent(backupName),
        encoding: .utf8
    )
    try require(!backupText.contains("old-key"), "backup retained old API key")
    try require(!backupText.contains("custom-secret"), "backup retained custom token")
}

let parsed = try AdvancedEnvironment.parse("ANTHROPIC_MODEL=mapped\nSECOND=a=b")
try require(parsed["SECOND"] == "a=b", "advanced environment parser split values incorrectly")

let desktopRoot = root.appendingPathComponent("Desktop", isDirectory: true)
let officialDesktopRoot = desktopRoot.appendingPathComponent("Claude", isDirectory: true)
let thirdPartyDesktopRoot = desktopRoot.appendingPathComponent("Claude-3p", isDirectory: true)
let desktopManager = ClaudeDesktopSettingsManager(
    officialRootURL: officialDesktopRoot,
    thirdPartyRootURL: thirdPartyDesktopRoot,
    backupDirectoryURL: desktopRoot.appendingPathComponent("Backups", isDirectory: true)
)
try fileManager.createDirectory(
    at: desktopManager.configLibraryURL,
    withIntermediateDirectories: true
)

func writeJSON(_ value: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try JSONSerialization.data(withJSONObject: value, options: .prettyPrinted)
        .write(to: url, options: .atomic)
}

func readJSON(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw VerificationError.failed("expected JSON object at \(url.path)")
    }
    return value
}

let otherProfileID = "11111111-2222-4333-8444-555555555555"
let otherProfileURL = desktopManager.configLibraryURL
    .appendingPathComponent("\(otherProfileID).json")
try writeJSON([
    "deploymentMode": "1p",
    "oauth": ["tokenCache": "official-login"],
    "keep": "normal"
], to: desktopManager.officialConfigURL)
try writeJSON([
    "deploymentMode": "1p",
    "oauth": ["tokenCacheV2": "third-party-login"],
    "keep": "third-party"
], to: desktopManager.thirdPartyConfigURL)
try writeJSON([
    "appliedId": otherProfileID,
    "entries": [["id": otherProfileID, "name": "Other Switcher"]],
    "keep": true
], to: desktopManager.metaURL)
try writeJSON(["inferenceProvider": "other"], to: otherProfileURL)

var desktopProfile = ProfileConfiguration(
    baseURL: "https://gateway.example.com/",
    credentialKind: .apiKey,
    environment: [
        "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": "not-desktop-safe",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5 [1m]"
    ]
)
var rejectedUnsupportedModel = false
do {
    try desktopManager.apply(
        profile: .custom,
        configuration: desktopProfile,
        credential: "desktop-secret"
    )
} catch {
    rejectedUnsupportedModel = error.localizedDescription.contains("本地转换代理")
}
try require(
    rejectedUnsupportedModel,
    "unsupported Desktop model was not rejected clearly"
)
desktopProfile.environment = [
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-6"
]
try desktopManager.apply(
    profile: .custom,
    configuration: desktopProfile,
    credential: "desktop-secret"
)

var desktopNormal = try readJSON(desktopManager.officialConfigURL)
var desktopThirdParty = try readJSON(desktopManager.thirdPartyConfigURL)
var desktopGateway = try readJSON(desktopManager.managedProfileURL)
var desktopMeta = try readJSON(desktopManager.metaURL)
try require(desktopNormal["deploymentMode"] as? String == "3p", "normal Desktop mode not switched")
try require(
    (desktopNormal["oauth"] as? [String: Any])?["tokenCache"] as? String == "official-login",
    "official Desktop login was changed"
)
try require(
    desktopThirdParty["deploymentMode"] as? String == "3p",
    "third-party Desktop mode not switched"
)
try require(
    (desktopThirdParty["oauth"] as? [String: Any])?["tokenCacheV2"] as? String
        == "third-party-login",
    "third-party Desktop login state was changed"
)
try require(
    desktopGateway["inferenceGatewayAuthScheme"] as? String == "x-api-key",
    "Desktop auth scheme not applied"
)
try require(
    desktopGateway["inferenceModels"] as? [String]
        == ["claude-sonnet-4-6", "claude-opus-4-6"],
    "Desktop safe model list not applied"
)
try require(
    desktopMeta["appliedId"] as? String == ClaudeDesktopSettingsManager.managedProfileID,
    "Desktop managed profile not selected"
)

desktopProfile.baseURL = ""
try desktopManager.apply(
    profile: .official,
    configuration: desktopProfile,
    credential: nil
)
desktopNormal = try readJSON(desktopManager.officialConfigURL)
desktopThirdParty = try readJSON(desktopManager.thirdPartyConfigURL)
desktopMeta = try readJSON(desktopManager.metaURL)
try require(desktopNormal["deploymentMode"] as? String == "1p", "official Desktop mode not restored")
try require(
    desktopThirdParty["deploymentMode"] as? String == "1p",
    "third-party Desktop config not restored"
)
try require(
    !fileManager.fileExists(atPath: desktopManager.managedProfileURL.path),
    "managed Desktop profile was not removed"
)
try require(
    desktopMeta["appliedId"] as? String == otherProfileID,
    "other Desktop profile selection was not preserved"
)
try require(
    fileManager.fileExists(atPath: otherProfileURL.path),
    "other Desktop profile was removed"
)

let officialAccountID = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
let officialOrganizationID = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
let thirdPartyAccountID = "cccccccc-3333-4333-8333-cccccccccccc"
let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
let mirror = ClaudeDesktopSessionIndexMirror(
    officialRootURL: officialDesktopRoot,
    thirdPartyRootURL: thirdPartyDesktopRoot,
    projectsDirectoryURL: projectsRoot,
    importStateURL: root.appendingPathComponent("session-import.json", isDirectory: false)
)

func writeTranscript(_ cliSessionID: String) throws {
    let url = projectsRoot
        .appendingPathComponent("-Users-someone-repo", isDirectory: true)
        .appendingPathComponent("\(cliSessionID).jsonl", isDirectory: false)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("{}\n".utf8).write(to: url, options: .atomic)
}

let officialIndexDirectory = officialDesktopRoot
    .appendingPathComponent("claude-code-sessions", isDirectory: true)
    .appendingPathComponent(officialAccountID, isDirectory: true)
    .appendingPathComponent(officialOrganizationID, isDirectory: true)
try fileManager.createDirectory(at: officialIndexDirectory, withIntermediateDirectories: true)

func writeIndexRecord(
    _ sessionID: String,
    cliSessionID: String,
    archived: Bool = false
) throws {
    var record: [String: Any] = [
        "cliSessionId": cliSessionID,
        "title": "Session \(sessionID)",
        "cwd": "/Users/someone/repo"
    ]
    if archived {
        record["isArchived"] = true
    }
    try writeJSON(
        record,
        to: officialIndexDirectory
            .appendingPathComponent("local_\(sessionID).json", isDirectory: false)
    )
}

// Eligible: transcript present, not archived, not tombstoned.
try writeTranscript("cli-live-1")
try writeIndexRecord("keeper-1", cliSessionID: "cli-live-1")
try writeTranscript("cli-live-2")
try writeIndexRecord("keeper-2", cliSessionID: "cli-live-2")
// Ineligible: transcript missing, archived, tombstoned.
try writeIndexRecord("no-transcript", cliSessionID: "cli-gone")
try writeTranscript("cli-live-3")
try writeIndexRecord("archived", cliSessionID: "cli-live-3", archived: true)
try writeTranscript("cli-live-4")
try writeIndexRecord("tombstoned", cliSessionID: "cli-live-4")
try Data("{}\n".utf8).write(
    to: officialIndexDirectory
        .appendingPathComponent("deleted_tombstoned.json", isDirectory: false),
    options: .atomic
)

var mirrorFailedWithoutAccount = false
do {
    _ = try mirror.importOfficialSessions()
} catch let error as ClaudeDesktopSessionMirrorError {
    if case .missingThirdPartyAccount = error {
        mirrorFailedWithoutAccount = true
    }
}
try require(
    mirrorFailedWithoutAccount,
    "import should refuse to guess a third-party account directory"
)

try writeJSON(
    ["lastKnownAccountUuid": officialAccountID],
    to: officialDesktopRoot.appendingPathComponent("config.json", isDirectory: false)
)
try writeJSON(
    ["lastKnownAccountUuid": thirdPartyAccountID],
    to: thirdPartyDesktopRoot.appendingPathComponent("config.json", isDirectory: false)
)

let preview = try mirror.previewImportableSessions()
try require(preview.imported == 2, "preview should find exactly the two live sessions")
try require(preview.examined == 5, "preview should examine every index record")
try require(mirror.hasImportableSessions(), "importable sessions were not detected")

let firstImport = try mirror.importOfficialSessions()
try require(firstImport.imported == 2, "import did not copy both live sessions")
try require(firstImport.missingTranscript == 1, "missing transcript was not skipped")
try require(firstImport.archivedOrDeleted == 2, "archived and tombstoned were not skipped")

let mirrorDestination = thirdPartyDesktopRoot
    .appendingPathComponent("claude-code-sessions", isDirectory: true)
    .appendingPathComponent(thirdPartyAccountID, isDirectory: true)
    .appendingPathComponent(
        ClaudeDesktopSessionIndexMirror.placeholderOrganizationID,
        isDirectory: true
    )
for name in ["local_keeper-1.json", "local_keeper-2.json"] {
    try require(
        fileManager.fileExists(
            atPath: mirrorDestination.appendingPathComponent(name).path
        ),
        "expected imported record \(name)"
    )
}
for name in ["local_no-transcript.json", "local_archived.json", "local_tombstoned.json"] {
    try require(
        !fileManager.fileExists(
            atPath: mirrorDestination.appendingPathComponent(name).path
        ),
        "ineligible record \(name) was imported"
    )
}
let mirroredRecord = try readJSON(
    mirrorDestination.appendingPathComponent("local_keeper-1.json")
)
try require(
    mirroredRecord["cliSessionId"] as? String == "cli-live-1",
    "imported record lost its transcript link"
)

// A session that began in third-party mode must survive undo.
let nativeThirdPartyRecord = mirrorDestination
    .appendingPathComponent("local_native-3p.json", isDirectory: false)
try writeJSON(["cliSessionId": "cli-native"], to: nativeThirdPartyRecord)

let secondImport = try mirror.importOfficialSessions()
try require(secondImport.imported == 0, "import was not idempotent")
try require(secondImport.alreadyPresent == 2, "existing records were not detected")

try require(
    fileManager.fileExists(atPath: officialIndexDirectory.path),
    "import must not modify the first-party index"
)
try require(
    try fileManager.contentsOfDirectory(atPath: officialIndexDirectory.path).count == 6,
    "first-party index gained or lost files"
)

let removed = try mirror.removeImportedSessions()
try require(removed == 2, "undo did not remove both imported records")
try require(
    fileManager.fileExists(atPath: nativeThirdPartyRecord.path),
    "undo removed a session that started in third-party mode"
)
for name in ["local_keeper-1.json", "local_keeper-2.json"] {
    try require(
        !fileManager.fileExists(
            atPath: mirrorDestination.appendingPathComponent(name).path
        ),
        "undo left imported record \(name)"
    )
}
try require(
    try mirror.removeImportedSessions() == 0,
    "undo was not idempotent"
)
try require(
    try fileManager.contentsOfDirectory(atPath: projectsRoot.path).count == 1,
    "transcripts directory was modified"
)

let legacyConfiguration = try JSONDecoder().decode(
    AppConfiguration.self,
    from: Data("""
    {
      "version": 1,
      "official": {"baseURL":"","credentialKind":"apiKey","environment":{}},
      "custom": {"baseURL":"","credentialKind":"apiKey","environment":{}}
    }
    """.utf8)
)
try require(
    !legacyConfiguration.claudeDesktopSyncEnabled,
    "legacy configuration unexpectedly enabled Desktop sync"
)
try require(
    !legacyConfiguration.claudeDesktopSessionImportEnabled,
    "legacy configuration unexpectedly enabled session import"
)
try require(
    !AppConfiguration().claudeDesktopSessionImportEnabled,
    "session import must be opt-in"
)

print("ClaudeSwitch verification passed")
