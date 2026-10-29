# QuotaBar

A lightweight macOS menu bar app for Claude and GPT account quotas, subscription plans, and reset countdowns.

**[Download QuotaBar (DMG)](https://github.com/imchenhua/QuotaBar/releases/latest/download/QuotaBar-arm64.dmg)** · [Releases](https://github.com/imchenhua/QuotaBar/releases) · [简体中文](README.md)

## Install

1. Download and open the DMG.
2. Double-click **Install QuotaBar**, then click **Install QuotaBar**. It installs and opens the app for you.
3. Click the Q icon in the menu bar and add your Claude or GPT accounts in Settings.

No terminal commands are needed to install the app. Signed updates are checked, downloaded, and installed automatically; change these preferences or check manually in Settings.

Requires **Apple Silicon and macOS 27 or later**. The app is locally signed and is not yet notarized by Apple. If macOS blocks it, review the app in System Settings → Privacy & Security.

## Features

- One menu bar icon, with a compact quota dashboard.
- Actual quota windows returned by each account, including 5-hour and weekly windows when available.
- Multiple Claude and GPT accounts, manual refresh, and unified diagnostics.
- System default, Simplified Chinese, or English; language changes take effect immediately.
- Account management in Settings, with navigation back to the dashboard.
- Ed25519 verification of the GitHub update feed and update archives using Sparkle.

GPT quota reading requires Codex CLI. Detecting the current Claude Code account requires Claude Code CLI. Quota checks do not start model conversations. New GPT sign-ins use isolated CLI directories and preserve your existing Codex sign-in.

The installer puts the app in `~/Applications/QuotaBar.app` and backs up an existing version. Accounts stay on your machine; account stores, credentials, and local logs are excluded from source and release packages. The fixed credential helper preserves its identity during updates to avoid repeated permission requests.

See the [development instructions](README.md#开发从源码构建) for building and publishing. Sparkle's license is included in [support/Sparkle-LICENSE](support/Sparkle-LICENSE).
