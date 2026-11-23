# Claude Switch

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](#requirements)

**English** · [简体中文](README.zh-CN.md)

A native macOS app that switches Claude Code between the official Anthropic API
and your own API endpoint or gateway, with an option to switch Claude Desktop at
the same time. Your conversation history survives the switch.

The main window shows the active provider, authentication mode, model mapping,
and switch scope. A menu bar item stays available for quick toggling.

## Features

- Configure everything in one window; flip between **Official API** and
  **Custom API** from the menu bar.
- New Claude Code CLI and IDE sessions pick up the config after you save.
- Optionally switch Claude Desktop between official and third-party API mode,
  restarting Desktop for you.
- Switching Desktop preserves your existing official login and official
  conversations; third-party mode uses a separate local record space.
- Optionally import the official session list into third-party mode, so the
  Desktop sidebar still shows earlier conversations (off by default, one-way).
- Supports both API Key and Bearer Token credential styles.
- Custom model mapping for Fable, Opus, Sonnet, and Haiku, plus advanced
  environment variables.
- Imports your existing `~/.claude/settings.json` API config on first launch.
- API keys live in the macOS Keychain; the active copy is written to a
  user-only-readable file (mode `0600`) because Claude requires it there.
- Backs up the original Claude settings before every change.
- Never touches `CLAUDE_CONFIG_DIR`, `~/.claude/projects`, `~/.claude.json`, or
  any transcript file.

## Requirements

- macOS 13 or later
- Apple Command Line Tools (`xcode-select --install`)

## Install

Download the `.zip` from the [latest release](../../releases/latest), unzip it,
and drag `Claude Switch.app` into `~/Applications` or `/Applications`.

The app is signed ad-hoc rather than notarized, so Gatekeeper will warn you the
first time. Right-click the app and choose **Open**, then confirm — or clear the
quarantine flag yourself:

```bash
xattr -dr com.apple.quarantine "$HOME/Applications/Claude Switch.app"
```

### Build from source

```bash
./scripts/install.sh
```

That builds the app, installs it to `~/Applications/Claude Switch.app`, and
launches it. To build without installing:

```bash
./scripts/build-app.sh && open "dist/Claude Switch.app"
```

## Usage

1. Open Claude Switch. The top of the window shows the active provider,
   authentication mode, and model mapping.
2. Pick **Custom API** or **Anthropic Official**. Fill in the base URL,
   authentication mode, credential, and optionally the Fable / Opus / Sonnet /
   Haiku model IDs. Leaving the official API key blank keeps using your existing
   Claude Code login or subscription.
3. To see recent official sessions in the custom provider’s Desktop **Code**
   sidebar, enable both Desktop switching and the option to show official local Code sessions.
4. Click **Save and switch**. After that, the circular-arrow menu bar item
   toggles between the two profiles.
5. Start a new Claude Code session, or run `claude --continue` in the same
   project directory to resume your most recent conversation.

Switching affects newly started Claude Code processes. Sessions that are already
running keep the environment variables they read at launch. Claude Desktop only
reads its config at startup, which is why the app quits and reopens it when you
enable Desktop switching; if Desktop is not running, the change applies next
time you open it.

## Why your conversations survive

Claude Code keeps settings, credentials, session history, and plugins in one
`~/.claude` config directory. Claude Switch always reuses that directory and only
atomically updates the provider-related fields inside the `env` block of
`~/.claude/settings.json`. That is why `claude --continue` and `claude --resume`
still find the conversations you had before switching.

Claude Desktop is different: official mode and third-party mode use two separate
spaces.

- Switching to a custom API does not overwrite or delete your official OAuth
  login or your official conversations.
- Switching back to official mode picks your official login and conversations
  right back up.
- Conversations created in third-party mode live in their own local space. You
  cannot continue the same Desktop conversation across the two modes.

### Showing official Code sessions in third-party mode

Desktop Code keeps a separate sidebar index for each account and organization.
When import is enabled, switching to the custom provider fills in missing entries
before Desktop loads its sidebar. If the custom provider is already active, enable
the option and save again.

This option covers local Code sessions with transcripts in the shared
`~/.claude/projects` directory. The importer skips archived or deleted records and
records without a shared transcript. Official Chat history is available in the
Chat tab in official mode.

The copy is deliberately one-way, official to third-party. The official space
owns `pending-uploads`, meaning records placed there can be synced to Anthropic —
so conversations produced through a custom gateway must never be pushed into it.

Backups live here:

```text
~/Library/Application Support/ClaudeSwitch/Backups/
~/Library/Application Support/ClaudeSwitch/Backups/ClaudeDesktop/
```

Non-sensitive app config lives here:

```text
~/Library/Application Support/ClaudeSwitch/config.json
```

## Claude Desktop compatibility

Recent Claude Desktop builds ship a third-party API mode. Claude Switch uses the
**direct gateway** approach, so your custom service has to implement the
Anthropic Messages API natively:

- `POST /v1/messages` with streaming and tool calls is required.
- `GET /v1/models` is optional. If you fill in safe `claude-sonnet-*`,
  `claude-opus-*`, `claude-haiku-*`, or `claude-fable-*` model IDs, the app
  writes them into the Desktop model list.
- Desktop route names must use those `claude-*` prefixes. Arbitrary names such as
  GLM model IDs cannot be written directly.
- A service that only speaks OpenAI's `/v1/chat/completions` or Responses API
  cannot be used with Desktop yet. It may still work with Claude Code depending
  on its own compatibility.

Tools like CC Switch support OpenAI-protocol and arbitrary model names by running
an extra local translation and routing proxy. Claude Switch does not bundle that
layer yet, so rather than silently writing an incompatible config into Desktop,
it declines to write one.

Both Claude Code and Desktop read the current credential from their own config,
so besides the Keychain copy, the key is written to a user-only-readable (`0600`)
active config. Persistent backups strip the Claude Code credential and skip
provider files containing Desktop credentials, so old key copies do not pile up.

To avoid opening up arbitrary outbound network access, the app never writes
`coworkEgressAllowedHosts=["*"]`. In third-party mode, Desktop's Code and Cowork
tools reach only the inference endpoint by default; chat and model calls are
unaffected.

## Development

```bash
swift test
```

If SwiftPM's build system is unavailable in your toolchain, there is a
SwiftPM-free verification path:

```bash
build_dir=$(mktemp -d)
swiftc -parse-as-library -emit-module -emit-library -module-name ClaudeSwitchCore Sources/ClaudeSwitchCore/*.swift -framework Security -o "$build_dir/libClaudeSwitchCore.dylib" -emit-module-path "$build_dir/ClaudeSwitchCore.swiftmodule"
swiftc Tests/Verification/main.swift -I "$build_dir" -L "$build_dir" -lClaudeSwitchCore -o "$build_dir/verify"
DYLD_LIBRARY_PATH="$build_dir" "$build_dir/verify"
```

The Claude Code configuration fields come from the official docs:

- [Environment variables](https://code.claude.com/docs/en/env-vars)
- [Claude Code settings](https://code.claude.com/docs/en/configuration)
- [Model configuration](https://code.claude.com/docs/en/model-config)
- [Claude Code Desktop](https://code.claude.com/docs/en/desktop)
- [Claude Desktop on third-party overview](https://claude.com/docs/third-party/claude-desktop/overview)
- [Claude Desktop configuration reference](https://claude.com/docs/third-party/claude-desktop/configuration)
- [Claude Desktop gateway requirements](https://claude.com/docs/third-party/claude-desktop/gateway)

## Contributing

Issues and pull requests are welcome. Please keep the safety properties intact:
never widen the Desktop egress allowlist, never make the session index copy
bidirectional, and never write credentials into a world-readable file.

## License

[MIT](LICENSE)


