# Claude Switch

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](#环境要求)

[English](README.md) · **简体中文**

macOS 原生窗口应用，一键切换 Claude Code CLI / IDE 使用的官方 API 与自定义
API/网关，并可选择让新版 Claude Desktop 同步切换。切换不会丢失对话记录。

主窗口提供当前状态、Provider、鉴权、模型映射和切换范围；菜单栏保留快速切换入口。

## 功能

- 主窗口可视化配置，菜单栏一键切换「官方 API」和「自定义 API」
- 保存或切换后，新开的 Claude Code CLI 和 IDE 会话读取最新配置
- 可选同步切换 Claude Desktop 的官方模式与第三方 API 模式，并自动重启 Desktop
- 切换 Desktop 时保留原有官方登录和官方记录；第三方模式使用独立的本地记录空间
- 可选把官方模式的会话列表导入第三方模式，让 Desktop 侧边栏继续显示切换前的对话
  （默认关闭，单向导入）
- 支持 API Key 与 Bearer Token 两种密钥发送方式；界面会提示普通用户如何选择
- 支持 Fable、Opus、Sonnet、Haiku 自定义模型映射及高级环境变量
- 首次启动自动导入当前 `~/.claude/settings.json` 中的 API 配置
- API 密钥主副本保存在 macOS 钥匙串；生效时按 Claude 要求同步到仅当前用户可读的本地配置
- 每次修改前备份原始 Claude 设置
- 不修改 `CLAUDE_CONFIG_DIR`、`~/.claude/projects`、`~/.claude.json` 或任何会话文件

## 环境要求

- macOS 13 或更高版本
- Apple Command Line Tools（运行 `xcode-select --install` 安装）

## 安装

从 [最新 Release](../../releases/latest) 下载 `.zip`，解压后把
`Claude Switch.app` 拖进 `~/Applications` 或 `/Applications`。

应用使用 ad-hoc 签名、未经公证，首次打开会被 Gatekeeper 拦截。右键点击应用选择
「打开」并确认即可；也可以手动清除隔离标记：

```bash
xattr -dr com.apple.quarantine "$HOME/Applications/Claude Switch.app"
```

### 从源码构建

```bash
./scripts/install.sh
```

应用会安装到 `~/Applications/Claude Switch.app` 并自动启动。也可以只构建：

```bash
./scripts/build-app.sh && open "dist/Claude Switch.app"
```

## 使用

1. 打开 Claude Switch，在主窗口顶部查看当前生效的 Provider、鉴权和模型映射。
2. 选择「自定义 API」或「Anthropic 官方」，填写地址、鉴权、密钥和可选的
   Fable/Opus/Sonnet/Haiku 模型 ID。官方 API Key 可以留空，此时沿用 Claude Code
   的登录/订阅。
3. 在「切换范围」中决定是否勾选「同时切换 Claude Desktop，并自动重启」。
4. 点击窗口底部的「保存并切换」按钮；之后也可以通过菜单栏循环箭头快速切换。
5. CLI 或 IDE 中新开一个 Claude Code 会话，或在原项目目录运行 `claude --continue`
   继续最近的对话。

切换对新启动的 Claude Code 进程生效；已经运行的 CLI / IDE 会话通常仍使用启动时读取
的环境变量。Claude Desktop 的配置只在启动时读取，因此勾选同步后应用会自动退出并重新
打开 Desktop；若 Desktop 当时未运行，则下次启动生效。

## 为什么对话记录不会丢

Claude Code 默认把设置、凭据、会话历史和插件放在同一个 `~/.claude` 配置目录。
Claude Switch 始终复用这个目录，只原子更新 `~/.claude/settings.json` 的 `env`
节点中与 API 供应商有关的字段。因此 `claude --continue` 和 `claude --resume`
仍能看到切换前的对话。

Claude Desktop 的官方模式和第三方模式使用两个独立空间：

- 切到第三方 API 时，原来的官方 OAuth 登录和官方对话不会被覆盖或删除
- 切回官方模式时，会继续使用原来的官方登录与官方对话
- 第三方模式的对话保存在本机的独立空间；不能跨两个模式继续同一条 Desktop 对话

### 导入官方会话列表

Desktop 把每条对话拆成两层存储：侧边栏渲染的**索引**位于
`<数据根>/claude-code-sessions/<accountUuid>/<orgUuid>/local_*.json`，而对话
**正文**一直在 `~/.claude/projects` 里。只有索引按模式隔离，所以第三方模式的侧边栏
初始是空的——尽管所有正文都还在磁盘上。

勾选「把官方模式的会话列表导入第三方模式」后，应用会把这些索引记录复制过去，恢复
侧边栏显示，正文一个字节都不动。已归档、已删除、或正文已不存在的记录会被跳过，
避免侧边栏出现点不开的条目。

导入是刻意设计为单向的（官方 → 第三方）。官方空间带有 `pending-uploads`
上传队列，放进去的记录可能被同步到 Anthropic——经自定义网关产生的对话绝不能流入
这个空间。

自动备份位于：

```text
~/Library/Application Support/ClaudeSwitch/Backups/
~/Library/Application Support/ClaudeSwitch/Backups/ClaudeDesktop/
```

非敏感的应用配置位于：

```text
~/Library/Application Support/ClaudeSwitch/config.json
```

## Claude Desktop 兼容范围

新版 Claude Desktop 已提供第三方 API 模式。当前版本采用「直连网关」方式，自定义服务
必须原生实现 Anthropic Messages API：

- 必须支持 `POST /v1/messages`、流式响应和工具调用
- `GET /v1/models` 可选；若已填写安全的 `claude-sonnet-*`、`claude-opus-*`、
  `claude-haiku-*` 或 `claude-fable-*` 模型 ID，应用会将其写入 Desktop 模型列表
- Desktop 直连模型路由名必须采用上述 `claude-*` 前缀；GLM 等任意模型名不能直接写入
- 只提供 OpenAI `/v1/chat/completions` 或 Responses 协议的服务暂不能直接用于
  Desktop；这种服务仍可按自身兼容情况用于 Claude Code

CC Switch 对 OpenAI 协议和任意模型名的支持来自它额外运行的本地协议转换与模型路由
代理。Claude Switch 目前只实现官方 Desktop 3P 的安全直连模式，尚未内置这层代理，
因此不会把不兼容配置静默写入 Desktop。

Claude Code 与 Desktop 都需要从各自配置中读取当前密钥，因此密钥除了保存在 macOS
钥匙串，也会写入仅当前用户可读（权限 `0600`）的生效配置。持久备份会移除 Claude Code
密钥，并且不会复制包含 Desktop 密钥的 Provider 文件，避免累积旧密钥副本。

为避免默认放开任意公网访问，应用不会写入 `coworkEgressAllowedHosts=["*"]`。第三方
模式下，Desktop 的 Code / Cowork 工具默认只能访问推理端点；聊天和模型调用不受影响。

## 开发与验证

```bash
swift test
```

如果当前工具链的 SwiftPM 构建系统不可用，可以使用不依赖 SwiftPM 的验证路径：

```bash
build_dir=$(mktemp -d)
swiftc -parse-as-library -emit-module -emit-library -module-name ClaudeSwitchCore Sources/ClaudeSwitchCore/*.swift -framework Security -o "$build_dir/libClaudeSwitchCore.dylib" -emit-module-path "$build_dir/ClaudeSwitchCore.swiftmodule"
swiftc Tests/Verification/main.swift -I "$build_dir" -L "$build_dir" -lClaudeSwitchCore -o "$build_dir/verify"
DYLD_LIBRARY_PATH="$build_dir" "$build_dir/verify"
```

Claude Code 使用的配置字段来自官方文档：

- [Environment variables](https://code.claude.com/docs/en/env-vars)
- [Claude Code settings](https://code.claude.com/docs/en/configuration)
- [Model configuration](https://code.claude.com/docs/en/model-config)
- [Claude Code Desktop](https://code.claude.com/docs/en/desktop)
- [Claude Desktop on third-party overview](https://claude.com/docs/third-party/claude-desktop/overview)
- [Claude Desktop configuration reference](https://claude.com/docs/third-party/claude-desktop/configuration)
- [Claude Desktop gateway requirements](https://claude.com/docs/third-party/claude-desktop/gateway)

## 参与贡献

欢迎提 Issue 和 PR。请保持以下安全性质不被破坏：不放宽 Desktop 出网白名单、
不把会话索引导入改成双向、不把密钥写入全局可读的文件。

## 许可证

[MIT](LICENSE)
