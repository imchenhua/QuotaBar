#!/usr/bin/env python3
"""Fake login command: no network, browser, user credentials, or model work."""
import json
import os
from pathlib import Path
import sys
import time

root = Path(__file__).parent
home = Path(os.environ["CODEX_HOME"])
assert sys.argv[1:] == ["login"]
assert home.parent.name == "accounts"
assert 'cli_auth_credentials_store = "file"' in (home / "config.toml").read_text()
(root / "called.json").write_text(json.dumps({"home": str(home)}))
scenario = (root / "login-scenario.txt").read_text().strip()
if scenario == "cancel":
    time.sleep(60)
elif scenario == "failure":
    sys.exit(1)
else:
    (home / "auth.json").write_text('{"fixture":true}')
