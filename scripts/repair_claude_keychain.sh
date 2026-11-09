#!/bin/bash
set -euo pipefail
# Compatibility entry point: no password prompts or manual partition edits.
python3 - <<'PYREPAIR'
import json, subprocess
from pathlib import Path
app=Path.home()/'Applications/QuotaBar.app/Contents/MacOS/QuotaBar'
r=subprocess.run([str(app),'--credential-check'],capture_output=True,text=True,check=True,timeout=12)
if json.loads(r.stdout).get('liveReadable'):
    print('Claude 凭据已可正常访问，无需再次修复。')
else:
    subprocess.run([str(app),'--repair-live-credential'],check=True,timeout=25)
PYREPAIR
