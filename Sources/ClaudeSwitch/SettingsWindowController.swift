import AppKit
import ClaudeSwitchCore

@MainActor
final class SettingsWindowController:
    NSWindowController,
    NSWindowDelegate,
    NSTextFieldDelegate,
    NSTextViewDelegate
{
    typealias SaveHandler = @MainActor (
        _ configuration: AppConfiguration,
        _ officialCredential: String,
        _ customCredential: String
    ) throws -> Void

    private static let fableModelKey = "ANTHROPIC_DEFAULT_FABLE_MODEL"
    private static let sonnetModelKey = "ANTHROPIC_DEFAULT_SONNET_MODEL"
    private static let opusModelKey = "ANTHROPIC_DEFAULT_OPUS_MODEL"
    private static let haikuModelKey = "ANTHROPIC_DEFAULT_HAIKU_MODEL"
    private static let dedicatedModelKeys: Set<String> = [
        fableModelKey,
        sonnetModelKey,
        opusModelKey,
        haikuModelKey
    ]

    private var configuration: AppConfiguration
    private var selectedProfile: ProfileID
    private var lastAppliedOfficialCredential = ""
    private var lastAppliedCustomCredential = ""
    private(set) var hasUnsavedChanges = false
    private let onSave: SaveHandler

    private let providerControl = NSSegmentedControl(
        labels: ["自定义 API", "Anthropic 官方"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let officialKeyField = NSSecureTextField()
    private let customURLField = NSTextField()
    private let credentialKindPopup = NSPopUpButton()
    private let credentialKindHint = NSTextField(wrappingLabelWithString: "")
    private let customKeyField = NSSecureTextField()
    private let desktopSyncCheckbox = NSButton(
        checkboxWithTitle: "同时切换 Claude Desktop，并自动重启",
        target: nil,
        action: nil
    )
    private let desktopSyncDetail = NSTextField(wrappingLabelWithString: "")
    private let desktopSessionImportCheckbox = NSButton(
        checkboxWithTitle: "把官方模式的会话列表导入第三方模式",
        target: nil,
        action: nil
    )
    private let desktopSessionImportDetail = NSTextField(wrappingLabelWithString: "")
    private let fableModelField = NSTextField()
    private let sonnetModelField = NSTextField()
    private let opusModelField = NSTextField()
    private let haikuModelField = NSTextField()
    private let advancedEnvironmentTextView = NSTextView()

    private let currentProviderValue = NSTextField(labelWithString: "—")
    private let currentURLValue = NSTextField(labelWithString: "—")
    private let currentAuthValue = NSTextField(labelWithString: "—")
    private let currentModelsValue = NSTextField(labelWithString: "—")
    private let currentKeyValue = NSTextField(labelWithString: "—")
    private let currentDesktopValue = NSTextField(labelWithString: "—")
    private let providerCardTitle = NSTextField(labelWithString: "")
    private let providerCardDescription = NSTextField(wrappingLabelWithString: "")
    private let statusBadgeLabel = NSTextField(labelWithString: "配置已读取")
    private let saveButton = NSButton()
    private let customFormStack = NSStackView()
    private let officialFormStack = NSStackView()

    init(
        configuration: AppConfiguration,
        officialCredential: String,
        customCredential: String,
        onSave: @escaping SaveHandler
    ) {
        self.configuration = configuration
        self.selectedProfile = configuration.activeProfile ?? .custom
        self.onSave = onSave

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude Switch"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 650)
        window.center()

        super.init(window: window)
        window.delegate = self
        configureFields(
            officialCredential: officialCredential,
            customCredential: customCredential
        )
        buildInterface(in: window)
        updateProviderEditor()
        refreshCurrentStatus(using: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reflectAppliedConfiguration(_ updated: AppConfiguration) {
        configuration = updated
        hasUnsavedChanges = false
        selectedProfile = updated.activeProfile ?? selectedProfile
        providerControl.selectedSegment = selectedProfile == .custom ? 0 : 1
        desktopSyncCheckbox.state = updated.claudeDesktopSyncEnabled ? .on : .off
        desktopSessionImportCheckbox.state =
            updated.claudeDesktopSessionImportEnabled ? .on : .off
        desktopSessionImportCheckbox.isEnabled = updated.claudeDesktopSyncEnabled
        updateProviderEditor()
        refreshCurrentStatus(using: updated)
        statusBadgeLabel.stringValue = "配置已应用"
    }

    func showStatus(_ message: String) {
        statusBadgeLabel.stringValue = message
    }

    private func configureFields(officialCredential: String, customCredential: String) {
        providerControl.target = self
        providerControl.action = #selector(providerChanged)
        providerControl.selectedSegment = selectedProfile == .custom ? 0 : 1
        providerControl.segmentStyle = .rounded
        providerControl.controlSize = .large

        officialKeyField.stringValue = officialCredential
        officialKeyField.placeholderString = "留空则使用 Claude 登录或订阅"
        officialKeyField.delegate = self
        lastAppliedOfficialCredential = normalizedCredential(officialCredential)

        customURLField.stringValue = configuration.custom.baseURL
        customURLField.placeholderString = "https://api.example.com"
        customURLField.delegate = self

        credentialKindPopup.addItems(withTitles: [
            "API Key（推荐，适合大多数服务）",
            "Bearer Token（服务商明确要求时）"
        ])
        credentialKindPopup.selectItem(at: configuration.custom.credentialKind == .apiKey ? 0 : 1)
        credentialKindPopup.target = self
        credentialKindPopup.action = #selector(credentialKindChanged)
        credentialKindHint.font = NSFont.systemFont(ofSize: 11)
        credentialKindHint.textColor = .secondaryLabelColor
        updateCredentialKindHint()

        customKeyField.stringValue = customCredential
        customKeyField.placeholderString = "输入自定义 API 密钥；本地无鉴权可留空"
        customKeyField.delegate = self
        lastAppliedCustomCredential = normalizedCredential(customCredential)

        desktopSyncCheckbox.state = configuration.claudeDesktopSyncEnabled ? .on : .off
        desktopSyncCheckbox.target = self
        desktopSyncCheckbox.action = #selector(desktopSyncChanged)
        desktopSyncDetail.font = NSFont.systemFont(ofSize: 11)
        desktopSyncDetail.textColor = .secondaryLabelColor
        desktopSyncDetail.maximumNumberOfLines = 3

        desktopSessionImportCheckbox.state =
            configuration.claudeDesktopSessionImportEnabled ? .on : .off
        desktopSessionImportCheckbox.target = self
        desktopSessionImportCheckbox.action = #selector(desktopSessionImportChanged)
        desktopSessionImportCheckbox.isEnabled = configuration.claudeDesktopSyncEnabled
        desktopSessionImportDetail.maximumNumberOfLines = 4

        let environment = configuration.custom.environment
        fableModelField.stringValue = environment[Self.fableModelKey] ?? ""
        fableModelField.placeholderString = "例如 claude-fable-5"
        fableModelField.delegate = self
        sonnetModelField.stringValue = environment[Self.sonnetModelKey] ?? ""
        sonnetModelField.placeholderString = "例如 claude-sonnet-4-6"
        sonnetModelField.delegate = self
        opusModelField.stringValue = environment[Self.opusModelKey] ?? ""
        opusModelField.placeholderString = "例如 claude-opus-4-6"
        opusModelField.delegate = self
        haikuModelField.stringValue = environment[Self.haikuModelKey] ?? ""
        haikuModelField.placeholderString = "例如 claude-haiku-4-5"
        haikuModelField.delegate = self

        let remainingEnvironment = environment.filter { !Self.dedicatedModelKeys.contains($0.key) }
        advancedEnvironmentTextView.string = AdvancedEnvironment.render(remainingEnvironment)
        advancedEnvironmentTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        advancedEnvironmentTextView.isRichText = false
        advancedEnvironmentTextView.isVerticallyResizable = true
        advancedEnvironmentTextView.isHorizontallyResizable = false
        advancedEnvironmentTextView.autoresizingMask = [.width]
        advancedEnvironmentTextView.minSize = NSSize(width: 0, height: 96)
        advancedEnvironmentTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        advancedEnvironmentTextView.textContainer?.widthTracksTextView = true
        advancedEnvironmentTextView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        advancedEnvironmentTextView.textContainerInset = NSSize(width: 7, height: 7)
        advancedEnvironmentTextView.isAutomaticQuoteSubstitutionEnabled = false
        advancedEnvironmentTextView.isAutomaticDashSubstitutionEnabled = false
        advancedEnvironmentTextView.delegate = self

        for valueLabel in [
            currentProviderValue,
            currentURLValue,
            currentAuthValue,
            currentModelsValue,
            currentKeyValue,
            currentDesktopValue
        ] {
            valueLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
            valueLabel.lineBreakMode = .byTruncatingMiddle
        }
    }

    private func buildInterface(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let footer = buildFooter()
        footer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(footer)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let contentStack = NSStackView(views: [
            buildHeader(),
            buildCurrentStatusSection(),
            buildConfigurationSection(),
            buildVersionFooter()
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 26
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        for arrangedView in contentStack.arrangedSubviews {
            arrangedView.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 76),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -28),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 26),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -18),
            contentStack.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -56)
        ])
    }

    private func buildHeader() -> NSView {
        let title = NSTextField(labelWithString: "Claude Switch")
        title.font = NSFont.systemFont(ofSize: 30, weight: .bold)

        let subtitle = NSTextField(
            labelWithString: "并行保留官方与自定义 API，一键切换 Claude Code；也可同步切换 Claude Desktop。"
        )
        subtitle.font = NSFont.systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 5

        let languageLabel = NSTextField(labelWithString: "语言")
        languageLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let languagePopup = NSPopUpButton()
        languagePopup.addItem(withTitle: "中文")
        languagePopup.controlSize = .regular
        let languageStack = NSStackView(views: [languageLabel, languagePopup])
        languageStack.orientation = .horizontal
        languageStack.alignment = .centerY
        languageStack.spacing = 8

        let badgeIcon = NSImageView(image: NSImage(
            systemSymbolName: "checkmark.circle",
            accessibilityDescription: "配置状态正常"
        ) ?? NSImage())
        badgeIcon.contentTintColor = .secondaryLabelColor
        statusBadgeLabel.textColor = .secondaryLabelColor
        statusBadgeLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let badgeStack = NSStackView(views: [badgeIcon, statusBadgeLabel])
        badgeStack.orientation = .horizontal
        badgeStack.alignment = .centerY
        badgeStack.spacing = 6
        let badge = CardView(backgroundColor: .controlBackgroundColor, cornerRadius: 8)
        badge.addPinnedSubview(badgeStack, insets: NSEdgeInsets(top: 6, left: 9, bottom: 6, right: 9))

        let rightStack = NSStackView(views: [badge, languageStack])
        rightStack.orientation = .vertical
        rightStack.alignment = .trailing
        rightStack.spacing = 10

        let spacer = NSView()
        let header = NSStackView(views: [titleStack, spacer, rightStack])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 16
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        titleStack.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        rightStack.setContentHuggingPriority(.required, for: .horizontal)
        return fullWidth(header)
    }

    private func buildCurrentStatusSection() -> NSView {
        let sectionTitle = makeSectionTitle("当前切换配置")
        let grid = NSGridView(views: [
            statusRow("Provider", currentProviderValue),
            statusRow("API 地址", currentURLValue),
            statusRow("鉴权方式", currentAuthValue),
            statusRow("模型映射", currentModelsValue),
            statusRow("API Key", currentKeyValue),
            statusRow("Claude Desktop", currentDesktopValue)
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 20
        grid.column(at: 0).width = 145
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill

        let card = CardView(backgroundColor: .controlBackgroundColor, cornerRadius: 10)
        card.addPinnedSubview(grid, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))

        let stack = NSStackView(views: [sectionTitle, card])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return fullWidth(stack)
    }

    private func buildConfigurationSection() -> NSView {
        let sectionTitle = makeSectionTitle("配置设置")

        let providerLabel = NSTextField(labelWithString: "选择 API 提供方")
        providerLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        providerLabel.translatesAutoresizingMaskIntoConstraints = false
        providerLabel.widthAnchor.constraint(equalToConstant: 145).isActive = true
        let providerRow = NSStackView(views: [providerLabel, providerControl])
        providerRow.orientation = .horizontal
        providerRow.alignment = .centerY
        providerRow.spacing = 14
        providerControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        providerControl.widthAnchor.constraint(
            equalTo: providerRow.widthAnchor,
            constant: -159
        ).isActive = true

        let providerHint = NSTextField(wrappingLabelWithString:
            "两套配置会同时保留。Claude Code 需要新开 CLI / IDE 会话；下方可选择是否让 Claude Desktop 一起切换。"
        )
        providerHint.font = NSFont.systemFont(ofSize: 12)
        providerHint.textColor = .secondaryLabelColor

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "shippingbox",
            accessibilityDescription: "API 提供方"
        ) ?? NSImage())
        icon.contentTintColor = .labelColor
        providerCardTitle.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        providerCardDescription.font = NSFont.systemFont(ofSize: 11)
        providerCardDescription.textColor = .secondaryLabelColor
        providerCardDescription.maximumNumberOfLines = 2

        let providerText = NSStackView(views: [providerCardTitle, providerCardDescription])
        providerText.orientation = .vertical
        providerText.alignment = .leading
        providerText.spacing = 3
        let providerSummary = NSStackView(views: [icon, providerText])
        providerSummary.orientation = .horizontal
        providerSummary.alignment = .centerY
        providerSummary.spacing = 10
        let providerCard = CardView(backgroundColor: .controlColor, cornerRadius: 9)
        providerCard.addPinnedSubview(
            providerSummary,
            insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        )

        configureFormStacks()

        let desktopScope = buildDesktopScope()

        let cardContent = NSStackView(views: [
            providerRow,
            providerHint,
            providerCard,
            desktopScope,
            customFormStack,
            officialFormStack
        ])
        cardContent.orientation = .vertical
        cardContent.alignment = .leading
        cardContent.spacing = 14
        providerRow.widthAnchor.constraint(equalTo: cardContent.widthAnchor).isActive = true
        providerHint.widthAnchor.constraint(equalTo: cardContent.widthAnchor).isActive = true
        providerCard.widthAnchor.constraint(equalTo: cardContent.widthAnchor).isActive = true
        desktopScope.widthAnchor.constraint(equalTo: cardContent.widthAnchor).isActive = true
        customFormStack.widthAnchor.constraint(equalTo: cardContent.widthAnchor).isActive = true
        officialFormStack.widthAnchor.constraint(equalTo: cardContent.widthAnchor).isActive = true

        let settingsCard = CardView(backgroundColor: .controlBackgroundColor, cornerRadius: 10)
        settingsCard.addPinnedSubview(
            cardContent,
            insets: NSEdgeInsets(top: 16, left: 16, bottom: 17, right: 16)
        )

        let stack = NSStackView(views: [sectionTitle, settingsCard])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        settingsCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return fullWidth(stack)
    }

    private func buildDesktopScope() -> NSView {
        let title = NSTextField(labelWithString: "切换范围")
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 145).isActive = true

        let claudeCode = NSTextField(labelWithString: "✓ Claude Code（CLI / IDE）")
        claudeCode.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        claudeCode.textColor = .secondaryLabelColor

        desktopSessionImportDetail.stringValue = "Desktop 的会话列表按模式分开存放，"
            + "勾选后切到自定义 API 时会把官方列表复制一份过去；对话正文本来就是共用的，不会被改动。"
            + "只做官方到第三方这一个方向，避免网关对话进入会同步到 Anthropic 的官方空间。"
        desktopSessionImportDetail.font = NSFont.systemFont(ofSize: 11)
        desktopSessionImportDetail.textColor = .secondaryLabelColor

        let controls = NSStackView(views: [
            claudeCode,
            desktopSyncCheckbox,
            desktopSyncDetail,
            desktopSessionImportCheckbox,
            desktopSessionImportDetail
        ])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 6
        controls.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [title, controls])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        controls.widthAnchor.constraint(
            equalTo: row.widthAnchor,
            constant: -159
        ).isActive = true

        let card = CardView(backgroundColor: .controlColor, cornerRadius: 9)
        card.addPinnedSubview(
            row,
            insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        )
        return card
    }

    private func configureFormStacks() {
        customFormStack.orientation = .vertical
        customFormStack.alignment = .leading
        customFormStack.spacing = 11

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = advancedEnvironmentTextView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let advancedHint = NSTextField(wrappingLabelWithString:
            "选填，每行 KEY=VALUE。已有的模型显示名称等扩展字段会自动保留。"
        )
        advancedHint.font = NSFont.systemFont(ofSize: 11)
        advancedHint.textColor = .tertiaryLabelColor

        let desktopNotice = makeNotice(
            icon: "desktopcomputer",
            title: "Claude Desktop 直连要求",
            detail: "服务需支持 Anthropic Messages API（/v1/messages），模型路由名需为 claude-sonnet-* / claude-opus-* / claude-haiku-* / claude-fable-*。OpenAI 接口或 GLM 等任意模型需要本地转换代理，本版暂未提供。"
        )

        for view in [
            desktopNotice,
            formRow(label: "自定义 API 地址", control: customURLField),
            formRow(label: "密钥发送方式", control: credentialKindPopup),
            indented(credentialKindHint),
            formRow(label: "访问密钥", control: customKeyField),
            formRow(label: "Fable 模型 ID", control: fableModelField),
            formRow(label: "Sonnet 模型 ID", control: sonnetModelField),
            formRow(label: "Opus 模型 ID", control: opusModelField),
            formRow(label: "Haiku 模型 ID", control: haikuModelField),
            formRow(label: "高级环境变量", control: scrollView),
            indented(advancedHint)
        ] {
            customFormStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: customFormStack.widthAnchor).isActive = true
        }

        officialFormStack.orientation = .vertical
        officialFormStack.alignment = .leading
        officialFormStack.spacing = 12
        let officialHint = NSTextField(wrappingLabelWithString:
            "API Key 留空时使用 Claude Code 已登录的 Pro、Max、Team 或 Enterprise 订阅；填写后将优先使用 Anthropic API 计费。"
        )
        officialHint.font = NSFont.systemFont(ofSize: 12)
        officialHint.textColor = .secondaryLabelColor
        let historyNotice = makeNotice(
            icon: "clock.arrow.circlepath",
            title: "Claude Code 记录不受切换影响",
            detail: "CLI / IDE 始终使用原来的 ~/.claude，会话、项目权限、插件和 MCP 配置都会保留。"
        )

        for view in [
            formRow(label: "官方 API Key", control: officialKeyField),
            indented(officialHint),
            historyNotice
        ] {
            officialFormStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: officialFormStack.widthAnchor).isActive = true
        }
    }

    private func buildFooter() -> NSView {
        saveButton.title = "保存配置并切换"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.isBordered = false
        saveButton.controlSize = .large
        saveButton.wantsLayer = true
        saveButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        saveButton.layer?.cornerRadius = 8
        saveButton.attributedTitle = NSAttributedString(
            string: saveButton.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        footer.wantsLayer = true
        footer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(separator)
        footer.addSubview(saveButton)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            separator.topAnchor.constraint(equalTo: footer.topAnchor),
            saveButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 28),
            saveButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -28),
            saveButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor, constant: 1),
            saveButton.heightAnchor.constraint(equalToConstant: 42)
        ])
        return footer
    }

    private func buildVersionFooter() -> NSView {
        let label = NSTextField(
            labelWithString: "v1.3.0  ·  Claude Code：~/.claude  ·  Claude Desktop：独立官方 / 第三方空间"
        )
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .tertiaryLabelColor
        label.alignment = .right
        return fullWidth(label)
    }

    private func makeNotice(icon: String, title: String, detail: String) -> NSView {
        let image = NSImageView(image: NSImage(
            systemSymbolName: icon,
            accessibilityDescription: title
        ) ?? NSImage())
        image.contentTintColor = .secondaryLabelColor
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let stack = NSStackView(views: [image, text])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        let card = CardView(backgroundColor: .controlColor, cornerRadius: 8)
        card.addPinnedSubview(stack, insets: NSEdgeInsets(top: 11, left: 13, bottom: 11, right: 13))
        return card
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func statusRow(_ label: String, _ value: NSTextField) -> [NSView] {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.systemFont(ofSize: 13)
        labelField.textColor = .secondaryLabelColor
        return [labelField, value]
    }

    private func formRow(label: String, control: NSView) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: 145).isActive = true

        control.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [labelField, control])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func indented(_ view: NSView) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: 159).isActive = true
        let row = NSStackView(views: [spacer, view])
        row.orientation = .horizontal
        row.alignment = .top
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func fullWidth(_ view: NSView) -> NSView {
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    @objc private func providerChanged() {
        selectedProfile = providerControl.selectedSegment == 0 ? .custom : .official
        updateProviderEditor()
        markUnsaved()
    }

    @objc private func credentialKindChanged() {
        updateCredentialKindHint()
        markUnsaved()
    }

    @objc private func desktopSyncChanged() {
        let syncEnabled = desktopSyncCheckbox.state == .on
        desktopSessionImportCheckbox.isEnabled = syncEnabled
        if !syncEnabled {
            desktopSessionImportCheckbox.state = .off
        }
        updateProviderEditor()
        markUnsaved()
    }

    @objc private func desktopSessionImportChanged() {
        markUnsaved()
    }

    func controlTextDidChange(_ notification: Notification) {
        markUnsaved()
    }

    func textDidChange(_ notification: Notification) {
        markUnsaved()
    }

    private func markUnsaved() {
        hasUnsavedChanges = true
        statusBadgeLabel.stringValue = "有未保存更改"
    }

    private func updateCredentialKindHint() {
        if credentialKindPopup.indexOfSelectedItem == 0 {
            credentialKindHint.stringValue =
                "不知道怎么选时就用这一项。服务商教程写了 API Key 或 x-api-key，也选择这一项。"
        } else {
            credentialKindHint.stringValue =
                "仅当服务商教程明确写了 Bearer、Authorization Token 或 ANTHROPIC_AUTH_TOKEN 时选择。"
        }
    }

    private func updateProviderEditor() {
        let isCustom = selectedProfile == .custom
        customFormStack.isHidden = !isCustom
        officialFormStack.isHidden = isCustom
        if isCustom {
            providerCardTitle.stringValue = "自定义 / 第三方 API"
            providerCardDescription.stringValue =
                "配置 Anthropic 兼容的代理、网关或第三方服务。按服务商教程选择密钥发送方式即可。"
        } else {
            providerCardTitle.stringValue = "Anthropic 官方 API"
            providerCardDescription.stringValue =
                "使用 Claude Code 登录订阅，或配置 console.anthropic.com 创建的官方 API Key。"
        }
        let desktopEnabled = desktopSyncCheckbox.state == .on
        customKeyField.placeholderString = desktopEnabled && isCustom
            ? "Desktop 同步需要密钥；无鉴权服务请填写占位值"
            : "输入自定义 API 密钥；本地无鉴权可留空"
        if desktopEnabled {
            desktopSyncDetail.stringValue = isCustom
                ? "会进入独立的第三方空间；密钥按 Desktop 要求写入仅当前用户可读的本地配置。官方登录和历史不删除，两边记录不合并。"
                : "会切回 Desktop 原来的官方空间。原有登录、订阅和官方历史继续保留。"
        } else {
            desktopSyncDetail.stringValue = "关闭时只切换 Claude Code，不修改 Claude Desktop。"
        }
        if desktopEnabled {
            saveButton.title = isCustom
                ? "保存、切换到自定义 API 并重启 Claude Desktop"
                : "保存、切回 Anthropic 官方并重启 Claude Desktop"
        } else {
            saveButton.title = isCustom
                ? "保存并将 Claude Code 切换到自定义 API"
                : "保存并将 Claude Code 切换到 Anthropic 官方"
        }
        saveButton.attributedTitle = NSAttributedString(
            string: saveButton.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
    }

    private func refreshCurrentStatus(using current: AppConfiguration) {
        let active = current.activeProfile
        currentProviderValue.stringValue = active?.displayName ?? "尚未选择"

        guard let active else {
            currentURLValue.stringValue = "—"
            currentAuthValue.stringValue = "—"
            currentModelsValue.stringValue = "—"
            currentKeyValue.stringValue = "—"
            currentDesktopValue.stringValue = current.claudeDesktopSyncEnabled
                ? "跟随 Provider（尚未选择）"
                : "不跟随（保持当前状态）"
            return
        }

        let profile = current[active]
        currentURLValue.stringValue = active == .official
            ? "https://api.anthropic.com（默认）"
            : (profile.baseURL.isEmpty ? "未配置" : profile.baseURL)
        currentAuthValue.stringValue = active == .official
            ? "Claude 登录 / API Key"
            : (profile.credentialKind == .apiKey ? "API Key" : "Bearer Token")
        currentModelsValue.stringValue = modelSummary(profile.environment)
        let credential = active == .official
            ? lastAppliedOfficialCredential
            : lastAppliedCustomCredential
        currentKeyValue.stringValue = maskedCredential(
            credential,
            emptyText: active == .official ? "未设置（使用 Claude 登录）" : "未设置"
        )
        if current.claudeDesktopSyncEnabled {
            currentDesktopValue.stringValue = active == .custom
                ? "第三方 API（独立空间）"
                : "Anthropic 官方"
        } else {
            currentDesktopValue.stringValue = "保持当前设置"
        }
    }

    private func modelSummary(_ environment: [String: String]) -> String {
        let models: [(String, String)] = [
            ("Fable", environment[Self.fableModelKey] ?? ""),
            ("Sonnet", environment[Self.sonnetModelKey] ?? ""),
            ("Opus", environment[Self.opusModelKey] ?? ""),
            ("Haiku", environment[Self.haikuModelKey] ?? "")
        ]
        let configured = models.compactMap { name, value in
            value.isEmpty ? nil : "\(name): \(value)"
        }
        return configured.isEmpty ? "Claude 默认模型" : configured.joined(separator: "  ·  ")
    }

    private func maskedCredential(_ credential: String, emptyText: String) -> String {
        guard !credential.isEmpty else { return emptyText }
        guard credential.count > 8 else { return String(repeating: "•", count: credential.count) }
        return "\(credential.prefix(3))••••\(credential.suffix(4))"
    }

    @objc private func save() {
        do {
            var updated = configuration
            updated.version = max(updated.version, 2)
            updated.activeProfile = selectedProfile
            updated.claudeDesktopSyncEnabled = desktopSyncCheckbox.state == .on
            updated.claudeDesktopSessionImportEnabled =
                updated.claudeDesktopSyncEnabled
                    && desktopSessionImportCheckbox.state == .on
            updated.custom.baseURL = customURLField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            updated.custom.credentialKind = credentialKindPopup.indexOfSelectedItem == 0
                ? .apiKey
                : .bearerToken

            var environment = try AdvancedEnvironment.parse(advancedEnvironmentTextView.string)
            setEnvironmentValue(fableModelField.stringValue, key: Self.fableModelKey, in: &environment)
            setEnvironmentValue(sonnetModelField.stringValue, key: Self.sonnetModelKey, in: &environment)
            setEnvironmentValue(opusModelField.stringValue, key: Self.opusModelKey, in: &environment)
            setEnvironmentValue(haikuModelField.stringValue, key: Self.haikuModelKey, in: &environment)
            updated.custom.environment = environment

            try onSave(updated, officialKeyField.stringValue, customKeyField.stringValue)
            configuration = updated
            lastAppliedOfficialCredential = normalizedCredential(officialKeyField.stringValue)
            lastAppliedCustomCredential = normalizedCredential(customKeyField.stringValue)
            hasUnsavedChanges = false
            refreshCurrentStatus(using: updated)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "配置无法保存"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            if let window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    private func setEnvironmentValue(
        _ rawValue: String,
        key: String,
        in environment: inout [String: String]
    ) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            environment.removeValue(forKey: key)
        } else {
            environment[key] = value
        }
    }

    private func normalizedCredential(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class CardView: NSView {
    init(backgroundColor: NSColor, cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func addPinnedSubview(_ view: NSView, insets: NSEdgeInsets) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom)
        ])
    }
}
