from pathlib import Path
import json, os, subprocess, tempfile, uuid

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='quotabar-live-bridge-') as tmp:
    work = Path(tmp)
    bridge, client = work/'bridge', work/'client'
    def run(args, **kw):
        return subprocess.run([str(x) for x in args],check=True,capture_output=True,text=True,timeout=60,**kw)
    run(['swiftc','-O','-suppress-warnings','-D','BRIDGE_TESTING',root/'CredentialAgent/LiveBridge.swift','-o',bridge])
    run(['swiftc','-O','-parse-as-library',root/'tests/LiveBridgeClient.swift','-o',client])
    run(['codesign','--sign','-','--identifier','dev.rebon.quotabar.bridge.tests',bridge])
    run(['codesign','--sign','-','--identifier','dev.rebon.quotabar.tests',client])
    env = dict(os.environ,QUOTABAR_TEST_PARENT=str(client),QUOTABAR_TEST_BRIDGE=str(bridge),
               QUOTABAR_TEST_LIVE_SERVICE='dev.rebon.quotabar.bridge.tests.'+str(uuid.uuid4()))
    denied = subprocess.run([str(bridge)],input='{"operation":"read"}',env=env,capture_output=True,text=True,timeout=5)
    assert json.loads(denied.stdout)['error'] == 'untrusted caller'
    print('PASS live bridge rejects untrusted caller before credential access')
    try:
        print(run([client],env=env).stdout.strip())
    finally:
        run([client,'--cleanup'],env=env)
