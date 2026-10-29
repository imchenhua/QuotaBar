from pathlib import Path
import os, subprocess, tempfile, json, shutil, hashlib

def main():
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='quotabar-agent-test-') as tmp:
        work = Path(tmp)
        os.chmod(work, 0o700)
        agent, client = work/'agent', work/'client'
        def run(args, **kwargs):
            return subprocess.run([str(a) for a in args],check=True,capture_output=True,text=True,timeout=45,**kwargs)
        run(['swiftc','-O','-D','VAULT_TESTING',root/'CredentialAgent/main.swift','-o',agent])
        run(['codesign','-s','-','--identifier','dev.rebon.quotabar.agent.tests',agent])
        helper_hash = hashlib.sha256(agent.read_bytes()).hexdigest()
        env = dict(os.environ,QUOTABAR_TEST_PARENT=str(client),QUOTABAR_TEST_AGENT=str(agent),QUOTABAR_TEST_LOCK=str(work/'lock'))
        run(['swiftc','-O','-parse-as-library',root/'tests/AgentClient.swift','-o',client])
        run(['codesign','-s','-','--identifier','dev.rebon.quotabar.tests',client])
        first_hash = hashlib.sha256(client.read_bytes()).hexdigest()
        # An arbitrary terminal process must not be able to use the agent as a credential reader.
        denied = subprocess.run([str(agent)],input='{"operation":"load"}',env=env,capture_output=True,text=True,timeout=5)
        assert json.loads(denied.stdout)['error'] == 'untrusted caller'
        print('PASS untrusted caller rejected before Keychain access')
        try:
            print(run([client,'write'],env=env).stdout.strip())
            run(['swiftc','-O','-D','BUILD_TWO','-parse-as-library',root/'tests/AgentClient.swift','-o',client])
            run(['codesign','-s','-','--identifier','dev.rebon.quotabar.tests',client])
            assert first_hash != hashlib.sha256(client.read_bytes()).hexdigest()
            assert helper_hash == hashlib.sha256(agent.read_bytes()).hexdigest()
            writer = work/'fixture-writer'
            run(['swiftc','-O',root/'tests/DeniedFixture.swift','-o',writer])
            run(['codesign','-s','-','--identifier','dev.rebon.quotabar.tests.fixture',writer])
            run([writer,'create'])
            try:
                print(run([client,'denied'],env=env).stdout.strip())
            finally:
                run([writer,'cleanup'])
            print(run([client,'read'],env=env).stdout.strip())
        finally:
            print(run([client,'cleanup'],env=env).stdout.strip())


if __name__ == "__main__":
    main()
