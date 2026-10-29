#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/QuotaBar.app/Contents/MacOS build/QuotaBar.app/Contents/Resources
python3 scripts/fetch_sparkle.py
mkdir -p build/QuotaBar.app/Contents/Frameworks
ditto vendor/Sparkle-2.10.1/Sparkle.framework build/QuotaBar.app/Contents/Frameworks/Sparkle.framework
# Keep the credential identity stable. Never silently rebuild or replace an existing agent.
python3 scripts/build_agent.py
swiftc -O -parse-as-library -F vendor/Sparkle-2.10.1 -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks App.swift AppUpdater.swift MenuBarLogo.swift CodexUsage.swift CodexAccounts.swift Core.swift API.swift ClaudeBarData.swift Login.swift Notify.swift Settings.swift Store.swift System.swift TokenStats.swift Views.swift build/AgentIdentity.swift -o build/QuotaBar.app/Contents/MacOS/QuotaBar
cp QuotaBar.icns build/QuotaBar.app/Contents/Resources/QuotaBar-Mint.icns
cp support/Sparkle-LICENSE build/QuotaBar.app/Contents/Resources/Sparkle-LICENSE
cp Info.plist build/QuotaBar.app/Contents/Info.plist
cp -f build/credential-agent-v1 build/credential-agent-v1.json build/QuotaBar.app/Contents/Resources/
chmod 500 build/QuotaBar.app/Contents/Resources/credential-agent-v1
codesign --force --sign - --identifier dev.rebon.quotabar build/QuotaBar.app
codesign --verify --deep --strict build/QuotaBar.app
