import AppKit
import ClaudeSwitchCore

@main
enum ClaudeSwitchMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        _ = delegate
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let claudeDesktopBundleIdentifier = "com.anthropic.claudefordesktop"

    private struct StoredCredentials {
        var official: String?
        var custom: String?

        subscript(profile: ProfileID) -> String? {
            switch profile {
            case .official: official
            case .custom: custom
            }
        }
    }

    private struct ManagedFileSnapshot {
        let url: URL
        let data: Data?
        let permissions: Int?
    }

    private enum SwitchCommitError: LocalizedError {
        case rollbackFailed(original: String, rollback: [String])

        var errorDescription: String? {
            switch self {
            case let .rollbackFailed(original, rollback):
                "切换失败：\(original)；恢复原配置时又遇到：\(rollback.joined(separator: "；"))"
            }
        }
    }

    private let configurationStore = ConfigurationStore()
    private let settingsManager = ClaudeSettingsManager()
    private let desktopSettingsManager = ClaudeDesktopSettingsManager()
    private let desktopSessionIndexMirror = ClaudeDesktopSessionIndexMirror()
    private let keychainStore = KeychainStore()
    private var configuration = AppConfiguration()
    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        do {
            try loadOrBootstrapConfiguration()
            installStatusItem()
            openSettings()
        } catch {
            installStatusItem()
            showError(title: "Claude Switch 启动失败", error: error)
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        NSApplication.shared.mainMenu = mainMenu

        let applicationName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Claude Switch"

        let applicationMenuItem = NSMenuItem()
        mainMenu.addItem(applicationMenuItem)
        let applicationMenu = NSMenu(title: applicationName)
        applicationMenuItem.submenu = applicationMenu

        let aboutItem = NSMenuItem(
            title: "关于 \(applicationName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApplication.shared
        applicationMenu.addItem(aboutItem)
        applicationMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "隐藏 \(applicationName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApplication.shared
        applicationMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: "隐藏其他应用",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = NSApplication.shared
        applicationMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: "全部显示",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAllItem.target = NSApplication.shared
        applicationMenu.addItem(showAllItem)
        applicationMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 \(applicationName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        applicationMenu.addItem(quitItem)

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")

        let pastePlainItem = NSMenuItem(
            title: "粘贴并匹配样式",
            action: #selector(NSTextView.pasteAsPlainText(_:)),
            keyEquivalent: "v"
        )
        pastePlainItem.keyEquivalentModifierMask = [.command, .option, .shift]
        editMenu.addItem(pastePlainItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApplication.shared.windowsMenu = windowMenu
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func loadOrBootstrapConfiguration() throws {
        if let saved = try configurationStore.load() {
            configuration = saved
            return
        }

        var initial = AppConfiguration()
        if let detected = try settingsManager.detectCurrentConfiguration() {
            initial.activeProfile = detected.profile
            initial[detected.profile] = detected.configuration
            if let credential = detected.credential {
                try keychainStore.setCredential(credential, for: detected.profile)
            }
        }
        configuration = initial
        try configurationStore.save(initial)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath.circle.fill",
                accessibilityDescription: "Claude API 切换"
            )
            button.imagePosition = .imageLeading
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let activeName = configuration.activeProfile?.displayName ?? "尚未选择"

        let status = NSMenuItem(title: "当前：\(activeName)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let official = NSMenuItem(
            title: "切换到官方 API",
            action: #selector(switchToOfficial),
            keyEquivalent: "1"
        )
        official.target = self
        official.state = configuration.activeProfile == .official ? .on : .off
        menu.addItem(official)

        let custom = NSMenuItem(
            title: "切换到自定义 API",
            action: #selector(switchToCustom),
            keyEquivalent: "2"
        )
        custom.target = self
        custom.state = configuration.activeProfile == .custom ? .on : .off
        menu.addItem(custom)

        menu.addItem(.separator())
        let effectTitle = configuration.claudeDesktopSyncEnabled
            ? "同时切换 Claude Desktop（自动重启）"
            : "只切换新开的 Claude Code 会话"
        let effectNotice = NSMenuItem(title: effectTitle, action: nil, keyEquivalent: "")
        effectNotice.isEnabled = false
        menu.addItem(effectNotice)

        let settings = NSMenuItem(
            title: "打开主窗口…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let openConfig = NSMenuItem(
            title: "打开 Claude 配置目录",
            action: #selector(openClaudeDirectory),
            keyEquivalent: ""
        )
        openConfig.target = self
        menu.addItem(openConfig)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "退出 Claude Switch",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
        statusItem?.button?.toolTip = "Claude Switch · \(activeName)"
    }

    @objc private func switchToOfficial() {
        switchProfile(.official)
    }

    @objc private func switchToCustom() {
        let customURL = configuration.custom.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !customURL.isEmpty else {
            openSettings()
            return
        }
        switchProfile(.custom)
    }

    private func switchProfile(_ profile: ProfileID) {
        if settingsWindowController?.hasUnsavedChanges == true {
            openSettings()
            settingsWindowController?.showStatus("主窗口有未保存更改，请先点击底部保存")
            NSSound.beep()
            return
        }
        do {
            var updated = configuration
            updated.activeProfile = profile
            try commit(updated)
            configuration = updated
            rebuildMenu()
            settingsWindowController?.reflectAppliedConfiguration(configuration)
            showAppliedStatus(for: profile)
            restartClaudeDesktopIfNeeded()
        } catch {
            showError(title: "无法切换到\(profile.displayName)", error: error)
        }
    }

    @objc private func openSettings() {
        if let controller = settingsWindowController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        do {
            let officialCredential = try keychainStore.credential(for: .official) ?? ""
            let customCredential = try keychainStore.credential(for: .custom) ?? ""
            let controller = SettingsWindowController(
                configuration: configuration,
                officialCredential: officialCredential,
                customCredential: customCredential
            ) { [weak self] updated, officialKey, customKey in
                guard let self else { return }
                if !updated.custom.baseURL.isEmpty {
                    try self.settingsManager.validateCustomBaseURL(updated.custom.baseURL)
                }
                let credentials = StoredCredentials(
                    official: self.normalizedCredential(officialKey),
                    custom: self.normalizedCredential(customKey)
                )
                try self.commit(updated, replacingCredentialsWith: credentials)
                self.configuration = updated
                self.rebuildMenu()
                self.settingsWindowController?.reflectAppliedConfiguration(updated)
                if let active = updated.activeProfile {
                    self.showAppliedStatus(for: active)
                    self.restartClaudeDesktopIfNeeded()
                }
            }
            settingsWindowController = controller
            controller.showWindow(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } catch {
            showError(title: "无法打开设置", error: error)
        }
    }

    @objc private func openClaudeDirectory() {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func showError(title: String, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showAppliedStatus(for profile: ProfileID) {
        let message: String
        if configuration.claudeDesktopSyncEnabled {
            message = profile == .custom
                ? "已切换 Claude Code 和 Desktop 到自定义 API"
                : "已切换 Claude Code 和 Desktop 到 Anthropic 官方"
        } else {
            message = profile == .custom
                ? "Claude Code 已切换到自定义 API"
                : "Claude Code 已切换到 Anthropic 官方"
        }
        settingsWindowController?.showStatus(message)
    }

    private func apply(
        profile: ProfileID,
        configuration: AppConfiguration,
        credential: String?
    ) throws {
        if configuration.claudeDesktopSyncEnabled {
            try desktopSettingsManager.apply(
                profile: profile,
                configuration: configuration[profile],
                credential: credential
            )
        }
        try settingsManager.apply(
            profile: profile,
            configuration: configuration,
            credential: credential
        )
        mirrorDesktopSessionIndexIfNeeded(for: profile, configuration: configuration)
    }

    /// Copies the first-party Desktop session index into the third-party space
    /// so the sidebar keeps listing earlier conversations.
    ///
    /// Only runs first-party to third-party: the first-party space syncs to
    /// Anthropic via `pending-uploads`, so gateway conversations must not be
    /// written into it. A failure here leaves the switch itself intact, since
    /// the index is a convenience and every transcript stays in
    /// `~/.claude/projects` either way.
    private func mirrorDesktopSessionIndexIfNeeded(
        for profile: ProfileID,
        configuration: AppConfiguration
    ) {
        guard configuration.claudeDesktopSyncEnabled,
              configuration.claudeDesktopSessionImportEnabled,
              profile == .custom else {
            return
        }
        do {
            let summary = try desktopSessionIndexMirror.importOfficialSessions()
            guard summary.imported > 0 || summary.missingTranscript > 0 else {
                return
            }
            var message = "已导入 \(summary.imported) 条官方会话到第三方模式列表"
            if summary.missingTranscript > 0 {
                message += "；\(summary.missingTranscript) 条因正文已不存在被跳过"
            }
            settingsWindowController?.showStatus(message)
        } catch {
            settingsWindowController?.showStatus(
                "配置已切换；导入官方会话列表失败：\(error.localizedDescription)"
            )
        }
    }

    private func commit(
        _ updated: AppConfiguration,
        replacingCredentialsWith replacement: StoredCredentials? = nil
    ) throws {
        let originalCredentials: StoredCredentials
        if replacement != nil {
            originalCredentials = StoredCredentials(
                official: try keychainStore.credential(for: .official),
                custom: try keychainStore.credential(for: .custom)
            )
        } else {
            switch updated.activeProfile {
            case .official:
                originalCredentials = StoredCredentials(
                    official: try keychainStore.credential(for: .official),
                    custom: nil
                )
            case .custom:
                originalCredentials = StoredCredentials(
                    official: nil,
                    custom: try keychainStore.credential(for: .custom)
                )
            case nil:
                originalCredentials = StoredCredentials(official: nil, custom: nil)
            }
        }
        let effectiveCredentials = replacement ?? originalCredentials
        let snapshots = try managedFileURLs(for: updated).map(captureSnapshot)

        do {
            if let active = updated.activeProfile {
                try apply(
                    profile: active,
                    configuration: updated,
                    credential: normalizedCredential(effectiveCredentials[active])
                )
            }
            try configurationStore.save(updated)
            if let replacement {
                try keychainStore.setCredential(replacement.official, for: .official)
                try keychainStore.setCredential(replacement.custom, for: .custom)
            }
        } catch {
            var rollbackErrors = restore(snapshots)
            if replacement != nil {
                do {
                    try keychainStore.setCredential(
                        originalCredentials.official,
                        for: .official
                    )
                } catch {
                    rollbackErrors.append("官方密钥：\(error.localizedDescription)")
                }
                do {
                    try keychainStore.setCredential(
                        originalCredentials.custom,
                        for: .custom
                    )
                } catch {
                    rollbackErrors.append("自定义密钥：\(error.localizedDescription)")
                }
            }
            if !rollbackErrors.isEmpty {
                throw SwitchCommitError.rollbackFailed(
                    original: error.localizedDescription,
                    rollback: rollbackErrors
                )
            }
            throw error
        }
    }

    private func managedFileURLs(for configuration: AppConfiguration) -> [URL] {
        var urls = [
            settingsManager.settingsURL,
            configurationStore.fileURL
        ]
        if configuration.claudeDesktopSyncEnabled {
            urls.append(contentsOf: [
                desktopSettingsManager.officialConfigURL,
                desktopSettingsManager.thirdPartyConfigURL,
                desktopSettingsManager.managedProfileURL,
                desktopSettingsManager.metaURL,
                desktopSettingsManager.selectionStateURL
            ])
        }
        return urls
    }

    private func captureSnapshot(at url: URL) throws -> ManagedFileSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ManagedFileSnapshot(url: url, data: nil, permissions: nil)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        return ManagedFileSnapshot(
            url: url,
            data: try Data(contentsOf: url),
            permissions: permissions
        )
    }

    private func restore(_ snapshots: [ManagedFileSnapshot]) -> [String] {
        var errors: [String] = []
        for snapshot in snapshots {
            do {
                if let data = snapshot.data {
                    try FileManager.default.createDirectory(
                        at: snapshot.url.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    try data.write(to: snapshot.url, options: .atomic)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: snapshot.permissions ?? 0o600],
                        ofItemAtPath: snapshot.url.path
                    )
                } else if FileManager.default.fileExists(atPath: snapshot.url.path) {
                    try FileManager.default.removeItem(at: snapshot.url)
                }
            } catch {
                errors.append(
                    "\(snapshot.url.lastPathComponent)：\(error.localizedDescription)"
                )
            }
        }
        return errors
    }

    private func normalizedCredential(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func restartClaudeDesktopIfNeeded() {
        guard configuration.claudeDesktopSyncEnabled else {
            return
        }

        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.claudeDesktopBundleIdentifier
        )
        guard !applications.isEmpty else {
            settingsWindowController?.showStatus(
                "配置已应用；Claude Desktop 下次启动时生效"
            )
            return
        }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.claudeDesktopBundleIdentifier
        ) else {
            settingsWindowController?.showStatus(
                "配置已应用；请手动重启 Claude Desktop"
            )
            return
        }

        settingsWindowController?.showStatus("配置已应用，正在重启 Claude Desktop…")
        for application in applications {
            _ = application.terminate()
        }
        waitForClaudeDesktopToQuit(
            applications,
            applicationURL: applicationURL,
            remainingAttempts: 25
        )
    }

    private func waitForClaudeDesktopToQuit(
        _ applications: [NSRunningApplication],
        applicationURL: URL,
        remainingAttempts: Int
    ) {
        if applications.allSatisfy(\.isTerminated) {
            let openConfiguration = NSWorkspace.OpenConfiguration()
            openConfiguration.activates = true
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: openConfiguration
            ) { [weak self] _, error in
                Task { @MainActor in
                    if let error {
                        self?.settingsWindowController?.showStatus(
                            "配置已应用，但重启失败：\(error.localizedDescription)"
                        )
                    } else {
                        self?.settingsWindowController?.showStatus(
                            "Claude Desktop 已按新配置重启"
                        )
                    }
                }
            }
            return
        }

        guard remainingAttempts > 0 else {
            settingsWindowController?.showStatus(
                "配置已应用；Claude Desktop 未能退出，请手动重启"
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForClaudeDesktopToQuit(
                applications,
                applicationURL: applicationURL,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }
}
