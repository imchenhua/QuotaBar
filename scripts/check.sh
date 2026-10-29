#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/build_agent.py
swiftc -O -parse-as-library Core.swift API.swift ClaudeBarData.swift Settings.swift TokenStats.swift build/AgentIdentity.swift tests/Regression.swift -o build/regression-tests
build/regression-tests
swiftc -O -parse-as-library Core.swift API.swift ClaudeBarData.swift Settings.swift System.swift TokenStats.swift CodexUsage.swift build/AgentIdentity.swift tests/CodexRegression.swift -o build/codex-regression-tests
build/codex-regression-tests
swiftc -O -parse-as-library Core.swift API.swift ClaudeBarData.swift Settings.swift System.swift TokenStats.swift CodexUsage.swift CodexAccounts.swift build/AgentIdentity.swift tests/CodexAccountsRegression.swift -o build/codex-accounts-tests
build/codex-accounts-tests
python3 -m unittest discover -s tests -p test_importer.py
python3 tests/test_agent.py
