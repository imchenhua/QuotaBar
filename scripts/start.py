from pathlib import Path
import json,os,plistlib,subprocess
home=Path.home();root=Path(__file__).resolve().parents[1]
app=home/'Applications/QuotaBar.app/Contents/MacOS/QuotaBar'
probe=subprocess.run([str(app),'--credential-check'],capture_output=True,text=True,timeout=10,check=True)
check=json.loads(probe.stdout)
if not check['agentVerified'] or not check['vaultAccessible']:
    raise SystemExit('Credential readiness check failed; auto-start was not enabled.')
agent=home/'Library/LaunchAgents/dev.rebon.quotabar.plist'
label=f'gui/{os.getuid()}/dev.rebon.quotabar'
loaded=subprocess.run(['launchctl','print',label],capture_output=True)
if loaded.returncode==0: raise SystemExit('QuotaBar already loaded; no duplicate started.')
config={'Label':'dev.rebon.quotabar','ProgramArguments':[str(app)],'RunAtLoad':True,
        'KeepAlive':{'SuccessfulExit':False},'ThrottleInterval':30,'LimitLoadToSessionType':'Aqua',
        'StandardOutPath':str(home/'Library/Logs/QuotaBar/app-stdout.log'),
        'StandardErrorPath':str(home/'Library/Logs/QuotaBar/app-stderr.log')}
agent.write_bytes(plistlib.dumps(config));os.chmod(agent,0o600)
subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(agent)],check=True,capture_output=True)
record=json.loads((root/'last-install.json').read_text());record['autoStartRestored']=True
(root/'last-install.json').write_text(json.dumps(record,indent=2))
print(f"QuotaBar {record['version']} started; login auto-start restored.")
