"""Install a reviewed build without launching it or replacing the pinned credential identity."""
from pathlib import Path
import datetime, hashlib, json, os, shutil, subprocess, plistlib
root=Path(__file__).resolve().parents[1]
home=Path.home()
source=root/'build/QuotaBar.app'
agent_source=root/'build/credential-agent-v1'
version=plistlib.loads((source/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
manifest=json.loads((root/'build/credential-agent-v1.json').read_text())
assert hashlib.sha256(agent_source.read_bytes()).hexdigest()==manifest['binarySHA256']
subprocess.run(['codesign','--verify','--deep','--strict',str(source)],check=True)
subprocess.run(['codesign','--verify','--strict',str(agent_source)],check=True)
agent_dir=home/'.local/libexec/quotabar'
agent=agent_dir/'credential-agent-v1'
if agent.exists() and hashlib.sha256(agent.read_bytes()).hexdigest()!=manifest['binarySHA256']:
    raise SystemExit('Installed credential identity differs; refusing to replace it.')
expected=str(home/'Applications/QuotaBar.app/Contents/MacOS/QuotaBar')
for line in subprocess.run(['ps','-axo','comm='],capture_output=True,text=True,check=True).stdout.splitlines():
    if line.strip()==expected: raise SystemExit('QuotaBar is still running; install stopped.')
agent_dir.mkdir(parents=True,exist_ok=True)
os.chmod(agent_dir,0o700)
if not agent.exists():
    shutil.copy2(agent_source,agent)
    shutil.copy2(root/'build/credential-agent-v1.json',agent.with_suffix('.json'))
    os.chmod(agent,0o500);os.chmod(agent.with_suffix('.json'),0o400)
profile=home/'.config/quotabar';profile.mkdir(parents=True,exist_ok=True);os.chmod(profile,0o700)
stage=home/'Applications/QuotaBar-stage.app'
if stage.exists(): raise SystemExit('Staging directory already exists; inspect it first.')
shutil.copytree(source,stage,symlinks=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(stage)],check=True)
target=home/'Applications/QuotaBar.app'
backup=root/'releases'/datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
backup.mkdir(parents=True)
if target.exists(): target.rename(backup/'QuotaBar.app')
stage.rename(target)
for name in ['quotabar-import.py']:
    shutil.copy2(root/name,home/'bin'/name);os.chmod(home/'bin'/name,0o700)
(root/'last-install.json').write_text(json.dumps({'version':version,'backup':str(backup),
    'agentSHA256':manifest['binarySHA256'],'autoStartRestored':False},indent=2))
print(f'Installed QuotaBar {version} without launching; credential identity pinned.')
